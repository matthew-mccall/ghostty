import AppKit

/// A logical tab collection. Callers need not know whether tabs are AppKit
/// windows or sessions inside a sidebar window.
protocol TerminalTabContainer: AnyObject {
    var controllers: [BaseTerminalController] { get }
    var selectedController: BaseTerminalController? { get }
    func select(_ controller: BaseTerminalController)
}

final class NativeTerminalTabContainer: TerminalTabContainer {
    weak var owner: TerminalController?

    init(_ owner: TerminalController) { self.owner = owner }

    var controllers: [BaseTerminalController] {
        guard let window = owner?.window else { return [] }
        return (window.tabGroup?.windows ?? [window]).compactMap { $0.windowController as? BaseTerminalController }
    }

    var selectedController: BaseTerminalController? {
        owner?.window?.tabGroup?.selectedWindow?.windowController as? BaseTerminalController ?? owner
    }

    func select(_ controller: BaseTerminalController) {
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

extension BaseTerminalController {
    var terminalWindowController: TerminalController? {
        (self as? TerminalController) ?? (self as? TerminalTabSessionController)?.host
    }

    var logicalTabID: String {
        if let session = self as? TerminalTabSessionController { return session.id.uuidString }
        return ObjectIdentifier(self).hexString
    }
}
