#include "ghostty.h"
#import <AppKit/AppKit.h>
#include <IOKit/ps/IOPowerSources.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#import <objc/runtime.h>
#include <stdatomic.h>
static _Atomic(BOOL) measuring;
static NSUInteger buffers, errors;
static double gpuTimes[10000];
static NSString *gpuName;
static _Atomic(BOOL) watchingQueues;
static NSMutableArray<NSString *> *createdQueues;
static NSMutableSet<NSString *> *integratedNames, *performanceNames;

static void observe(id<MTLCommandBuffer> buffer) {
  BOOL record = measuring;
  if (record) {
    @synchronized(NSApp) {
      gpuName = buffer.device.name;
    }
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
      @synchronized(NSApp) {
        if (done.status == MTLCommandBufferStatusError)
          errors++;
        if (buffers < 10000)
          gpuTimes[buffers++] = (done.GPUEndTime - done.GPUStartTime) * 1000;
      }
    }];
  }
}
static void wake(void *p) {}
static bool action(ghostty_app_t app, ghostty_target_s target,
                   ghostty_action_s action) {
  return true;
}
static ghostty_clipboard_read_result_e readclip(void *p, ghostty_clipboard_e c,
                                                void *s, const char *const *m,
                                                size_t n, bool b) {
  return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED;
}
static void confirm(void *p, const ghostty_clipboard_confirm_s *c, void *s,
                    ghostty_clipboard_request_e r) {}
static void writeclip(void *p, ghostty_clipboard_e c,
                      const ghostty_clipboard_content_s *v, size_t n, bool b) {}
static double now(void) { return CACurrentMediaTime(); }
static int cmp(const void *a, const void *b) {
  double d = *(double *)a - *(double *)b;
  return (d > 0) - (d < 0);
}
// Test-only wrappers retain the real AC query for benchmarks, and allow
// notification delivery to be exercised without changing the laptop's power.
static int simulatedBattery = -1;
static IOPowerSourceCallbackType powerCallback;
static void *powerContext;
CFStringRef IOPSGetProvidingPowerSourceType(CFTypeRef snapshot) {
  if (simulatedBattery >= 0)
    return simulatedBattery ? CFSTR("Battery Power") : CFSTR("AC Power");
  CFStringRef (*real)(CFTypeRef) =
      dlsym(RTLD_NEXT, "IOPSGetProvidingPowerSourceType");
  return real(snapshot);
}
CFRunLoopSourceRef
IOPSNotificationCreateRunLoopSource(IOPowerSourceCallbackType callback,
                                    void *context) {
  powerCallback = callback;
  powerContext = context;
  CFRunLoopSourceRef (*real)(IOPowerSourceCallbackType, void *) =
      dlsym(RTLD_NEXT, "IOPSNotificationCreateRunLoopSource");
  return real(callback, context);
}
static NSData *pixels(NSView *view) {
  IOSurfaceRef output = (__bridge IOSurfaceRef)view.layer.contents;
  if (!output)
    return nil;
  IOSurfaceLock(output, kIOSurfaceLockReadOnly, NULL);
  const uint8_t *data = IOSurfaceGetBaseAddress(output);
  size_t size = IOSurfaceGetAllocSize(output);
  NSData *copy = [NSData dataWithBytes:data length:size];
  IOSurfaceUnlock(output, kIOSurfaceLockReadOnly, NULL);
  return copy;
}
// Different GPU compilers can round the shader's floating-point output by
// up to two 8-bit steps. Lost text or images cause much larger differences.
static BOOL equivalent(NSData *a, NSData *b) {
  if (!a || !b || a.length != b.length)
    return NO;
  const uint8_t *x = a.bytes, *y = b.bytes;
  for (size_t i = 0; i < a.length; i++)
    if (abs((int)x[i] - (int)y[i]) > 2)
      return NO;
  return YES;
}
static void settle(ghostty_app_t app, double seconds) {
  double end = now() + seconds;
  while (now() < end) {
    ghostty_app_tick(app);
    [[NSRunLoop currentRunLoop]
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
}
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 3) {
      fprintf(stderr, "Usage: renderer-bench CONFIG WORKLOAD [--switch]\n");
      return 1;
    }
    BOOL switchTest = argc > 3 && strcmp(argv[3], "--switch") == 0;
    if (switchTest)
      setenv("GHOSTTY_BENCH_STATIC", "1", 1);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    // Only intercept the selected command-buffer class, leaving selection to
    // Ghostty.
    createdQueues = [NSMutableArray array];
    integratedNames = [NSMutableSet set];
    performanceNames = [NSMutableSet set];
    for (id<MTLDevice> dev in MTLCopyAllDevices()) {
      if (dev.isLowPower && !dev.isRemovable)
        [integratedNames addObject:dev.name];
      if (!dev.isLowPower)
        [performanceNames addObject:dev.name];
      Class deviceClass = object_getClass(dev);
      if (!objc_getAssociatedObject(deviceClass, "queue_hook")) {
        objc_setAssociatedObject(deviceClass, "queue_hook", @YES,
                                 OBJC_ASSOCIATION_RETAIN);
        Method method =
            class_getInstanceMethod(deviceClass, @selector(newCommandQueue));
        IMP original = method_getImplementation(method);
        IMP replacement =
            imp_implementationWithBlock(^id(id<MTLDevice> device) {
              if (watchingQueues)
                @synchronized(createdQueues) {
                  [createdQueues addObject:device.name];
                }
              return ((id (*)(id, SEL))original)(device,
                                                 @selector(newCommandQueue));
            });
        class_addMethod(deviceClass, @selector(newCommandQueue), original,
                        method_getTypeEncoding(method));
        class_replaceMethod(deviceClass, @selector(newCommandQueue),
                            replacement, method_getTypeEncoding(method));
      }
      id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
      Class cls = object_getClass(cb);
      Method method = class_getInstanceMethod(cls, @selector(commit));
      if (!objc_getAssociatedObject(cls, "bench_hook")) {
        objc_setAssociatedObject(cls, "bench_hook", @YES,
                                 OBJC_ASSOCIATION_RETAIN);
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^(id buffer) {
          observe(buffer);
          ((void (*)(id, SEL))original)(buffer, @selector(commit));
        });
        class_addMethod(cls, @selector(commit), original,
                        method_getTypeEncoding(method));
        class_replaceMethod(cls, @selector(commit), replacement,
                            method_getTypeEncoding(method));
      }
    }
    if (switchTest && (!integratedNames.count || !performanceNames.count)) {
      fprintf(stderr, "Switch test requires integrated and discrete GPUs\n");
      return 77;
    }
    char *args[] = {argv[0], NULL};
    if (ghostty_init(1, args) != 0)
      return 2;
    ghostty_config_t cfg = ghostty_config_new();
    ghostty_config_load_file(cfg, argv[1]);
    ghostty_config_finalize(cfg);
    if (ghostty_config_diagnostics_count(cfg)) {
      for (uint32_t i = 0; i < ghostty_config_diagnostics_count(cfg); i++)
        fprintf(stderr, "%s\n", ghostty_config_get_diagnostic(cfg, i).message);
      return 3;
    }
    ghostty_runtime_config_s rt = {0};
    rt.wakeup_cb = wake;
    rt.action_cb = action;
    rt.read_clipboard_cb = readclip;
    rt.confirm_read_clipboard_cb = confirm;
    rt.write_clipboard_cb = writeclip;
    ghostty_app_t app = ghostty_app_new(&rt, cfg);
    if (!app)
      return 4;
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 2560, 1440)];
    ghostty_surface_config_s sc = ghostty_surface_config_new();
    sc.platform_tag = GHOSTTY_PLATFORM_MACOS;
    sc.platform.macos.nsview = (__bridge void *)view;
    sc.scale_factor = 2;
    sc.command = [[NSString
        stringWithFormat:@"/usr/bin/python3 \"%s\"", argv[2]] UTF8String];
    ghostty_surface_t surf = ghostty_surface_new(app, &sc);
    if (!surf)
      return 5;
    ghostty_surface_set_content_scale(surf, 2, 2);
    ghostty_surface_set_size(surf, 5120, 2880);
    ghostty_surface_set_focus(surf, true);
    ghostty_surface_set_occlusion(surf, true);
    settle(app, 3);
    for (int i = 0; i < 20; i++)
      ghostty_surface_draw(surf);
    if (switchTest) {
      if (!powerCallback) {
        fprintf(stderr, "Power notification callback was not registered\n");
        return 7;
      }
      // Keep a second, occluded renderer alive during both transitions.
      NSView *hidden =
          [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 2560, 1440)];
      sc.platform.macos.nsview = (__bridge void *)hidden;
      ghostty_surface_t second = ghostty_surface_new(app, &sc);
      if (!second)
        return 8;
      ghostty_surface_set_content_scale(second, 2, 2);
      ghostty_surface_set_size(second, 5120, 2880);
      settle(app, 2);
      ghostty_surface_draw(surf);
      ghostty_surface_draw(second);
      NSData *firstPixels = pixels(view), *secondPixels = pixels(hidden);

      ghostty_surface_set_occlusion(second, false);
      NSMutableArray *steps = [NSMutableArray array];
      for (int state = 1; state >= 0; state--) {
        [createdQueues removeAllObjects];
        watchingQueues = YES;
        simulatedBattery = state;
        powerCallback(powerContext);
        settle(app, 2);
        watchingQueues = NO;
        BOOL idleMigrated = createdQueues.count == 2;
        for (NSString *name in createdQueues)
          idleMigrated &= [(state ? integratedNames
                                  : performanceNames) containsObject:name];
        measuring = YES;
        ghostty_surface_draw(surf);
        measuring = NO;
        NSString *visibleGPU = gpuName;
        measuring = YES;
        ghostty_surface_draw(second);
        measuring = NO;
        NSString *hiddenGPU = gpuName;
        NSData *visiblePixels = pixels(view), *hiddenPixels = pixels(hidden);
        BOOL same = equivalent(firstPixels, visiblePixels) &&
                    equivalent(secondPixels, hiddenPixels);
        NSSet *expectedNames = state ? integratedNames : performanceNames;
        BOOL selected = [expectedNames containsObject:visibleGPU] &&
                        [expectedNames containsObject:hiddenGPU];
        [steps addObject:@{
          @"on_battery" : @(state),
          @"visible_gpu" : visibleGPU ?: @"unknown",
          @"occluded_gpu" : hiddenGPU ?: @"unknown",
          @"pixels_preserved" : @(same),
          @"both_migrated_before_draw" : @(idleMigrated),
          @"selected_correctly" : @(selected)
        }];
        if (!same || !selected || !idleMigrated)
          errors++;
      }
      NSData *json =
          [NSJSONSerialization dataWithJSONObject:steps
                                          options:NSJSONWritingPrettyPrinted
                                            error:nil];
      fwrite(json.bytes, 1, json.length, stdout);
      puts("");
      ghostty_surface_free(second);
      ghostty_surface_free(surf);
      ghostty_app_free(app);
      ghostty_config_free(cfg);
      return errors ? 9 : 0;
    }
    double times[300];
    buffers = 0;
    errors = 0;
    measuring = YES;
    double start = now();
    for (int i = 0; i < 300; i++) {
      @autoreleasepool {
        double t = now();
        ghostty_app_tick(app);
        ghostty_surface_draw(surf);
        times[i] = (now() - t) * 1000;
      }
    }
    double elapsed = now() - start;
    measuring = NO;
    qsort(times, 300, sizeof(double), cmp);
    qsort(gpuTimes, buffers, sizeof(double), cmp);
    IOSurfaceRef output = (__bridge IOSurfaceRef)view.layer.contents;
    NSDictionary *result = @{
      @"gpu" : gpuName ?: @"unknown",
      @"width" : @(output ? IOSurfaceGetWidth(output) : 0),
      @"height" : @(output ? IOSurfaceGetHeight(output) : 0),
      @"frames" : @300,
      @"seconds" : @(elapsed),
      @"renderer_fps" : @(300 / elapsed),
      @"frame_median_ms" : @(times[150]),
      @"frame_p95_ms" : @(times[284]),
      @"gpu_buffers" : @(buffers),
      @"gpu_median_ms" : @(buffers ? gpuTimes[buffers / 2] : 0),
      @"gpu_p95_ms" : @(buffers ? gpuTimes[(buffers - 1) * 95 / 100] : 0),
      @"gpu_errors" : @(errors)
    };
    NSData *json =
        [NSJSONSerialization dataWithJSONObject:result
                                        options:NSJSONWritingPrettyPrinted
                                          error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    puts("");
    ghostty_surface_free(surf);
    ghostty_app_free(app);
    ghostty_config_free(cfg);
    return errors ? 6 : 0;
  }
}
