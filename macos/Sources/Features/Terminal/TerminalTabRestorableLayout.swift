import AppKit

/// Version 8 window state. Each record retains the same per-terminal codec used
/// by legacy windows; only the owning tab hierarchy is new.
struct TerminalTabRestorableLayout<ViewType: NSView & Codable & Identifiable>: Codable {
    struct Tab: Codable {
        let id: UUID
        let surfaceTree: SplitTree<ViewType>
        let focusedSurface: String?
        let titleOverride: String?
        let tabColor: TerminalTabColor?
        let expanded: Bool
        let children: [Tab]
        var preorder: [Tab] { [self] + children.flatMap(\.preorder) }
    }
    let roots: [Tab]
    let selected: UUID?
    let sidebarWidth: Double
    let sidebarHidden: Bool
    var preorder: [Tab] { roots.flatMap(\.preorder) }
}

extension VerticalTabContainerController {
    typealias SavedLayout = TerminalTabRestorableLayout<Ghostty.SurfaceView>

    func restorableLayout() -> SavedLayout {
        func save(_ nodes: [Node]) -> [SavedLayout.Tab] {
            nodes.flatMap { node -> [SavedLayout.Tab] in
                let children = save(node.children)
                let session = node.value
                // A custom-command tab must not make ordinary child tabs vanish.
                guard session.isRestorable else { return children }
                return [.init(id: node.id, surfaceTree: session.controller.surfaceTree,
                              focusedSurface: session.controller.focusedSurface?.id.uuidString,
                              titleOverride: session.controller.titleOverride, tabColor: session.controller.tabColor,
                              expanded: node.isExpanded, children: children)]
            }
        }
        return SavedLayout(roots: save(tree.roots), selected: tree.selectedID,
                           sidebarWidth: Double(sidebarWidth), sidebarHidden: sidebarHidden)
    }

    func restoreLayout(_ layout: SavedLayout) {
        var used: Set<UUID> = []
        func restore(_ tabs: [SavedLayout.Tab]) -> [Node] {
            tabs.flatMap { record -> [Node] in
                let children = restore(record.children)
                guard used.insert(record.id).inserted, !record.surfaceTree.isEmpty else { return children }
                let session = TerminalTabSession(owner.ghostty, host: owner, id: record.id, tree: record.surfaceTree)
                session.controller.titleOverride = record.titleOverride
                session.controller.tabColor = record.tabColor ?? .none
                if let focused = record.focusedSurface,
                   let surface = record.surfaceTree.first(where: { $0.id.uuidString == focused }) {
                    session.controller.focusedSurfaceDidChange(to: surface)
                }
                return [Node(id: record.id, value: session, children: children, isExpanded: record.expanded)]
            }
        }
        let roots = restore(layout.roots)
        guard !roots.isEmpty else { return }
        let width = layout.sidebarWidth.isFinite ? min(max(layout.sidebarWidth, 120), 1000) : 240
        self.restore(Snapshot(roots: roots, selected: layout.selected,
                              frame: owner.window?.frame ?? .zero,
                              width: width, hidden: layout.sidebarHidden))
    }
}
