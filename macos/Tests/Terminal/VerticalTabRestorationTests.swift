import AppKit
import Testing
@testable import Ghostty

@MainActor
struct VerticalTabRestorationTests {
    @Test func roundTripRetainsNestedSplitsAndSidebarState() throws {
        typealias Layout = TerminalTabRestorableLayout<MockView>
        let (split, first, second) = try SplitTreeTests.makeHorizontalSplit()
        let child = Layout.Tab(id: UUID(), surfaceTree: split, focusedSurface: second.id.uuidString,
                               titleOverride: "Child", tabColor: .green, expanded: false, children: [])
        let root = Layout.Tab(id: UUID(), surfaceTree: split, focusedSurface: first.id.uuidString,
                              titleOverride: "Parent", tabColor: .blue, expanded: true, children: [child])
        let layout = Layout(roots: [root], selected: child.id, sidebarWidth: 263, sidebarHidden: true)
        let state = TerminalRestorableState.InternalState<MockView>(
            focusedSurface: first.id.uuidString, surfaceTree: split,
            effectiveFullscreenMode: .native, tabColor: .blue, titleOverride: "Parent", verticalTabs: layout)
        let data = try PropertyListEncoder().encode(state)
        let decoded = try PropertyListDecoder().decode(TerminalRestorableState.InternalState<MockView>.self, from: data)
        let restored = try #require(decoded.verticalTabs)
        #expect(restored.preorder.map(\.id) == [root.id, child.id])
        #expect(restored.selected == child.id)
        #expect(restored.sidebarWidth == 263)
        #expect(restored.sidebarHidden)
        #expect(restored.roots.first?.children.first?.expanded == false)
        #expect(restored.preorder.last?.surfaceTree.contains(where: { $0.id == second.id }) == true)
    }

    @Test func legacyWindowWithoutHierarchyRemainsDecodable() throws {
        let (tree, _, _) = try SplitTreeTests.makeHorizontalSplit()
        let old = TerminalRestorableState.InternalState<MockView>(
            focusedSurface: nil, surfaceTree: tree, effectiveFullscreenMode: nil, tabColor: nil, titleOverride: nil)
        let data = try PropertyListEncoder().encode(old)
        let decoded = try PropertyListDecoder().decode(TerminalRestorableState.InternalState<MockView>.self, from: data)
        #expect(decoded.verticalTabs == nil)
        #expect(decoded.surfaceTree.isSplit)
    }
}
