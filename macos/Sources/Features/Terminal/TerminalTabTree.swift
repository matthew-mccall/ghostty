import Foundation

/// The ordering and hierarchy of tabs, independent of AppKit and terminal lifetime.
/// Payloads are retained across moves and undo; changing the tree never starts a PTY.
final class TerminalTabTree<Value> {
    final class Node: Identifiable {
        let id: UUID
        let value: Value
        var children: [Node]
        var isExpanded: Bool

        init(id: UUID = UUID(), value: Value, children: [Node] = [], isExpanded: Bool = true) {
            self.id = id
            self.value = value
            self.children = children
            self.isExpanded = isExpanded
        }

        var preorder: [Node] { [self] + children.flatMap(\.preorder) }

        func copy() -> Node {
            Node(id: id, value: value, children: children.map { $0.copy() }, isExpanded: isExpanded)
        }
    }

    struct Position: Equatable {
        let parent: UUID?
        let index: Int
    }

    private(set) var roots: [Node]
    var selectedID: UUID?

    init(roots: [Node] = [], selectedID: UUID? = nil) {
        self.roots = roots
        self.selectedID = selectedID ?? roots.first?.id
    }

    var preorder: [Node] { roots.flatMap(\.preorder) }
    var selected: Node? { selectedID.flatMap(node) }

    func node(_ id: UUID) -> Node? { preorder.first { $0.id == id } }

    func position(of id: UUID) -> Position? {
        func find(_ nodes: [Node], parent: UUID?) -> Position? {
            for (index, node) in nodes.enumerated() {
                if node.id == id { return Position(parent: parent, index: index) }
                if let position = find(node.children, parent: node.id) { return position }
            }
            return nil
        }
        return find(roots, parent: nil)
    }

    func siblings(of id: UUID) -> [Node] {
        guard let position = position(of: id) else { return [] }
        return position.parent.flatMap(node)?.children ?? roots
    }

    func ancestors(of id: UUID) -> [Node] {
        var result: [Node] = []
        var current = position(of: id)?.parent
        while let parentID = current, let parent = node(parentID) {
            result.append(parent)
            current = position(of: parentID)?.parent
        }
        return result
    }

    func select(_ id: UUID, reveal: Bool = true) {
        guard node(id) != nil else { return }
        selectedID = id
        if reveal { ancestors(of: id).forEach { $0.isExpanded = true } }
    }

    @discardableResult
    func insert(_ node: Node, at position: Position) -> Bool {
        let ids = node.preorder.map(\.id)
        guard Set(ids).count == ids.count, !preorder.contains(where: { ids.contains($0.id) }) else { return false }
        if let parentID = position.parent {
            guard let parent = self.node(parentID), position.index >= 0, position.index <= parent.children.count else { return false }
            parent.children.insert(node, at: position.index)
        } else {
            guard position.index >= 0, position.index <= roots.count else { return false }
            roots.insert(node, at: position.index)
        }
        return true
    }

    /// Removes one node or a subtree. Children promoted by a single-tab close
    /// retain their order and occupy their parent's old sibling position.
    @discardableResult
    func remove(_ id: UUID, subtree: Bool) -> Node? {
        let oldOrder = preorder.map(\.id)
        guard let oldIndex = oldOrder.firstIndex(of: id), let position = position(of: id), let removed = node(id) else { return nil }
        let removedIDs = Set(subtree ? removed.preorder.map(\.id) : [id])
        let replacements = subtree ? [] : removed.children
        if let parentID = position.parent, let parent = node(parentID) {
            parent.children.replaceSubrange(position.index...position.index, with: replacements)
        } else {
            roots.replaceSubrange(position.index...position.index, with: replacements)
        }
        if !subtree { removed.children = [] }
        if let selectedID, removedIDs.contains(selectedID) {
            let survivors = preorder
            self.selectedID = survivors.isEmpty ? nil : survivors[min(oldIndex, survivors.count - 1)].id
        }
        return removed
    }

    /// The position is expressed in the tree before removal, as AppKit drop
    /// positions are. Reject cycles before mutating either sibling list.
    @discardableResult
    func move(_ id: UUID, to position: Position) -> Bool {
        guard let source = node(id), let old = self.position(of: id), position.index >= 0 else { return false }
        if let parentID = position.parent {
            guard let parent = node(parentID), !source.preorder.contains(where: { $0.id == parentID }), position.index <= parent.children.count else { return false }
        } else if position.index > roots.count { return false }
        let selected = selectedID
        let destinationIndex = position.index - (old.parent == position.parent && old.index < position.index ? 1 : 0)
        guard let detached = remove(id, subtree: true) else { return false }
        _ = insert(detached, at: Position(parent: position.parent, index: destinationIndex))
        selectedID = selected
        return true
    }

    @discardableResult
    func indent(_ id: UUID) -> Bool {
        guard let position = position(of: id), position.index > 0 else { return false }
        let previous = siblings(of: id)[position.index - 1]
        guard move(id, to: Position(parent: previous.id, index: previous.children.count)) else { return false }
        previous.isExpanded = true
        return true
    }

    @discardableResult
    func outdent(_ id: UUID) -> Bool {
        guard let parentID = position(of: id)?.parent, let parentPosition = position(of: parentID) else { return false }
        return move(id, to: Position(parent: parentPosition.parent, index: parentPosition.index + 1))
    }

    func restore(roots: [Node], selectedID: UUID?) {
        self.roots = roots.map { $0.copy() }
        self.selectedID = selectedID.flatMap { node($0)?.id } ?? self.roots.first?.id
    }
}
