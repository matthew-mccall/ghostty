import AppKit

extension TerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // MARK: - Version 8
        var verticalTabs: TerminalTabRestorableLayout<ViewType>?
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: TerminalController) {
        let layout = controller.verticalTabs?.restorableLayout()
        self.init(
            focusedSurface: layout == nil ? controller.focusedSurface?.id.uuidString : nil,
            // The hierarchy already encodes each eligible terminal exactly once.
            // A mirrored legacy tree would decode a second, unused PTY and could
            // also restore a custom-command tab excluded from the hierarchy.
            surfaceTree: layout == nil ? controller.surfaceTree : .init(),
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: controller.titleOverride,
            verticalTabs: layout,
        )
    }
}
