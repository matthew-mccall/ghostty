import AppKit

/// A public transfer path for both native tabs and sidebar subtrees.
final class TerminalTabMoveMenu: NSMenu, NSMenuDelegate {
    weak var source: TerminalController?
    var sourceID: UUID?

    init(source: TerminalController? = nil, id: UUID? = nil) {
        self.source = source
        sourceID = id
        super.init(title: "Move Tab to Window")
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        guard let source = source ?? NSApp.keyWindow?.windowController as? TerminalController else { return }
        var groups: Set<ObjectIdentifier> = []
        for destination in TerminalController.all where destination !== source {
            guard let window = destination.window else { continue }
            if destination.verticalTabs == nil {
                guard source.verticalTabs != nil || source.window?.tabGroup !== window.tabGroup else { continue }
                if let group = window.tabGroup, !groups.insert(ObjectIdentifier(group)).inserted { continue }
            }
            let item = NSMenuItem(title: window.title, action: #selector(moveTab(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Destination(source: source, target: destination, id: sourceID)
            addItem(item)
        }
        if items.isEmpty {
            let item = NSMenuItem(title: "No Other Windows", action: nil, keyEquivalent: "")
            item.isEnabled = false
            addItem(item)
        }
    }

    private final class Destination {
        weak var source: TerminalController?
        weak var target: TerminalController?
        let id: UUID?
        init(source: TerminalController, target: TerminalController, id: UUID?) {
            self.source = source; self.target = target; self.id = id
        }
    }

    @objc private func moveTab(_ item: NSMenuItem) {
        guard let destination = item.representedObject as? Destination,
              let source = destination.source, let target = destination.target else { return }
        if let tabs = source.verticalTabs, let id = destination.id ?? tabs.tree.selectedID {
            if let other = target.verticalTabs {
                _ = other.transfer(from: tabs, id: id, to: .init(parent: nil, index: other.tree.roots.count))
            } else { tabs.flatten(id, into: target) }
        } else if let tabs = target.verticalTabs {
            _ = tabs.importTab(source)
        } else if let window = source.window {
            target.window?.addTabbedWindowSafely(window, ordered: .above)
            source.showWindow(nil)
        }
    }
}

extension TerminalController {
    func moveTabMenuItem(sourceID: UUID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "Move Tab to Window", action: nil, keyEquivalent: "")
        item.submenu = TerminalTabMoveMenu(source: self, id: sourceID)
        return item
    }
}

/// Native horizontal tabs can be dragged using this public titlebar accessory.
/// AppKit's own tab-strip drag payload is private and is deliberately not used.
final class TerminalTabDragHandle: NSView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("com.mitchellh.ghostty.native-terminal-tab")

    override func draw(_ dirtyRect: NSRect) {
        NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)?
            .draw(in: bounds.insetBy(dx: 4, dy: 4))
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let data = NSPasteboardItem()
        data.setString(String(window.windowNumber), forType: Self.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: data)
        item.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    static func controller(from info: NSDraggingInfo) -> TerminalController? {
        guard let raw = info.draggingPasteboard.string(forType: pasteboardType), let number = Int(raw),
              let controller = NSApp.window(withWindowNumber: number)?.windowController as? TerminalController,
              controller.verticalTabs == nil else { return nil }
        return controller
    }
}
