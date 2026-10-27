# Vertical tabs validation

The deliverable is `/Volumes/T7/Projects/ghostty/macos/build/ReleaseLocal/Ghostty.app`.

Automated checks completed on October 27, 2026, using macOS 26.7.1 on the Intel MacBook Pro:

- The shared library built with `zig build -Doptimize=fast -Demit-macos-app=false -Dxcframework-target=native -Dsentry=false`.
- The focused Zig action-parser run passed all 78 collected tests.
- The macOS unit and session integration suite passed through `macos/build.nu --configuration Debug --architecture x86_64 --action test`. CLI execution excludes the separate UI-test target, as the repository script specifies.
- `macos/build.nu --configuration ReleaseLocal --architecture x86_64` succeeded. Deep, strict code-signature verification passed for the app bundle.
- Strict SwiftLint checks passed for the changed Swift files. Zig formatting and `git diff --check` passed.
- The release executable reports `macos-vertical-tabs = false` in its default configuration.

Session integration tests cover retained terminal identities and ownership, inactive session updates, split-event dispatch without duplicate host handling, parent promotion, close-subtree undo/redo, subtree transfers, import from horizontal windows, flattening into consecutive native tabs, collapse/reveal behavior, restoration filtering, fixed window modes, AppleScript depth-first enumeration, and OSC 11 header-color changes. Tests use temporary configuration and hidden windows. Existing user sessions were not closed or restarted.

The new undo test also exposed a cleanup crash in the existing expiring undo manager. Cleanup now retains the old targets until its collection mutation finishes and clears their manager reference before callbacks. A focused regression test covers clearing expiring actions.

The Xcode test host initially stalled while loading the separate Sparkle build product. The test plan now searches the verified framework inside Ghostty.app first. This leaves normal app launching unchanged.

## Renderer measurements

Three sequential runs per library used the same eight-sample CRT shader, text, ligature, Kitty-image, and counter workload at 5120 × 2880. The preserved pre-feature library and the final library both rendered on AMD Radeon Pro 5500M while the laptop was on AC power.

| Library | Median throughput | Median frame time | Worst run's p95 |
| --- | ---: | ---: | ---: |
| Preserved pre-feature | 165.60 FPS | 6.10 ms | 6.39 ms |
| Final | 164.82 FPS | 6.11 ms | 6.29 ms |

All runs completed without GPU command-buffer errors. Both remain below the 16.67 ms renderer budget for 60 FPS. The high-fidelity glow remains enabled in the existing CRT configuration; this feature did not edit the user's configuration.

Simulated power notifications moved both an active and an occluded renderer to Intel UHD Graphics 630 on battery and back to Radeon Pro 5500M on AC before a forced draw. Rendered pixels survived both transitions. The benchmark records the actual devices used by completed Metal command buffers.

These are offscreen renderer measurements. They do not establish physical fullscreen frame rate or keystroke-to-display latency. Raw measurements and library, shader, benchmark executable, and release executable hashes are in [vertical-tabs-results.json](../test/renderer-power/vertical-tabs-results.json).

## Visible QA

The user manually confirmed that the native sidebar and nested tabs work, native fullscreen typing on the 5K display stays responsive, and the CRT background blends seamlessly into the terminal header. The tested release executable had SHA-256 `25f65827d78234ed821f475cdaf4309c1f84afd5bfa2fce72e8c09dcbf44a848`.

Read-only IOKit diagnostics identified that exact app at PID 70586, with live `AMDRadeonX6000_AMDAccelCommandQueue` connections under the Radeon graphics accelerator. The process path was the requested ReleaseLocal executable.

Computer Use explicitly denies access to `com.mitchellh.ghostty` for safety reasons, so the visible checks were performed by the user. Existing terminal sessions were not closed or restarted.

A subsequent requested adjustment makes the sidebar scrollbars auto-hide, places the sidebar toggle in the leading navigation area beside the window controls, and removes the toolbar's New Tab button. The toolbar now displays icons without visible labels; the sidebar toggle retains its tooltip and accessibility name. Close buttons are pinned directly to the trailing edge of each outline cell, with titles filling and truncating within the remaining space. This keeps the buttons aligned across short and long names and across indentation levels. The updated appearance needs manual confirmation after launching the rebuilt app. The hierarchy/session behavior and renderer are unchanged by that adjustment.

Close controls now use the native circled-X symbol and appear only for the active tab or the row under the pointer. Hover tracking covers the entire row, including indentation and disclosure controls. Hidden close controls retain their reserved layout space, preserving right alignment and preventing title shifts.

Middle-clicking a sidebar row now uses the ordinary close-tab path, preserving process confirmations, child promotion, selection fallback, and undo. A middle-button press and release must target the same row; empty space and other mouse buttons do not close tabs.

Additional visible checks not yet performed include cross-display dragging, VoiceOver, and the CRT/titlebar seam through the complete resizing and fullscreen-transition matrix. Automated tests cover the corresponding session transfers and background-color updates.

Use temporary launch overrides for QA, preserving the user's persistent configuration:

```sh
open -g -n /Volumes/T7/Projects/ghostty/macos/build/ReleaseLocal/Ghostty.app --args \
  --macos-vertical-tabs=true --window-save-state=never --initial-window=false
```

The background launch intentionally creates no window. Open the exact app normally when ready to test, then create a new window. On the QA machine the 5K S27B80T display is primary and the built-in Retina display is secondary. Ghostty's existing public launch path does not provide hidden window placement on a chosen display, so visible manual checks use its default placement. Preserve the user's focus and existing terminal sessions.
