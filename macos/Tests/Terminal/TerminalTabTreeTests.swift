import Foundation
import Testing
@testable import Ghostty

struct TerminalTabTreeTests {
    typealias Tree = TerminalTabTree<String>
    typealias Node = Tree.Node

    @Test func closingParentPromotesChildrenInPlace() {
        let child = Node(value: "child"), grandchild = Node(value: "grandchild")
        child.children = [grandchild]
        let parent = Node(value: "parent", children: [child, Node(value: "other child")])
        let tree = Tree(roots: [Node(value: "before"), parent, Node(value: "after")], selectedID: child.id)
        _ = tree.remove(parent.id, subtree: false)
        #expect(tree.roots.map(\.value) == ["before", "child", "other child", "after"])
        #expect(child.children.first === grandchild)
        #expect(tree.selectedID == child.id)
    }

    @Test func closingActiveSubtreeSelectsNextSurvivor() {
        let child = Node(value: "child"), next = Node(value: "next")
        let parent = Node(value: "parent", children: [child])
        let tree = Tree(roots: [parent, next], selectedID: child.id)
        _ = tree.remove(parent.id, subtree: true)
        #expect(tree.preorder.map(\.value) == ["next"])
        #expect(tree.selectedID == next.id)
        _ = tree.remove(next.id, subtree: true)
        #expect(tree.roots.isEmpty)
        #expect(tree.selectedID == nil)
    }

    @Test func revealingDescendantExpandsAncestorsButCollapseDoesNotSelectParent() {
        let child = Node(value: "child")
        let parent = Node(value: "parent", children: [child], isExpanded: false)
        let tree = Tree(roots: [parent])
        tree.select(child.id)
        #expect(parent.isExpanded)
        parent.isExpanded = false
        #expect(tree.selectedID == child.id)
        #expect(tree.preorder.map(\.value) == ["parent", "child"])
    }

    @Test func rejectsCyclesAndDuplicateIDsWithoutChangingTree() {
        let child = Node(value: "child")
        let parent = Node(value: "parent", children: [child])
        let tree = Tree(roots: [parent], selectedID: child.id)
        #expect(!tree.move(parent.id, to: .init(parent: child.id, index: 0)))
        #expect(!tree.move(child.id, to: .init(parent: child.id, index: 0)))
        #expect(!tree.insert(Node(id: child.id, value: "duplicate"), at: .init(parent: nil, index: 0)))
        #expect(tree.roots.first === parent)
        #expect(tree.selectedID == child.id)
    }

    @Test func indentAndOutdentMoveWholeSubtree() {
        let first = Node(value: "first"), leaf = Node(value: "leaf")
        let second = Node(value: "second", children: [leaf])
        let tree = Tree(roots: [first, second], selectedID: leaf.id)
        #expect(tree.indent(second.id))
        #expect(first.children.first === second)
        #expect(second.children.first === leaf)
        #expect(tree.selectedID == leaf.id)
        #expect(tree.outdent(second.id))
        #expect(tree.roots.map(\.id) == [first.id, second.id])
        #expect(!tree.indent(first.id))
        #expect(!tree.outdent(first.id))
    }

    @Test func restoresStructureAndExpansionWithoutRecreatingPayloads() {
        final class Session {}
        let session = Session()
        let child = TerminalTabTree<Session>.Node(value: session)
        let parent = TerminalTabTree<Session>.Node(value: Session(), children: [child], isExpanded: false)
        let tree = TerminalTabTree<Session>(roots: [parent], selectedID: child.id)
        let saved = tree.roots.map { $0.copy() }
        _ = tree.remove(parent.id, subtree: true)
        tree.restore(roots: saved, selectedID: child.id)
        #expect(tree.selected?.value === session)
        #expect(tree.roots.first?.isExpanded == false)
        #expect(tree.preorder.count == 2)
    }

    @Test func movesAcrossParentsUsingPreRemovalDropPositions() {
        let a = Node(value: "a"), b = Node(value: "b"), c = Node(value: "c")
        let tree = Tree(roots: [a, b, c], selectedID: b.id)
        #expect(tree.move(a.id, to: .init(parent: nil, index: 3)))
        #expect(tree.roots.map(\.value) == ["b", "c", "a"])
        #expect(tree.move(b.id, to: .init(parent: c.id, index: 0)))
        #expect(tree.preorder.map(\.value) == ["c", "b", "a"])
        #expect(tree.selectedID == b.id)
    }
}
