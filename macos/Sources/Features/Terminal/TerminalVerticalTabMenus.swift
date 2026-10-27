import AppKit

extension TerminalController {
    private static var verticalTabMenuItems: [NSMenuItem] = []
    private static var moveTabItem: NSMenuItem?

    static func updateVerticalTabMenus(enabled: Bool) {
        if enabled && verticalTabMenuItems.isEmpty {
            func findNewTab(in menu: NSMenu) -> (NSMenu, Int)? {
                for (index, item) in menu.items.enumerated() {
                    if item.action == #selector(newTab(_:)) { return (menu, index) }
                    if let submenu = item.submenu, let found = findNewTab(in: submenu) { return found }
                }
                return nil
            }
            guard let main = NSApp.mainMenu, let (menu, index) = findNewTab(in: main) else { return }
            let actions: [(String, Selector)] = [
                ("New Child Tab", #selector(newChildTab(_:))),
                ("Indent Tab", #selector(indentTab(_:))),
                ("Outdent Tab", #selector(outdentTab(_:))),
                ("Close Tab Subtree", #selector(closeTabSubtree(_:))),
                ("Toggle Tab Sidebar", #selector(toggleTabSidebar(_:))),
            ]
            for (offset, entry) in actions.enumerated() {
                let item = NSMenuItem(title: entry.0, action: entry.1, keyEquivalent: "")
                menu.insertItem(item, at: index + offset + 1)
                verticalTabMenuItems.append(item)
            }
        }
        verticalTabMenuItems.forEach { $0.isHidden = !enabled }
        let hasVertical = enabled || all.contains { $0.verticalTabs != nil }
        if hasVertical, moveTabItem == nil, let menu = verticalTabMenuItems.first?.menu {
            let item = NSMenuItem(title: "Move Tab to Window", action: nil, keyEquivalent: "")
            item.submenu = TerminalTabMoveMenu()
            menu.addItem(item)
            moveTabItem = item
        }
        moveTabItem?.isHidden = !hasVertical
        all.forEach { $0.updateTabDragHandle(enabled: hasVertical) }
    }
}
