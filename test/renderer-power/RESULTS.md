# 5K renderer results

Measured on 2026-10-26 while the Intel MacBook Pro was connected to AC power. Both the preserved unmodified library and the changed library used `-Doptimize=fast -Dsentry=false` and the native x86_64 target. Builds finished before the sequential timing runs began.

The first baseline was measured before renderer edits. The preserved library was also measured again with the final shared text, ligature, Kitty image, and counter workload for the comparison below. Each row summarizes three runs of 300 synchronous frames after warm-up.

| Renderer and glow | Actual GPU | Median throughput | Median frame time | Worst run's p95 |
|---|---|---:|---:|---:|
| Before, four halo samples | Intel(R) UHD Graphics 630 | 37.67 FPS | 26.63 ms | 27.35 ms |
| After, four halo samples | AMD Radeon Pro 5500M | 185.15 FPS | 5.23 ms | 6.66 ms |
| After, eight weighted halo samples | AMD Radeon Pro 5500M | 160.83 FPS | 6.18 ms | 8.33 ms |

All runs produced 5120 × 2880 IOSurfaces and completed without Metal command-buffer errors. On actual AC power, the changed renderer selected AMD Radeon Pro 5500M. The eight-sample glow stayed below the 16.67 ms renderer budget in every run, so the user's CRT shader was restored to that halo. Scanlines remain disabled. Curvature, glow strength/radius, background lift, vignette, dithering, and static redraw behavior retain their settings.

This is offscreen renderer throughput, not a measurement of physical fullscreen presentation or keystroke latency. The test does not measure a full-screen-changing cmatrix workload. The restored glow's 60 FPS result applies to AC power on the Radeon; battery performance on Intel is not established by this comparison.

## Automatic switching verification

Test-only IOKit wrappers simulated battery and AC readings and invoked the actual registered notification callback. Two existing renderers, one occluded, both created their replacement queues before any forced draw. Completed command buffers used Intel UHD 630 on simulated battery power and Radeon Pro 5500M on simulated AC power. Text and Kitty image output survived both transitions within two 8-bit color steps. A separate run also preserved a background-image texture. No system power settings changed and the laptop remained plugged in throughout.

## Validation and build

- The targeted `zig build test -Dtest-filter='Metal GPU power preference' -Doptimize=fast -Dsentry=false -Demit-macos-app=false` executable passed all 78 collected tests, including the explicit GPU preference test.
- The release library build and Zig formatting checks passed.
- The native macOS app built with `macos/build.nu --configuration ReleaseLocal --architecture x86_64`. A temporary Nushell binary ran the script because Nushell was not installed. The optional architecture flag lets the build script consume a native XCFramework; the default remains unchanged.
- The app is at `macos/build/ReleaseLocal/Ghostty.app`. The installed `/Applications/Ghostty.app` has not been replaced or restarted. Use the built app to get the changed renderer.

Raw timings, library hashes, and transition checks are in [results.json](results.json). The harness and reproduction commands are in [README.md](README.md).

The implementation uses Apple's [power-source notifications](https://developer.apple.com/documentation/iokit/1523868-iopsnotificationcreaterunloopsou?language=occ) and [Metal GPU properties](https://developer.apple.com/documentation/metal/finding-multiple-gpus-on-an-intel-based-mac).
