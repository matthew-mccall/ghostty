import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor
@Suite(.serialized)
struct VerticalTabSessionTests {
    // AppKit can autorelease terminal views after a test returns. Keep their
    // libghostty application alive for the lifetime of the test process.
    private static var application: Ghostty.App?

    private func makeHost() throws -> TerminalController {
        let app: Ghostty.App
        if let existing = Self.application { app = existing } else {
            let configuration = try TemporaryConfig("initial-window = false\nwindow-save-state = never\nmacos-vertical-tabs = true")
            app = Ghostty.App(configPath: configuration.temporaryFile.path)
            Self.application = app
        }
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/usr/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: base, verticalTabs: true)
        _ = controller.window
        // Windows stay hidden throughout the tests. Place them before any
        // rendering on the current non-primary display when one is available.
        let primary = CGMainDisplayID()
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value != primary
        }) { controller.window?.setFrameOrigin(screen.visibleFrame.origin) }
        return controller
    }

    @Test func tabsRetainTerminalsAndOwnershipAcrossSelection() throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        defer { host.window?.close() }
        let tabs = try #require(host.verticalTabs)
        let parent = try #require(tabs.selectedController as? TerminalTabSessionController)
        let original = try #require(parent.surfaceTree.root?.leftmostLeaf())
        let child = try #require(tabs.newTab(child: true) as? TerminalTabSessionController)
        #expect(tabs.tree.position(of: child.id)?.parent == parent.id)
        #expect(BaseTerminalController.controller(owning: original) === parent)
        tabs.select(parent)
        tabs.select(child)
        tabs.select(parent)
        #expect(parent.surfaceTree.root?.leftmostLeaf() === original)
        #expect(host.surfaceTree.root?.leftmostLeaf() === original)
        #expect(tabs.controllers.count == 2)
        #expect(host.window?.tabbingMode == .disallowed)
        #expect(!child.surfaceTreeIsVisible)
        #expect(!parent.surfaceTreeIsVisible) // hidden test window
    }

    @Test func parentClosePromotesLiveChildAndPreservesControllerIdentity() throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        defer { host.window?.close() }
        let tabs = try #require(host.verticalTabs)
        let parent = try #require(tabs.selectedController as? TerminalTabSessionController)
        let child = try #require(tabs.newTab(child: true) as? TerminalTabSessionController)
        tabs.close(parent.id, subtree: false, confirm: false)
        #expect(tabs.controllers.count == 1)
        #expect(tabs.selectedController === child)
        #expect(tabs.tree.position(of: child.id)?.parent == nil)
        #expect(child.host === host)
    }

    @Test func restoresSessionSnapshotWithoutReplacingViews() throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        defer { host.window?.close() }
        let tabs = try #require(host.verticalTabs)
        let parent = try #require(tabs.tree.selected)
        let child = try #require(tabs.newTab(child: true) as? TerminalTabSessionController)
        let original = child.surfaceTree.root?.leftmostLeaf()
        parent.isExpanded = false
        let saved = tabs.snapshot()
        _ = tabs.perform("outdent_tab", on: child.id)
        tabs.restore(saved)
        #expect(tabs.tree.position(of: child.id)?.parent == parent.id)
        #expect(tabs.tree.node(parent.id)?.isExpanded == false)
        #expect(tabs.selectedController === child)
        #expect(child.surfaceTree.root?.leftmostLeaf() === original)
    }

    @Test func subtreeTransferRetainsViewsAndChangesOwningWindow() throws {
        guard #available(macOS 26.0, *) else { return }
        let first = try makeHost(), second = try makeHost()
        defer { first.window?.close(); second.window?.close() }
        let source = try #require(first.verticalTabs), target = try #require(second.verticalTabs)
        let parent = try #require(source.tree.selected)
        let child = try #require(source.newTab(child: true) as? TerminalTabSessionController)
        let original = try #require(child.surfaceTree.root?.leftmostLeaf())
        #expect(target.transfer(from: source, id: parent.id, to: .init(parent: nil, index: 1)))
        #expect(target.tree.preorder.contains { $0.id == child.id })
        #expect(target.tree.position(of: child.id)?.parent == parent.id)
        #expect(child.host === second)
        #expect(BaseTerminalController.controller(owning: original) === child)
    }
    @Test func inactiveSessionTitleAndTreeChangesDoNotChangeSelection() throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        defer { host.window?.close() }
        let tabs = try #require(host.verticalTabs)
        let parent = try #require(tabs.selectedController as? TerminalTabSessionController)
        let child = try #require(tabs.newTab(child: true) as? TerminalTabSessionController)
        let surface = try #require(parent.surfaceTree.root?.leftmostLeaf())
        parent.titleOverride = "Background session"
        tabs.refreshSelection(focus: false)
        #expect(tabs.selectedController === child)
        #expect(parent.tabTitle == "Background session")
        #expect(BaseTerminalController.controller(owning: surface) === parent)
        #expect(host.focusedSurface === child.focusedSurface)
    }

    @Test func nativeImportPreservesTerminalIdentity() throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        let native = TerminalController(host.ghostty, verticalTabs: false)
        _ = native.window
        defer { host.window?.close(); native.window?.close() }
        let tabs = try #require(host.verticalTabs)
        let original = try #require(native.surfaceTree.root?.leftmostLeaf())
        native.titleOverride = "Imported"
        #expect(tabs.importTab(native))
        let imported = try #require(tabs.tree.selected)
        #expect(imported.value.controller.surfaceTree.contains(original))
        #expect(tabs.tree.position(of: imported.id)?.parent == nil)
        #expect(imported.value.controller.titleOverride == "Imported")
        #expect(BaseTerminalController.controller(owning: original) === imported.value.controller)
        #expect(native.surfaceTree.isEmpty)
    }

    @Test func collapseAndNavigationIncludeHiddenDescendants() async throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        defer { host.window?.close() }
        let tabs = try #require(host.verticalTabs)
        let parent = try #require(tabs.tree.selected)
        let child = try #require(tabs.newTab(child: true) as? TerminalTabSessionController)
        tabs.outline.collapseItem(parent)
        #expect(tabs.tree.selectedID == child.id)
        #expect(!parent.isExpanded)
        tabs.outline.expandItem(parent)
        try await Task.sleep(for: .milliseconds(30))
        #expect((tabs.outline.item(atRow: tabs.outline.selectedRow) as? VerticalTabContainerController.Node)?.id == child.id)
        tabs.outline.collapseItem(parent)
        tabs.gotoTab(GHOSTTY_GOTO_TAB_PREVIOUS)
        #expect(tabs.selectedController === parent.value.controller)
        tabs.gotoTab(GHOSTTY_GOTO_TAB_NEXT)
        #expect(tabs.selectedController === child)
        #expect(parent.isExpanded)
    }

    @Test func restorationFiltersCommandsAndDoesNotDuplicateMirroredTree() throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        defer { host.window?.close() }
        let tabs = try #require(host.verticalTabs)
        let parent = try #require(tabs.tree.selected)
        let child = try #require(tabs.newTab(child: true) as? TerminalTabSessionController)
        parent.value.isRestorable = false
        tabs.tree.node(child.id)?.value.isRestorable = true
        let state = TerminalRestorableState.InternalState<Ghostty.SurfaceView>(from: host)
        #expect(state.surfaceTree.isEmpty)
        #expect(state.verticalTabs?.roots.map(\.id) == [child.id])
        #expect(state.verticalTabs?.preorder.count == 1)
    }

    @Test func modeIsFixedForExistingWindows() throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        let horizontal = TerminalController(host.ghostty, verticalTabs: false)
        _ = horizontal.window
        defer { host.window?.close(); horizontal.window?.close() }
        #expect(host.verticalTabsEnabled)
        #expect(!horizontal.verticalTabsEnabled)
        #expect(horizontal.verticalTabs == nil)
        #expect(host.verticalTabs != nil)
    }

    @Test func splitNotificationHasOneOwnerAndUpdatesInactiveSession() throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        defer { host.window?.close() }
        let tabs = try #require(host.verticalTabs)
        let parent = try #require(tabs.selectedController as? TerminalTabSessionController)
        let surface = try #require(parent.surfaceTree.root?.leftmostLeaf())
        NotificationCenter.default.post(name: Ghostty.Notification.ghosttyNewSplit, object: surface,
                                        userInfo: ["direction": GHOSTTY_SPLIT_DIRECTION_RIGHT])
        #expect(Array(parent.surfaceTree).count == 2)
        tabs.refreshSelection(focus: false)
        #expect(Array(host.surfaceTree).count == 2)
        let child = tabs.newTab(child: true)
        NotificationCenter.default.post(name: Ghostty.Notification.ghosttyNewSplit, object: surface,
                                        userInfo: ["direction": GHOSTTY_SPLIT_DIRECTION_DOWN])
        #expect(Array(parent.surfaceTree).count == 3)
        #expect(tabs.selectedController === child)
        #expect(Array(host.surfaceTree).count == 1)
    }

    @Test func closeSubtreeUndoAndRedoRetainTerminals() throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        defer { host.window?.close() }
        let tabs = try #require(host.verticalTabs)
        let parent = try #require(tabs.tree.selected)
        let child = try #require(tabs.newTab(child: true) as? TerminalTabSessionController)
        tabs.select(parent.value.controller)
        _ = tabs.newTab(child: false)
        let undo = try #require(host.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.removeAllActions(); undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        tabs.close(parent.id, subtree: true, confirm: false)
        undo.endUndoGrouping()
        #expect(tabs.controllers.count == 1)
        #expect(child.host == nil)
        undo.undo()
        #expect(tabs.controllers.count == 3)
        #expect(tabs.tree.node(child.id)?.value.controller === child)
        #expect(child.host === host)
        undo.redo()
        #expect(tabs.controllers.count == 1)
    }

    @Test func flattenMovesSubtreeToConsecutiveNativeTabsWithoutRestartingTerminals() throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        let native = TerminalController(host.ghostty, verticalTabs: false)
        _ = native.window
        let tabs = try #require(host.verticalTabs)
        let parent = try #require(tabs.tree.selected)
        _ = tabs.newTab(child: true)
        _ = tabs.newTab(child: true)
        let originals = parent.preorder.map { $0.value.controller.surfaceTree.root?.leftmostLeaf() }
        let moved = tabs.flatten(parent.id, into: native, showWindows: false)
        defer { moved.forEach { $0.window?.close() }; native.window?.close(); host.window?.close() }
        #expect(moved.count == 3)
        #expect(moved.allSatisfy { !$0.verticalTabsEnabled })
        #expect(moved.map { $0.surfaceTree.root?.leftmostLeaf() } == originals)
        #expect(native.window?.tabGroup?.windows.count == 4)
        #expect(moved.first?.restorable == false)
        for (controller, surface) in zip(moved, originals) {
            if let surface { #expect(BaseTerminalController.controller(owning: surface) === controller) }
        }
    }

    @Test func terminalHeaderTracksOSC11AndTabSelection() async throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        defer { host.window?.close() }
        let tabs = try #require(host.verticalTabs)
        let parent = try #require(tabs.selectedController as? TerminalTabSessionController)
        let surface = try #require(parent.focusedSurface)
        let child = tabs.newTab(child: true)
        let change = Ghostty.Action.ColorChange(c: .init(kind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, r: 7, g: 14, b: 10))
        NotificationCenter.default.post(name: .ghosttyColorDidChange, object: surface,
                                        userInfo: [Notification.Name.GhosttyColorChangeKey: change])
        try await Task.sleep(for: .milliseconds(30))
        #expect(tabs.selectedController === child)
        tabs.select(parent)
        let header = try #require(tabs.splitViewItems[1].viewController.view.layer?.backgroundColor)
        let color = try #require(NSColor(cgColor: header)?.usingColorSpace(.deviceRGB))
        #expect(abs(color.redComponent - 7.0 / 255) < 0.001)
        #expect(abs(color.greenComponent - 14.0 / 255) < 0.001)
        #expect(abs(color.blueComponent - 10.0 / 255) < 0.001)
        #expect(host.window?.titlebarAppearsTransparent == true)
        #expect(host.window?.titlebarSeparatorStyle == NSTitlebarSeparatorStyle.none)
    }

    @Test func scriptingTabsEnumerateDepthFirstAndKeepDistinctIDs() throws {
        guard #available(macOS 26.0, *) else { return }
        let host = try makeHost()
        defer { host.window?.close() }
        let tabs = try #require(host.verticalTabs)
        let parent = try #require(tabs.selectedController)
        let child = tabs.newTab(child: true)
        tabs.select(parent)
        let sibling = tabs.newTab(child: false)
        let script = ScriptWindow(primaryController: host)
        if NSApp.isAppleScriptEnabled {
            #expect(script.tabs.map(\.idValue) == [parent, child, sibling].map { "tab-\($0.logicalTabID)" })
            #expect(script.selectedTab?.idValue == "tab-\(sibling.logicalTabID)")
            #expect(Set(script.tabs.map(\.idValue)).count == 3)
        } else { #expect(script.tabs.isEmpty) }
    }

}
