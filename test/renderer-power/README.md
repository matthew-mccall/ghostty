# Metal power selection and renderer benchmarks

This macOS harness links the actual Ghostty renderer into an offscreen, layer-hosting NSView at 5120 × 2880. It never creates a window or activates an app. GPU selection remains Ghostty's responsibility; command-buffer instrumentation records the device that actually renders each frame.

Build a release library before running it:

```sh
zig build -Doptimize=fast -Demit-macos-app=false -Dxcframework-target=native -Dsentry=false
```

Preserve `macos/GhosttyKit.xcframework/macos-x86_64/libghostty-internal.a` before editing renderer code, then build and preserve the changed library. On Apple silicon, the native framework directory uses that architecture instead. Run libraries sequentially against the same configuration and workload, with no concurrent builds or benchmarks:

```sh
test/renderer-power/run.sh /absolute/path/before.a \
  "$PWD/test/renderer-power/benchmark.conf" /private/tmp/ghostty-before

test/renderer-power/run.sh /absolute/path/after.a \
  "$PWD/test/renderer-power/benchmark.conf" /private/tmp/ghostty-after
```

The fixture includes Cascadia Code ligatures, dense green text, a Kitty image, and a counter updated at a requested 120 Hz. The benchmark warms the terminal for three seconds and renders 20 additional warm-up frames, then measures 300 synchronous full-renderer draws. The CPU timer includes command encoding, waiting for GPU completion, and setting the layer's IOSurface contents. GPU timestamps come from completed Metal command buffers. Vsync is disabled only in the benchmark configuration.

These results measure renderer throughput. They exclude WindowServer composition, physical display refresh, and input-to-display latency. They are more complete than a shader-only benchmark, but do not establish displayed fullscreen FPS. The 60 FPS renderer threshold is 16.67 ms per frame.

`fast.glsl` preserves the four-tap approximation from the existing CRT configuration. `high.glsl` restores the original eight weighted halo samples while keeping scanlines disabled and retaining the other shader optimizations. To compare glow quality, copy the configuration and set `custom-shader` to the absolute path of `high.glsl`.

For switching verification on a Mac with both integrated and discrete GPUs:

```sh
test/renderer-power/run.sh /absolute/path/after.a \
  "$PWD/test/renderer-power/benchmark.conf" /private/tmp/ghostty-switch --switch
```

The test first uses the actual power source. Test-only IOKit wrappers then simulate battery and AC readings and call the registered power-notification callback. This does not change system power settings or require unplugging the laptop. The test verifies that two existing renderers, one occluded, create replacement command queues before any forced draw. It checks the GPUs used by their subsequent command buffers and compares rendered text and Kitty image pixels. Cross-GPU output may differ by up to two 8-bit color steps because of floating-point shader rounding. Exit code 77 means the required GPU pair is unavailable.

Results for the development machine are recorded in [RESULTS.md](RESULTS.md).
