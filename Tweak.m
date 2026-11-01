//
//  Tweak.m
//  VCamPlus
//
//  Hook 入口（3 个 hook：BWNodeOutput / BWStillImageScalerNode / BWPhotoEncoderNode）
//  自包含编译：不 #import 任何项目内头文件；VCamCore / VCamFloatingBall 通过
//  NSClassFromString + objc_msgSend 弱调用（类不存在则 no-op，存在则功能完整）。
//
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <signal.h>
#import <execinfo.h>
#import <fcntl.h>
#import <unistd.h>
#import <time.h>
#import <string.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

#pragma mark - 弱调用桥（编译期零项目依赖）

static id vcam_class_singleton(const char *className) {
    Class cls = NSClassFromString([NSString stringWithUTF8String:className]);
    if (!cls) return nil;
    SEL sel = sel_registerName("sharedInstance");
    if (![cls respondsToSelector:sel]) return nil;
    return ((id(*)(id, SEL))objc_msgSend)((id)cls, sel);
}

static void vcam_core_render(CVPixelBufferRef pb, double pts) {
    id core = vcam_class_singleton("VCamCore");
    if (!core) return;
    SEL sel = sel_registerName("renderReplacementToPixelBuffer:pts:");
    if ([core respondsToSelector:sel])
        ((void(*)(id, SEL, CVPixelBufferRef, double))objc_msgSend)(core, sel, pb, pts);
}

static void vcam_core_init_msd(void) {
    id core = vcam_class_singleton("VCamCore");
    if (!core) return;
    SEL sel = sel_registerName("initializeInMediaserverd");
    if ([core respondsToSelector:sel]) ((void(*)(id, SEL))objc_msgSend)(core, sel);
}

static void vcam_core_init_sb(void) {
    id core = vcam_class_singleton("VCamCore");
    if (!core) return;
    SEL sel = sel_registerName("initializeInSpringBoard");
    if ([core respondsToSelector:sel]) ((void(*)(id, SEL))objc_msgSend)(core, sel);
}

static void vcam_core_stop_polling(void) {
    id core = vcam_class_singleton("VCamCore");
    if (!core) return;
    SEL sel = sel_registerName("stopStatePolling");
    if ([core respondsToSelector:sel]) ((void(*)(id, SEL))objc_msgSend)(core, sel);
}

static void vcam_ball_show(void) {
    id ball = vcam_class_singleton("VCamFloatingBall");
    if (!ball) return;
    SEL sel = sel_registerName("showFloatingBall");
    if ([ball respondsToSelector:sel]) ((void(*)(id, SEL))objc_msgSend)(ball, sel);
}

#pragma mark - Hook 基础设施

static void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *origPtr) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) { if (origPtr) *origPtr = NULL; return; }
    if (origPtr) *origPtr = method_getImplementation(method);
    method_setImplementation(method, newImp);
}

static BOOL vcam_log_enabled(void) {
    static int cached = -1;
    if (cached < 0) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
            if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
            if (d) cached = d[@"logEnabled"] ? [d[@"logEnabled"] boolValue] : 0;
        } @catch (NSException *e) {}
    }
    return cached == 1;
}

extern BOOL vcam_log_budget_take(void);

static volatile int32_t vcamTweakLogCount = 0;
static void vcam_tweak_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
    int32_t n = __sync_add_and_fetch(&vcamTweakLogCount, 1);
    if (n > 2000) return;
    @try {
        NSString *logPath = @"/tmp/vcam_tweak_log.txt";
        NSString *ts = [NSDate date].description;
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", ts, msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        else { [fh seekToEndOfFile]; [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    } @catch (NSException *e) {}
}

#pragma mark - 照片过曝诊断 / 曝光元数据剥离

static int vcamScalerArrCount = 0;
static int vcamEncoderArrCount = 0;
static int vcamPhotoEmitCount = 0;

static BOOL vcamMetaFixCached = NO;
static time_t vcamMetaFixTS = 0;
static BOOL vcamMetaFixOn(void) {
    time_t now = time(NULL);
    if (now - vcamMetaFixTS >= 3) {
        vcamMetaFixTS = now;
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
            if (d && d[@"metaFix"]) vcamMetaFixCached = [d[@"metaFix"] boolValue];
        } @catch (NSException *e) {}
    }
    return vcamMetaFixCached;
}

static NSArray *vcamExposureKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"ExposureTime", @"ExposureBiasValue", @"ExposureIndex",
                 @"Sensitivity", @"ISOSensitivity", @"BrightnessValue",
                 @"LuxLevel", @"AvgLuma", @"RecommendedAvgLuma",
                 @"AnalogGain", @"DigitalGain", @"ISPGain", @"SensorGain", @"AGC"];
    });
    return keys;
}

static void vcamStripExposureMeta(CMSampleBufferRef sb, CVPixelBufferRef pb) {
    if (!vcamMetaFixOn()) return;
    for (NSString *key in vcamExposureKeys()) {
        CFStringRef ck = (__bridge CFStringRef)key;
        if (sb) CMRemoveAttachment(sb, ck);
        if (pb) CMRemoveAttachment(pb, ck);
    }
}

static NSString *vcamLumaSamples(CVPixelBufferRef pb) {
    if (!pb) return @"nil";
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    NSMutableArray *samples = [NSMutableArray array];
    size_t cx = w / 2, cy = h / 2;
    size_t xs[5] = {cx, cx / 2, cx + cx / 2, cx, cx};
    size_t ys[5] = {cy, cy, cy, cy / 2, cy + cy / 2};
    if (CVPixelBufferGetPlaneCount(pb) >= 1) {
        uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        if (base) for (int i = 0; i < 5; i++)
            if (xs[i] < w && ys[i] < h) [samples addObject:@(base[ys[i] * bpr + xs[i]])];
    } else {
        uint8_t *base = CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        if (base) for (int i = 0; i < 5; i++)
            if (xs[i] < w && ys[i] < h) [samples addObject:@(base[ys[i] * bpr + xs[i] * 4 + 1])];
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return samples.description;
}

static NSString *vcamTrunc(NSString *s, NSUInteger n) {
    if (!s || s.length <= n) return s ?: @"{}";
    return [NSString stringWithFormat:@"%@...", [s substringToIndex:n]];
}

static BOOL vcamStillDiagOn(void) {
    static int cached = -1;
    if (cached < 0) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
            cached = (d && d[@"stillDiag"]) ? [d[@"stillDiag"] boolValue] : 0;
        } @catch (NSException *e) { cached = 0; }
    }
    return cached == 1;
}

static void vcamDumpStillArrival(NSString *tag, int idx, CMSampleBufferRef sb, CVPixelBufferRef pb) {
    if (!pb || !vcamStillDiagOn()) return;
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    NSString *sbA = @"{}", *pbA = @"{}";
    if (sb) {
        CFDictionaryRef d1 = CMCopyDictionaryOfAttachments(NULL, sb, kCMAttachmentMode_ShouldPropagate);
        if (d1) sbA = vcamTrunc([(NSDictionary *)CFBridgingRelease(d1) description], 700);
    }
    CFDictionaryRef d2 = CMCopyDictionaryOfAttachments(NULL, pb, kCMAttachmentMode_ShouldPropagate);
    if (d2) pbA = vcamTrunc([(NSDictionary *)CFBridgingRelease(d2) description], 700);
    vcam_tweak_log([NSString stringWithFormat:
        @"[vcam][still] %@#%d fmt=0x%x %zux%zu Y/G=%@ metaFix=%d sbAtts=%@ pbAtts=%@",
        tag, idx, (unsigned)fmt, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
        vcamLumaSamples(pb), vcamMetaFixOn(), sbA, pbA]);
}

#pragma mark - Hook 原始指针

static void (*orig_BWNodeOutput_emitSampleBuffer)(id, SEL, CMSampleBufferRef);
static void (*orig_BWStillImageScalerNode_renderSampleBuffer)(id, SEL, CMSampleBufferRef, id);
static void (*orig_BWPhotoEncoderNode_renderSampleBuffer)(id, SEL, CMSampleBufferRef, id);

#pragma mark - Hook 实现

static BOOL vcamPhotoStreamThrottled(OSType fmt) {
    if (!(fmt == 0x2d386630 || fmt == 0x7c386630 || fmt == 0x7c387630)) return NO;
    static int enabled = -1;
    if (enabled < 0) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
            enabled = (d && d[@"photoThrottle"]) ? [d[@"photoThrottle"] boolValue] : 0;
        } @catch (NSException *e) { enabled = 0; }
    }
    if (!enabled) return NO;
    static CFAbsoluteTime lastHandled = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastHandled < 0.14) return YES;
    lastHandled = now;
    return NO;
}

static void hook_BWNodeOutput_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer) {
    static int vcamEmitCount = 0;
    vcamEmitCount++;
    if (vcamEmitCount % 1800 == 1) {
        CVPixelBufferRef pb = sampleBuffer ? CMSampleBufferGetImageBuffer(sampleBuffer) : NULL;
        OSType fmt = pb ? CVPixelBufferGetPixelFormatType(pb) : 0;
        vcam_tweak_log([NSString stringWithFormat:@"[vcam] emit#%d fmt=0x%x cls=%@",
                        vcamEmitCount, (unsigned)fmt, NSStringFromClass([self class])]);
    }
    if (sampleBuffer) {
     @autoreleasepool {
        @try {
            SEL mediaTypeSel = sel_registerName("mediaType");
            if ([self respondsToSelector:mediaTypeSel]) {
                uint32_t mt = ((uint32_t(*)(id, SEL))objc_msgSend)(self, mediaTypeSel);
                if (mt != 'vide') {
                    if (orig_BWNodeOutput_emitSampleBuffer) orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
                    return;
                }
            }
        } @catch (NSException *e) {}
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pixelBuffer) {
            OSType efmt = CVPixelBufferGetPixelFormatType(pixelBuffer);
            BOOL photoStream = (efmt == 0x2d386630 || efmt == 0x7c386630 || efmt == 0x7c387630);
            if (photoStream) {
                vcamPhotoEmitCount++;
                if (vcamPhotoEmitCount <= 16 || vcamPhotoEmitCount % 3600 == 0)
                    vcamDumpStillArrival(@"emitPhoto", vcamPhotoEmitCount, sampleBuffer, pixelBuffer);
                vcamStripExposureMeta(sampleBuffer, pixelBuffer);
            }
            if (vcamPhotoStreamThrottled(efmt)) {
                if (orig_BWNodeOutput_emitSampleBuffer) orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
                return;
            }
            @try {
                vcam_core_render(pixelBuffer, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)));
            } @catch (NSException *e) {
                vcam_tweak_log([NSString stringWithFormat:@"[vcam] emit hook exception: %@", e]);
            }
        }
     }
    }
    if (orig_BWNodeOutput_emitSampleBuffer) orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
}

static void hook_BWStillImageScalerNode_renderSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    if (sampleBuffer) {
     @autoreleasepool {
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pb) {
            vcamScalerArrCount++;
            if (vcamScalerArrCount <= 16 || vcamScalerArrCount % 3600 == 0)
                vcamDumpStillArrival(@"scaler", vcamScalerArrCount, sampleBuffer, pb);
            vcamStripExposureMeta(sampleBuffer, pb);
            if (vcamPhotoStreamThrottled(CVPixelBufferGetPixelFormatType(pb))) {
                if (orig_BWStillImageScalerNode_renderSampleBuffer)
                    orig_BWStillImageScalerNode_renderSampleBuffer(self, _cmd, sampleBuffer, input);
                return;
            }
            @try {
                vcam_core_render(pb, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)));
            } @catch (NSException *e) {
                vcam_tweak_log([NSString stringWithFormat:@"[vcam] scaler hook exception: %@", e]);
            }
        }
     }
    }
    if (orig_BWStillImageScalerNode_renderSampleBuffer)
        orig_BWStillImageScalerNode_renderSampleBuffer(self, _cmd, sampleBuffer, input);
}

static void hook_BWPhotoEncoderNode_renderSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    if (sampleBuffer) {
     @autoreleasepool {
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pb) {
            vcamEncoderArrCount++;
            if (vcamEncoderArrCount <= 16 || vcamEncoderArrCount % 3600 == 0)
                vcamDumpStillArrival(@"encoder", vcamEncoderArrCount, sampleBuffer, pb);
            vcamStripExposureMeta(sampleBuffer, pb);
            @try {
                vcam_core_render(pb, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)));
            } @catch (NSException *e) {
                vcam_tweak_log([NSString stringWithFormat:@"[vcam] encoder hook exception: %@", e]);
            }
        }
     }
    }
    if (orig_BWPhotoEncoderNode_renderSampleBuffer)
        orig_BWPhotoEncoderNode_renderSampleBuffer(self, _cmd, sampleBuffer, input);
}

#pragma mark - Hook 安装

static void installMediaserverdHooks(void) {
    Class c1 = objc_getClass("BWNodeOutput");
    if (c1) {
        MSHookMessageEx(c1, @selector(emitSampleBuffer:),
                        (IMP)hook_BWNodeOutput_emitSampleBuffer,
                        (IMP *)&orig_BWNodeOutput_emitSampleBuffer);
        vcam_tweak_log(@"[vcam] Hooked BWNodeOutput emitSampleBuffer:");
    } else vcam_tweak_log(@"[vcam] BWNodeOutput class not found");

    Class c2 = objc_getClass("BWStillImageScalerNode");
    if (c2) {
        MSHookMessageEx(c2, @selector(renderSampleBuffer:forInput:),
                        (IMP)hook_BWStillImageScalerNode_renderSampleBuffer,
                        (IMP *)&orig_BWStillImageScalerNode_renderSampleBuffer);
        vcam_tweak_log(@"[vcam] Hooked BWStillImageScalerNode renderSampleBuffer:forInput:");
    } else vcam_tweak_log(@"[vcam] BWStillImageScalerNode class not found");

    Class c3 = objc_getClass("BWPhotoEncoderNode");
    if (c3) {
        MSHookMessageEx(c3, @selector(renderSampleBuffer:forInput:),
                        (IMP)hook_BWPhotoEncoderNode_renderSampleBuffer,
                        (IMP *)&orig_BWPhotoEncoderNode_renderSampleBuffer);
        vcam_tweak_log(@"[vcam] Hooked BWPhotoEncoderNode renderSampleBuffer:forInput:");
    } else vcam_tweak_log(@"[vcam] BWPhotoEncoderNode class not found");
}

#pragma mark - 进程初始化

static void initializeInMediaserverd(void) {
    vcam_tweak_log(@"[vcam] Initializing in mediaserverd...");
    vcam_core_init_msd();
    installMediaserverdHooks();
    vcam_tweak_log(@"[vcam] MediaServerd hooks initialized");
}

static void initializeInSpringBoard(void) {
    vcam_tweak_log(@"[vcam] SpringBoard hooks initialized");
    vcam_core_init_sb();
    vcam_ball_show();
}

#pragma mark - 崩溃捕获

static void vcam_crash_handler(int sig, siginfo_t *info, void *ucontext) {
    (void)ucontext;
    int fd = open("/tmp/vcam_crash.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        dprintf(fd, "[vcam] ===== SIG%d addr=%p ", sig, info ? info->si_addr : NULL);
        char ts[32] = {0};
        time_t now = time(NULL);
        struct tm tmv; localtime_r(&now, &tmv);
        strftime(ts, sizeof(ts), "%H:%M:%S", &tmv);
        dprintf(fd, "%s backtrace:\n", ts);
        void *frames[64];
        int n = backtrace(frames, 64);
        backtrace_symbols_fd(frames, n, fd);
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void vcam_install_crash_handler(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = vcam_crash_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
}

#pragma mark - 双布局防重入 / 加载信标

static void vcamInit(void);

static BOOL vcam_loaded_via_other_path(void) {
    Dl_info info;
    if (!dladdr((void *)&vcamInit, &info) || !info.dli_fname) return NO;
    const char *selfPath = info.dli_fname;
    const char *selfBase = strrchr(selfPath, '/');
    selfBase = selfBase ? selfBase + 1 : selfPath;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (!p || strcmp(p, selfPath) == 0) continue;
        const char *base = strrchr(p, '/');
        base = base ? base + 1 : p;
        if (strcmp(base, selfBase) == 0) return YES;
    }
    return NO;
}

static void vcam_load_beacon(NSString *processName) {
    NSString *line = [NSString stringWithFormat:@"[%@] loaded in %@ (pid %d)\n",
                      [NSDate date], processName, getpid()];
    NSArray *paths = @[@"/var/mobile/Media/DCIM/vcam_load.txt",
                       @"/tmp/vcam_load.txt",
                       @"/private/tmp/vcam_load.txt",
                       @"/var/tmp/vcam_load.txt"];
    for (NSString *p in paths) {
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        } @catch (NSException *e) {}
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void vcamInit(void) {
    @autoreleasepool {
        if (vcam_loaded_via_other_path()) return;
        NSString *processName = [[NSProcessInfo processInfo] processName];
        vcam_load_beacon(processName);
        vcam_tweak_log([NSString stringWithFormat:@"[vcam] Loading in process: %@", processName]);

        if ([processName isEqualToString:@"mediaserverd"]) {
            vcam_install_crash_handler();
            initializeInMediaserverd();
        } else if ([processName isEqualToString:@"SpringBoard"]) {
            initializeInSpringBoard();
        } else {
            vcam_tweak_log([NSString stringWithFormat:@"[vcam] Loaded in other process: %@", processName]);
            vcam_core_init_msd();
        }
    }
}

__attribute__((destructor))
static void vcamDeinit(void) {
    vcam_tweak_log(@"[vcam] Unloading...");
    vcam_core_stop_polling();
}
