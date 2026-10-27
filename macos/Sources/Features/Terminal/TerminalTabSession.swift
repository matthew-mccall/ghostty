import AppKit
import Combine
import SwiftUI

/// Owns a session and its existing hosting view. The controller deliberately
/// has only a weak reference back here, avoiding a model/hosting-view cycle.
final class TerminalTabSession {
    let controller: TerminalTabSessionController
    let content: TerminalViewContainer
    var isRestorable: Bool

    init(_ ghostty: Ghostty.App, host: TerminalController?, id: UUID = UUID(),
         baseConfig: Ghostty.SurfaceConfiguration? = nil,
         tree: SplitTree<Ghostty.SurfaceView>? = nil) {
        let model = TerminalTabSessionController(ghostty, id: id, tree: tree, baseConfig: baseConfig)
        controller = model
        isRestorable = (baseConfig?.command ?? "").isEmpty
        content = TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: model, delegate: model)
        }
        controller.session = self
        controller.host = host
        content.initialContentSize = controller.focusedSurface?.initialSize
    }
}

/// Per-tab split and event handling, independent of the physical window's
/// controller. Inactive tabs remain registered owners of their terminals.
class TerminalTabSessionController: BaseTerminalController {
    let id: UUID
    weak var host: TerminalController?
    weak var session: TerminalTabSession?
    var tabColor: TerminalTabColor = .none { didSet { sessionStateDidChange() } }
    private var appearanceObservers: Set<AnyCancellable> = []
    private var surfaceAppearanceObservers: Set<AnyCancellable> = []

    override var window: NSWindow? {
        get { host?.window }
        set { super.window = newValue }
    }

    override var surfaceTreeIsVisible: Bool {
        host?.verticalTabs?.selectedController === self && (host?.window?.occlusionState.contains(.visible) ?? false)
    }

    var tabTitle: String { titleOverride ?? focusedSurface?.title ?? surfaceTree.root?.leftmostLeaf().title ?? "Ghostty" }

    init(_ ghostty: Ghostty.App, id: UUID,
         tree: SplitTree<Ghostty.SurfaceView>? = nil,
         baseConfig: Ghostty.SurfaceConfiguration? = nil) {
        self.id = id
        super.init(ghostty, baseConfig: baseConfig, surfaceTree: tree)
        focusedSurfaceDidChange(to: surfaceTree.root?.leftmostLeaf())
        observeSurfaceAppearance()
        $bell.dropFirst().sink { [weak self] _ in self?.sessionStateDidChange() }.store(in: &appearanceObservers)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func sessionStateDidChange() {
        host?.verticalTabs?.sessionDidChange(self)
    }

    override func applyTitleToWindow() { sessionStateDidChange() }

    override func pwdDidChange(to: URL?) {
        if host?.verticalTabs?.selectedController === self { super.pwdDidChange(to: to) }
    }

    override func cellSizeDidChange(to: NSSize) {
        if host?.verticalTabs?.selectedController === self { super.cellSizeDidChange(to: to) }
    }

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)
        sessionStateDidChange()
    }

    private func observeSurfaceAppearance() {
        surfaceAppearanceObservers.removeAll()
        for surface in surfaceTree {
            surface.$backgroundColor.dropFirst().sink { [weak self] _ in self?.sessionStateDidChange() }.store(in: &surfaceAppearanceObservers)
            surface.$derivedConfig.dropFirst().sink { [weak self] _ in self?.sessionStateDidChange() }.store(in: &surfaceAppearanceObservers)
        }
    }

    override func focusSurface(_ view: Ghostty.SurfaceView) {
        host?.verticalTabs?.select(self)
        super.focusSurface(view)
    }

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)
        observeSurfaceAppearance()
        if to.isEmpty { host?.verticalTabs?.close(id, subtree: false, confirm: false) }
    }

    override func closeSurface(_ node: SplitTree<Ghostty.SurfaceView>.Node, withConfirmation: Bool = true) {
        if surfaceTree.root == node {
            host?.verticalTabs?.close(id, subtree: false, confirm: withConfirmation)
        } else {
            super.closeSurface(node, withConfirmation: withConfirmation)
        }
    }

    override func replaceSurfaceTree(_ newTree: SplitTree<Ghostty.SurfaceView>,
                                     moveFocusTo newView: Ghostty.SurfaceView? = nil,
                                     moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
                                     undoAction: String? = nil) {
        if newTree.isEmpty {
            host?.verticalTabs?.close(id, subtree: false, confirm: false)
        } else {
            super.replaceSurfaceTree(newTree, moveFocusTo: newView, moveFocusFrom: oldView, undoAction: undoAction)
        }
    }

    override func closeWindow(_ sender: Any?) { host?.closeWindow(sender) }

    override func toggleFullscreen(mode: FullscreenMode) { host?.toggleFullscreen(mode: .native) }

    override func syncAppearance() { sessionStateDidChange() }
}
