import AppKit
import GhosttyKit

/// A native AppKit sidebar and a single terminal column. Tab sessions own their
/// views, so selecting and moving rows never rebuilds a terminal or its PTY.
final class VerticalTabContainerController: NSSplitViewController, TerminalTabContainer,
                                            NSOutlineViewDataSource, NSOutlineViewDelegate,
                                            NSToolbarDelegate, NSMenuDelegate {
    typealias Tree = TerminalTabTree<TerminalTabSession>
    typealias Node = Tree.Node
    static let pasteboardType = NSPasteboard.PasteboardType("com.mitchellh.ghostty.tab-subtree")
    private static let instances = NSMapTable<NSString, VerticalTabContainerController>.strongToWeakObjects()
    let instanceID = UUID()
    let owner: TerminalController
    let tree: Tree
    let outline = TabOutlineView()
    private let terminalColumn = NSViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private var presentedID: UUID?
    private var updating = false
    private var refreshQueued = false
    private var collapsing = false
    private var draggedID: UUID?
    private var contextID: UUID?

    var controllers: [BaseTerminalController] { tree.preorder.map { $0.value.controller } }
    var selectedSession: TerminalTabSession? { tree.selected?.value }
    var selectedController: BaseTerminalController? { selectedSession?.controller }
    var sidebarWidth: CGFloat { splitView.subviews.first?.frame.width ?? 240 }
    var sidebarHidden: Bool { sidebarItem?.isCollapsed ?? false }

    init(owner: TerminalController, initialTree: SplitTree<Ghostty.SurfaceView>, restorable: Bool) {
        self.owner = owner
        let session = TerminalTabSession(owner.ghostty, host: nil, tree: initialTree)
        session.isRestorable = restorable
        tree = Tree(roots: [Node(id: session.controller.id, value: session)])
        super.init(nibName: nil, bundle: nil)
        session.controller.host = owner
        Self.instances.setObject(self, forKey: instanceID.uuidString as NSString)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .default
        outline.allowsMultipleSelection = false
        outline.indentationPerLevel = 16
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.minWidth = 180
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clickedRow)
        outline.doubleAction = #selector(renameTab)
        outline.setAccessibilityLabel("Terminal tabs")
        outline.registerForDraggedTypes([Self.pasteboardType, TerminalTabDragHandle.pasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.focusTerminal = { [weak self] in self?.focusTerminal() }
        outline.closeItem = { [weak self] item in
            guard let node = item as? Node else { return }
            self?.close(node.id, subtree: false)
        }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        let sidebar = NSViewController()
        sidebar.view = scroll
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.preferredThicknessFraction = 0.24
        sidebarItem.allowsFullHeightLayout = true
        addSplitViewItem(sidebarItem)
        terminalColumn.view = NSView()
        terminalColumn.view.wantsLayer = true
        let content = NSSplitViewItem(viewController: terminalColumn)
        content.allowsFullHeightLayout = true
        addSplitViewItem(content)
        refreshSelection(focus: false)
    }

    func installToolbar() {
        let toolbar = NSToolbar(identifier: "VerticalTabToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        owner.window?.toolbar = toolbar
        owner.window?.toolbarStyle = .unified
        owner.window?.registerForDraggedTypes([Self.pasteboardType])
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .sidebarTrackingSeparator {
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 0)
        }
        guard identifier == .toggleSidebar else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Toggle Sidebar"
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
        item.action = #selector(toggleSidebar(_:))
        item.isNavigational = true
        item.isBordered = true
        item.target = self
        return item
    }

    override func toggleSidebar(_ sender: Any?) {
        super.toggleSidebar(sender)
        owner.invalidateRestorableState()
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        if !updating { owner.invalidateRestorableState() }
    }

    func select(_ controller: BaseTerminalController) {
        guard let session = controller as? TerminalTabSessionController, tree.node(session.id) != nil else { return }
        tree.select(session.id)
        refreshSelection(focus: true)
    }

    func refreshSelection(focus: Bool) {
        guard isViewLoaded, !updating else { return }
        updating = true
        defer { updating = false }
        guard let node = tree.selected else { return }
        let session = node.value
        if presentedID != node.id {
            terminalColumn.view.subviews.forEach { $0.removeFromSuperview() }
            let content = session.content
            content.translatesAutoresizingMaskIntoConstraints = false
            terminalColumn.view.addSubview(content)
            let safe = terminalColumn.view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                content.topAnchor.constraint(equalTo: safe.topAnchor),
                content.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            ])
            presentedID = node.id
        }
        owner.surfaceTree = session.controller.surfaceTree
        if owner.focusedSurface !== session.controller.focusedSurface {
            owner.focusedSurfaceDidChange(to: session.controller.focusedSurface)
        }
        owner.window?.title = session.controller.tabTitle
        (owner.window as? TerminalWindow)?.tabColor = session.controller.tabColor
        owner.syncAppearance()
        if let color = (owner.window as? TerminalWindow)?.preferredBackgroundColor {
            // This backdrop extends through the transparent terminal header.
            // The sidebar's system-owned glass is left untouched.
            terminalColumn.view.layer?.backgroundColor = color.withAlphaComponent(1).cgColor
            owner.window?.backgroundColor = color.withAlphaComponent(1)
        }
        owner.window?.titlebarAppearsTransparent = true
        owner.window?.titlebarSeparatorStyle = .none
        reloadOutline()
        controllers.forEach { $0.syncSurfaceTreeOcclusionState(); $0.syncFocusToSurfaceTree() }
        owner.syncRestoration(owner.ghostty.config)
        owner.invalidateRestorableState()
        if focus { DispatchQueue.main.async { [weak self] in self?.focusTerminal() } }
    }

    func focusTerminal() {
        guard let view = selectedController?.focusedSurface else { return }
        Ghostty.moveFocus(to: view)
    }

    func sessionDidChange(_ controller: TerminalTabSessionController) {
        guard !updating, tree.node(controller.id) != nil, !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refreshSelection(focus: false)
        }
    }

    @discardableResult
    func newTab(baseConfig: Ghostty.SurfaceConfiguration? = nil, child: Bool,
                relativeTo sourceID: UUID? = nil) -> BaseTerminalController {
        let source = sourceID.flatMap(tree.node) ?? tree.selected
        let inherited = baseConfig ?? source?.value.controller.focusedSurface?.surface.map {
            Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config($0, GHOSTTY_SURFACE_CONTEXT_TAB))
        }
        let session = TerminalTabSession(owner.ghostty, host: owner, baseConfig: inherited)
        let node = Node(id: session.controller.id, value: session)
        mutate("New Tab") {
            let position: Tree.Position
            if child, let source {
                position = .init(parent: source.id, index: source.children.count)
                source.isExpanded = true
            } else if let source, let current = tree.position(of: source.id) {
                let index = owner.ghostty.config.windowNewTabPosition == "end" ? tree.siblings(of: source.id).count : current.index + 1
                position = .init(parent: current.parent, index: index)
            } else { position = .init(parent: nil, index: tree.roots.count) }
            _ = tree.insert(node, at: position)
            tree.select(node.id)
        }
        return session.controller
    }

    func gotoTab(_ direction: ghostty_action_goto_tab_e) {
        let nodes = tree.preorder
        guard !nodes.isEmpty else { return }
        let current = nodes.firstIndex { $0.id == tree.selectedID } ?? 0
        let index: Int
        switch direction {
        case GHOSTTY_GOTO_TAB_PREVIOUS: index = (current + nodes.count - 1) % nodes.count
        case GHOSTTY_GOTO_TAB_NEXT: index = (current + 1) % nodes.count
        case GHOSTTY_GOTO_TAB_LAST: index = nodes.count - 1
        default: index = min(max(Int(direction.rawValue) - 1, 0), nodes.count - 1)
        }
        tree.select(nodes[index].id)
        refreshSelection(focus: true)
    }

    func move(_ id: UUID, amount: Int) {
        guard let position = tree.position(of: id) else { return }
        let siblings = tree.siblings(of: id)
        guard siblings.count > 1 else { return }
        let next = ((position.index + amount) % siblings.count + siblings.count) % siblings.count
        mutate("Move Tab") {
            _ = tree.move(id, to: .init(parent: position.parent, index: next > position.index ? next + 1 : next))
        }
    }

    func perform(_ action: String, on id: UUID? = nil) -> Bool {
        guard let id = id ?? tree.selectedID, tree.node(id) != nil else { return false }
        switch action {
        case "new_child_tab": _ = newTab(child: true, relativeTo: id)
        case "indent_tab":
            guard (tree.position(of: id)?.index ?? 0) > 0 else { return false }
            mutate("Indent Tab") { _ = tree.indent(id) }
        case "outdent_tab":
            guard tree.position(of: id)?.parent != nil else { return false }
            mutate("Outdent Tab") { _ = tree.outdent(id) }
        case "close_tab_subtree": close(id, subtree: true)
        case "toggle_tab_sidebar": toggleSidebar(nil)
        default: return false
        }
        return true
    }

    func close(_ id: UUID, subtree: Bool, confirm: Bool = true) {
        guard let node = tree.node(id) else { return }
        let closing = subtree ? node.preorder : [node]
        let completion = { [weak self] in
            guard let self, self.tree.node(id) != nil else { return }
            if closing.count == self.tree.preorder.count { self.closeWindow(confirm: false); return }
            self.mutate(subtree ? "Close Tab Subtree" : "Close Tab") {
                _ = self.tree.remove(id, subtree: subtree)
                for tab in closing {
                    tab.value.content.removeFromSuperview()
                    tab.value.controller.syncSurfaceTreeOcclusionState()
                    tab.value.controller.syncFocusToSurfaceTree()
                    tab.value.controller.host = nil
                }
            }
        }
        if confirm && closing.contains(where: { $0.value.controller.surfaceTree.contains(where: { $0.needsConfirmQuit }) }) {
            owner.confirmClose(messageText: subtree ? "Close Tab Subtree?" : "Close Tab?",
                               informativeText: "Running processes in the selected tabs will be terminated.", completion: completion)
        } else { completion() }
    }

    func closeOthers(toRight: Bool, relativeTo sourceID: UUID? = nil) {
        let ids = tree.preorder.map(\.id)
        guard let selected = sourceID ?? tree.selectedID, let index = ids.firstIndex(of: selected) else { return }
        let closing = toRight ? Array(ids.dropFirst(index + 1)) : ids.filter { $0 != selected }
        guard !closing.isEmpty else { return }
        let completion = { [weak self] in
            guard let self else { return }
            self.mutate(toRight ? "Close Tabs on the Right" : "Close Other Tabs") {
                for id in closing {
                    if let node = self.tree.remove(id, subtree: false) { node.value.controller.host = nil }
                }
            }
        }
        if closing.contains(where: { id in tree.node(id)?.value.controller.surfaceTree.contains(where: { $0.needsConfirmQuit }) ?? false }) {
            owner.confirmClose(messageText: "Close Tabs?", informativeText: "Running processes in these tabs will be terminated.", completion: completion)
        } else { completion() }
    }

    struct Snapshot {
        let roots: [Node]
        let selected: UUID?
        let frame: NSRect
        let width: CGFloat
        let hidden: Bool
    }

    func snapshot() -> Snapshot {
        Snapshot(roots: tree.roots.map { $0.copy() }, selected: tree.selectedID,
                 frame: owner.window?.frame ?? .zero, width: sidebarWidth, hidden: sidebarHidden)
    }

    private func mutate(_ name: String, _ operation: () -> Void) {
        let before = snapshot()
        operation()
        registerUndo(before, name: name)
        refreshSelection(focus: true)
    }

    private func registerUndo(_ snapshot: Snapshot, name: String) {
        owner.undoManager?.setActionName(name)
        owner.undoManager?.registerUndo(withTarget: owner.ghostty, expiresAfter: owner.undoExpiration) { [weak self] ghostty in
            if let self, self.owner.verticalTabs === self {
                let redo = self.snapshot()
                self.restore(snapshot)
                self.registerUndo(redo, name: name)
            } else { Self.restoreWindow(ghostty, snapshot: snapshot) }
        }
    }

    func restore(_ snapshot: Snapshot) {
        terminalColumn.view.subviews.forEach { $0.removeFromSuperview() }
        for node in tree.preorder where !snapshot.roots.flatMap(\.preorder).contains(where: { $0.id == node.id }) {
            node.value.controller.host = nil
        }
        tree.restore(roots: snapshot.roots, selectedID: snapshot.selected)
        for node in tree.preorder {
            node.value.controller.host = owner
            BaseTerminalController.updateSurfaceControllers(node.value.controller, from: .init(), to: node.value.controller.surfaceTree)
        }
        presentedID = nil
        sidebarItem.isCollapsed = snapshot.hidden
        splitView.setPosition(snapshot.width, ofDividerAt: 0)
        refreshSelection(focus: true)
    }

    @discardableResult
    static func restoreWindow(_ ghostty: Ghostty.App, snapshot: Snapshot) -> TerminalController? {
        guard let first = snapshot.roots.first else { return nil }
        let controller = TerminalController(ghostty, withSurfaceTree: first.value.controller.surfaceTree, verticalTabs: true)
        _ = controller.window
        controller.verticalTabs?.restore(snapshot)
        controller.window?.setFrame(snapshot.frame, display: false)
        controller.showWindow(nil)
        return controller
    }

    func closeWindow(confirm: Bool) {
        let completion = { [weak self] in
            guard let self else { return }
            self.registerUndo(self.snapshot(), name: "Close Window")
            self.owner.window?.close()
        }
        if confirm && controllers.contains(where: { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) }) {
            owner.confirmClose(messageText: "Close Window?", informativeText: "All terminal sessions in this window will be terminated.", completion: completion)
        } else { completion() }
    }

    func shutdown() {
        for node in tree.preorder {
            node.value.content.removeFromSuperview()
            node.value.controller.host = nil
            node.value.controller.syncSurfaceTreeOcclusionState()
            node.value.controller.syncFocusToSurfaceTree()
        }
    }

    func reloadOutline() {
        let wasUpdating = updating
        updating = true
        defer { updating = wasUpdating }
        outline.reloadData()
        for node in tree.preorder where !node.isExpanded { outline.collapseItem(node) }
        for node in tree.preorder where node.isExpanded && tree.ancestors(of: node.id).allSatisfy(\.isExpanded) {
            outline.expandItem(node)
        }
        guard let active = tree.selected else { return }
        let visible = ([active] + tree.ancestors(of: active.id)).first { outline.row(forItem: $0) >= 0 }
        if let visible { outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: visible)), byExtendingSelection: false) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? tree.roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Node)?.children ?? tree.roots)[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return !node.children.isEmpty
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        TerminalTabRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let cell = TerminalTabCellView()
        cell.isActiveTab = node.id == tree.selectedID
        let icon = NSImageView()
        let containsActive = !node.isExpanded && node.id != tree.selectedID && node.preorder.contains { $0.id == tree.selectedID }
        icon.image = NSImage(systemSymbolName: containsActive ? "circle.inset.filled" : "terminal", accessibilityDescription: containsActive ? "Contains active tab" : "Terminal")
        icon.contentTintColor = node.value.controller.tabColor.displayColor ?? .secondaryLabelColor
        let title = NSTextField(labelWithString: node.value.controller.tabTitle + (node.value.controller.bell ? " •" : ""))
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Tab")!, target: self, action: #selector(closeRow))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.imageScaling = .scaleProportionallyDown
        cell.closeButton = close
        close.identifier = .init(node.id.uuidString)
        close.setAccessibilityLabel("Close \(node.value.controller.tabTitle)")
        for view in [icon, title, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = icon
        cell.textField = title
        // AppKit indents the cell's leading edge while keeping its trailing
        // edge aligned. Reserve that edge for the close control; the title
        // fills the remaining width and truncates before the button.
        let titleLeading = title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8)
        titleLeading.priority = .defaultHigh
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            titleLeading,
            title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            close.widthAnchor.constraint(equalToConstant: 18),
            close.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel(node.value.controller.tabTitle)
        cell.setAccessibilityValue(containsActive ? "Contains active tab" : "")
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updating, !collapsing, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        tree.select(node.id)
        refreshSelection(focus: false)
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !updating, let node = notification.userInfo?["NSObject"] as? Node else { return }
        node.isExpanded = true
        owner.invalidateRestorableState()
        DispatchQueue.main.async { [weak self] in self?.refreshSelection(focus: false) }
    }
    func outlineViewItemWillCollapse(_ notification: Notification) {
        if !updating { collapsing = true }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !updating, let node = notification.userInfo?["NSObject"] as? Node else { collapsing = false; return }
        node.isExpanded = false
        DispatchQueue.main.async { [weak self] in
            self?.collapsing = false
            self?.refreshSelection(focus: false)
        }
    }

    @objc private func clickedRow() {
        guard !collapsing, let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        tree.select(node.id)
        refreshSelection(focus: true)
    }
    @objc private func closeRow(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        close(id, subtree: false)
    }
    @objc private func renameTab() {
        guard let id = contextID ?? tree.selectedID, let node = tree.node(id) else { return }
        node.value.controller.promptTabTitle()
    }
    func menuWillOpen(_ menu: NSMenu) {
        contextID = (outline.item(atRow: outline.clickedRow) as? Node)?.id ?? tree.selectedID
        menu.removeAllItems()
        for (title, action) in [("New Tab", "new_tab"), ("New Child Tab", "new_child_tab"), ("Indent", "indent_tab"), ("Outdent", "outdent_tab"), ("Close Tab", "close_tab"), ("Close Subtree", "close_tab_subtree"), ("Move to New Window", "detach")] {
            let item = NSMenuItem(title: title, action: #selector(menuAction), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "Rename Tab…", action: #selector(renameTab), keyEquivalent: ""))
        menu.items.last?.target = self
        let colors = NSMenu()
        for color in TerminalTabColor.allCases {
            let item = NSMenuItem(title: color.localizedName, action: #selector(setTabColor), keyEquivalent: "")
            item.target = self
            item.tag = color.rawValue
            colors.addItem(item)
        }
        if let contextID {
            menu.addItem(owner.moveTabMenuItem(sourceID: contextID))
        }
        let colorItem = NSMenuItem(title: "Tab Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
    }
    @objc private func setTabColor(_ item: NSMenuItem) {
        guard let id = contextID, let node = tree.node(id), let color = TerminalTabColor(rawValue: item.tag) else { return }
        node.value.controller.tabColor = color
    }
    @objc private func menuAction(_ item: NSMenuItem) {
        guard let action = item.representedObject as? String, let id = contextID else { return }
        switch action {
        case "new_tab": _ = newTab(child: false, relativeTo: id)
        case "close_tab": close(id, subtree: false)
        case "detach": detach(id)
        default: _ = perform(action, on: id)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node else { return nil }
        let data = NSPasteboardItem()
        data.setString("\(instanceID.uuidString)/\(node.id.uuidString)", forType: Self.pasteboardType)
        return data
    }
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        draggedID = (draggedItems.first as? Node)?.id
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if TerminalTabDragHandle.controller(from: info) != nil {
            // Horizontal tabs always enter as roots.
            outlineView.setDropItem(nil, dropChildIndex: tree.roots.count)
            return .move
        }
        guard let (source, id) = Self.dragSource(info), let node = source.tree.node(id) else { return [] }
        if source === self, let parent = item as? Node, node.preorder.contains(where: { $0.id == parent.id }) { return [] }
        return .move
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let controller = TerminalTabDragHandle.controller(from: info) { return importTab(controller) }
        guard let (source, id) = Self.dragSource(info) else { return false }
        let parent = item as? Node
        let position = Tree.Position(parent: parent?.id, index: index < 0 ? (parent?.children.count ?? tree.roots.count) : index)
        return transfer(from: source, id: id, to: position)
    }
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { draggedID = nil }
        guard operation.isEmpty, NSEvent.pressedMouseButtons == 0,
              NSApp.currentEvent?.keyCode != 53, let id = draggedID, tree.node(id) != nil,
              !TerminalController.all.contains(where: { $0.window?.frame.contains(screenPoint) == true }) else { return }
        detach(id, at: screenPoint)
    }
    static func dragSource(_ info: NSDraggingInfo) -> (VerticalTabContainerController, UUID)? {
        guard let raw = info.draggingPasteboard.string(forType: pasteboardType) else { return nil }
        let parts = raw.split(separator: "/")
        guard parts.count == 2, let source = instances.object(forKey: String(parts[0]) as NSString), let id = UUID(uuidString: String(parts[1])) else { return nil }
        return (source, id)
    }

    @discardableResult
    func transfer(from source: VerticalTabContainerController, id: UUID, to position: Tree.Position) -> Bool {
        if source === self {
            var moved = false
            mutate("Move Tab") { moved = tree.move(id, to: position) }
            return moved
        }
        guard let node = source.tree.node(id),
              !node.preorder.contains(where: { tree.node($0.id) != nil }), position.index >= 0 else { return false }
        if let parentID = position.parent {
            guard let parent = tree.node(parentID), position.index <= parent.children.count else { return false }
        } else if position.index > tree.roots.count { return false }
        let oldSource = source.snapshot(), oldTarget = snapshot()
        guard let detached = source.tree.remove(id, subtree: true) else { return false }
        guard tree.insert(detached, at: position) else {
            source.restore(oldSource)
            return false
        }
        node.preorder.forEach { $0.value.controller.host = owner }
        let selected = oldSource.selected.flatMap { active in node.preorder.contains(where: { $0.id == active }) ? active : nil }
        tree.select(selected ?? id)
        source.presentedID = nil
        source.refreshSelection(focus: false)
        refreshSelection(focus: true)
        owner.undoManager?.setActionName("Move Tab Between Windows")
        owner.undoManager?.registerUndo(withTarget: owner.ghostty, expiresAfter: owner.undoExpiration) { [weak source, weak self] ghostty in
            if let self { self.restore(oldTarget) } else { Self.restoreWindow(ghostty, snapshot: oldTarget) }
            if let source, source.owner.verticalTabs === source { source.restore(oldSource) } else { Self.restoreWindow(ghostty, snapshot: oldSource) }
        }
        if source.tree.roots.isEmpty { source.owner.window?.close() }
        return true
    }

    @discardableResult
    func importTab(_ source: TerminalController) -> Bool {
        guard source !== owner, source.verticalTabs == nil, !source.surfaceTree.isEmpty else { return false }
        let originalTree = source.surfaceTree
        let originalFocus = source.focusedSurface
        let originalRestorable = source.restorable
        let title = source.titleOverride
        let color = (source.window as? TerminalWindow)?.tabColor ?? .none
        let frame = source.window?.frame ?? .zero
        let session = TerminalTabSession(owner.ghostty, host: owner, tree: originalTree)
        session.isRestorable = source.restorable
        session.controller.titleOverride = title
        session.controller.tabColor = color
        session.controller.focusedSurfaceDidChange(to: originalFocus)
        let before = snapshot()
        // Emptying the old controller closes only its window. The session and
        // undo record retain the existing surfaces and PTYs.
        source.surfaceTree = .init()
        _ = tree.insert(Node(id: session.controller.id, value: session), at: .init(parent: nil, index: tree.roots.count))
        BaseTerminalController.updateSurfaceControllers(session.controller, from: .init(), to: originalTree)
        tree.select(session.controller.id)
        refreshSelection(focus: true)
        owner.undoManager?.registerUndo(withTarget: owner.ghostty, expiresAfter: owner.undoExpiration) { [weak self] ghostty in
            guard let self, self.owner.verticalTabs === self else { return }
            self.restore(before)
            let restored = TerminalController(ghostty, withSurfaceTree: originalTree, verticalTabs: false, restorable: originalRestorable)
            restored.titleOverride = title
            restored.focusedSurfaceDidChange(to: originalFocus)
            restored.window?.setFrame(frame, display: false)
            (restored.window as? TerminalWindow)?.tabColor = color
            restored.showWindow(nil)
        }
        owner.undoManager?.setActionName("Move Tab to Vertical Window")
        return true
    }

    func detach(_ id: UUID, at point: NSPoint? = nil) {
        guard let node = tree.node(id) else { return }
        let next = TerminalController(owner.ghostty, withSurfaceTree: node.value.controller.surfaceTree,
                                      restorable: node.value.isRestorable)
        _ = next.window
        if let target = next.verticalTabs {
            // Discard the placeholder session without closing the shared terminal.
            target.tree.restore(roots: [], selectedID: nil)
            _ = target.transfer(from: self, id: id, to: .init(parent: nil, index: 0))
        } else { flatten(id, into: next) }
        if let point { next.window?.setFrameTopLeftPoint(point) }
        next.showWindow(nil)
    }

    @discardableResult
    func flatten(_ id: UUID, into destination: TerminalController, showWindows: Bool = true) -> [TerminalController] {
        guard let node = tree.node(id) else { return [] }
        let before = snapshot()
        let tabs = node.preorder
        _ = tree.remove(id, subtree: true)
        var parent = destination.window
        var moved: [TerminalController] = []
        for (index, tab) in tabs.enumerated() {
            let controller: TerminalController
            if index == 0 && destination.surfaceTree.root == tab.value.controller.surfaceTree.root {
                controller = destination
            } else {
                controller = TerminalController(owner.ghostty, withSurfaceTree: tab.value.controller.surfaceTree,
                                                verticalTabs: false, restorable: tab.value.isRestorable)
            }
            tab.value.content.removeFromSuperview()
            tab.value.controller.host = nil
            controller.titleOverride = tab.value.controller.titleOverride
            (controller.window as? TerminalWindow)?.tabColor = tab.value.controller.tabColor
            if let window = controller.window, window !== parent { parent?.addTabbedWindowSafely(window, ordered: .above); parent = window }
            moved.append(controller)
        }
        if showWindows { moved.first?.showWindow(nil) }
        owner.undoManager?.setActionName("Move Tabs to Horizontal Window")
        owner.undoManager?.registerUndo(withTarget: owner.ghostty, expiresAfter: owner.undoExpiration) { [weak self] ghostty in
            moved.forEach { $0.surfaceTree = .init() }
            if let self, self.owner.verticalTabs === self { self.restore(before) } else { Self.restoreWindow(ghostty, snapshot: before) }
        }
        presentedID = nil
        if tree.roots.isEmpty { owner.window?.close() } else { refreshSelection(focus: false) }
        return moved
    }
}

/// Hiding the control leaves its constraints in place, so titles and close
/// buttons keep the same alignment when selection or hover changes.
private final class TerminalTabCellView: NSTableCellView {
    weak var closeButton: NSButton? { didSet { updateCloseButton() } }
    var isActiveTab = false { didSet { updateCloseButton() } }
    var isHovered = false { didSet { updateCloseButton() } }

    private func updateCloseButton() {
        guard let closeButton else { return }
        let hidden = !isActiveTab && !isHovered
        if closeButton.isHidden != hidden { closeButton.isHidden = hidden }
    }
}

/// Track the complete native row, including its disclosure and indentation area.
private final class TerminalTabRowView: NSTableRowView {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            if isHovered != oldValue { (view(atColumn: 0) as? TerminalTabCellView)?.isHovered = isHovered }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        updateHoverFromPointer()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? TerminalTabCellView)?.isHovered = isHovered
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHoverFromPointer()
    }

    override func layout() {
        super.layout()
        updateHoverFromPointer()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func updateHoverFromPointer() {
        guard let window, window.isVisible else { isHovered = false; return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isHovered = bounds.contains(point) && visibleRect.contains(point)
    }
}

final class TabOutlineView: NSOutlineView {
    var focusTerminal: (() -> Void)?
    var closeItem: ((AnyObject) -> Void)?
    private var middleClickItem: AnyObject?

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        middleClickItem = item(at: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        defer { middleClickItem = nil }
        guard let pressed = middleClickItem, let released = item(at: event), pressed === released else { return }
        closeItem?(pressed)
    }

    private func item(at event: NSEvent) -> AnyObject? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0, let item = item(atRow: index) else { return nil }
        return item as AnyObject
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 53 { focusTerminal?(); return }
        super.keyDown(with: event)
    }
}
