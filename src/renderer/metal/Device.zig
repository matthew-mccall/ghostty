//! The Metal device context.
//!
//! Tracks the power preference shared by all Metal renderers. Each renderer
//! owns its GPU selection so it can drain and migrate independently.
const Device = @This();

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const macos = @import("macos");
const xev = @import("xev");

const mtl = @import("api.zig");
const shaders = @import("shaders.zig");

const log = std.log.scoped(.metal);

/// Options used when creating the Metal device.
/// There are currently no options.
pub const Options = struct {};

/// Power notifications and listeners are managed on the main thread.
on_battery: std.atomic.Value(bool),
listeners: std.ArrayList(*xev.Async) = .empty,
power_source: if (builtin.target.os.tag == .macos) macos.c.CFRunLoopSourceRef else void =
    if (builtin.target.os.tag == .macos) null else {},

pub fn init(alloc: std.mem.Allocator, options: Options) !*Device {
    _ = options;
    const self = try alloc.create(Device);
    errdefer alloc.destroy(self);
    self.* = .{ .on_battery = .init(isOnBattery()) };
    if (comptime builtin.target.os.tag == .macos) {
        self.power_source = macos.c.IOPSNotificationCreateRunLoopSource(powerChanged, self) orelse
            return error.PowerNotificationFailed;
        macos.c.CFRunLoopAddSource(macos.c.CFRunLoopGetMain(), self.power_source, macos.c.kCFRunLoopCommonModes);
        // Recheck after subscribing so a transition during setup is not lost.
        self.on_battery.store(isOnBattery(), .release);
    }
    return self;
}

pub fn deinit(self: *Device, alloc: std.mem.Allocator) void {
    std.debug.assert(self.listeners.items.len == 0);
    if (comptime builtin.target.os.tag == .macos) {
        macos.c.CFRunLoopSourceInvalidate(self.power_source);
        macos.c.CFRelease(self.power_source);
    }
    self.listeners.deinit(alloc);
    alloc.destroy(self);
}

pub fn listen(self: *Device, alloc: std.mem.Allocator, wakeup: *xev.Async) !void {
    try self.listeners.append(alloc, wakeup);
}

pub fn unlisten(self: *Device, wakeup: *xev.Async) void {
    for (self.listeners.items, 0..) |item, i| {
        if (item == wakeup) {
            _ = self.listeners.swapRemove(i);
            return;
        }
    }
    unreachable;
}

fn powerChanged(context: ?*anyopaque) callconv(.c) void {
    const self: *Device = @ptrCast(@alignCast(context.?));
    const on_battery = isOnBattery();
    if (self.on_battery.swap(on_battery, .acq_rel) == on_battery) return;
    for (self.listeners.items) |wakeup| wakeup.notify() catch {};
}

fn isOnBattery() bool {
    if (comptime builtin.target.os.tag != .macos) return true;
    const info = macos.c.IOPSCopyPowerSourcesInfo() orelse return true;
    defer macos.c.CFRelease(info);
    const source = macos.c.IOPSGetProvidingPowerSourceType(info) orelse return true;
    var buf: [32]u8 = undefined;
    if (macos.c.CFStringGetCString(source, &buf, buf.len, macos.c.kCFStringEncodingUTF8) == 0) return true;
    // Treat UPS power and unknown sources conservatively too.
    return !std.mem.eql(u8, std.mem.sliceTo(&buf, 0), "AC Power");
}

/// A renderer owns this snapshot until all of its GPU work has finished.
/// The app-wide state deliberately holds no GPU reference, so it cannot keep
/// the discrete GPU awake after every window has migrated to integrated graphics.
pub const Selection = struct {
    /// MTLDevice
    device: objc.Object,

    /// The default storage mode to use for resources created with our device.
    ///
    /// This is based on whether the device is a discrete GPU or not, since
    /// discrete GPUs do not have unified memory and therefore do not support
    /// the "shared" storage mode, instead we have to use the "managed" mode.
    default_storage_mode: mtl.MTLResourceOptions.StorageMode,

    /// The maximum 2D texture width and height supported by the device.
    max_texture_size: u32,

    on_battery: bool,

    pub fn init(on_battery: bool) !Selection {
        // Choose our MTLDevice.
        const device = try chooseDevice(on_battery);
        errdefer device.release();

        // Grab metadata about the device.
        const default_storage_mode: mtl.MTLResourceOptions.StorageMode = switch (comptime builtin.target.os.tag) {
            // manage mode is not supported by iOS
            .ios => .shared,
            else => if (device.getProperty(bool, "hasUnifiedMemory")) .shared else .managed,
        };
        const max_texture_size = queryMaxTextureSize(device);
        const name = device.getProperty(objc.Object, "name").msgSend([*:0]const u8, "UTF8String", .{});
        log.info("selected GPU={s} on_battery={} low_power={}", .{
            name, on_battery, device.getProperty(bool, "isLowPower"),
        });
        log.debug("device properties default_storage_mode={} max_texture_size={}", .{
            default_storage_mode, max_texture_size,
        });

        return .{
            .device = device,
            .on_battery = on_battery,
            .default_storage_mode = default_storage_mode,
            .max_texture_size = max_texture_size,
        };
    }

    pub fn deinit(self: Selection) void {
        self.device.release();
    }
};

/// Warm up the Metal device machinery. The first Metal device query in
/// a process takes multiple milliseconds; once warm, subsequent queries
/// are effectively free. Calling this early (e.g. on a background
/// thread at app startup; Metal device queries are thread-safe) moves
/// that one-time cost off the critical path of the first surface's
/// renderer initialization.
pub fn warmup() void {
    const device = chooseDevice(isOnBattery()) catch return;
    defer device.release();

    // Create and release a command queue. The first command queue
    // created for a device pays additional one-time driver setup
    // costs; subsequent creations are much cheaper.
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    queue.release();

    // Build and discard our shader pipelines for both pixel formats we
    // may use (which one is used depends on the blending config). The
    // first pipeline state creation compiles shaders which is slow;
    // once warm, later creations hit driver and OS caches.
    inline for (.{
        mtl.MTLPixelFormat.bgra8unorm_srgb,
        mtl.MTLPixelFormat.bgra8unorm,
    }) |format| {
        if (shaders.Shaders.init(
            std.heap.c_allocator,
            device,
            &.{},
            format,
        )) |s| {
            var s_mut = s;
            s_mut.deinit(std.heap.c_allocator);
        } else |err| {
            log.warn("metal warmup shader init failed err={}", .{err});
        }
    }
}

fn chooseDevice(on_battery: bool) error{NoMetalDevice}!objc.Object {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var chosen_device: ?objc.Object = null;

    switch (comptime builtin.target.os.tag) {
        .macos => {
            const devices = objc.Object.fromId(mtl.MTLCopyAllDevices());
            defer devices.release();

            var best_rank: u8 = 0;
            var iter = devices.iterate();
            while (iter.next()) |device| {
                const rank = deviceRank(on_battery, .{
                    .headless = device.getProperty(bool, "isHeadless"),
                    .removable = device.getProperty(bool, "isRemovable"),
                    .low_power = device.getProperty(bool, "isLowPower"),
                });
                if (rank > best_rank) {
                    chosen_device = device;
                    best_rank = rank;
                }
            }
            // MTLCopyAllDevices owns these references only until this scope ends.
            if (chosen_device) |device| return device.retain();
        },

        .ios => {
            chosen_device = objc.Object.fromId(mtl.MTLCreateSystemDefaultDevice());
        },
        else => @compileError("unsupported target for Metal"),
    }

    const device = chosen_device orelse return error.NoMetalDevice;
    return device;
}

/// Determines the maximum 2D texture size supported by the device.
/// We need to clamp our frame size to this if it's larger.
fn queryMaxTextureSize(device: objc.Object) u32 {
    // https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf

    if (device.msgSend(
        bool,
        objc.sel("supportsFamily:"),
        .{mtl.MTLGPUFamily.apple10},
    )) return 32768;

    if (device.msgSend(
        bool,
        objc.sel("supportsFamily:"),
        .{mtl.MTLGPUFamily.apple3},
    )) return 16384;

    return 8192;
}

const Properties = struct { headless: bool = false, removable: bool = false, low_power: bool = false };

fn deviceRank(on_battery: bool, props: Properties) u8 {
    if (props.headless) return 0;
    if (on_battery) return if (props.low_power and !props.removable) 3 else if (!props.removable) 2 else 1;
    return if (props.removable) 3 else if (!props.low_power) 2 else 1;
}

test "Metal GPU power preference" {
    const expect = std.testing.expect;
    const integrated: Properties = .{ .low_power = true };
    const discrete: Properties = .{};
    const external: Properties = .{ .removable = true };
    try expect(deviceRank(true, integrated) > deviceRank(true, discrete));
    try expect(deviceRank(true, integrated) > deviceRank(true, external));
    try expect(deviceRank(false, discrete) > deviceRank(false, integrated));
    try expect(deviceRank(false, external) > deviceRank(false, discrete));
    try expect(deviceRank(true, .{ .headless = true }) == 0);
    try expect(deviceRank(false, .{ .headless = true }) == 0);
    // All usable devices remain fallbacks on single-GPU systems.
    try expect(deviceRank(true, discrete) > 0);
    try expect(deviceRank(false, integrated) > 0);
}
