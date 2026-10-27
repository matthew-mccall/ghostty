import Testing
@testable import Ghostty

@MainActor
struct ExpiringUndoManagerTests {
    @Test func clearingExpiringActionsReleasesTargetsWithoutReentrantMutation() {
        final class Target {}
        let manager = ExpiringUndoManager()
        let target = Target()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: target, expiresAfter: .seconds(60)) { _ in }
        manager.endUndoGrouping()
        #expect(manager.canUndo)
        manager.removeAllActions()
        #expect(!manager.canUndo)
        #expect(!manager.canRedo)
    }
}
