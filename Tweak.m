//
//  Tweak.m
//  VCamPlus · 完整修复版
//  视频替换：照搬源码1 三车道 + 三级回退 + 熔断
//  填充：边界像素延伸（无重叠、无黑边）
//  卡顿：process 结果缓存（同帧同参数复用）
//  彩色注入整段未动
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import <math.h>
#import <string.h>
#import <mach-o/dyld.h>

// ======================= 日志 =======================
static BOOL vcamLogOn(void) {
    static int c = -1;
    if (c < 0) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/DCIM/vc.plist"];
            if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
            if (d) c = d[@"logEnabled"] ? [d[@"logEnabled"] boolValue] : 0;
        } @catch (NSException *e) {}
    }
    return c == 1;
}
static void vcamLog(NSString *m) {
    if (!vcamLogOn()) return;
    @try {
        NSString *p = @"/tmp/vcam_log.txt";
        NSString *e = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], m];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) [e writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        else { [fh seekToEndOfFile]; [fh writeData:[e dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    } @catch (NSException *e) {}
}
static void vcamLoadBeacon(NSString *processName) {
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
static void vcamInit(void);
static BOOL vcamLoadedViaOtherPath(void) {
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

// ======================= plist IPC =======================
static NSString *const kPlist = @"/var/mobile/Media/DCIM/vc.plist";
static NSDictionary *plRead(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPlist];
    if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
    return d ?: @{};
}
static void plSet(NSString *k, id v) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:plRead()];
    if (v) d[k] = v; else [d removeObjectForKey:k];
    [d writeToFile:kPlist atomically:YES];
}
static void plSetMany(NSDictionary *kv) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:plRead()];
    for (NSString *k in kv) {
        id v = kv[k];
        if (v) d[k] = v; else [d removeObjectForKey:k];
    }
    [d writeToFile:kPlist atomically:YES];
}

// ======================= VT 私有 API =======================
typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
typedef struct OpaqueVTPixelRotationSession *VTPixelRotationSessionRef;
extern OSStatus VTPixelTransferSessionCreate(CFAllocatorRef, VTPixelTransferSessionRef *);
extern OSStatus VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);
extern OSStatus VTPixelTransferSessionInvalidate(VTPixelTransferSessionRef);
extern OSStatus VTSessionSetProperty(CFTypeRef, CFStringRef, CFTypeRef);
typedef OSStatus (*VTRotCreateT)(CFAllocatorRef, VTPixelRotationSessionRef *);
typedef OSStatus (*VTRotTransT)(VTPixelRotationSessionRef, CVPixelBufferRef, CVPixelBufferRef);
typedef OSStatus (*VTRotInvT)(VTPixelRotationSessionRef);

// ======================= 帧队列 =======================
@interface VCQueue : NSObject
@property (nonatomic, strong) NSMutableArray *arr;
@property (nonatomic, strong) NSRecursiveLock *lock;
@property (nonatomic, assign) NSUInteger cap;
@property (nonatomic, assign) CVPixelBufferRef current;
@end
@implementation VCQueue
- (instancetype)initWithCap:(NSUInteger)cap {
    self = [super init];
    if (self) { _arr = [NSMutableArray array]; _lock = [[NSRecursiveLock alloc] init]; _cap = cap; }
    return self;
}
- (void)dealloc { [self clear]; }
- (void)push:(CVPixelBufferRef)b {
    if (!b) return;
    [_lock lock];
    [_arr addObject:(__bridge id)b];
    while (_arr.count > _cap) [_arr removeObjectAtIndex:0];
    if (_current) CVPixelBufferRelease(_current);
    _current = b; CVPixelBufferRetain(_current);
    [_lock unlock];
}
- (CVPixelBufferRef)pop CF_RETURNS_RETAINED {
    [_lock lock];
    CVPixelBufferRef b = NULL;
    if (_arr.count > 0) {
        b = (__bridge CVPixelBufferRef)_arr[0]; CVPixelBufferRetain(b);
        [_arr removeObjectAtIndex:0];
    }
    [_lock unlock];
    return b;
}
- (CVPixelBufferRef)copyCurrent CF_RETURNS_RETAINED {
    [_lock lock]; CVPixelBufferRef b = _current ? CVPixelBufferRetain(_current) : NULL; [_lock unlock]; return b;
}
- (void)clear {
    [_lock lock];
    [_arr removeAllObjects];
    if (_current) { CVPixelBufferRelease(_current); _current = NULL; }
    [_lock unlock];
}
@end

// ======================= 视频解码器 =======================
@interface VCPlayer : NSObject
@property (nonatomic, strong) AVURLAsset *asset;
@property (nonatomic, strong) AVAssetTrack *track;
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *output;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) VCQueue *queue;
@property (nonatomic, strong) NSThread *thread;
@property (nonatomic, assign) BOOL shouldRun, paused;
@property (nonatomic, assign) size_t w, h;
@property (nonatomic, assign) CGFloat fps;
@property (nonatomic, assign) CGFloat effFps;
@property (nonatomic, assign) BOOL hasLastPTS;
@property (nonatomic, assign) double lastPTS;
@property (nonatomic, assign) int preferredRotation;
@property (nonatomic, assign) volatile int64_t reqGen, appGen;
@property (nonatomic, copy) NSString *pendingPath;
@property (nonatomic, copy) NSString *failedPath;
@property (nonatomic, assign) CFAbsoluteTime failedAt;
@end

@implementation VCPlayer
- (instancetype)init {
    self = [super init];
    if (self) { _queue = [[VCQueue alloc] initWithCap:8]; _fps = 30; }
    return self;
}
- (void)dealloc { [self stop]; [_queue clear]; }
- (void)load:(NSString *)p {
    if (!p || p.length == 0) return;
    if ([p isEqualToString:_failedPath] && CFAbsoluteTimeGetCurrent() - _failedAt < 5.0) return;
    _pendingPath = [p copy];
    __sync_add_and_fetch(&_reqGen, 1);
    [self start];
}
- (void)start {
    if (_thread && _shouldRun) return;
    _shouldRun = YES;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(loop) object:nil];
    _thread.name = @"vcam.decoder";
    _thread.qualityOfService = NSQualityOfServiceDefault;
    [_thread start];
}
- (void)stop { _shouldRun = NO; }
- (NSDictionary *)readerOutputSettings {
    return @{ (id)kCVPixelBufferPixelFormatTypeKey: @((OSType)'420f') };
}
- (void)rebuild {
    @try {
        if (_reader) { [_reader cancelReading]; _reader = nil; }
        _output = nil; [_queue clear];
        if (!_asset || !_track) return;
        NSError *err = nil;
        _reader = [[AVAssetReader alloc] initWithAsset:_asset error:&err];
        if (err || !_reader) return;
        _output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:_track
                                                            outputSettings:[self readerOutputSettings]];
        _output.alwaysCopiesSampleData = NO;
        if (![_reader canAddOutput:_output]) { _reader = nil; _output = nil; return; }
        [_reader addOutput:_output];
        if (![_reader startReading]) { [_reader cancelReading]; _reader = nil; _output = nil; return; }
        for (int i = 0; i < 5; i++) {
            CVPixelBufferRef b = [self read];
            if (!b) break;
            [_queue push:b]; CVPixelBufferRelease(b);
        }
    } @catch (NSException *e) { vcamLog([NSString stringWithFormat:@"rebuild exception: %@", e]); }
}
- (void)restartReader {
    @try {
        if (_reader) { [_reader cancelReading]; _reader = nil; }
        _output = nil;
        if (!_asset || !_track) return;
        NSError *err = nil;
        _reader = [[AVAssetReader alloc] initWithAsset:_asset error:&err];
        if (err || !_reader) { _reader = nil; return; }
        _output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:_track
                                                            outputSettings:[self readerOutputSettings]];
        _output.alwaysCopiesSampleData = NO;
        if (![_reader canAddOutput:_output]) { _reader = nil; _output = nil; return; }
        [_reader addOutput:_output];
        if (![_reader startReading]) { [_reader cancelReading]; _reader = nil; _output = nil; }
    } @catch (NSException *e) { vcamLog([NSString stringWithFormat:@"restartReader exception: %@", e]); }
}
- (CVPixelBufferRef)read CF_RETURNS_RETAINED {
    if (!_output || _reader.status != AVAssetReaderStatusReading) return NULL;
    CMSampleBufferRef sb = [_output copyNextSampleBuffer];
    if (!sb) return NULL;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    double sec = CMTimeGetSeconds(pts);
    if (CMTIME_IS_VALID(pts) && !isnan(sec)) {
        if (_hasLastPTS && sec > _lastPTS) {
            double iv = sec - _lastPTS;
            if (iv >= 0.005 && iv <= 0.2) {
                double inst = 1.0 / iv;
                _effFps = (_effFps > 1.0) ? (_effFps * 0.8 + inst * 0.2) : inst;
            }
        }
        _lastPTS = sec;
        _hasLastPTS = YES;
    }
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (pb) CVPixelBufferRetain(pb);
    CFRelease(sb);
    return pb;
}
- (void)applyPath:(NSString *)p {
    @try {
        _asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:p]
                                     options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
        NSArray *t = [_asset tracksWithMediaType:AVMediaTypeVideo];
        if (!t || t.count == 0) {
            vcamLog(@"no video track");
            if (_reader) { [_reader cancelReading]; _reader = nil; }
            _output = nil; _track = nil;
            _failedPath = [p copy]; _failedAt = CFAbsoluteTimeGetCurrent();
            return;
        }
        _path = [p copy]; _failedPath = nil; _track = t[0];
        _w = (size_t)_track.naturalSize.width;
        _h = (size_t)_track.naturalSize.height;
        _fps = _track.nominalFrameRate > 1 ? _track.nominalFrameRate : 30.0;
        _effFps = 0; _hasLastPTS = NO; _lastPTS = 0;
        CGAffineTransform pt = _track.preferredTransform;
        if (pt.a == 0 && pt.b == 1 && pt.c == -1 && pt.d == 0) _preferredRotation = 90;
        else if (pt.a == -1 && pt.b == 0 && pt.c == 0 && pt.d == -1) _preferredRotation = 180;
        else if (pt.a == 0 && pt.b == -1 && pt.c == 1 && pt.d == 0) _preferredRotation = 270;
        else _preferredRotation = 0;
        [self rebuild];
    } @catch (NSException *e) {
        vcamLog([NSString stringWithFormat:@"applyPath exception: %@", e]);
        if (_reader) { [_reader cancelReading]; _reader = nil; }
        _output = nil; _track = nil;
        _failedPath = [p copy]; _failedAt = CFAbsoluteTimeGetCurrent();
    }
}
- (void)loop {
    @autoreleasepool {
        CFAbsoluteTime tick = CFAbsoluteTimeGetCurrent();
        while (_shouldRun) {
            @autoreleasepool {
                if (_reqGen != _appGen) { _appGen = _reqGen; if (_pendingPath) [self applyPath:_pendingPath]; }
                if (!_output) { [NSThread sleepForTimeInterval:0.1]; continue; }
                if (_paused) { [NSThread sleepForTimeInterval:0.05]; tick = CFAbsoluteTimeGetCurrent(); continue; }
                CVPixelBufferRef b = [self read];
                if (b) {
                    [_queue push:b]; CVPixelBufferRelease(b);
                    CGFloat ef = _effFps > 1.0 ? _effFps : (_fps > 1.0 ? _fps : 30.0);
                    double iv = 1.0 / MIN(MAX(ef, 1.0), 120.0);
                    tick += iv;
                    double w = tick - CFAbsoluteTimeGetCurrent();
                    if (w > 0.001) [NSThread sleepForTimeInterval:w];
                    else tick = CFAbsoluteTimeGetCurrent();
                } else {
                    if (_reader && _reader.status == AVAssetReaderStatusCompleted) [self restartReader];
                    [NSThread sleepForTimeInterval:0.005];
                    tick = CFAbsoluteTimeGetCurrent();
                }
            }
        }
    }
}
@end

// ======================= 镜像 =======================
static void vcamMirrorRowsInPlace(CVPixelBufferRef pb) {
    if (!pb) return;
    CVPixelBufferLockBaseAddress(pb, 0);
    int planes = (int)CVPixelBufferGetPlaneCount(pb);
    if (planes <= 0) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
        size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        size_t w = CVPixelBufferGetWidth(pb) * 4;
        size_t h = CVPixelBufferGetHeight(pb);
        for (size_t y = 0; y < h && base; y++) {
            uint8_t *row = base + y * bpr;
            for (size_t l = 0, r = w - 4; l < r; l += 4, r -= 4) {
                uint32_t t = *(uint32_t *)(row + l);
                *(uint32_t *)(row + l) = *(uint32_t *)(row + r);
                *(uint32_t *)(row + r) = t;
            }
        }
    } else {
        for (int p = 0; p < planes; p++) {
            uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, p);
            size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, p);
            size_t pw = CVPixelBufferGetWidthOfPlane(pb, p);
            size_t ph = CVPixelBufferGetHeightOfPlane(pb, p);
            size_t px = (p == 0) ? 1 : 2;
            size_t rowBytes = pw * px;
            for (size_t y = 0; y < ph && base; y++) {
                uint8_t *row = base + y * bpr;
                for (size_t l = 0, r = rowBytes - px; l < r; l += px, r -= px) {
                    for (size_t b = 0; b < px; b++) {
                        uint8_t t = row[l + b];
                        row[l + b] = row[r + b];
                        row[r + b] = t;
                    }
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}

// ======================= 附件拷贝 =======================
static void vcamCopyAttachments(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return;
    if (@available(iOS 15.0, *)) {
        CFDictionaryRef atts = CVBufferCopyAttachments(src, kCVAttachmentMode_ShouldPropagate);
        if (atts) { CVBufferSetAttachments(dst, atts, kCVAttachmentMode_ShouldPropagate); CFRelease(atts); }
    } else {
        static CFStringRef keys[3];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            keys[0] = kCVImageBufferColorPrimariesKey;
            keys[1] = kCVImageBufferTransferFunctionKey;
            keys[2] = kCVImageBufferYCbCrMatrixKey;
        });
        for (int i = 0; i < 3; i++) {
            CFTypeRef v = CVBufferGetAttachment(src, keys[i], NULL);
            if (v) CVBufferSetAttachment(dst, keys[i], v, kCVAttachmentMode_ShouldPropagate);
        }
    }
}
static void vcamSyncColorAttachments(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return;
    static CFStringRef keys[3];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys[0] = kCVImageBufferColorPrimariesKey;
        keys[1] = kCVImageBufferTransferFunctionKey;
        keys[2] = kCVImageBufferYCbCrMatrixKey;
    });
    for (int i = 0; i < 3; i++) {
        CFTypeRef v = CVBufferGetAttachment(src, keys[i], NULL);
        if (v) CVBufferSetAttachment(dst, keys[i], v, kCVAttachmentMode_ShouldPropagate);
    }
}
static void vcamTrimFractionalCrop(CVPixelBufferRef src, CVPixelBufferRef dst, BOOL *fixH, BOOL *fixV) {
    *fixH = NO; *fixV = NO;
    if (!src || !dst) return;
    size_t srcW = CVPixelBufferGetWidth(src), srcH = CVPixelBufferGetHeight(src);
    size_t dstW = CVPixelBufferGetWidth(dst), dstH = CVPixelBufferGetHeight(dst);
    if (!srcW || !srcH || !dstW || !dstH) return;
    double sc = MAX((double)dstW / srcW, (double)dstH / srcH);
    double cropW = srcW * sc - dstW;
    double cropH = srcH * sc - dstH;
    if (cropW > 0.5) {
        double off = cropW / 2.0;
        *fixH = (fabs(off - floor(off + 0.5)) > 1e-3);
    }
    if (cropH > 0.5) {
        double off = cropH / 2.0;
        *fixV = (fabs(off - floor(off + 0.5)) > 1e-3);
    }
}
static CVPixelBufferRef vcamCropStaging(CVPixelBufferRef staging, CVPixelBufferRef dst,
                                        CVPixelBufferRef *cropSlot, size_t *slotW, size_t *slotH) {
    if (!staging || !dst || !cropSlot) return NULL;
    size_t sw = CVPixelBufferGetWidth(staging), sh = CVPixelBufferGetHeight(staging);
    size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
    if (!sw || !sh || !dw || !dh) return NULL;
    double r = (double)dw / dh;
    size_t cw, ch;
    if ((double)sw / sh > r) { ch = sh; cw = (size_t)(sh * r); }
    else                     { cw = sw; ch = (size_t)(sw / r); }
    cw &= ~(size_t)1; ch &= ~(size_t)1;
    if (cw < 4 || ch < 4 || cw > sw || ch > sh) return NULL;
    size_t cx = (((sw - cw) / 2) & ~(size_t)1);
    size_t cy = (((sh - ch) / 2) & ~(size_t)1);
    if (!*cropSlot || *slotW != cw || *slotH != ch) {
        if (*cropSlot) CVPixelBufferRelease(*cropSlot);
        *cropSlot = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, cw, ch,
                                kCVPixelFormatType_32BGRA, NULL, cropSlot) != noErr || !*cropSlot) {
            *slotW = *slotH = 0; return NULL;
        }
        *slotW = cw; *slotH = ch;
    }
    CVPixelBufferLockBaseAddress(staging, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(*cropSlot, 0);
    uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddress(staging);
    uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddress(*cropSlot);
    size_t srb = CVPixelBufferGetBytesPerRow(staging);
    size_t drb = CVPixelBufferGetBytesPerRow(*cropSlot);
    if (sb && db && srb >= cw * 4 && drb >= cw * 4) {
        for (size_t y = 0; y < ch; y++)
            memcpy(db + y * drb, sb + (cy + y) * srb + cx * 4, cw * 4);
    } else {
        CVPixelBufferUnlockBaseAddress(*cropSlot, 0);
        CVPixelBufferUnlockBaseAddress(staging, kCVPixelBufferLock_ReadOnly);
        return NULL;
    }
    vcamSyncColorAttachments(staging, *cropSlot);
    CVPixelBufferUnlockBaseAddress(*cropSlot, 0);
    CVPixelBufferUnlockBaseAddress(staging, kCVPixelBufferLock_ReadOnly);
    return *cropSlot;
}

// [填充] 边界延伸：前景覆盖后，只在空隙处把前景边缘像素向外拉伸（无重叠、无黑边、无额外 VT）
static void vcamExtendEdges(CVPixelBufferRef canvas,
                            long dx0, long dy0, long dx1, long dy1) {
    size_t W = CVPixelBufferGetWidth(canvas);
    size_t H = CVPixelBufferGetHeight(canvas);
    if (W < 4 || H < 4) return;
    if (dx0 < 0) dx0 = 0;
    if (dy0 < 0) dy0 = 0;
    if (dx1 > (long)W) dx1 = W;
    if (dy1 > (long)H) dy1 = H;
    if (dx1 <= dx0 || dy1 <= dy0) return;

    CVPixelBufferLockBaseAddress(canvas, 0);

    uint8_t *yp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, 0);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(canvas, 0);
    if (yp) {
        for (long y = dy0; y < dy1; y++) {
            uint8_t *row = yp + (size_t)y * ys;
            if (dx0 > 0) {
                uint8_t c = row[dx0];
                for (long x = 0; x < dx0; x++) row[x] = c;
            }
            if (dx1 < (long)W) {
                uint8_t c = row[dx1 - 1];
                for (long x = dx1; x < (long)W; x++) row[x] = c;
            }
        }
        if (dy0 > 0) {
            uint8_t *src = yp + (size_t)dy0 * ys;
            for (long y = 0; y < dy0; y++) memcpy(yp + (size_t)y * ys, src, W);
        }
        if (dy1 < (long)H) {
            uint8_t *src = yp + (size_t)(dy1 - 1) * ys;
            for (long y = dy1; y < (long)H; y++) memcpy(yp + (size_t)y * ys, src, W);
        }
    }

    size_t cw = W / 2, ch = H / 2;
    long cdx0 = dx0 / 2, cdy0 = dy0 / 2, cdx1 = dx1 / 2, cdy1 = dy1 / 2;
    uint8_t *cp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, 1);
    size_t cs = CVPixelBufferGetBytesPerRowOfPlane(canvas, 1);
    if (cp) {
        for (long y = cdy0; y < cdy1; y++) {
            uint8_t *row = cp + (size_t)y * cs;
            if (cdx0 > 0) {
                uint8_t cb = row[cdx0 * 2];
                uint8_t cr = row[cdx0 * 2 + 1];
                for (long x = 0; x < cdx0; x++) {
                    row[x * 2] = cb; row[x * 2 + 1] = cr;
                }
            }
            if (cdx1 < (long)cw) {
                uint8_t cb = row[(cdx1 - 1) * 2];
                uint8_t cr = row[(cdx1 - 1) * 2 + 1];
                for (long x = cdx1; x < (long)cw; x++) {
                    row[x * 2] = cb; row[x * 2 + 1] = cr;
                }
            }
        }
        if (cdy0 > 0) {
            uint8_t *src = cp + (size_t)cdy0 * cs;
            for (long y = 0; y < cdy0; y++) memcpy(cp + (size_t)y * cs, src, cw * 2);
        }
        if (cdy1 < (long)ch) {
            uint8_t *src = cp + (size_t)(cdy1 - 1) * cs;
            for (long y = cdy1; y < (long)ch; y++) memcpy(cp + (size_t)y * cs, src, cw * 2);
        }
    }

    CVPixelBufferUnlockBaseAddress(canvas, 0);
}

// ======================= 图片模式 =======================
@interface VCImageStore : NSObject
+ (instancetype)shared;
- (BOOL)syncWithPath:(NSString *)path version:(int)ver rotation:(int)rot;
- (BOOL)replaceCameraBuffer:(CVPixelBufferRef)cam panX:(double)panX panY:(double)panY zoom:(double)zoom;
@end
@implementation VCImageStore {
    NSLock *_lock;
    CGImageRef _srcImage;
    size_t _srcW, _srcH;
    NSString *_lastPath;
    int _lastVer;
    int _rotation;
    VTPixelTransferSessionRef _toCam;
}
+ (instancetype)shared {
    static VCImageStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VCImageStore new]; });
    return s;
}
- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _rotation = 0;
        _lastVer = -1;
    }
    return self;
}
- (BOOL)syncWithPath:(NSString *)path version:(int)ver rotation:(int)rot {
    if (path.length == 0) return NO;
    [_lock lock];
    BOOL need = (!_lastPath || ![_lastPath isEqualToString:path] || ver != _lastVer || rot != _rotation);
    if (!need) { [_lock unlock]; return YES; }
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) { [_lock unlock]; return NO; }
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform:   @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize:          @(4096),
    };
    CGImageRef img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!img) { [_lock unlock]; return NO; }
    if (_srcImage) CGImageRelease(_srcImage);
    _srcImage = img;
    _srcW = CGImageGetWidth(img);
    _srcH = CGImageGetHeight(img);
    _lastPath = [path copy];
    _lastVer = ver;
    _rotation = ((rot % 360) + 360) % 360;
    [_lock unlock];
    vcamLog([NSString stringWithFormat:@"image loaded %@ (%zux%zu ver=%d rot=%d)",
             path.lastPathComponent, _srcW, _srcH, ver, rot]);
    return YES;
}
- (BOOL)replaceCameraBuffer:(CVPixelBufferRef)cam panX:(double)panX panY:(double)panY zoom:(double)zoom {
    if (!cam) return NO;
    [_lock lock];
    if (!_srcImage) { [_lock unlock]; return NO; }
    size_t camW = CVPixelBufferGetWidth(cam);
    size_t camH = CVPixelBufferGetHeight(cam);
    CVPixelBufferRef bgra = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, camW, camH,
                            kCVPixelFormatType_32BGRA, NULL, &bgra) != noErr || !bgra) {
        [_lock unlock]; return NO;
    }
    CVPixelBufferLockBaseAddress(bgra, 0);
    void *base = CVPixelBufferGetBaseAddress(bgra);
    size_t bpr = CVPixelBufferGetBytesPerRow(bgra);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, camW, camH, 8, bpr, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!ctx) { CVPixelBufferUnlockBaseAddress(bgra, 0); CVPixelBufferRelease(bgra); [_lock unlock]; return NO; }
    CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, camW, camH));
    BOOL swap = (_rotation == 90 || _rotation == 270);
    CGFloat effW = swap ? (CGFloat)_srcH : (CGFloat)_srcW;
    CGFloat effH = swap ? (CGFloat)_srcW : (CGFloat)_srcH;
    CGFloat baseScale = MAX((CGFloat)camW / effW, (CGFloat)camH / effH);
    CGFloat z = zoom < 0.5 ? 0.5 : (zoom > 4.0 ? 4.0 : zoom);
    CGFloat scale = baseScale * z;
    CGFloat drawW = (CGFloat)_srcW * scale;
    CGFloat drawH = (CGFloat)_srcH * scale;
    CGFloat cx = camW / 2.0 + panX * camW;
    CGFloat cy = camH / 2.0 - panY * camH;
    CGContextTranslateCTM(ctx, cx, cy);
    CGContextRotateCTM(ctx, (CGFloat)_rotation * (CGFloat)M_PI / 180.0);
    CGContextDrawImage(ctx, CGRectMake(-drawW/2.0, -drawH/2.0, drawW, drawH), _srcImage);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(bgra, 0);
    if (!_toCam) {
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_toCam) != noErr) _toCam = NULL;
        if (_toCam) {
            VTSessionSetProperty(_toCam, CFSTR("ScalingMode"), CFSTR("Trim"));
            VTSessionSetProperty(_toCam, CFSTR("RealTime"), kCFBooleanTrue);
        }
    }
    BOOL ok = NO;
    if (_toCam) {
        ok = (VTPixelTransferSessionTransferImage(_toCam, bgra, cam) == noErr);
        if (ok) vcamCopyAttachments(bgra, cam);
    }
    CVPixelBufferRelease(bgra);
    [_lock unlock];
    return ok;
}
- (void)dealloc {
    if (_srcImage) CGImageRelease(_srcImage);
    if (_toCam) VTPixelTransferSessionInvalidate(_toCam);
}
@end

// ======================= 图像处理 =======================
@interface VCProc : NSObject
@property (nonatomic, assign) VTPixelTransferSessionRef bgra, yuv, priv, normal;
@property (nonatomic, assign) VTPixelRotationSessionRef rot;
@property (nonatomic, assign) VTRotCreateT rotCreate;
@property (nonatomic, assign) VTRotTransT rotTransfer;
@property (nonatomic, assign) VTRotInvT rotInv;
@property (nonatomic, assign) CFStringRef rotKey, rotCW90, rotCCW90, rot180;
@property (nonatomic, assign) int rotationAngle, sourceRotation;
@property (nonatomic, assign) BOOL mirrored;
@property (nonatomic, assign) double panX, panY, zoom;
@property (nonatomic, assign) BOOL lightOn;
@property (nonatomic, assign) uint32_t lightColor;
@property (nonatomic, assign) int lightX, lightY, lightInt, lightDia, lightFea;
@property (nonatomic, assign) CVPixelBufferRef pieceA, pieceB;
@property (nonatomic, assign) size_t pieceAW, pieceAH, pieceBW, pieceBH;
@property (nonatomic, assign) OSType pieceFmt;
@property (nonatomic, assign) CVPixelBufferRef cropBuf;
@property (nonatomic, assign) size_t cropW, cropH;
@property (nonatomic, assign) VTPixelTransferSessionRef s1Session;
@property (nonatomic, strong) NSLock *laneLock;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *laneFailCounts;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *laneDisabled;
@property (nonatomic, assign) CVPixelBufferRef yuvStaging;
@property (nonatomic, assign) size_t yuvStagingW, yuvStagingH;
@property (nonatomic, assign) CVPixelBufferRef bgraStaging;
@property (nonatomic, assign) size_t bgraStagingW, bgraStagingH;
// [卡顿优化] process 结果缓存：同输入帧 + 同变换参数 → 复用上次输出
@property (nonatomic, assign) CVPixelBufferRef lastInPtr;
@property (nonatomic, assign) CVPixelBufferRef lastOut;
@property (nonatomic, assign) double lastPanX, lastPanY, lastZoom;
@property (nonatomic, assign) int lastRot;
@property (nonatomic, assign) BOOL lastMirror;
@property (nonatomic, assign) uint64_t lastLightSig;
@property (nonatomic, assign) int cacheHitCount;
- (instancetype)init;
- (BOOL)transfer:(CVPixelBufferRef)s to:(CVPixelBufferRef)d;
- (CVPixelBufferRef)process:(CVPixelBufferRef)s targetW:(size_t)tw targetH:(size_t)th CF_RETURNS_RETAINED;
- (CVPixelBufferRef)_process:(CVPixelBufferRef)s targetW:(size_t)tw targetH:(size_t)th CF_RETURNS_RETAINED;
@end

@implementation VCProc
- (instancetype)init {
    self = [super init];
    if (self) {
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_bgra);
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_yuv);
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_priv);
        if (_bgra) VTSessionSetProperty(_bgra, CFSTR("ScalingMode"), CFSTR("Trim"));
        if (_yuv) VTSessionSetProperty(_yuv, CFSTR("ScalingMode"), CFSTR("Trim"));
        if (_priv) {
            VTSessionSetProperty(_priv, CFSTR("ScalingMode"), CFSTR("Trim"));
            VTSessionSetProperty(_priv, CFSTR("RealTime"), kCFBooleanTrue);
        }
        void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_LAZY | RTLD_GLOBAL);
        void *base = vt ? vt : RTLD_DEFAULT;
        _rotCreate = (VTRotCreateT)dlsym(base, "VTPixelRotationSessionCreate");
        _rotTransfer = (VTRotTransT)dlsym(base, "VTPixelRotationSessionRotateImage");
        _rotInv = (VTRotInvT)dlsym(base, "VTPixelRotationSessionInvalidate");
        void *rk = dlsym(base, "kVTPixelRotationPropertyKey_Rotation");
        _rotKey = rk ? *(CFStringRef *)rk : CFSTR("Rotation");
        void *ccw = dlsym(base, "kVTRotation_CCW90");
        _rotCCW90 = ccw ? *(CFStringRef *)ccw : CFSTR("CCW90");
        void *cw = dlsym(base, "kVTRotation_CW90");
        _rotCW90 = cw ? *(CFStringRef *)cw : CFSTR("CW90");
        void *r180 = dlsym(base, "kVTRotation_180");
        _rot180 = r180 ? *(CFStringRef *)r180 : CFSTR("180");
        if (_rotCreate && _rotTransfer) _rotCreate(kCFAllocatorDefault, &_rot);
        _zoom = 1.0;
        _laneLock = [[NSLock alloc] init];
        _laneFailCounts = [NSMutableDictionary dictionary];
        _laneDisabled = [NSMutableDictionary dictionary];
        _s1Session = NULL;
        _cacheHitCount = 0;
    }
    return self;
}
- (void)dealloc {
    if (_pieceA) CVPixelBufferRelease(_pieceA);
    if (_pieceB) CVPixelBufferRelease(_pieceB);
    if (_cropBuf) CVPixelBufferRelease(_cropBuf);
    if (_yuvStaging) CVPixelBufferRelease(_yuvStaging);
    if (_bgraStaging) CVPixelBufferRelease(_bgraStaging);
    if (_lastOut) CVPixelBufferRelease(_lastOut);
    if (_bgra) VTPixelTransferSessionInvalidate(_bgra);
    if (_yuv) VTPixelTransferSessionInvalidate(_yuv);
    if (_priv) VTPixelTransferSessionInvalidate(_priv);
    if (_normal) VTPixelTransferSessionInvalidate(_normal);
    if (_s1Session) VTPixelTransferSessionInvalidate(_s1Session);
    if (_rot && _rotInv) _rotInv(_rot);
}
- (VTPixelTransferSessionRef)normalSession {
    if (_normal) return _normal;
    @synchronized(self) {
        if (!_normal) {
            if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_normal) == noErr) {
                VTSessionSetProperty(_normal, CFSTR("ScalingMode"), CFSTR("Normal"));
                VTSessionSetProperty(_normal, CFSTR("RealTime"), kCFBooleanTrue);
            }
        }
    }
    return _normal;
}
// 三车道 + 三级回退 + 熔断（照搬源码1 transferPixelBuffer:toPixelBuffer:token:）
- (BOOL)transfer:(CVPixelBufferRef)s to:(CVPixelBufferRef)d {
    if (!s || !d) return NO;
    OSType dstFormat = CVPixelBufferGetPixelFormatType(d);
    size_t srcW = CVPixelBufferGetWidth(s), srcH = CVPixelBufferGetHeight(s);
    size_t dstW = CVPixelBufferGetWidth(d), dstH = CVPixelBufferGetHeight(d);
    if ([_laneDisabled[@(dstFormat)] boolValue]) return NO;
    BOOL isYuvLane  = ((dstFormat & 0xffffffef) == '420f' || dstFormat == 0x70343230);
    BOOL isBgraLane = (dstFormat == kCVPixelFormatType_32BGRA);
    if (!isBgraLane && !isYuvLane) {
        [_laneLock lock];
        if (!_s1Session) {
            if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_s1Session) == noErr) {
                VTSessionSetProperty(_s1Session, CFSTR("ScalingMode"), CFSTR("Trim"));
                VTSessionSetProperty(_s1Session, CFSTR("RealTime"), kCFBooleanTrue);
            }
        }
        if (!_priv) {
            if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_priv) == noErr) {
                VTSessionSetProperty(_priv, CFSTR("ScalingMode"), CFSTR("Trim"));
                VTSessionSetProperty(_priv, CFSTR("RealTime"), kCFBooleanTrue);
            }
        }
        OSType srcFmt = CVPixelBufferGetPixelFormatType(s);
        BOOL srcYuvPlanar = (srcFmt == '420f' || srcFmt == '420v' || srcFmt == 0x70343230);
        BOOL sizeDiff = (srcW != dstW || srcH != dstH);
        if (srcYuvPlanar && sizeDiff && _priv) {
            OSStatus st = VTPixelTransferSessionTransferImage(_priv, s, d);
            if (st == noErr) { [_laneLock unlock]; return YES; }
        }
        if (srcYuvPlanar && sizeDiff && _priv && _s1Session) {
            if (!_yuvStaging || _yuvStagingW != srcW || _yuvStagingH != srcH) {
                if (_yuvStaging) { CVPixelBufferRelease(_yuvStaging); _yuvStaging = NULL; }
                if (CVPixelBufferCreate(kCFAllocatorDefault, srcW, srcH, '420f', NULL, &_yuvStaging) == noErr && _yuvStaging) {
                    _yuvStagingW = srcW; _yuvStagingH = srcH;
                }
            }
            if (_yuvStaging) {
                OSStatus st1 = VTPixelTransferSessionTransferImage(_s1Session, s, _yuvStaging);
                if (st1 == noErr) {
                    OSStatus st2 = VTPixelTransferSessionTransferImage(_priv, _yuvStaging, d);
                    if (st2 == noErr) { [_laneLock unlock]; return YES; }
                }
            }
        }
        if (_priv && _s1Session) {
            if (!_bgraStaging || _bgraStagingW != srcW || _bgraStagingH != srcH) {
                if (_bgraStaging) { CVPixelBufferRelease(_bgraStaging); _bgraStaging = NULL; }
                if (CVPixelBufferCreate(kCFAllocatorDefault, srcW, srcH,
                                        kCVPixelFormatType_32BGRA, NULL, &_bgraStaging) == noErr && _bgraStaging) {
                    _bgraStagingW = srcW; _bgraStagingH = srcH;
                }
            }
            if (_bgraStaging) {
                OSStatus st1 = VTPixelTransferSessionTransferImage(_s1Session, s, _bgraStaging);
                if (st1 == noErr) {
                    CVPixelBufferRef s2src = _bgraStaging;
                    VTPixelTransferSessionRef s2sess = _priv;
                    BOOL fixH = NO, fixV = NO;
                    vcamTrimFractionalCrop(_bgraStaging, d, &fixH, &fixV);
                    if (fixH || fixV) {
                        CVPixelBufferRef cropped = vcamCropStaging(_bgraStaging, d, &_cropBuf, &_cropW, &_cropH);
                        if (cropped) {
                            s2src = cropped;
                            VTPixelTransferSessionRef norm = [self normalSession];
                            if (norm) s2sess = norm;
                        }
                    }
                    OSStatus st2 = VTPixelTransferSessionTransferImage(s2sess, s2src, d);
                    if (st2 == noErr) { [_laneLock unlock]; return YES; }
                }
            }
        }
        [_laneLock unlock];
        @synchronized(self) {
            NSInteger fails = [_laneFailCounts[@(dstFormat)] integerValue] + 1;
            _laneFailCounts[@(dstFormat)] = @(fails);
            if (fails >= 2) _laneDisabled[@(dstFormat)] = @YES;
        }
        return NO;
    }
    VTPixelTransferSessionRef sess = isBgraLane ? _bgra : _yuv;
    if (!sess) return NO;
    [_laneLock lock];
    OSStatus st = VTPixelTransferSessionTransferImage(sess, s, d);
    [_laneLock unlock];
    if (st != noErr) {
        @synchronized(self) {
            NSInteger fails = [_laneFailCounts[@(dstFormat)] integerValue] + 1;
            _laneFailCounts[@(dstFormat)] = @(fails);
            if (fails >= 2) _laneDisabled[@(dstFormat)] = @YES;
        }
        return NO;
    }
    return YES;
}
- (CVPixelBufferRef)pieceAForW:(size_t)w H:(size_t)h fmt:(OSType)fmt {
    if (_pieceA && _pieceAW == w && _pieceAH == h && _pieceFmt == fmt) return _pieceA;
    if (_pieceA) { CVPixelBufferRelease(_pieceA); _pieceA = NULL; }
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, NULL, &_pieceA) != noErr || !_pieceA) { _pieceA = NULL; return NULL; }
    _pieceAW = w; _pieceAH = h; _pieceFmt = fmt;
    return _pieceA;
}
- (CVPixelBufferRef)pieceBForW:(size_t)w H:(size_t)h fmt:(OSType)fmt {
    if (_pieceB && _pieceBW == w && _pieceBH == h && _pieceFmt == fmt) return _pieceB;
    if (_pieceB) { CVPixelBufferRelease(_pieceB); _pieceB = NULL; }
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, NULL, &_pieceB) != noErr || !_pieceB) { _pieceB = NULL; return NULL; }
    _pieceBW = w; _pieceBH = h; _pieceFmt = fmt;
    return _pieceB;
}
// [填充] 前景清晰覆盖 + 空隙处源边缘像素自然延伸（无模糊背景、无重叠、无黑边）
- (CVPixelBufferRef)bakeTransform:(CVPixelBufferRef)input CF_RETURNS_RETAINED {
    if (!input) return NULL;
    BOOL noTransform = (fabs(_zoom - 1.0) < 0.001 && _panX == 0.0 && _panY == 0.0);
    if (noTransform) return (CVPixelBufferRef)CVPixelBufferRetain(input);
    if (CVPixelBufferGetPlaneCount(input) != 2) return (CVPixelBufferRef)CVPixelBufferRetain(input);
    size_t W = CVPixelBufferGetWidth(input), H = CVPixelBufferGetHeight(input);
    if (W < 16 || H < 16) return (CVPixelBufferRef)CVPixelBufferRetain(input);
    OSType fmt = CVPixelBufferGetPixelFormatType(input);
    CVPixelBufferRef canvas = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, W, H, fmt, NULL, &canvas) != noErr || !canvas)
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    vcamCopyAttachments(input, canvas);

    double z = _zoom < 0.5 ? 0.5 : (_zoom > 4.0 ? 4.0 : _zoom);
    double ww = W / z, wh = H / z;
    double wx = (W - ww) / 2.0 - _panX * W;
    double wy = (H - wh) / 2.0 - _panY * W;
    long sx0 = (long)MAX(wx, 0.0), sy0 = (long)MAX(wy, 0.0);
    long sx1 = (long)MIN(wx + ww, (double)W), sy1 = (long)MIN(wy + wh, (double)H);
    sx0 &= ~1L; sy0 &= ~1L; sx1 &= ~1L; sy1 &= ~1L;

    BOOL hasFg = NO;
    long dx0 = 0, dy0 = 0, dx1 = 0, dy1 = 0;

    if (sx1 > sx0 && sy1 > sy0) {
        size_t sw = sx1 - sx0, sh = sy1 - sy0;
        double kx = (double)W / ww;
        dx0 = lround(((double)sx0 - wx) * kx) & ~1L;
        dy0 = lround(((double)sy0 - wy) * kx) & ~1L;
        dx1 = lround(((double)sx1 - wx) * kx) & ~1L;
        dy1 = lround(((double)sy1 - wy) * kx) & ~1L;
        if (dx0 < 0) dx0 = 0; if (dy0 < 0) dy0 = 0;
        if (dx1 > (long)W) dx1 = W; if (dy1 > (long)H) dy1 = H;
        if (dx1 > dx0 && dy1 > dy0) {
            size_t dw = dx1 - dx0, dh = dy1 - dy0;
            CVPixelBufferRef pieceA = [self pieceAForW:sw H:sh fmt:fmt];
            CVPixelBufferRef pieceB = [self pieceBForW:dw H:dh fmt:fmt];
            if (pieceA && pieceB) {
                CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
                CVPixelBufferLockBaseAddress(pieceA, 0);
                for (int p = 0; p < 2; p++) {
                    uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(input, p);
                    uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pieceA, p);
                    if (!sb || !db) continue;
                    size_t srs = CVPixelBufferGetBytesPerRowOfPlane(input, p);
                    size_t drs = CVPixelBufferGetBytesPerRowOfPlane(pieceA, p);
                    size_t yDiv = (p == 0) ? 1 : 2;
                    for (size_t y = 0; y < sh / yDiv; y++)
                        memcpy(db + y * drs, sb + ((size_t)sy0 / yDiv + y) * srs + sx0, sw);
                }
                CVPixelBufferUnlockBaseAddress(pieceA, 0);
                CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
                if ([self transfer:pieceA to:pieceB]) {
                    CVPixelBufferLockBaseAddress(pieceB, kCVPixelBufferLock_ReadOnly);
                    CVPixelBufferLockBaseAddress(canvas, 0);
                    for (int p = 0; p < 2; p++) {
                        uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pieceB, p);
                        uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, p);
                        if (!sb || !db) continue;
                        size_t srs = CVPixelBufferGetBytesPerRowOfPlane(pieceB, p);
                        size_t drs = CVPixelBufferGetBytesPerRowOfPlane(canvas, p);
                        size_t yDiv = (p == 0) ? 1 : 2;
                        for (size_t y = 0; y < dh / yDiv; y++)
                            memcpy(db + ((size_t)dy0 / yDiv + y) * drs + dx0, sb + y * srs, dw);
                    }
                    CVPixelBufferUnlockBaseAddress(canvas, 0);
                    CVPixelBufferUnlockBaseAddress(pieceB, kCVPixelBufferLock_ReadOnly);
                    hasFg = YES;
                }
            }
        }
    }

    if (hasFg) {
        vcamExtendEdges(canvas, dx0, dy0, dx1, dy1);
    } else {
        // 前景完全在源外（罕见）：用源填满画布
        CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(canvas, 0);
        for (int p = 0; p < 2; p++) {
            uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(input, p);
            uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, p);
            if (!sb || !db) continue;
            size_t srs = CVPixelBufferGetBytesPerRowOfPlane(input, p);
            size_t drs = CVPixelBufferGetBytesPerRowOfPlane(canvas, p);
            size_t pw = CVPixelBufferGetWidthOfPlane(canvas, p);
            size_t ph = CVPixelBufferGetHeightOfPlane(canvas, p);
            size_t px = (p == 0) ? 1 : 2;
            for (size_t y = 0; y < ph; y++)
                memcpy(db + y * drs, sb + y * srs, pw * px);
        }
        CVPixelBufferUnlockBaseAddress(canvas, 0);
        CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    }
    return canvas;
}
// 彩色注入：整段未动
- (void)injectLight:(CVPixelBufferRef)buf {
    if (!buf || !_lightOn || _lightColor == 0) return;
    size_t W = CVPixelBufferGetWidth(buf), H = CVPixelBufferGetHeight(buf);
    if (W < 16 || H < 16 || CVPixelBufferGetPlaneCount(buf) != 2) return;
    if ((W & 1) || (H & 1)) return;
    uint8_t r = (_lightColor >> 16) & 0xFF;
    uint8_t g = (_lightColor >> 8) & 0xFF;
    uint8_t b = _lightColor & 0xFF;
    uint8_t cy = (uint8_t)((299 * r + 587 * g + 114 * b) / 1000);
    uint8_t cu = (uint8_t)((-169 * r - 331 * g + 500 * b) / 1000 + 128);
    uint8_t cv = (uint8_t)((500 * r - 419 * g - 81 * b) / 1000 + 128);
    int cx = (int)((int64_t)_lightX * W / 100);
    int cyy = (int)((int64_t)_lightY * H / 100);
    int minDim = (int)MIN(W, H);
    int radius = (int)((int64_t)_lightDia * minDim / 200);
    if (radius < 2) return;
    int innerR = radius * (100 - _lightFea) * 80 / 10000;
    int maxAlpha = _lightInt * 192 / 100;
    int radiusSq = radius * radius, innerSq = innerR * innerR;
    int feather = radiusSq - innerSq;
    double invA = feather > 0 ? (double)maxAlpha / feather : 0;
    uint8_t *yp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 0);
    uint8_t *cp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 1);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
    size_t cs = CVPixelBufferGetBytesPerRowOfPlane(buf, 1);
    if (!yp || !cp) return;
    int y0 = MAX(cyy - radius, 0), y1 = MIN(cyy + radius, (int)H);
    for (int y = y0; y < y1; y++) {
        int dy = y - cyy, dySq = dy * dy;
        if (dySq >= radiusSq) continue;
        uint8_t *row = yp + (size_t)y * ys;
        int remain = radiusSq - dySq;
        int dxMax = radius;
        dxMax = (dxMax + remain / dxMax) / 2;
        int x0 = MAX(cx - dxMax, 0), x1 = MIN(cx + dxMax, (int)W);
        int c0 = MAX(cx - innerR, x0), c1 = MIN(cx + innerR, x1);
        for (int x = x0; x < c0; x++) {
            int dx = x - cx, dSq = dx * dx + dySq;
            if (dSq <= innerSq || dSq >= radiusSq) continue;
            int a = (int)((radiusSq - dSq) * invA);
            row[x] = (uint8_t)((row[x] * (256 - a) + cy * a) >> 8);
        }
        for (int x = c0; x < c1; x++)
            row[x] = (uint8_t)((row[x] * (256 - maxAlpha) + cy * maxAlpha) >> 8);
        for (int x = c1; x < x1; x++) {
            int dx = x - cx, dSq = dx * dx + dySq;
            if (dSq <= innerSq || dSq >= radiusSq) continue;
            int a = (int)((radiusSq - dSq) * invA);
            row[x] = (uint8_t)((row[x] * (256 - a) + cy * a) >> 8);
        }
    }
    int bw2 = (int)W / 2, bh2 = (int)H / 2;
    int cx2 = cx / 2, cy2 = cyy / 2;
    int r2 = radius / 2, ir2 = innerR / 2;
    int r2Sq = r2 * r2, ir2Sq = ir2 * ir2;
    int f2 = r2Sq - ir2Sq;
    double invC = f2 > 0 ? (double)maxAlpha / f2 : 0;
    int yc0 = MAX(cy2 - r2, 0), yc1 = MIN(cy2 + r2, bh2);
    for (int y = yc0; y < yc1; y++) {
        int dy = y - cy2, dySq = dy * dy;
        if (dySq >= r2Sq) continue;
        uint8_t *row = cp + (size_t)y * cs;
        int remain = r2Sq - dySq;
        int dxMax = r2 < 1 ? 1 : r2;
        dxMax = (dxMax + remain / dxMax) / 2;
        int x0 = MAX(cx2 - dxMax, 0), x1 = MIN(cx2 + dxMax, bw2);
        int c0 = MAX(cx2 - ir2, x0), c1 = MIN(cx2 + ir2, x1);
        for (int x = x0; x < c0; x++) {
            int dx = x - cx2, dSq = dx * dx + dySq;
            if (dSq <= ir2Sq || dSq >= r2Sq) continue;
            int a = (int)((r2Sq - dSq) * invC);
            int i = x * 2;
            row[i] = (uint8_t)((row[i] * (256 - a) + cu * a) >> 8);
            row[i+1] = (uint8_t)((row[i+1] * (256 - a) + cv * a) >> 8);
        }
        for (int x = c0; x < c1; x++) {
            int i = x * 2;
            row[i] = (uint8_t)((row[i] * (256 - maxAlpha) + cu * maxAlpha) >> 8);
            row[i+1] = (uint8_t)((row[i+1] * (256 - maxAlpha) + cv * maxAlpha) >> 8);
        }
        for (int x = c1; x < x1; x++) {
            int dx = x - cx2, dSq = dx * dx + dySq;
            if (dSq <= ir2Sq || dSq >= r2Sq) continue;
            int a = (int)((r2Sq - dSq) * invC);
            int i = x * 2;
            row[i] = (uint8_t)((row[i] * (256 - a) + cu * a) >> 8);
            row[i+1] = (uint8_t)((row[i+1] * (256 - a) + cv * a) >> 8);
        }
    }
}
// [卡顿优化] 同输入帧 + 同变换参数 → 复用上次输出（30 次命中上限防指针池化误命中）
- (CVPixelBufferRef)process:(CVPixelBufferRef)s targetW:(size_t)tw targetH:(size_t)th CF_RETURNS_RETAINED {
    if (!s) return NULL;
    uint64_t lightSig = ((uint64_t)(_lightOn ? 1 : 0) << 56)
                      | ((uint64_t)(_lightColor & 0xFFFFFF) << 24)
                      | ((uint64_t)(_lightX & 0x7F) << 17)
                      | ((uint64_t)(_lightY & 0x7F) << 10)
                      | ((uint64_t)(_lightInt & 0x7F) << 3)
                      | (uint64_t)(_lightDia & 0x7);
    int curTotalRot = (_sourceRotation + _rotationAngle) % 360;
    if (curTotalRot < 0) curTotalRot += 360;
    BOOL cacheHit = (_lastOut != NULL)
                 && (_lastInPtr == s)
                 && (fabs(_lastPanX - _panX) < 1e-6
                     && fabs(_lastPanY - _panY) < 1e-6
                     && fabs(_lastZoom - _zoom) < 1e-6)
                 && (_lastRot == curTotalRot)
                 && (_lastMirror == _mirrored)
                 && (_lastLightSig == lightSig);
    if (cacheHit && _cacheHitCount < 30) {
        _cacheHitCount++;
        return (CVPixelBufferRef)CVPixelBufferRetain(_lastOut);
    }
    CVPixelBufferRef out = NULL;
    @try { out = [self _process:s targetW:tw targetH:th]; }
    @catch (NSException *e) { vcamLog([NSString stringWithFormat:@"process exception: %@", e]); }
    _lastInPtr = s;
    _lastPanX = _panX; _lastPanY = _panY; _lastZoom = _zoom;
    _lastRot = curTotalRot; _lastMirror = _mirrored;
    _lastLightSig = lightSig;
    _cacheHitCount = 0;
    if (_lastOut) CVPixelBufferRelease(_lastOut);
    _lastOut = out ? CVPixelBufferRetain(out) : NULL;
    return out;
}
- (CVPixelBufferRef)_process:(CVPixelBufferRef)s targetW:(size_t)tw targetH:(size_t)th CF_RETURNS_RETAINED {
    (void)tw; (void)th;
    size_t iw = CVPixelBufferGetWidth(s), ih = CVPixelBufferGetHeight(s);
    int total = (_sourceRotation + _rotationAngle) % 360;
    if (total < 0) total += 360;
    CVPixelBufferRef rot = s;
    BOOL rotOwned = NO;
    if (total != 0 && _rot && _rotTransfer) {
        size_t ow = (total == 90 || total == 270) ? ih : iw;
        size_t oh = (total == 90 || total == 270) ? iw : ih;
        OSType fmt = CVPixelBufferGetPixelFormatType(s);
        CVPixelBufferRef d = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, ow, oh, fmt, NULL, &d) == noErr && d) {
            CFTypeRef v = kCFBooleanFalse;
            if (total == 90) v = _rotCW90;
            else if (total == 180) v = _rot180;
            else if (total == 270) v = _rotCCW90;
            VTSessionSetProperty(_rot, _rotKey, v);
            if (_rotTransfer(_rot, s, d) == noErr) { rot = d; rotOwned = YES; }
            else CVPixelBufferRelease(d);
        }
    }
    CVPixelBufferRef use = rot;
    CVPixelBufferRef extra = NULL;
    if (_mirrored) {
        if (rotOwned) { vcamMirrorRowsInPlace(rot); }
        else {
            size_t w = CVPixelBufferGetWidth(rot), h = CVPixelBufferGetHeight(rot);
            OSType fmt = CVPixelBufferGetPixelFormatType(rot);
            if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, NULL, &extra) == noErr && extra) {
                int planes = (int)CVPixelBufferGetPlaneCount(rot);
                CVPixelBufferLockBaseAddress(rot, kCVPixelBufferLock_ReadOnly);
                CVPixelBufferLockBaseAddress(extra, 0);
                if (planes <= 0) {
                    uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddress(rot);
                    uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddress(extra);
                    size_t srs = CVPixelBufferGetBytesPerRow(rot);
                    size_t drs = CVPixelBufferGetBytesPerRow(extra);
                    size_t rows = CVPixelBufferGetHeight(rot);
                    size_t rb = MIN(srs, drs);
                    for (size_t y = 0; y < rows && sb && db; y++) memcpy(db + y * drs, sb + y * srs, rb);
                } else {
                    for (int p = 0; p < planes; p++) {
                        uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(rot, p);
                        uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(extra, p);
                        if (!sb || !db) continue;
                        size_t srs = CVPixelBufferGetBytesPerRowOfPlane(rot, p);
                        size_t drs = CVPixelBufferGetBytesPerRowOfPlane(extra, p);
                        size_t rows = CVPixelBufferGetHeightOfPlane(rot, p);
                        size_t rb = MIN(srs, drs);
                        for (size_t y = 0; y < rows; y++) memcpy(db + y * drs, sb + y * srs, rb);
                    }
                }
                CVPixelBufferUnlockBaseAddress(extra, 0);
                CVPixelBufferUnlockBaseAddress(rot, kCVPixelBufferLock_ReadOnly);
                vcamMirrorRowsInPlace(extra);
                use = extra;
            }
        }
    }
    CVPixelBufferRef baked = [self bakeTransform:use];
    if (extra) CVPixelBufferRelease(extra);
    if (rotOwned) CVPixelBufferRelease(rot);
    if (!baked) return NULL;
    if (_lightOn && _lightColor != 0 && CVPixelBufferGetPlaneCount(baked) == 2) {
        size_t bw = CVPixelBufferGetWidth(baked), bh = CVPixelBufferGetHeight(baked);
        if (!(bw & 1) && !(bh & 1)) {
            OSType fmt = CVPixelBufferGetPixelFormatType(baked);
            CVPixelBufferRef canvas = NULL;
            if (CVPixelBufferCreate(kCFAllocatorDefault, bw, bh, fmt, NULL, &canvas) == noErr && canvas) {
                CVPixelBufferLockBaseAddress(baked, kCVPixelBufferLock_ReadOnly);
                CVPixelBufferLockBaseAddress(canvas, 0);
                for (int p = 0; p < 2; p++) {
                    const uint8_t *sb = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(baked, p);
                    uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, p);
                    if (!sb || !db) continue;
                    size_t srs = CVPixelBufferGetBytesPerRowOfPlane(baked, p);
                    size_t drs = CVPixelBufferGetBytesPerRowOfPlane(canvas, p);
                    size_t rows = (p == 0) ? bh : bh / 2;
                    size_t rb = MIN(srs, drs);
                    for (size_t y = 0; y < rows; y++) memcpy(db + y * drs, sb + y * srs, rb);
                }
                CVPixelBufferUnlockBaseAddress(baked, kCVPixelBufferLock_ReadOnly);
                vcamCopyAttachments(baked, canvas);
                [self injectLight:canvas];
                CVPixelBufferUnlockBaseAddress(canvas, 0);
                CVPixelBufferRelease(baked);
                baked = canvas;
            }
        }
    }
    return baked;
}
@end

// ======================= 渲染核心 =======================
@interface VCCore : NSObject
@property (nonatomic, strong) VCPlayer *player;
@property (nonatomic, strong) VCProc *proc;
@property (nonatomic, strong) NSLock *renderLock;
@property (nonatomic, strong) NSLock *dedupLock;
@property (nonatomic, assign) CVPixelBufferRef dedupBuf;
@property (nonatomic, assign) double dedupPts;
@property (nonatomic, assign) CFAbsoluteTime dedupTime;
@property (nonatomic, assign) CVPixelBufferRef fallback;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL isMsd;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, assign) NSInteger lastEn, lastRot, lastPaused;
@property (nonatomic, assign) double lastPanX, lastPanY, lastZoom;
@property (nonatomic, assign) BOOL lastMirror, lastLightOn;
@property (nonatomic, assign) uint32_t lastLightColor;
@property (nonatomic, assign) int lastLX, lastLY, lastLI, lastLD, lastLF;
@property (nonatomic, assign) NSInteger lastVideoVersion;
+ (instancetype)shared;
- (void)startRender;
- (void)startPolling;
- (void)renderInto:(CVPixelBufferRef)pb pts:(double)pts;
- (void)_renderInto:(CVPixelBufferRef)pb pts:(double)pts;
@end

@implementation VCCore
+ (instancetype)shared {
    static VCCore *i; static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [[VCCore alloc] init]; });
    return i;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        _renderLock = [[NSLock alloc] init];
        _dedupLock = [[NSLock alloc] init];
        _lastEn = -1; _lastRot = -1; _lastPaused = -1;
        _lastZoom = -1;
        _lastMirror = NO; _lastLightOn = NO; _lastLightColor = 0;
        _lastVideoVersion = -1;
        BOOL isSB = [[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"];
        if (!isSB) {
            _player = [[VCPlayer alloc] init];
            _proc = [[VCProc alloc] init];
        } else {
            vcamLog(@"[vcam] VCCore lean init in SpringBoard");
        }
    }
    return self;
}
- (void)startRender {
    _isMsd = [[[NSProcessInfo processInfo] processName] isEqualToString:@"mediaserverd"];
    if (!_isMsd) return;
    NSString *p = plRead()[@"activePlaybackPath"];
    if (![p isKindOfClass:[NSString class]] || p.length == 0) p = @"/var/mobile/Media/DCIM/vcam.mp4";
    [_player load:p];
    [_player start];
    vcamLog(@"render started");
}
- (void)startPolling {
    if (_timer) return;
    dispatch_queue_t q = dispatch_queue_create("vcam.poll", DISPATCH_QUEUE_SERIAL);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.15 * NSEC_PER_SEC), (uint64_t)(0.075 * NSEC_PER_SEC));
    __weak typeof(self) w = self;
    dispatch_source_set_event_handler(_timer, ^{ [w poll]; });
    dispatch_resume(_timer);
}
- (void)poll {
    if (!_isMsd) return;
    @try {
        NSDictionary *pl = plRead();
        NSInteger en = [pl[@"enabled"] boolValue] ? 1 : 0;
        NSInteger rot = [pl[@"manualRotation"] integerValue];
        BOOL mirror = [pl[@"mirrored"] boolValue];
        double px = [pl[@"userPanX"] doubleValue];
        double py = [pl[@"userPanY"] doubleValue];
        double z = [pl[@"userZoom"] doubleValue];
        if (z <= 0) z = 1.0;
        BOOL lon = [pl[@"lightEnabled"] boolValue];
        uint32_t lc = (uint32_t)[pl[@"lightColor"] unsignedIntValue];
        int lx = pl[@"lightX"] ? [pl[@"lightX"] intValue] : 50;
        int ly = pl[@"lightY"] ? [pl[@"lightY"] intValue] : 50;
        int li = pl[@"lightIntensity"] ? [pl[@"lightIntensity"] intValue] : 30;
        int ld = pl[@"lightDiameter"] ? [pl[@"lightDiameter"] intValue] : 48;
        int lf = pl[@"lightFeather"] ? [pl[@"lightFeather"] intValue] : 100;
        if (lx <= 0 || lx > 100) lx = 50;
        if (ly <= 0 || ly > 100) ly = 50;
        if (li < 0 || li > 100) li = 30;
        if (ld <= 0 || ld > 100) ld = 48;
        if (lf < 0 || lf > 100) lf = 100;
        BOOL paused = [pl[@"paused"] boolValue];
        NSString *path = [pl[@"activePlaybackPath"] isKindOfClass:[NSString class]] ? pl[@"activePlaybackPath"] : nil;
        NSInteger videoVer = [pl[@"vcamVideoVersion"] integerValue];
        BOOL enChanged = (en != _lastEn);
        BOOL rotChanged = (rot != _lastRot);
        BOOL mirrorChanged = (mirror != _lastMirror);
        BOOL panChanged = (px != _lastPanX || py != _lastPanY || z != _lastZoom);
        BOOL lightChanged = (lon != _lastLightOn || lc != _lastLightColor ||
                             lx != _lastLX || ly != _lastLY || li != _lastLI || ld != _lastLD || lf != _lastLF);
        if (enChanged || rotChanged || mirrorChanged || panChanged || lightChanged) {
            [_renderLock lock];
            if (enChanged) { _lastEn = en; _enabled = (en == 1); }
            if (rotChanged) { _lastRot = rot; _proc.rotationAngle = (int)(rot % 360); }
            if (mirrorChanged) { _lastMirror = mirror; _proc.mirrored = mirror; }
            if (panChanged) { _lastPanX = px; _lastPanY = py; _lastZoom = z; _proc.panX = px; _proc.panY = py; _proc.zoom = z; }
            if (lightChanged) {
                _lastLightOn = lon; _lastLightColor = lc;
                _lastLX = lx; _lastLY = ly; _lastLI = li; _lastLD = ld; _lastLF = lf;
                _proc.lightOn = lon; _proc.lightColor = lc;
                _proc.lightX = lx; _proc.lightY = ly;
                _proc.lightInt = li; _proc.lightDia = ld; _proc.lightFea = lf;
            }
            [_renderLock unlock];
        }
        if (enChanged && _enabled) [_player start];
        // 视频版本检测：同一路径重新选视频也要 reload
        BOOL verChanged = (videoVer != _lastVideoVersion);
        if (path && (verChanged || ![path isEqualToString:_player.path])) {
            [_player load:path];
            _lastVideoVersion = videoVer;
            vcamLog([NSString stringWithFormat:@"[vcam] player reload: %@ ver=%ld",
                     path.lastPathComponent, (long)videoVer]);
        }
        if (paused != _lastPaused) { _lastPaused = paused; _player.paused = paused; }
    } @catch (NSException *e) { vcamLog([NSString stringWithFormat:@"poll exception: %@", e]); }
}
- (void)renderInto:(CVPixelBufferRef)pb pts:(double)pts {
    if (!_enabled || !pb) return;
    @try { [self _renderInto:pb pts:pts]; }
    @catch (NSException *e) { vcamLog([NSString stringWithFormat:@"renderInto exception: %@", e]); }
}
- (void)_renderInto:(CVPixelBufferRef)pb pts:(double)pts {
    [_dedupLock lock];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL same = (_dedupBuf == pb);
    BOOL dup = same && ((pts > 0 && _dedupPts == pts) || (now - _dedupTime < 0.005));
    if (pts > 0) _dedupPts = pts;
    _dedupBuf = pb; _dedupTime = now;
    [_dedupLock unlock];
    if (dup) return;

    NSDictionary *pl = plRead();
    NSString *mediaType = pl[@"vcamSlotMediaType"];
    if ([mediaType isEqualToString:@"image"]) {
        NSString *imgPath = pl[@"vcamActiveImagePath"];
        int ver = [pl[@"vcamImageVersion"] intValue];
        int rot = (int)[pl[@"manualRotation"] integerValue];
        double ipx = [pl[@"userPanX"] doubleValue];
        double ipy = [pl[@"userPanY"] doubleValue];
        double iz  = [pl[@"userZoom"] doubleValue];
        if (iz <= 0) iz = 1.0;
        if ([imgPath isKindOfClass:[NSString class]] && imgPath.length > 0) {
            [[VCImageStore shared] syncWithPath:imgPath version:ver rotation:rot];
            if ([[VCImageStore shared] replaceCameraBuffer:pb panX:ipx panY:ipy zoom:iz]) return;
        }
    }

    size_t tw = CVPixelBufferGetWidth(pb), th = CVPixelBufferGetHeight(pb);
    [_renderLock lock];
    CVPixelBufferRef frame = [_player.queue pop];
    if (!frame) frame = [_player.queue copyCurrent];
    if (!frame) frame = _fallback ? CVPixelBufferRetain(_fallback) : NULL;
    if (!frame) { [_renderLock unlock]; return; }
    _proc.sourceRotation = _player.preferredRotation;
    CVPixelBufferRef out = [_proc process:frame targetW:tw targetH:th];
    CVPixelBufferRelease(frame);
    if (out) {
        if ([_proc transfer:out to:pb]) {
            vcamCopyAttachments(out, pb);
            if (_fallback) CVPixelBufferRelease(_fallback);
            _fallback = CVPixelBufferRetain(out);
        } else {
            vcamLog(@"[vcam] transfer failed, keep camera frame");
        }
        CVPixelBufferRelease(out);
    }
    [_renderLock unlock];
}
@end

// ======================= Hook =======================
static void (*origEmit)(id, SEL, CMSampleBufferRef);
static void (*origScaler)(id, SEL, CMSampleBufferRef, id);
static void (*origEncoder)(id, SEL, CMSampleBufferRef, id);

static void processSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb) {
    if (!sb) return;
    @try {
        SEL mts = sel_registerName("mediaType");
        if ([self respondsToSelector:mts]) {
            uint32_t mt = ((uint32_t(*)(id, SEL))objc_msgSend)(self, mts);
            if (mt != 'vide') return;
        }
    } @catch (NSException *e) {}
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    if (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        fmt != kCVPixelFormatType_32BGRA) return;
    if (CVPixelBufferGetWidth(pb) & 1) return;
    if (CVPixelBufferGetPlaneCount(pb) == 2 &&
        CVPixelBufferGetWidthOfPlane(pb, 1) * 2 != CVPixelBufferGetWidth(pb)) return;
    @try {
        double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb));
        [[VCCore shared] renderInto:pb pts:pts];
    } @catch (NSException *e) { vcamLog([NSString stringWithFormat:@"render call exception: %@", e]); }
}
static void hookEmit(id self, SEL _cmd, CMSampleBufferRef sb) {
    @autoreleasepool { processSampleBuffer(self, _cmd, sb); if (origEmit) origEmit(self, _cmd, sb); }
}
static void hookScaler(id self, SEL _cmd, CMSampleBufferRef sb, id input) {
    @autoreleasepool { processSampleBuffer(self, _cmd, sb); if (origScaler) origScaler(self, _cmd, sb, input); }
}
static void hookEncoder(id self, SEL _cmd, CMSampleBufferRef sb, id input) {
    @autoreleasepool { processSampleBuffer(self, _cmd, sb); if (origEncoder) origEncoder(self, _cmd, sb, input); }
}
static void installHooks(void) {
    @try {
        Class c = objc_getClass("BWNodeOutput");
        if (c) {
            Method m = class_getInstanceMethod(c, sel_registerName("emitSampleBuffer:"));
            if (m) {
                origEmit = (void (*)(id, SEL, CMSampleBufferRef))method_getImplementation(m);
                method_setImplementation(m, (IMP)hookEmit);
                vcamLog(@"Hooked BWNodeOutput");
            }
        }
    } @catch (NSException *e) { vcamLog([NSString stringWithFormat:@"hook emit exception: %@", e]); }
    @try {
        Class c2 = objc_getClass("BWStillImageScalerNode");
        if (c2) {
            Method m = class_getInstanceMethod(c2, sel_registerName("renderSampleBuffer:forInput:"));
            if (m) {
                origScaler = (void (*)(id, SEL, CMSampleBufferRef, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)hookScaler);
                vcamLog(@"Hooked BWStillImageScalerNode");
            }
        }
    } @catch (NSException *e) { vcamLog([NSString stringWithFormat:@"hook scaler exception: %@", e]); }
    @try {
        Class c3 = objc_getClass("BWPhotoEncoderNode");
        if (c3) {
            Method m = class_getInstanceMethod(c3, sel_registerName("renderSampleBuffer:forInput:"));
            if (m) {
                origEncoder = (void (*)(id, SEL, CMSampleBufferRef, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)hookEncoder);
                vcamLog(@"Hooked BWPhotoEncoderNode");
            }
        }
    } @catch (NSException *e) { vcamLog([NSString stringWithFormat:@"hook encoder exception: %@", e]); }
}

// ======================= UI =======================
static void vcamBallLog(NSString *m) {
    NSArray *paths = @[@"/tmp/vcam_ball_log.txt",
                       @"/private/tmp/vcam_ball_log.txt",
                       @"/var/tmp/vcam_ball_log.txt",
                       @"/var/mobile/Media/DCIM/vcam_ball_log.txt"];
    NSString *e = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], m];
    for (NSString *p in paths) {
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) [e writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            else { [fh seekToEndOfFile]; [fh writeData:[e dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        } @catch (NSException *e) {}
    }
}
static UIColor *CBgDeep(void)    { return [UIColor colorWithRed:0.00 green:0.188 blue:0.125 alpha:0.65]; }
static UIColor *CBtnBg(void)     { return [UIColor colorWithRed:0.00 green:0.275 blue:0.188 alpha:0.80]; }
static UIColor *CBtnBorder(void) { return [UIColor colorWithRed:0.486 green:1.00 blue:0.698 alpha:0.40]; }
static UIColor *CTextMain(void)  { return [UIColor colorWithRed:0.875 green:1.00 blue:0.933 alpha:1.0]; }
static UIColor *CGlow(void)      { return [UIColor colorWithRed:0.486 green:1.00 blue:0.698 alpha:1.0]; }
static UIColor *CDeep(void)      { return [UIColor colorWithRed:0.02 green:0.04 blue:0.02 alpha:1.0]; }

@interface VCOverlayWindow : UIWindow @end
@implementation VCOverlayWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *h = [super hitTest:p withEvent:e];
    if (h == self || h == self.rootViewController.view) return nil;
    return h;
}
@end

@interface VCBallView : UIView
@property (nonatomic, strong) UILabel *mainLabel;
@property (nonatomic, strong) UILabel *yenLabel;
@end
@implementation VCBallView
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = f.size.width / 2;
        self.layer.masksToBounds = NO;
        self.layer.borderWidth = 1;
        self.layer.borderColor = CBtnBorder().CGColor;
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        blur.frame = self.bounds;
        blur.layer.cornerRadius = f.size.width / 2;
        blur.layer.masksToBounds = YES;
        blur.userInteractionEnabled = NO;
        [self addSubview:blur];
        UIView *tint = [[UIView alloc] initWithFrame:self.bounds];
        tint.backgroundColor = [UIColor colorWithRed:0 green:0.188 blue:0.125 alpha:0.35];
        tint.layer.cornerRadius = f.size.width / 2;
        tint.userInteractionEnabled = NO;
        [self addSubview:tint];
        _mainLabel = [[UILabel alloc] initWithFrame:CGRectMake(4, f.size.height*0.30, f.size.width-8, f.size.height*0.34)];
        _mainLabel.text = @"SQKJ";
        _mainLabel.textAlignment = NSTextAlignmentCenter;
        _mainLabel.textColor = CGlow();
        _mainLabel.font = [UIFont fontWithName:@"Courier New-Bold" size:13] ?: [UIFont boldSystemFontOfSize:13];
        _mainLabel.layer.shadowColor = CGlow().CGColor;
        _mainLabel.layer.shadowRadius = 6;
        _mainLabel.layer.shadowOpacity = 0.9;
        _mainLabel.layer.shadowOffset = CGSizeZero;
        [self addSubview:_mainLabel];
        _yenLabel = [[UILabel alloc] initWithFrame:CGRectMake(f.size.width-22, 6, 18, 18)];
        _yenLabel.text = @"¥";
        _yenLabel.textAlignment = NSTextAlignmentCenter;
        _yenLabel.textColor = CGlow();
        _yenLabel.font = [UIFont boldSystemFontOfSize:12];
        _yenLabel.layer.shadowColor = CGlow().CGColor;
        _yenLabel.layer.shadowRadius = 4;
        _yenLabel.layer.shadowOpacity = 0.9;
        _yenLabel.layer.shadowOffset = CGSizeZero;
        [self addSubview:_yenLabel];
    }
    return self;
}
@end

static UIButton *makeRetroBtn(NSString *title, CGRect frame, id t, SEL s) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:CTextMain() forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont fontWithName:@"Courier New-Bold" size:12] ?: [UIFont boldSystemFontOfSize:12];
    b.backgroundColor = CBtnBg();
    b.layer.cornerRadius = 10;
    b.layer.borderWidth = 1;
    b.layer.borderColor = CBtnBorder().CGColor;
    if (t && s) [b addTarget:t action:s forControlEvents:UIControlEventTouchUpInside];
    return b;
}
static UIButton *makeIconBtn(NSString *sys, CGRect frame, id t, SEL s) {
    UIButton *b = makeRetroBtn(@"", frame, t, s);
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold];
    UIImage *img = [UIImage systemImageNamed:sys withConfiguration:cfg];
    if (img) { [b setImage:img forState:UIControlStateNormal]; b.tintColor = CTextMain(); }
    return b;
}

@interface VCBall : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, strong) UIWindow *win;
@property (nonatomic, strong) VCBallView *ball;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *ctrlPage, *lightPage;
@property (nonatomic, strong) UIButton *tabCtrlBtn, *tabLightBtn;
@property (nonatomic, strong) UIButton *replaceBtn, *playBtn, *mirrorBtn, *lightBtn;
@property (nonatomic, strong) NSMutableArray<UIButton *> *colorBtns;
@property (nonatomic, strong) NSMutableArray<UILabel *> *sliderValueLabels;
@property (nonatomic, strong) NSMutableArray<UISlider *> *sliders;
@property (nonatomic, assign) BOOL visible, floating, paused, lightPageActive;
@property (nonatomic, assign) int buildRetries;
+ (instancetype)shared;
- (void)show;
- (void)hide;
- (void)build;
- (void)_build;
@end

@implementation VCBall
+ (instancetype)shared {
    static VCBall *i; static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [[VCBall alloc] init]; });
    return i;
}
- (void)show {
    if (_floating) return;
    _floating = YES;
    vcamBallLog(@"[vcam] VCBall show");
    dispatch_async(dispatch_get_main_queue(), ^{ [self build]; });
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didActive) name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)hide {
    _floating = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.win removeFromSuperview];
        self.win.hidden = YES;
        self.win = nil; self.ball = nil; self.panel = nil;
        self.ctrlPage = nil; self.lightPage = nil;
    });
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)didActive {
    vcamBallLog(@"[vcam] VCBall didActive");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_floating && self.win && self.win.windowScene == nil) {
            vcamBallLog(@"[vcam] VCBall window no scene, recreating");
            [self.win removeFromSuperview];
            self.win = nil;
            [self build];
        }
    });
}
- (void)build {
    @try { [self _build]; }
    @catch (NSException *e) { vcamBallLog([NSString stringWithFormat:@"[vcam] build exception: %@", e]); }
}
- (void)_build {
    CGRect sb = [UIScreen mainScreen].bounds;
    if (sb.size.width < 100 || sb.size.height < 100) {
        if (_buildRetries < 20) {
            _buildRetries++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self->_floating) [self build];
            });
        }
        return;
    }
    _buildRetries = 0;
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene) for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    if (scene) {
        _win = [[VCOverlayWindow alloc] initWithWindowScene:scene];
    } else {
        _win = [[VCOverlayWindow alloc] initWithFrame:sb];
    }
    _win.frame = sb;
    _win.windowLevel = UIWindowLevelAlert + 100;
    _win.backgroundColor = [UIColor clearColor];
    _win.rootViewController = [[UIViewController alloc] init];
    _win.hidden = NO;
    _win.userInteractionEnabled = YES;
    CGFloat bs = 64;
    CGFloat bx = sb.size.width - bs - 20;
    CGFloat by = sb.size.height / 2 - bs / 2;
    _ball = [[VCBallView alloc] initWithFrame:CGRectMake(bx, by, bs, bs)];
    [_ball addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ballTap)]];
    [_ball addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(ballDrag:)]];
    [self buildPanel];
    [_win addSubview:_ball];
}
- (void)buildPanel {
    CGFloat pw = 250, ph = 400, pad = 12;
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, ph)];
    _panel.backgroundColor = CBgDeep();
    _panel.layer.borderWidth = 1;
    _panel.layer.borderColor = CBtnBorder().CGColor;
    _panel.layer.cornerRadius = 10;
    _panel.hidden = YES;
    _panel.alpha = 0;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, 8, pw - pad * 2, 26)];
    title.text = @"iOS-画面切换器-SQKJ";
    title.textColor = CGlow();
    title.font = [UIFont boldSystemFontOfSize:12];
    title.textAlignment = NSTextAlignmentCenter;
    [_panel addSubview:title];
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(pad, 38, pw - pad * 2, 1)];
    sep.backgroundColor = CBtnBorder();
    [_panel addSubview:sep];
    CGFloat tabY = 46, tabH = 26, contentW = pw - pad * 2;
    CGFloat tabW = (contentW - 6) / 2;
    _tabCtrlBtn = makeRetroBtn(@"控制", CGRectMake(pad, tabY, tabW, tabH), self, @selector(switchCtrlTab));
    _tabLightBtn = makeRetroBtn(@"打光", CGRectMake(pad + tabW + 6, tabY, tabW, tabH), self, @selector(switchLightTab));
    [_panel addSubview:_tabCtrlBtn]; [_panel addSubview:_tabLightBtn];
    CGFloat pageY = tabY + tabH + 6;
    CGFloat pageH = ph - pageY - pad;
    _ctrlPage = [[UIView alloc] initWithFrame:CGRectMake(0, pageY, pw, pageH)];
    [self buildCtrlPage:_ctrlPage width:pw pad:pad contentW:contentW pageH:pageH];
    [_panel addSubview:_ctrlPage];
    _lightPage = [[UIView alloc] initWithFrame:CGRectMake(0, pageY, pw, pageH)];
    [self buildLightPage:_lightPage width:pw pad:pad contentW:contentW pageH:pageH];
    _lightPage.hidden = YES;
    [_panel addSubview:_lightPage];
    [self refreshVisuals];
    [_win addSubview:_panel];
}
// 控制页：旋转/镜像/播放 左右边缘与方向键区精确对齐；方向键 - [←] [复] [→] +
- (void)buildCtrlPage:(UIView *)page width:(CGFloat)pw pad:(CGFloat)pad
             contentW:(CGFloat)contentW pageH:(CGFloat)pageH {
    CGFloat y = 0, btnH = 30, gap = 8;

    CGFloat cell = 44, dg = 4, smallW = 32;
    CGFloat dpadTotal = smallW + dg + cell + dg + cell + dg + cell + dg + smallW;
    CGFloat dpadStartX = pad + (contentW - dpadTotal) / 2.0;

    [page addSubview:makeRetroBtn(@"选择 视频/图片",
                                  CGRectMake(pad, y, contentW, btnH),
                                  self, @selector(pickMedia))];
    y += btnH + gap;

    _replaceBtn = makeRetroBtn(@"替 换 · ON",
                               CGRectMake
