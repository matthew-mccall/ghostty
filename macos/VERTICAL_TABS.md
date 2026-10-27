# Nested vertical tabs

On macOS Tahoe 26 or newer, opt in with:

```ini
macos-vertical-tabs = true
```

Reload the configuration, then open a new window. Existing windows keep their current tab mode. Older macOS versions continue using horizontal tabs. Quick Terminal is unchanged.

The native sidebar starts visible, even with one tab. Use the toolbar icon beside the window controls or `toggle_tab_sidebar` to hide it. Sidebar scrollbars appear only when needed and use the system overlay style. Vertical windows own their titlebar layout and always use native fullscreen, including when `macos-non-native-fullscreen` requests another mode. The terminal header follows the effective top-edge terminal background. The sidebar uses the system glass appearance.

Command-T creates a sibling, following `window-new-tab-position`. New Child Tab appends a child to the current tab. Every row is a terminal session and can contain splits. Circled-X close buttons appear on the active tab and the hovered row. They share the same right edge across nesting levels; long titles truncate before them, and hovering does not shift the title. The following actions are available in menus, the command palette, and keybindings, without new default shortcuts:

- `new_child_tab`
- `indent_tab`
- `outdent_tab`
- `close_tab_subtree`
- `toggle_tab_sidebar`

Tab navigation and numbered shortcuts follow depth-first order, including collapsed descendants. Navigation expands the selected tab's ancestors. Collapsing a branch leaves its active terminal running and marks the collapsed ancestor.

Middle-click a sidebar row to close that tab without selecting it first. Closing a parent promotes its children in place. Close Subtree closes the entire branch. Closing the active tab selects the next surviving tab, or the previous tab at the end. Process confirmations and undo also apply to these operations.

Drag a sidebar row to move its complete subtree. Drop onto a row to nest it, between rows to reorder it, into another sidebar to preserve its tree, or onto a horizontal window's terminal content to flatten it into consecutive tabs. Drag outside Ghostty windows to detach the branch. Horizontal windows expose a small draggable tab icon in the titlebar while vertical windows exist. Drop that icon into a sidebar to import the horizontal tab as a root. The Move Tab to Window menu also supports transfers between modes.

Under `window-save-state`, restoration retains eligible sessions, hierarchy, order, selection, expansion, and sidebar size and visibility. Tabs running custom commands remain excluded by Ghostty's existing restoration policy; their eligible children are promoted. If vertical tabs are disabled at the next launch, every eligible saved tab restores as a horizontal tab in depth-first order. AppleScript continues exposing a flat collection in that same order, with distinct tab IDs.

Build and test evidence, renderer timings, and pending visible checks are recorded in [VERTICAL_TABS_VALIDATION.md](VERTICAL_TABS_VALIDATION.md).
