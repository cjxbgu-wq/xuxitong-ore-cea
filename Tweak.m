//
//  Tweak.m
//  VCamPlus · 最终稳定版
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import <math.h>
#import <string.h>
#import <mach-o/dyld.h>
#include <mach/mach_time.h>
#import <Vision/Vision.h>

static NSString *const kPlist = @"/var/mobile/Media/DCIM/vc.plist";

__attribute__((unused)) static BOOL vcamLogOn(void) {
    static int c = -1;
    if (c < 0) {
        @try {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPlist];
            if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
            if (d) c = d[@"logEnabled"] ? [d[@"logEnabled"] boolValue] : 0;
        } @catch (NSException *e) {}
    }
    return c == 1;
}
__attribute__((unused)) static void vcamLog(NSString *m) {
    if (!vcamLogOn()) return;
    @try {
        NSString *p = @"/tmp/vcam_log.txt";
        NSString *e = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], m];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) [e writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        else { [fh seekToEndOfFile]; [fh writeData:[e dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    } @catch (NSException *e) {}
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

static NSDictionary *plRead(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPlist];
    if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/rootfs/private/var/mobile/Media/DCIM/vc.plist"];
    return d ?: @{};
}
static void plSet(NSString *k, id v) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:plRead()];
    if (v) d[k] = v; else [d removeObjectForKey:k];
    [d writeToFile:kPlist atomically:NO];
}
static void plSetMany(NSDictionary *kv) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:plRead()];
    for (NSString *k in kv) {
        id v = kv[k];
        if (v) d[k] = v; else [d removeObjectForKey:k];
    }
    [d writeToFile:kPlist atomically:NO];
}

typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
typedef struct OpaqueVTPixelRotationSession *VTPixelRotationSessionRef;
extern OSStatus VTPixelTransferSessionCreate(CFAllocatorRef, VTPixelTransferSessionRef *);
extern OSStatus VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);
extern OSStatus VTPixelTransferSessionInvalidate(VTPixelTransferSessionRef);
extern OSStatus VTSessionSetProperty(CFTypeRef, CFStringRef, CFTypeRef);
typedef OSStatus (*VTRotCreateT)(CFAllocatorRef, VTPixelRotationSessionRef *);
typedef OSStatus (*VTRotTransT)(VTPixelRotationSessionRef, CVPixelBufferRef, CVPixelBufferRef);
typedef OSStatus (*VTRotInvT)(VTPixelRotationSessionRef);

@interface VCQueue : NSObject
@property (nonatomic, strong) NSMutableArray *arr;
@property (nonatomic, strong) NSRecursiveLock *lock;
@property (nonatomic, assign) NSUInteger cap;
@property (nonatomic, assign) CVPixelBufferRef current;
@end
@implementation VCQueue
- (instancetype)initWithCap:(NSUInteger)cap { if (self = [super init]) { _arr = [NSMutableArray array]; _lock = [[NSRecursiveLock alloc] init]; _cap = cap; } return self; }
- (void)dealloc { [self clear]; }
- (void)push:(CVPixelBufferRef)b {
    if (!b) return; [_lock lock]; [_arr addObject:(__bridge id)b];
    while (_arr.count > _cap) [_arr removeObjectAtIndex:0];
    if (_current) CVPixelBufferRelease(_current);
    _current = b; CVPixelBufferRetain(_current); [_lock unlock];
}
- (CVPixelBufferRef)pop CF_RETURNS_RETAINED {
    [_lock lock]; CVPixelBufferRef b = NULL;
    if (_arr.count > 0) { b = (__bridge CVPixelBufferRef)_arr[0]; CVPixelBufferRetain(b); [_arr removeObjectAtIndex:0]; }
    [_lock unlock]; return b;
}
- (CVPixelBufferRef)copyCurrent CF_RETURNS_RETAINED { [_lock lock]; CVPixelBufferRef b = _current ? CVPixelBufferRetain(_current) : NULL; [_lock unlock]; return b; }
- (void)clear { [_lock lock]; [_arr removeAllObjects]; if (_current) { CVPixelBufferRelease(_current); _current = NULL; } [_lock unlock]; }
@end

@interface VCPlayer : NSObject
@property (nonatomic, strong) AVURLAsset *asset; @property (nonatomic, strong) AVAssetTrack *track; @property (nonatomic, strong) AVAssetReader *reader; @property (nonatomic, strong) AVAssetReaderTrackOutput *output;
@property (nonatomic, copy) NSString *path; @property (nonatomic, strong) VCQueue *queue; @property (nonatomic, strong) NSThread *thread;
@property (nonatomic, assign) BOOL shouldRun, paused; @property (nonatomic, assign) size_t w, h; @property (nonatomic, assign) CGFloat fps, effFps;
@property (nonatomic, assign) BOOL hasLastPTS; @property (nonatomic, assign) double lastPTS; @property (nonatomic, assign) int preferredRotation;
@property (nonatomic, assign) volatile int64_t reqGen, appGen; @property (nonatomic, copy) NSString *pendingPath, *failedPath; @property (nonatomic, assign) CFAbsoluteTime failedAt;
@end

@implementation VCPlayer
- (instancetype)init { if (self = [super init]) { _queue = [[VCQueue alloc] initWithCap:8]; _fps = 30; } return self; }
- (void)dealloc { [self stop]; [_queue clear]; }
- (void)load:(NSString *)p {
    if (!p || p.length == 0) return;
    if ([p isEqualToString:_failedPath] && CFAbsoluteTimeGetCurrent() - _failedAt < 5.0) return;
    _pendingPath = [p copy]; __sync_add_and_fetch(&_reqGen, 1); [self start];
}
- (void)start { if (_thread && _shouldRun) return; _shouldRun = YES; _thread = [[NSThread alloc] initWithTarget:self selector:@selector(loop) object:nil]; _thread.name = @"vcam.decoder"; _thread.qualityOfService = NSQualityOfServiceDefault; [_thread start]; }
- (void)stop { _shouldRun = NO; }
- (NSDictionary *)readerOutputSettings { return @{ (id)kCVPixelBufferPixelFormatTypeKey: @((OSType)'420f') }; }
- (void)rebuild {
    @try {
        if (_reader) { [_reader cancelReading]; _reader = nil; }
        _output = nil; [_queue clear];
        if (!_asset || !_track) return;
        NSError *err = nil; _reader = [[AVAssetReader alloc] initWithAsset:_asset error:&err];
        if (err || !_reader) return;
        _output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:_track outputSettings:[self readerOutputSettings]]; _output.alwaysCopiesSampleData = NO;
        if (![_reader canAddOutput:_output]) { _reader = nil; _output = nil; return; }
        [_reader addOutput:_output];
        if (![_reader startReading]) { [_reader cancelReading]; _reader = nil; _output = nil; return; }
        for (int i = 0; i < 5; i++) { CVPixelBufferRef b = [self read]; if (!b) break; [_queue push:b]; CVPixelBufferRelease(b); }
    } @catch (NSException *e) {}
}
- (void)restartReader {
    @try {
        if (_reader) { [_reader cancelReading]; _reader = nil; }
        _output = nil; if (!_asset || !_track) return;
        NSError *err = nil; _reader = [[AVAssetReader alloc] initWithAsset:_asset error:&err];
        if (err || !_reader) { _reader = nil; return; }
        _output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:_track outputSettings:[self readerOutputSettings]]; _output.alwaysCopiesSampleData = NO;
        if (![_reader canAddOutput:_output]) { _reader = nil; _output = nil; return; }
        [_reader addOutput:_output];
        if (![_reader startReading]) { [_reader cancelReading]; _reader = nil; _output = nil; }
    } @catch (NSException *e) {}
}
- (CVPixelBufferRef)read CF_RETURNS_RETAINED {
    if (!_output || _reader.status != AVAssetReaderStatusReading) return NULL;
    CMSampleBufferRef sb = [_output copyNextSampleBuffer];
    if (!sb) return NULL;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb); double sec = CMTimeGetSeconds(pts);
    if (CMTIME_IS_VALID(pts) && !isnan(sec)) {
        if (_hasLastPTS && sec > _lastPTS) {
            double iv = sec - _lastPTS;
            if (iv >= 0.005 && iv <= 0.2) _effFps = (_effFps > 1.0) ? (_effFps * 0.8 + (1.0 / iv) * 0.2) : (1.0 / iv);
        }
        _lastPTS = sec; _hasLastPTS = YES;
    }
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb); if (pb) CVPixelBufferRetain(pb);
    CFRelease(sb); return pb;
}
- (void)applyPath:(NSString *)p {
    @try {
        _asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:p] options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
        NSArray *t = [_asset tracksWithMediaType:AVMediaTypeVideo];
        if (!t || t.count == 0) { _failedPath = [p copy]; _failedAt = CFAbsoluteTimeGetCurrent(); return; }
        _path = [p copy]; _failedPath = nil; _track = t[0];
        _w = (size_t)_track.naturalSize.width; _h = (size_t)_track.naturalSize.height;
        _fps = _track.nominalFrameRate > 1 ? _track.nominalFrameRate : 30.0;
        _effFps = 0; _hasLastPTS = NO; _lastPTS = 0;
        CGAffineTransform pt = _track.preferredTransform;
        if (pt.a == 0 && pt.b == 1 && pt.c == -1 && pt.d == 0) _preferredRotation = 90;
        else if (pt.a == -1 && pt.b == 0 && pt.c == 0 && pt.d == -1) _preferredRotation = 180;
        else if (pt.a == 0 && pt.b == -1 && pt.c == 1 && pt.d == 0) _preferredRotation = 270;
        else _preferredRotation = 0;
        [self rebuild];
    } @catch (NSException *e) {}
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
                    double iv = 1.0 / MIN(MAX(ef, 1.0), 120.0); tick += iv;
                    double w = tick - CFAbsoluteTimeGetCurrent();
                    if (w > 0.001) [NSThread sleepForTimeInterval:w]; else tick = CFAbsoluteTimeGetCurrent();
                } else {
                    if (_reader && _reader.status == AVAssetReaderStatusCompleted) [self restartReader];
                    [NSThread sleepForTimeInterval:0.005]; tick = CFAbsoluteTimeGetCurrent();
                }
            }
        }
    }
}
@end

static void vcamMirrorRowsInPlace(CVPixelBufferRef pb) {
    if (!pb) return; CVPixelBufferLockBaseAddress(pb, 0); int planes = (int)CVPixelBufferGetPlaneCount(pb);
    if (planes <= 0) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb); size_t bpr = CVPixelBufferGetBytesPerRow(pb);
        size_t w = CVPixelBufferGetWidth(pb) * 4; size_t h = CVPixelBufferGetHeight(pb);
        for (size_t y = 0; y < h && base; y++) {
            uint8_t *row = base + y * bpr;
            for (size_t l = 0, r = w - 4; l < r; l += 4, r -= 4) {
                uint32_t t = *(uint32_t *)(row + l); *(uint32_t *)(row + l) = *(uint32_t *)(row + r); *(uint32_t *)(row + r) = t;
            }
        }
    } else {
        for (int p = 0; p < planes; p++) {
            uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, p); size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, p);
            size_t pw = CVPixelBufferGetWidthOfPlane(pb, p); size_t ph = CVPixelBufferGetHeightOfPlane(pb, p);
            size_t px = (p == 0) ? 1 : 2; size_t rowBytes = pw * px;
            for (size_t y = 0; y < ph && base; y++) {
                uint8_t *row = base + y * bpr;
                for (size_t l = 0, r = rowBytes - px; l < r; l += px, r -= px) {
                    for (size_t b = 0; b < px; b++) { uint8_t t = row[l + b]; row[l + b] = row[r + b]; row[r + b] = t; }
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
}
static void vcamCopyAttachments(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return;
    if (@available(iOS 15.0, *)) {
        CFDictionaryRef atts = CVBufferCopyAttachments(src, kCVAttachmentMode_ShouldPropagate);
        if (atts) { CVBufferSetAttachments(dst, atts, kCVAttachmentMode_ShouldPropagate); CFRelease(atts); }
    } else {
        static CFStringRef keys[3]; static dispatch_once_t once;
        dispatch_once(&once, ^{ keys[0] = kCVImageBufferColorPrimariesKey; keys[1] = kCVImageBufferTransferFunctionKey; keys[2] = kCVImageBufferYCbCrMatrixKey; });
        for (int i = 0; i < 3; i++) { CFTypeRef v = CVBufferGetAttachment(src, keys[i], NULL); if (v) CVBufferSetAttachment(dst, keys[i], v, kCVAttachmentMode_ShouldPropagate); }
    }
}
static void vcamExtendEdges(CVPixelBufferRef canvas, long dx0, long dy0, long dx1, long dy1) {
    size_t W = CVPixelBufferGetWidth(canvas), H = CVPixelBufferGetHeight(canvas);
    if (W < 4 || H < 4) return; dx0 = MAX(0, dx0); dy0 = MAX(0, dy0); dx1 = MIN((long)W, dx1); dy1 = MIN((long)H, dy1);
    if (dx1 <= dx0 || dy1 <= dy0) return; CVPixelBufferLockBaseAddress(canvas, 0);
    uint8_t *yp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, 0); size_t ys = CVPixelBufferGetBytesPerRowOfPlane(canvas, 0);
    if (yp) {
        for (long y = dy0; y < dy1; y++) {
            uint8_t *row = yp + (size_t)y * ys;
            if (dx0 > 0) { uint8_t c = row[dx0]; for (long x = 0; x < dx0; x++) row[x] = c; }
            if (dx1 < (long)W) { uint8_t c = row[dx1 - 1]; for (long x = dx1; x < (long)W; x++) row[x] = c; }
        }
        if (dy0 > 0) { uint8_t *src = yp + (size_t)dy0 * ys; for (long y = 0; y < dy0; y++) memcpy(yp + (size_t)y * ys, src, W); }
        if (dy1 < (long)H) { uint8_t *src = yp + (size_t)(dy1 - 1) * ys; for (long y = dy1; y < (long)H; y++) memcpy(yp + (size_t)y * ys, src, W); }
    }
    size_t cw = W / 2, ch = H / 2; long cdx0 = dx0 / 2, cdy0 = dy0 / 2, cdx1 = dx1 / 2, cdy1 = dy1 / 2;
    uint8_t *cp = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, 1); size_t cs = CVPixelBufferGetBytesPerRowOfPlane(canvas, 1);
    if (cp) {
        for (long y = cdy0; y < cdy1; y++) {
            uint8_t *row = cp + (size_t)y * cs;
            if (cdx0 > 0) { uint8_t cb = row[cdx0 * 2], cr = row[cdx0 * 2 + 1]; for (long x = 0; x < cdx0; x++) { row[x * 2] = cb; row[x * 2 + 1] = cr; } }
            if (cdx1 < (long)cw) { uint8_t cb = row[(cdx1 - 1) * 2], cr = row[(cdx1 - 1) * 2 + 1]; for (long x = cdx1; x < (long)cw; x++) { row[x * 2] = cb; row[x * 2 + 1] = cr; } }
        }
        if (cdy0 > 0) { uint8_t *src = cp + (size_t)cdy0 * cs; for (long y = 0; y < cdy0; y++) memcpy(cp + (size_t)y * cs, src, cw * 2); }
        if (cdy1 < (long)ch) { uint8_t *src = cp + (size_t)(cdy1 - 1) * cs; for (long y = cdy1; y < (long)ch; y++) memcpy(cp + (size_t)y * cs, src, cw * 2); }
    }
    CVPixelBufferUnlockBaseAddress(canvas, 0);
}

@interface VCImageStore : NSObject
+ (instancetype)shared;
- (BOOL)syncWithPath:(NSString *)path version:(int)ver rotation:(int)rot;
- (BOOL)replaceCameraBuffer:(CVPixelBufferRef)cam panX:(double)panX panY:(double)panY zoom:(double)zoom;
@end
@implementation VCImageStore {
    NSLock *_lock; CGImageRef _srcImage; size_t _srcW, _srcH; NSString *_lastPath; int _lastVer; int _rotation; VTPixelTransferSessionRef _toCam;
}
+ (instancetype)shared { static VCImageStore *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [VCImageStore new]; }); return s; }
- (instancetype)init { if ((self = [super init])) { _lock = [NSLock new]; _rotation = 0; _lastVer = -1; } return self; }
- (BOOL)syncWithPath:(NSString *)path version:(int)ver rotation:(int)rot {
    if (path.length == 0) return NO; [_lock lock];
    BOOL need = (!_lastPath || ![_lastPath isEqualToString:path] || ver != _lastVer || rot != _rotation);
    if (!need) { [_lock unlock]; return YES; }
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) { [_lock unlock]; return NO; }
    NSDictionary *opts = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES, (id)kCGImageSourceCreateThumbnailWithTransform: @YES, (id)kCGImageSourceThumbnailMaxPixelSize: @(4096)};
    CGImageRef img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts); CFRelease(src);
    if (!img) { [_lock unlock]; return NO; }
    if (_srcImage) CGImageRelease(_srcImage);
    _srcImage = img; _srcW = CGImageGetWidth(img); _srcH = CGImageGetHeight(img); _lastPath = [path copy]; _lastVer = ver; _rotation = ((rot % 360) + 360) % 360;
    [_lock unlock]; return YES;
}
- (BOOL)replaceCameraBuffer:(CVPixelBufferRef)cam panX:(double)panX panY:(double)panY zoom:(double)zoom {
    if (!cam) return NO; [_lock lock]; if (!_srcImage) { [_lock unlock]; return NO; }
    size_t camW = CVPixelBufferGetWidth(cam), camH = CVPixelBufferGetHeight(cam); CVPixelBufferRef bgra = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, camW, camH, kCVPixelFormatType_32BGRA, NULL, &bgra) != noErr || !bgra) { [_lock unlock]; return NO; }
    CVPixelBufferLockBaseAddress(bgra, 0); CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(bgra), camW, camH, 8, CVPixelBufferGetBytesPerRow(bgra), cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst); CGColorSpaceRelease(cs);
    if (!ctx) { CVPixelBufferUnlockBaseAddress(bgra, 0); CVPixelBufferRelease(bgra); [_lock unlock]; return NO; }
    CGContextSetRGBFillColor(ctx, 0, 0, 0, 1); CGContextFillRect(ctx, CGRectMake(0, 0, camW, camH));
    BOOL swap = (_rotation == 90 || _rotation == 270);
    CGFloat effW = swap ? (CGFloat)_srcH : (CGFloat)_srcW, effH = swap ? (CGFloat)_srcW : (CGFloat)_srcH;
    CGFloat baseScale = MAX((CGFloat)camW / effW, (CGFloat)camH / effH), z = zoom < 0.5 ? 0.5 : (zoom > 4.0 ? 4.0 : zoom);
    CGFloat scale = baseScale * z, drawW = (CGFloat)_srcW * scale, drawH = (CGFloat)_srcH * scale;
    CGContextTranslateCTM(ctx, camW / 2.0 + panX * camW, camH / 2.0 - panY * camH);
    CGContextRotateCTM(ctx, (CGFloat)_rotation * (CGFloat)M_PI / 180.0);
    CGContextDrawImage(ctx, CGRectMake(-drawW/2.0, -drawH/2.0, drawW, drawH), _srcImage);
    CGContextRelease(ctx); CVPixelBufferUnlockBaseAddress(bgra, 0);
    if (!_toCam) { if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_toCam) == noErr) { VTSessionSetProperty(_toCam, CFSTR("ScalingMode"), CFSTR("Trim")); VTSessionSetProperty(_toCam, CFSTR("RealTime"), kCFBooleanTrue); } }
    BOOL ok = NO;
    if (_toCam) { ok = (VTPixelTransferSessionTransferImage(_toCam, bgra, cam) == noErr); if (ok) vcamCopyAttachments(bgra, cam); }
    CVPixelBufferRelease(bgra); [_lock unlock]; return ok;
}
- (void)dealloc { if (_srcImage) CGImageRelease(_srcImage); if (_toCam) VTPixelTransferSessionInvalidate(_toCam); }
@end

@interface VCProc : NSObject
@property (nonatomic, assign) VTPixelTransferSessionRef bgra, yuv, priv, normal; @property (nonatomic, assign) VTPixelRotationSessionRef rot;
@property (nonatomic, assign) VTRotCreateT rotCreate; @property (nonatomic, assign) VTRotTransT rotTransfer; @property (nonatomic, assign) VTRotInvT rotInv;
@property (nonatomic, assign) CFStringRef rotKey, rotCW90, rotCCW90, rot180; @property (nonatomic, assign) int rotationAngle, sourceRotation;
@property (nonatomic, assign) BOOL mirrored; @property (nonatomic, assign) double panX, panY, zoom;
@property (nonatomic, assign) CVPixelBufferRef pieceA, pieceB; @property (nonatomic, assign) size_t pieceAW, pieceAH, pieceBW, pieceBH; @property (nonatomic, assign) OSType pieceFmt;
@property (nonatomic, assign) CVPixelBufferRef cropBuf; @property (nonatomic, assign) size_t cropW, cropH; @property (nonatomic, strong) NSLock *laneLock;
@property (nonatomic, strong) NSMutableDictionary *laneFailCounts, *laneDisabled;
@property (nonatomic, assign) CVPixelBufferRef lastInPtr, lastOut; @property (nonatomic, assign) double lastPanX, lastPanY, lastZoom; @property (nonatomic, assign) int lastRot; @property (nonatomic, assign) BOOL lastMirror;
@property (nonatomic, assign) int cacheHitCount; @property (nonatomic, assign) BOOL vesselFlowEnabled;
- (instancetype)init; - (BOOL)transfer:(CVPixelBufferRef)s to:(CVPixelBufferRef)d; - (CVPixelBufferRef)process:(CVPixelBufferRef)s targetW:(size_t)tw targetH:(size_t)th CF_RETURNS_RETAINED; - (CVPixelBufferRef)_process:(CVPixelBufferRef)s targetW:(size_t)tw targetH:(size_t)th CF_RETURNS_RETAINED;
@end

@implementation VCProc
- (instancetype)init {
    self = [super init];
    if (self) {
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_bgra); VTPixelTransferSessionCreate(kCFAllocatorDefault, &_yuv); VTPixelTransferSessionCreate(kCFAllocatorDefault, &_priv);
        if (_bgra) VTSessionSetProperty(_bgra, CFSTR("ScalingMode"), CFSTR("Trim"));
        if (_yuv) VTSessionSetProperty(_yuv, CFSTR("ScalingMode"), CFSTR("Trim"));
        if (_priv) { VTSessionSetProperty(_priv, CFSTR("ScalingMode"), CFSTR("Trim")); VTSessionSetProperty(_priv, CFSTR("RealTime"), kCFBooleanTrue); }
        void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_LAZY | RTLD_GLOBAL); void *base = vt ? vt : RTLD_DEFAULT;
        _rotCreate = (VTRotCreateT)dlsym(base, "VTPixelRotationSessionCreate"); _rotTransfer = (VTRotTransT)dlsym(base, "VTPixelRotationSessionRotateImage"); _rotInv = (VTRotInvT)dlsym(base, "VTPixelRotationSessionInvalidate");
        void *rk = dlsym(base, "kVTPixelRotationPropertyKey_Rotation"); _rotKey = rk ? *(CFStringRef *)rk : CFSTR("Rotation");
        void *ccw = dlsym(base, "kVTRotation_CCW90"); _rotCCW90 = ccw ? *(CFStringRef *)ccw : CFSTR("CCW90");
        void *cw = dlsym(base, "kVTRotation_CW90"); _rotCW90 = cw ? *(CFStringRef *)cw : CFSTR("CW90");
        void *r180 = dlsym(base, "kVTRotation_180"); _rot180 = r180 ? *(CFStringRef *)r180 : CFSTR("180");
        if (_rotCreate && _rotTransfer) _rotCreate(kCFAllocatorDefault, &_rot);
        _zoom = 1.0; _laneLock = [[NSLock alloc] init]; _laneFailCounts = [NSMutableDictionary dictionary]; _laneDisabled = [NSMutableDictionary dictionary]; _vesselFlowEnabled = NO;
    }
    return self;
}
- (void)dealloc {
    if (_pieceA) CVPixelBufferRelease(_pieceA); if (_pieceB) CVPixelBufferRelease(_pieceB); if (_cropBuf) CVPixelBufferRelease(_cropBuf); if (_lastOut) CVPixelBufferRelease(_lastOut);
    if (_bgra) VTPixelTransferSessionInvalidate(_bgra); if (_yuv) VTPixelTransferSessionInvalidate(_yuv); if (_priv) VTPixelTransferSessionInvalidate(_priv); if (_normal) VTPixelTransferSessionInvalidate(_normal); if (_rot && _rotInv) _rotInv(_rot);
}
- (VTPixelTransferSessionRef)normalSession { if (_normal) return _normal; @synchronized(self) { if (!_normal) { if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_normal) == noErr) { VTSessionSetProperty(_normal, CFSTR("ScalingMode"), CFSTR("Normal")); VTSessionSetProperty(_normal, CFSTR("RealTime"), kCFBooleanTrue); } } } return _normal; }
- (BOOL)transfer:(CVPixelBufferRef)s to:(CVPixelBufferRef)d {
    if (!s || !d) return NO;
    OSType dstFormat = CVPixelBufferGetPixelFormatType(d); if ([_laneDisabled[@(dstFormat)] boolValue]) return NO;
    BOOL isYuvLane = ((dstFormat & 0xffffffef) == '420f' || dstFormat == 0x70343230); BOOL isBgraLane = (dstFormat == kCVPixelFormatType_32BGRA);
    if (!isBgraLane && !isYuvLane) {
        [_laneLock lock]; if (!_priv) { if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_priv) == noErr) { VTSessionSetProperty(_priv, CFSTR("ScalingMode"), CFSTR("Trim")); VTSessionSetProperty(_priv, CFSTR("RealTime"), kCFBooleanTrue); } }
        OSStatus st = VTPixelTransferSessionTransferImage(_priv, s, d); [_laneLock unlock]; return st == noErr;
    }
    VTPixelTransferSessionRef sess = isBgraLane ? _bgra : _yuv; if (!sess) return NO;
    [_laneLock lock]; OSStatus st = VTPixelTransferSessionTransferImage(sess, s, d); [_laneLock unlock]; return st == noErr;
}
- (CVPixelBufferRef)pieceAForW:(size_t)w H:(size_t)h fmt:(OSType)fmt {
    if (_pieceA && _pieceAW == w && _pieceAH == h && _pieceFmt == fmt) return _pieceA;
    if (_pieceA) { CVPixelBufferRelease(_pieceA); _pieceA = NULL; }
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, NULL, &_pieceA) != noErr || !_pieceA) { _pieceA = NULL; return NULL; }
    _pieceAW = w; _pieceAH = h; _pieceFmt = fmt; return _pieceA;
}
- (CVPixelBufferRef)pieceBForW:(size_t)w H:(size_t)h fmt:(OSType)fmt {
    if (_pieceB && _pieceBW == w && _pieceBH == h && _pieceFmt == fmt) return _pieceB;
    if (_pieceB) { CVPixelBufferRelease(_pieceB); _pieceB = NULL; }
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, NULL, &_pieceB) != noErr || !_pieceB) { _pieceB = NULL; return NULL; }
    _pieceBW = w; _pieceBH = h; _pieceFmt = fmt; return _pieceB;
}
- (CVPixelBufferRef)bakeTransform:(CVPixelBufferRef)input CF_RETURNS_RETAINED {
    if (!input) return NULL;
    BOOL noTransform = (fabs(_zoom - 1.0) < 0.001 && _panX == 0.0 && _panY == 0.0);
    if (noTransform || CVPixelBufferGetPlaneCount(input) != 2) return (CVPixelBufferRef)CVPixelBufferRetain(input);
    size_t W = CVPixelBufferGetWidth(input), H = CVPixelBufferGetHeight(input); if (W < 16 || H < 16) return (CVPixelBufferRef)CVPixelBufferRetain(input);
    OSType fmt = CVPixelBufferGetPixelFormatType(input); CVPixelBufferRef canvas = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, W, H, fmt, NULL, &canvas) != noErr || !canvas) return (CVPixelBufferRef)CVPixelBufferRetain(input);
    vcamCopyAttachments(input, canvas);
    double z = _zoom < 0.5 ? 0.5 : (_zoom > 4.0 ? 4.0 : _zoom), ww = W / z, wh = H / z, wx = (W - ww) / 2.0 - _panX * W, wy = (H - wh) / 2.0 - _panY * W;
    long sx0 = (long)MAX(wx, 0.0), sy0 = (long)MAX(wy, 0.0), sx1 = (long)MIN(wx + ww, (double)W), sy1 = (long)MIN(wy + wh, (double)H);
    sx0 &= ~1L; sy0 &= ~1L; sx1 &= ~1L; sy1 &= ~1L; BOOL hasFg = NO; long dx0 = 0, dy0 = 0, dx1 = 0, dy1 = 0;
    if (sx1 > sx0 && sy1 > sy0) {
        size_t sw = sx1 - sx0, sh = sy1 - sy0; double kx = (double)W / ww;
        dx0 = lround(((double)sx0 - wx) * kx) & ~1L; dy0 = lround(((double)sy0 - wy) * kx) & ~1L;
        dx1 = lround(((double)sx1 - wx) * kx) & ~1L; dy1 = lround(((double)sy1 - wy) * kx) & ~1L;
        dx0 = MAX(0, dx0); dy0 = MAX(0, dy0); dx1 = MIN((long)W, dx1); dy1 = MIN((long)H, dy1);
        if (dx1 > dx0 && dy1 > dy0) {
            size_t dw = dx1 - dx0, dh = dy1 - dy0; CVPixelBufferRef pA = [self pieceAForW:sw H:sh fmt:fmt], pB = [self pieceBForW:dw H:dh fmt:fmt];
            if (pA && pB) {
                CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(pA, 0);
                for (int p = 0; p < 2; p++) {
                    uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(input, p), *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pA, p);
                    if (!sb || !db) continue; size_t srs = CVPixelBufferGetBytesPerRowOfPlane(input, p), drs = CVPixelBufferGetBytesPerRowOfPlane(pA, p), yD = (p == 0) ? 1 : 2;
                    for (size_t y = 0; y < sh / yD; y++) memcpy(db + y * drs, sb + ((size_t)sy0 / yD + y) * srs + sx0, sw);
                }
                CVPixelBufferUnlockBaseAddress(pA, 0); CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
                if ([self transfer:pA to:pB]) {
                    CVPixelBufferLockBaseAddress(pB, kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(canvas, 0);
                    for (int p = 0; p < 2; p++) {
                        uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pB, p), *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, p);
                        if (!sb || !db) continue; size_t srs = CVPixelBufferGetBytesPerRowOfPlane(pB, p), drs = CVPixelBufferGetBytesPerRowOfPlane(canvas, p), yD = (p == 0) ? 1 : 2;
                        for (size_t y = 0; y < dh / yD; y++) memcpy(db + ((size_t)dy0 / yD + y) * drs + dx0, sb + y * srs, dw);
                    }
                    CVPixelBufferUnlockBaseAddress(canvas, 0); CVPixelBufferUnlockBaseAddress(pB, kCVPixelBufferLock_ReadOnly); hasFg = YES;
                }
            }
        }
    }
    if (hasFg) {
        vcamExtendEdges(canvas, dx0, dy0, dx1, dy1);
    } else {
        CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(canvas, 0);
        for (int p = 0; p < 2; p++) {
            uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(input, p), *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, p);
            if (!sb || !db) continue; size_t srs = CVPixelBufferGetBytesPerRowOfPlane(input, p), drs = CVPixelBufferGetBytesPerRowOfPlane(canvas, p), pw = CVPixelBufferGetWidthOfPlane(canvas, p), ph = CVPixelBufferGetHeightOfPlane(canvas, p), px = (p == 0) ? 1 : 2;
            for (size_t y = 0; y < ph; y++) memcpy(db + y * drs, sb + y * srs, pw * px);
        }
        CVPixelBufferUnlockBaseAddress(canvas, 0); CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    }
    return canvas;
}
- (void)injectVesselFlow:(CVPixelBufferRef)buf {
    if (!buf) return;
    NSDictionary *pl = plRead(); CGFloat injR = 0.75, injG = 0.18, injB = 0.12;
    if ([pl[@"lightEnabled"] boolValue]) {
        uint32_t c = (uint32_t)[pl[@"lightColor"] unsignedIntValue];
        if (c != 0) { injR = ((c >> 16) & 0xFF) / 255.0; injG = ((c >> 8) & 0xFF) / 255.0; injB = (c & 0xFF) / 255.0; }
    }
    CGFloat injAlpha = 0.35; id aObj = pl[@"injectAlpha"];
    if (aObj) { injAlpha = [aObj doubleValue]; if (injAlpha < 0.05) injAlpha = 0.05; if (injAlpha > 1.0) injAlpha = 1.0; }
    CGFloat injDiameter = 0.50, injOffX = 0.0, injOffY = 0.0; int injMode = 1;

    static CIContext *sCtx = nil; if (!sCtx) sCtx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    CIImage *raw = [CIImage imageWithCVPixelBuffer:buf options:@{kCIImageColorSpace:[NSNull null]}]; if (!raw) return;
    CGRect ext = raw.extent; if (ext.size.width < 4 || ext.size.height < 4) return;
    CGImageRef cg = [sCtx createCGImage:raw fromRect:ext]; if (!cg) return;
    CIImage *img = [CIImage imageWithCGImage:cg]; CGImageRelease(cg); if (!img) return;

    static int sDetectSkip = 0; static CGRect gLastFaceRect; static uint64_t gLastFaceTime = 0; CGRect faceRect = gLastFaceRect;
    if (sDetectSkip <= 0 || CGRectIsEmpty(faceRect)) {
        @autoreleasepool {
            VNDetectFaceLandmarksRequest *req = [[VNDetectFaceLandmarksRequest alloc] init];
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:img options:@{}];
            [handler performRequests:@[req] error:nil];
            NSArray<VNFaceObservation *> *results = req.results;
            if (results.count > 0) {
                VNFaceObservation *obs = results[0]; CGRect bbox = obs.boundingBox;
                CGFloat imgW = ext.size.width, imgH = ext.size.height, bx = bbox.origin.x * imgW, by = bbox.origin.y * imgH, bw = bbox.size.width * imgW, bh = bbox.size.height * imgH;
                CGFloat cx = bx + bw * 0.5 + injOffX * bw, cy = by + bh * 0.5 + injOffY * bh, nw = bw * injDiameter * 2, nh = bh * injDiameter * 2;
                faceRect = CGRectIntersection(CGRectMake(cx - nw * 0.5, cy - nh * 0.5, nw, nh), ext);
                gLastFaceRect = faceRect; gLastFaceTime = mach_absolute_time();
            } else {
                mach_timebase_info_data_t tbi; mach_timebase_info(&tbi);
                if ((mach_absolute_time() - gLastFaceTime) * tbi.numer / tbi.denom > 500000000ULL) { gLastFaceRect = CGRectZero; return; }
            }
        }
        sDetectSkip = 3;
    } else { sDetectSkip--; }
    if (CGRectIsEmpty(faceRect)) return;

    CIImage *mask = nil;
    if (!mask) {
        CGFloat mcx = CGRectGetMidX(faceRect), mcy = CGRectGetMidY(faceRect), radius = MAX(faceRect.size.width, faceRect.size.height) * 0.5;
        CIFilter *radial = [CIFilter filterWithName:@"CIRadialGradient"];
        [radial setValue:[CIVector vectorWithX:mcx Y:mcy] forKey:@"inputCenter"]; [radial setValue:@(radius * 0.6) forKey:@"inputRadius0"]; [radial setValue:@(radius) forKey:@"inputRadius1"];
        [radial setValue:[CIColor colorWithRed:1 green:1 blue:1 alpha:1] forKey:@"inputColor0"]; [radial setValue:[CIColor colorWithRed:1 green:1 blue:1 alpha:0] forKey:@"inputColor1"];
        mask = [radial.outputImage imageByCroppingToRect:ext];
    }
    if (!mask) return;
    CIImage *colorImg = [[CIImage imageWithColor:[CIColor colorWithRed:injR green:injG blue:injB alpha:injAlpha]] imageByCroppingToRect:ext];
    CIFilter *blendMask = [CIFilter filterWithName:@"CIBlendWithMask"];
    [blendMask setValue:colorImg forKey:kCIInputImageKey]; [blendMask setValue:img forKey:kCIInputBackgroundImageKey]; [blendMask setValue:mask forKey:@"inputMaskImage"];
    CIImage *result = blendMask.outputImage; if (result) [sCtx render:result toCVPixelBuffer:buf];
}
- (CVPixelBufferRef)process:(CVPixelBufferRef)s targetW:(size_t)tw targetH:(size_t)th CF_RETURNS_RETAINED {
    if (!s) return NULL; int curTotalRot = (_sourceRotation + _rotationAngle) % 360; if (curTotalRot < 0) curTotalRot += 360;
    BOOL cacheHit = (_lastOut != NULL) && (_lastInPtr == s) && (fabs(_lastPanX - _panX) < 1e-6 && fabs(_lastPanY - _panY) < 1e-6 && fabs(_lastZoom - _zoom) < 1e-6) && (_lastRot == curTotalRot) && (_lastMirror == _mirrored) && !_vesselFlowEnabled;
    if (cacheHit && _cacheHitCount < 30) { _cacheHitCount++; return (CVPixelBufferRef)CVPixelBufferRetain(_lastOut); }
    CVPixelBufferRef out = NULL; @try { out = [self _process:s targetW:tw targetH:th]; } @catch (NSException *e) {}
    _lastInPtr = s; _lastPanX = _panX; _lastPanY = _panY; _lastZoom = _zoom; _lastRot = curTotalRot; _lastMirror = _mirrored; _cacheHitCount = 0;
    if (_lastOut) CVPixelBufferRelease(_lastOut); _lastOut = out ? CVPixelBufferRetain(out) : NULL; return out;
}
- (CVPixelBufferRef)_process:(CVPixelBufferRef)s targetW:(size_t)tw targetH:(size_t)th CF_RETURNS_RETAINED {
    (void)tw; (void)th; size_t iw = CVPixelBufferGetWidth(s), ih = CVPixelBufferGetHeight(s); int total = (_sourceRotation + _rotationAngle) % 360; if (total < 0) total += 360;
    CVPixelBufferRef rot = s; BOOL rotOwned = NO;
    if (total != 0 && _rot && _rotTransfer) {
        size_t ow = (total == 90 || total == 270) ? ih : iw, oh = (total == 90 || total == 270) ? iw : ih; OSType fmt = CVPixelBufferGetPixelFormatType(s); CVPixelBufferRef d = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, ow, oh, fmt, NULL, &d) == noErr && d) {
            CFTypeRef v = kCFBooleanFalse; if (total == 90) v = _rotCW90; else if (total == 180) v = _rot180; else if (total == 270) v = _rotCCW90;
            VTSessionSetProperty(_rot, _rotKey, v); if (_rotTransfer(_rot, s, d) == noErr) { rot = d; rotOwned = YES; } else CVPixelBufferRelease(d);
        }
    }
    CVPixelBufferRef use = rot, extra = NULL;
    if (_mirrored) {
        if (rotOwned) { vcamMirrorRowsInPlace(rot); }
        else {
            size_t w = CVPixelBufferGetWidth(rot), h = CVPixelBufferGetHeight(rot); OSType fmt = CVPixelBufferGetPixelFormatType(rot);
            if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, NULL, &extra) == noErr && extra) {
                int planes = (int)CVPixelBufferGetPlaneCount(rot); CVPixelBufferLockBaseAddress(rot, kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(extra, 0);
                for (int p = 0; p < planes; p++) {
                    uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(rot, p), *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(extra, p); if (!sb || !db) continue;
                    size_t srs = CVPixelBufferGetBytesPerRowOfPlane(rot, p), drs = CVPixelBufferGetBytesPerRowOfPlane(extra, p), rows = CVPixelBufferGetHeightOfPlane(rot, p);
                    for (size_t y = 0; y < rows; y++) memcpy(db + y * drs, sb + y * srs, MIN(srs, drs));
                }
                CVPixelBufferUnlockBaseAddress(extra, 0); CVPixelBufferUnlockBaseAddress(rot, kCVPixelBufferLock_ReadOnly); vcamMirrorRowsInPlace(extra); use = extra;
            }
        }
    }
    CVPixelBufferRef baked = [self bakeTransform:use]; if (extra) CVPixelBufferRelease(extra); if (rotOwned) CVPixelBufferRelease(rot); if (!baked) return NULL;
    if (_vesselFlowEnabled && CVPixelBufferGetPlaneCount(baked) == 2) {
        size_t bw = CVPixelBufferGetWidth(baked), bh = CVPixelBufferGetHeight(baked);
        if (!(bw & 1) && !(bh & 1)) {
            OSType fmt = CVPixelBufferGetPixelFormatType(baked); CVPixelBufferRef canvas = NULL;
            if (CVPixelBufferCreate(kCFAllocatorDefault, bw, bh, fmt, NULL, &canvas) == noErr && canvas) {
                CVPixelBufferLockBaseAddress(baked, kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(canvas, 0);
                for (int p = 0; p < 2; p++) {
                    const uint8_t *sb = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(baked, p); uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, p); if (!sb || !db) continue;
                    size_t srs = CVPixelBufferGetBytesPerRowOfPlane(baked, p), drs = CVPixelBufferGetBytesPerRowOfPlane(canvas, p), rows = (p == 0) ? bh : bh / 2;
                    for (size_t y = 0; y < rows; y++) memcpy(db + y * drs, sb + y * srs, MIN(srs, drs));
                }
                CVPixelBufferUnlockBaseAddress(baked, kCVPixelBufferLock_ReadOnly); CVPixelBufferUnlockBaseAddress(canvas, 0);
                vcamCopyAttachments(baked, canvas); [self injectVesselFlow:canvas]; CVPixelBufferRelease(baked); baked = canvas;
            }
        }
    }
    return baked;
}
@end

@interface VCCore : NSObject
@property (nonatomic, strong) VCPlayer *player; @property (nonatomic, strong) VCProc *proc; @property (nonatomic, strong) NSLock *renderLock, *dedupLock;
@property (nonatomic, assign) CVPixelBufferRef dedupBuf, fallback; @property (nonatomic, assign) double dedupPts; @property (nonatomic, assign) CFAbsoluteTime dedupTime;
@property (nonatomic, assign) BOOL enabled, isMsd; @property (nonatomic, strong) dispatch_source_t timer; @property (nonatomic, assign) NSInteger lastEn, lastRot, lastPaused, lastVideoVersion;
@property (nonatomic, assign) double lastPanX, lastPanY, lastZoom; @property (nonatomic, assign) BOOL lastMirror, lastVesselFlow;
+ (instancetype)shared; - (void)startRender; - (void)startPolling; - (void)renderInto:(CVPixelBufferRef)pb pts:(double)pts;
@end
@implementation VCCore
+ (instancetype)shared { static VCCore *i; static dispatch_once_t t; dispatch_once(&t, ^{ i = [[VCCore alloc] init]; }); return i; }
- (instancetype)init {
    self = [super init];
    if (self) {
        _renderLock = [[NSLock alloc] init]; _dedupLock = [[NSLock alloc] init]; _lastEn = -1; _lastRot = -1; _lastPaused = -1; _lastZoom = -1; _lastMirror = NO; _lastVesselFlow = NO; _lastVideoVersion = -1;
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) { _player = [[VCPlayer alloc] init]; _proc = [[VCProc alloc] init]; }
    }
    return self;
}
- (void)startRender {
    _isMsd = [[[NSProcessInfo processInfo] processName] isEqualToString:@"mediaserverd"]; if (!_isMsd) return;
    NSString *p = plRead()[@"activePlaybackPath"]; if (![p isKindOfClass:[NSString class]] || p.length == 0) p = @"/var/mobile/Media/DCIM/vcam.mp4";
    [_player load:p]; [_player start];
}
- (void)startPolling {
    if (_timer) return; dispatch_queue_t q = dispatch_queue_create("vcam.poll", DISPATCH_QUEUE_SERIAL); _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(0.15 * NSEC_PER_SEC), (uint64_t)(0.075 * NSEC_PER_SEC));
    __weak typeof(self) w = self; dispatch_source_set_event_handler(_timer, ^{ [w poll]; }); dispatch_resume(_timer);
}
- (void)poll {
    if (!_isMsd) return;
    @try {
        NSDictionary *pl = plRead(); NSInteger en = [pl[@"enabled"] boolValue] ? 1 : 0, rot = [pl[@"manualRotation"] integerValue];
        BOOL mirror = [pl[@"mirrored"] boolValue]; double px = [pl[@"userPanX"] doubleValue], py = [pl[@"userPanY"] doubleValue], z = [pl[@"userZoom"] doubleValue]; if (z <= 0) z = 1.0;
        BOOL vOn = [pl[@"vesselFlowEnabled"] boolValue], paused = [pl[@"paused"] boolValue];
        NSString *path = [pl[@"activePlaybackPath"] isKindOfClass:[NSString class]] ? pl[@"activePlaybackPath"] : nil; NSInteger vVer = [pl[@"vcamVideoVersion"] integerValue];
        BOOL enChg = (en != _lastEn), rotChg = (rot != _lastRot), mirChg = (mirror != _lastMirror), panChg = (px != _lastPanX || py != _lastPanY || z != _lastZoom), vChg = (vOn != _lastVesselFlow);
        if (enChg || rotChg || mirChg || panChg || vChg) {
            [_renderLock lock];
            if (enChg) { _lastEn = en; _enabled = (en == 1); }
            if (rotChg) { _lastRot = rot; _proc.rotationAngle = (int)(rot % 360); }
            if (mirChg) { _lastMirror = mirror; _proc.mirrored = mirror; }
            if (panChg) { _lastPanX = px; _lastPanY = py; _lastZoom = z; _proc.panX = px; _proc.panY = py; _proc.zoom = z; }
            if (vChg) { _lastVesselFlow = vOn; _proc.vesselFlowEnabled = vOn; }
            [_renderLock unlock];
        }
        if (enChg && _enabled) [_player start]; BOOL verChg = (vVer != _lastVideoVersion);
        if (path && (verChg || ![path isEqualToString:_player.path])) { [_player load:path]; _lastVideoVersion = vVer; }
        if (paused != _lastPaused) { _lastPaused = paused; _player.paused = paused; }
    } @catch (NSException *e) {}
}
- (void)renderInto:(CVPixelBufferRef)pb pts:(double)pts {
    if (!_enabled || !pb) return;
    @try {
        [_dedupLock lock]; CFAbsoluteTime now = CFAbsoluteTimeGetCurrent(); BOOL dup = (_dedupBuf == pb) && ((pts > 0 && _dedupPts == pts) || (now - _dedupTime < 0.005));
        if (pts > 0) _dedupPts = pts; _dedupBuf = pb; _dedupTime = now; [_dedupLock unlock]; if (dup) return;
        NSDictionary *pl = plRead(); NSString *mediaType = pl[@"vcamSlotMediaType"];
        if ([mediaType isEqualToString:@"image"]) {
            NSString *imgPath = pl[@"vcamActiveImagePath"]; int ver = [pl[@"vcamImageVersion"] intValue], rot = (int)[pl[@"manualRotation"] integerValue];
            double ipx = [pl[@"userPanX"] doubleValue], ipy = [pl[@"userPanY"] doubleValue], iz = [pl[@"userZoom"] doubleValue]; if (iz <= 0) iz = 1.0;
            if ([imgPath isKindOfClass:[NSString class]] && imgPath.length > 0) {
                [[VCImageStore shared] syncWithPath:imgPath version:ver rotation:rot];
                if ([[VCImageStore shared] replaceCameraBuffer:pb panX:ipx panY:ipy zoom:iz]) return;
            }
        }
        size_t tw = CVPixelBufferGetWidth(pb), th = CVPixelBufferGetHeight(pb); [_renderLock lock]; CVPixelBufferRef frame = [_player.queue pop];
        if (!frame) frame = [_player.queue copyCurrent]; if (!frame) frame = _fallback ? CVPixelBufferRetain(_fallback) : NULL;
        if (!frame) { [_renderLock unlock]; return; }
        _proc.sourceRotation = _player.preferredRotation; CVPixelBufferRef out = [_proc process:frame targetW:tw targetH:th]; CVPixelBufferRelease(frame);
        if (out) { if ([_proc transfer:out to:pb]) { vcamCopyAttachments(out, pb); if (_fallback) CVPixelBufferRelease(_fallback); _fallback = CVPixelBufferRetain(out); } CVPixelBufferRelease(out); }
        [_renderLock unlock];
    } @catch (NSException *e) {}
}
@end

static void (*origEmit)(id, SEL, CMSampleBufferRef); static void (*origScaler)(id, SEL, CMSampleBufferRef, id); static void (*origEncoder)(id, SEL, CMSampleBufferRef, id);
static void processSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb) {
    if (!sb) return; @try { SEL mts = sel_registerName("mediaType"); if ([self respondsToSelector:mts]) { if (((uint32_t(*)(id, SEL))objc_msgSend)(self, mts) != 'vide') return; } } @catch (NSException *e) {}
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb); if (!pb) return; OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    if (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange && fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && fmt != kCVPixelFormatType_32BGRA) return;
    if (CVPixelBufferGetWidth(pb) & 1) return; if (CVPixelBufferGetPlaneCount(pb) == 2 && CVPixelBufferGetWidthOfPlane(pb, 1) * 2 != CVPixelBufferGetWidth(pb)) return;
    @try { [[VCCore shared] renderInto:pb pts:CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))]; } @catch (NSException *e) {}
}
static void hookEmit(id self, SEL _cmd, CMSampleBufferRef sb) { @autoreleasepool { processSampleBuffer(self, _cmd, sb); if (origEmit) origEmit(self, _cmd, sb); } }
static void hookScaler(id self, SEL _cmd, CMSampleBufferRef sb, id input) { @autoreleasepool { processSampleBuffer(self, _cmd, sb); if (origScaler) origScaler(self, _cmd, sb, input); } }
static void hookEncoder(id self, SEL _cmd, CMSampleBufferRef sb, id input) { @autoreleasepool { processSampleBuffer(self, _cmd, sb); if (origEncoder) origEncoder(self, _cmd, sb, input); } }
static void installHooks(void) {
    @try { Class c = objc_getClass("BWNodeOutput"); if (c) { Method m = class_getInstanceMethod(c, sel_registerName("emitSampleBuffer:")); if (m) { origEmit = (void (*)(id, SEL, CMSampleBufferRef))method_getImplementation(m); method_setImplementation(m, (IMP)hookEmit); } } } @catch (NSException *e) {}
    @try { Class c2 = objc_getClass("BWStillImageScalerNode"); if (c2) { Method m = class_getInstanceMethod(c2, sel_registerName("renderSampleBuffer:forInput:")); if (m) { origScaler = (void (*)(id, SEL, CMSampleBufferRef, id))method_getImplementation(m); method_setImplementation(m, (IMP)hookScaler); } } } @catch (NSException *e) {}
    @try { Class c3 = objc_getClass("BWPhotoEncoderNode"); if (c3) { Method m = class_getInstanceMethod(c3, sel_registerName("renderSampleBuffer:forInput:")); if (m) { origEncoder = (void (*)(id, SEL, CMSampleBufferRef, id))method_getImplementation(m); method_setImplementation(m, (IMP)hookEncoder); } } } @catch (NSException *e) {}
}

static UIColor *CBgDeep(void)    { return [UIColor colorWithRed:0.00 green:0.188 blue:0.125 alpha:0.65]; }
static UIColor *CBtnBg(void)     { return [UIColor colorWithRed:0.00 green:0.275 blue:0.188 alpha:0.80]; }
static UIColor *CBtnBorder(void) { return [UIColor colorWithRed:0.486 green:1.00 blue:0.698 alpha:0.40]; }
static UIColor *CTextMain(void)  { return [UIColor colorWithRed:0.875 green:1.00 blue:0.933 alpha:1.0]; }
static UIColor *CGlow(void)      { return [UIColor colorWithRed:0.486 green:1.00 blue:0.698 alpha:1.0]; }
static UIColor *CDeep(void)      { return [UIColor colorWithRed:0.02 green:0.04 blue:0.02 alpha:1.0]; }

@interface VCOverlayWindow : UIWindow @end
@implementation VCOverlayWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { UIView *h = [super hitTest:p withEvent:e]; if (h == self || h == self.rootViewController.view) return nil; return h; }
@end

@interface VCBallView : UIView @end
@implementation VCBallView
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor]; self.layer.cornerRadius = f.size.width / 2; self.layer.masksToBounds = NO; self.layer.borderWidth = 1; self.layer.borderColor = CBtnBorder().CGColor;
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        blur.frame = self.bounds; blur.layer.cornerRadius = f.size.width / 2; blur.layer.masksToBounds = YES; blur.userInteractionEnabled = NO; [self addSubview:blur];
        UIView *tint = [[UIView alloc] initWithFrame:self.bounds]; tint.backgroundColor = [UIColor colorWithRed:0 green:0.188 blue:0.125 alpha:0.35]; tint.layer.cornerRadius = f.size.width / 2; tint.userInteractionEnabled = NO; [self addSubview:tint];
        UILabel *mainLabel = [[UILabel alloc] initWithFrame:CGRectMake(4, f.size.height*0.30, f.size.width-8, f.size.height*0.34)];
        mainLabel.text = @"SQKJ"; mainLabel.textAlignment = NSTextAlignmentCenter; mainLabel.textColor = CGlow(); mainLabel.font = [UIFont boldSystemFontOfSize:13];
        mainLabel.layer.shadowColor = CGlow().CGColor; mainLabel.layer.shadowRadius = 6; mainLabel.layer.shadowOpacity = 0.9; mainLabel.layer.shadowOffset = CGSizeZero; [self addSubview:mainLabel];
        UILabel *yenLabel = [[UILabel alloc] initWithFrame:CGRectMake(f.size.width-22, 6, 18, 18)];
        yenLabel.text = @"¥"; yenLabel.textAlignment = NSTextAlignmentCenter; yenLabel.textColor = CGlow(); yenLabel.font = [UIFont boldSystemFontOfSize:12];
        yenLabel.layer.shadowColor = CGlow().CGColor; yenLabel.layer.shadowRadius = 4; yenLabel.layer.shadowOpacity = 0.9; yenLabel.layer.shadowOffset = CGSizeZero; [self addSubview:yenLabel];
    }
    return self;
}
@end

static UIButton *makeRetroBtn(NSString *title, CGRect frame, id t, SEL s) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom]; b.frame = frame; [b setTitle:title forState:UIControlStateNormal]; [b setTitleColor:CTextMain() forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:12]; b.backgroundColor = CBtnBg(); b.layer.cornerRadius = 10; b.layer.borderWidth = 1; b.layer.borderColor = CBtnBorder().CGColor;
    if (t && s) [b addTarget:t action:s forControlEvents:UIControlEventTouchUpInside]; return b;
}
static UIButton *makeIconBtn(NSString *sys, CGRect frame, id t, SEL s) {
    UIButton *b = makeRetroBtn(@"", frame, t, s); UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold];
    UIImage *img = [UIImage systemImageNamed:sys withConfiguration:cfg]; if (img) { [b setImage:img forState:UIControlStateNormal]; b.tintColor = CTextMain(); } return b;
}

@interface VCBall : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, strong) UIWindow *win; @property (nonatomic, strong) VCBallView *ball; @property (nonatomic, strong) UIView *panel, *ctrlPage;
@property (nonatomic, strong) UIButton *replaceBtn, *playBtn, *mirrorBtn, *vesselBtn, *pickBtn; @property (nonatomic, strong) UISlider *colorSlider; @property (nonatomic, strong) UILabel *colorValueLabel;
@property (nonatomic, strong) UIView *colorIndicator, *pickerCrosshair; @property (nonatomic, strong) NSTimer *colorSampleTimer; @property (nonatomic, assign) BOOL visible, floating, paused;
@property (nonatomic, assign) int buildRetries, pickerState;
+ (instancetype)shared; - (void)show; - (void)hide; - (void)build; - (void)_build; - (void)buildPanel; - (void)buildCtrlPage:(UIView *)page width:(CGFloat)pw pad:(CGFloat)pad contentW:(CGFloat)contentW pageH:(CGFloat)pageH; - (void)refreshVisuals; - (void)layoutPanel; - (void)toast:(NSString *)msg; - (void)pickMedia; - (void)toggleReplace; - (void)rotate; - (void)togglePause; - (void)panUp; - (void)panDown; - (void)panLeft; - (void)panRight; - (void)panByX:(double)dx Y:(double)dy; - (void)zoomIn; - (void)zoomOut; - (void)zoomBy:(double)f; - (void)resetTransform; - (void)toggleMirror; - (void)toggleVesselFlow; - (void)colorIntensityChanged:(UISlider *)s; - (void)startColorSampling; - (void)stopColorSampling; - (void)sampleScreenColor; - (void)ballTap; - (void)ballDrag:(UIPanGestureRecognizer *)g; - (void)didActive; - (void)loadVideoProvider:(NSItemProvider *)p; - (void)loadImageProvider:(NSItemProvider *)p; - (BOOL)isVideoProvider:(NSItemProvider *)p; - (BOOL)isImageProvider:(NSItemProvider *)p; - (UIButton *)makeRainbowBtn:(CGRect)frame; - (UIView *)makeReserveSlot:(CGRect)frame; - (void)pickBtnTapped; - (void)pickBtnLongPressed:(UILongPressGestureRecognizer *)g; - (void)handlePickerPan:(UIPanGestureRecognizer *)g; - (void)pickColorAtPoint:(CGPoint)pt;
@end

@implementation VCBall
+ (instancetype)shared { static VCBall *i; static dispatch_once_t t; dispatch_once(&t, ^{ i = [[VCBall alloc] init]; }); return i; }
- (void)show { if (_floating) return; _floating = YES; dispatch_async(dispatch_get_main_queue(), ^{ [self build]; }); [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didActive) name:UIApplicationDidBecomeActiveNotification object:nil]; }
- (void)hide { _floating = NO; dispatch_async(dispatch_get_main_queue(), ^{ [self.win removeFromSuperview]; self.win.hidden = YES; self.win = nil; self.ball = nil; self.panel = nil; self.ctrlPage = nil; }); [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)didActive { dispatch_async(dispatch_get_main_queue(), ^{ if (self->_floating && self.win && self.win.windowScene == nil) { [self.win removeFromSuperview]; self.win = nil; [self build]; } }); }
- (void)build { @try { [self _build]; } @catch (NSException *e) {} }
- (void)_build {
    CGRect sb = [UIScreen mainScreen].bounds; if (sb.size.width < 100 || sb.size.height < 100) { if (_buildRetries < 20) { _buildRetries++; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (self->_floating) [self build]; }); } return; }
    _buildRetries = 0; UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) { if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; } }
    if (!scene) for (UIScene *s in [UIApplication sharedApplication].connectedScenes) { if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; } }
    if (scene) { _win = [[VCOverlayWindow alloc] initWithWindowScene:scene]; } else { _win = [[VCOverlayWindow alloc] initWithFrame:sb]; }
    _win.frame = sb; _win.windowLevel = UIWindowLevelAlert + 100; _win.backgroundColor = [UIColor clearColor]; _win.rootViewController = [[UIViewController alloc] init]; _win.hidden = NO; _win.userInteractionEnabled = YES;
    CGFloat bs = 64; _ball = [[VCBallView alloc] initWithFrame:CGRectMake(sb.size.width - bs - 20, sb.size.height / 2 - bs / 2, bs, bs)];
    [_ball addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ballTap)]]; [_ball addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(ballDrag:)]];
    [self buildPanel]; [_win addSubview:_ball];
}
- (void)buildPanel {
    CGFloat pw = 250, ph = 400, pad = 12; _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pw, ph)];
    _panel.backgroundColor = CBgDeep(); _panel.layer.borderWidth = 1; _panel.layer.borderColor = CBtnBorder().CGColor; _panel.layer.cornerRadius = 10; _panel.hidden = YES; _panel.alpha = 0;
    _colorIndicator = [[UIView alloc] initWithFrame:CGRectMake(10, 12, 20, 20)]; _colorIndicator.layer.cornerRadius = 10; _colorIndicator.layer.borderWidth = 2; _colorIndicator.layer.borderColor = CBtnBorder().CGColor;
    _colorIndicator.backgroundColor = [UIColor blackColor]; _colorIndicator.userInteractionEnabled = NO; _colorIndicator.hidden = YES; [_panel addSubview:_colorIndicator];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, 8, pw - pad * 2, 26)]; title.text = @"iOS-画面切换器-SQKJ"; title.textColor = CGlow(); title.font = [UIFont boldSystemFontOfSize:12]; title.textAlignment = NSTextAlignmentCenter; [_panel addSubview:title];
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(pad, 38, pw - pad * 2, 1)]; sep.backgroundColor = CBtnBorder(); [_panel addSubview:sep];
    CGFloat pageY = 46, contentW = pw - pad * 2, pageH = ph - pageY - pad; _ctrlPage = [[UIView alloc] initWithFrame:CGRectMake(0, pageY, pw, pageH)];
    [self buildCtrlPage:_ctrlPage width:pw pad:pad contentW:contentW pageH:pageH]; [_panel addSubview:_ctrlPage]; [self refreshVisuals]; [_win addSubview:_panel];
}
- (void)buildCtrlPage:(UIView *)page width:(CGFloat)pw pad:(CGFloat)pad contentW:(CGFloat)contentW pageH:(CGFloat)pageH {
    CGFloat y = 0, btnH = 30, gap = 8, cell = 44, dg = 4, smallW = 32, dpadTotal = smallW + dg + cell + dg + cell + dg + cell + dg + smallW, dpadStartX = pad + (contentW - dpadTotal) / 2.0;
    [page addSubview:makeRetroBtn(@"选择 视频/图片", CGRectMake(pad, y, contentW, btnH), self, @selector(pickMedia))]; y += btnH + gap;
    _replaceBtn = makeRetroBtn(@"替 换 · ON", CGRectMake(pad, y, contentW, btnH), self, @selector(toggleReplace)); [page addSubview:_replaceBtn]; y += btnH + gap;
    CGFloat threeW = (dpadTotal - dg * 2) / 3.0;
    [page addSubview:makeIconBtn(@"arrow.clockwise", CGRectMake(dpadStartX, y, threeW, btnH), self, @selector(rotate))];
    _mirrorBtn = makeIconBtn(@"arrow.left.and.right.righttriangle.left.righttriangle.right", CGRectMake(dpadStartX + threeW + dg, y, threeW, btnH), self, @selector(toggleMirror)); [page addSubview:_mirrorBtn];
    _playBtn = makeIconBtn(@"pause.fill", CGRectMake(dpadStartX + (threeW + dg) * 2, y, threeW, btnH), self, @selector(togglePause)); [page addSubview:_playBtn]; y += btnH + gap;
    CGFloat xMinus = dpadStartX, xLeft = dpadStartX + smallW + dg, xMid = xLeft + cell + dg, xRight = xMid + cell + dg, xPlus = xRight + cell + dg, topY = y, midY = y + cell + dg, botY = y + (cell + dg) * 2;
    UIButton *up = makeIconBtn(@"arrow.up", CGRectMake(xMid, topY, cell, cell), self, @selector(panUp)), *dn = makeIconBtn(@"arrow.down", CGRectMake(xMid, botY, cell, cell), self, @selector(panDown)), *lf = makeIconBtn(@"arrow.left", CGRectMake(xLeft, midY, cell, cell), self, @selector(panLeft)), *rt = makeIconBtn(@"arrow.right", CGRectMake(xRight, midY, cell, cell), self, @selector(panRight)), *rs = makeRetroBtn(@"复", CGRectMake(xMid, midY, cell, cell), self, @selector(resetTransform)), *minus = makeRetroBtn(@"−", CGRectMake(xMinus, midY, smallW, cell), self, @selector(zoomOut)), *plus = makeRetroBtn(@"+", CGRectMake(xPlus, midY, smallW, cell), self, @selector(zoomIn));
    up.layer.borderColor = CGlow().CGColor; up.layer.borderWidth = 2; dn.layer.borderColor = CGlow().CGColor; dn.layer.borderWidth = 2; up.tintColor = CGlow(); dn.tintColor = CGlow();
    [page addSubview:up]; [page addSubview:dn]; [page addSubview:lf]; [page addSubview:rt]; [page addSubview:rs]; [page addSubview:minus]; [page addSubview:plus]; y += cell * 3 + dg * 2 + gap;
    UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(pad, y, contentW, 1)]; divider.backgroundColor = CBtnBorder(); [page addSubview:divider]; y += 1 + gap;
    UILabel *sliderLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, 56, btnH)]; sliderLabel.text = @"彩色强度"; sliderLabel.textColor = CTextMain(); sliderLabel.font = [UIFont boldSystemFontOfSize:11]; [page addSubview:sliderLabel];
    _colorSlider = [[UISlider alloc] initWithFrame:CGRectMake(pad + 60, y, contentW - 60 - 44, btnH)]; _colorSlider.minimumValue = 0.05; _colorSlider.maximumValue = 1.0; _colorSlider.value = 0.35; _colorSlider.minimumTrackTintColor = CGlow(); _colorSlider.maximumTrackTintColor = CBtnBg();
    [_colorSlider addTarget:self action:@selector(colorIntensityChanged:) forControlEvents:UIControlEventValueChanged]; [page addSubview:_colorSlider];
    _colorValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad + contentW - 42, y, 42, btnH)]; _colorValueLabel.text = @"35%"; _colorValueLabel.textColor = CGlow(); _colorValueLabel.font = [UIFont boldSystemFontOfSize:12]; _colorValueLabel.textAlignment = NSTextAlignmentRight; [page addSubview:_colorValueLabel]; y += btnH + gap;
    CGFloat rbW = contentW * 0.4, rbH = 32; _vesselBtn = [self makeRainbowBtn:CGRectMake(pad, y, rbW, rbH)]; [page addSubview:_vesselBtn];
    CGFloat reserveW = contentW * 0.3 - 6, r1x = pad + rbW + 6, r2x = r1x + reserveW + 6;
    _pickBtn = makeRetroBtn(@"🎯 吸色", CGRectMake(r1x, y, reserveW, rbH), nil, nil); _pickBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11]; [page addSubview:_pickBtn];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pickBtnTapped)]; [_pickBtn addGestureRecognizer:tap];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pickBtnLongPressed:)]; longPress.minimumPressDuration = 3.0; [_pickBtn addGestureRecognizer:longPress];
    [tap requireGestureRecognizerToFail:longPress];
    UIView *r2 = [self makeReserveSlot:CGRectMake(r2x, y, reserveW, rbH)]; [page addSubview:r2];
}
- (UIButton *)makeRainbowBtn:(CGRect)frame {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom]; b.frame = frame; CAGradientLayer *g = [CAGradientLayer layer]; g.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
    g.colors = @[(id)[UIColor colorWithRed:1.00 green:0.00 blue:0.00 alpha:1.0].CGColor, (id)[UIColor colorWithRed:1.00 green:0.50 blue:0.00 alpha:1.0].CGColor, (id)[UIColor colorWithRed:1.00 green:1.00 blue:0.00 alpha:1.0].CGColor, (id)[UIColor colorWithRed:0.00 green:0.85 blue:0.20 alpha:1.0].CGColor, (id)[UIColor colorWithRed:0.00 green:0.80 blue:1.00 alpha:1.0].CGColor, (id)[UIColor colorWithRed:0.15 green:0.25 blue:1.00 alpha:1.0].CGColor, (id)[UIColor colorWithRed:0.60 green:0.00 blue:0.90 alpha:1.0].CGColor];
    g.locations = @[@0.0, @0.166, @0.333, @0.5, @0.666, @0.833, @1.0]; g.startPoint = CGPointMake(0, 0.5); g.endPoint = CGPointMake(1, 0.5); g.cornerRadius = 10; [b.layer insertSublayer:g atIndex:0];
    b.layer.cornerRadius = 10; b.layer.masksToBounds = YES; b.layer.borderWidth = 1; b.layer.borderColor = [UIColor whiteColor].CGColor;
    UIView *tint = [[UIView alloc] initWithFrame:b.bounds]; tint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28]; tint.userInteractionEnabled = NO; [b addSubview:tint];
    [b setTitle:@"🌈 注入 · OFF" forState:UIControlStateNormal]; [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; b.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    b.titleLabel.layer.shadowColor = [UIColor blackColor].CGColor; b.titleLabel.layer.shadowRadius = 3; b.titleLabel.layer.shadowOpacity = 0.9; b.titleLabel.layer.shadowOffset = CGSizeZero;
    [b addTarget:self action:@selector(toggleVesselFlow) forControlEvents:UIControlEventTouchUpInside]; return b;
}
- (UIView *)makeReserveSlot:(CGRect)frame {
    UIView *v = [[UIView alloc] initWithFrame:frame]; v.backgroundColor = [CBtnBg() colorWithAlphaComponent:0.15]; v.layer.cornerRadius = 10; v.layer.borderWidth = 1; v.layer.borderColor = [CBtnBorder() colorWithAlphaComponent:0.3].CGColor;
    UILabel *l = [[UILabel alloc] initWithFrame:v.bounds]; l.text = @"+"; l.textColor = [CTextMain() colorWithAlphaComponent:0.3]; l.textAlignment = NSTextAlignmentCenter; l.font = [UIFont systemFontOfSize:16]; l.userInteractionEnabled = NO; [v addSubview:l]; return v;
}
- (void)layoutPanel { CGFloat pw = _panel.frame.size.width, ph = _panel.frame.size.height, gap = 8, rx = CGRectGetMaxX(_ball.frame) + gap, lx = _ball.frame.origin.x - pw - gap; CGFloat px = (rx + pw <= _win.frame.size.width - 5) ? rx : lx; px = MAX(5, px); CGFloat py = _ball.center.y - ph / 2; py = MAX(5, MIN(_win.frame.size.height - ph - 5, py)); _panel.frame = CGRectMake(px, py, pw, ph); }
- (void)ballTap { _visible = !_visible; if (_visible) { [self layoutPanel]; _panel.hidden = NO; [UIView animateWithDuration:0.2 animations:^{ _panel.alpha = 1; }]; } else { [UIView animateWithDuration:0.2 animations:^{ _panel.alpha = 0; } completion:^(BOOL f){ _panel.hidden = YES; }]; } }
- (void)ballDrag:(UIPanGestureRecognizer *)g { CGPoint t = [g translationInView:_win], c = CGPointMake(_ball.center.x + t.x, _ball.center.y + t.y); CGFloat h = _ball.frame.size.width / 2; c.x = MAX(h, MIN(_win.frame.size.width - h, c.x)); c.y = MAX(h, MIN(_win.frame.size.height - h, c.y)); _ball.center = c; [g setTranslation:CGPointZero inView:_win]; [self layoutPanel]; }
- (void)refreshVisuals {
    NSDictionary *pl = plRead(); BOOL en = [pl[@"enabled"] boolValue];
    [_replaceBtn setTitle:(en ? @"替 换 · ON" : @"还 原 · OFF") forState:UIControlStateNormal]; _replaceBtn.backgroundColor = en ? CGlow() : CBtnBg(); [_replaceBtn setTitleColor:(en ? CDeep() : CTextMain()) forState:UIControlStateNormal]; _replaceBtn.layer.borderColor = en ? CDeep().CGColor : CBtnBorder().CGColor;
    BOOL mi = [pl[@"mirrored"] boolValue]; _mirrorBtn.backgroundColor = mi ? CBtnBorder() : CBtnBg(); _mirrorBtn.tintColor = mi ? CGlow() : CTextMain();
    BOOL vesselOn = [pl[@"vesselFlowEnabled"] boolValue]; if (_vesselBtn) { [_vesselBtn setTitle:(vesselOn ? @"🌈 注入 · ON" : @"🌈 注入 · OFF") forState:UIControlStateNormal]; _vesselBtn.alpha = vesselOn ? 1.0 : 0.55; }
    if (_colorSlider) { double a = [pl[@"injectAlpha"] doubleValue]; if (a < 0.05 || a > 1.0) a = 0.35; _colorSlider.value = a; _colorValueLabel.text = [NSString stringWithFormat:@"%d%%", (int)(a * 100)]; }
    if (_colorIndicator) { uint32_t c = (uint32_t)[pl[@"lightColor"] unsignedIntValue]; _colorIndicator.hidden = (c == 0 && !vesselOn); if (vesselOn) { if (c == 0) { _colorIndicator.backgroundColor = [UIColor colorWithRed:0.75 green:0.18 blue:0.12 alpha:1.0]; } else { CGFloat r = ((c >> 16) & 0xFF) / 255.0, gg = ((c >> 8) & 0xFF) / 255.0, bb = (c & 0xFF) / 255.0; _colorIndicator.backgroundColor = [UIColor colorWithRed:r green:gg blue:bb alpha:1.0]; } } }
    _paused = [pl[@"paused"] boolValue]; UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold]; [_playBtn setImage:[UIImage systemImageNamed:(_paused ? @"play.fill" : @"pause.fill") withConfiguration:cfg] forState:UIControlStateNormal];
}

- (void)colorIntensityChanged:(UISlider *)s { double v = s.value; if (v < 0.05) v = 0.05; if (v > 1.0) v = 1.0; _colorValueLabel.text = [NSString stringWithFormat:@"%d%%", (int)(v * 100)]; plSet(@"injectAlpha", @(v)); }

- (void)toggleVesselFlow {
    BOOL cur = [plRead()[@"vesselFlowEnabled"] boolValue], next = !cur;
    NSMutableDictionary *kv = [@{@"vesselFlowEnabled": @(next), @"lightColor": @(0)} mutableCopy]; 
    if (next) kv[@"enabled"] = @YES;
    plSetMany(kv); 
    [self refreshVisuals]; 
    [self toast:(next ? @"彩色注入开 (默认红)" : @"彩色注入关")];
}

- (void)startColorSampling {}
- (void)stopColorSampling {}
- (void)sampleScreenColor {}

- (void)pickBtnTapped {
    if (_pickerState == 1) {
        _pickerCrosshair.hidden = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self pickColorAtPoint:_pickerCrosshair.center]; 
            _pickerCrosshair.hidden = NO;
            _pickerState = 2; 
            [_pickBtn setTitle:@"❌ 关闭" forState:UIControlStateNormal]; 
            _pickBtn.backgroundColor = CBtnBg(); 
            [_pickBtn setTitleColor:CTextMain() forState:UIControlStateNormal]; 
            _pickBtn.layer.borderColor = CBtnBorder().CGColor;
            [self toast:@"颜色已锁定，点击关闭恢复默认红"];
        });
    } else if (_pickerState == 2) {
        _pickerState = 0; 
        _pickerCrosshair.hidden = YES; 
        plSet(@"lightColor", @(0));
        [self refreshVisuals];
        [_pickBtn setTitle:@"🎯 吸色" forState:UIControlStateNormal]; 
        _pickBtn.backgroundColor = CBtnBg(); 
        [_pickBtn setTitleColor:CTextMain() forState:UIControlStateNormal]; 
        _pickBtn.layer.borderColor = CBtnBorder().CGColor;
        [self toast:@"已恢复默认红色"];
    }
}

- (void)pickBtnLongPressed:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        if (_pickerState != 0) return; 
        _pickerState = 1; 
        
        [_pickBtn setTitle:@"🔍 取色" forState:UIControlStateNormal]; 
        _pickBtn.backgroundColor = CGlow(); 
        [_pickBtn setTitleColor:CDeep() forState:UIControlStateNormal]; 
        _pickBtn.layer.borderColor = CDeep().CGColor;
        
        if (!_pickerCrosshair) {
            _pickerCrosshair = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)]; 
            _pickerCrosshair.backgroundColor = [UIColor clearColor]; 
            _pickerCrosshair.layer.borderColor = [UIColor whiteColor].CGColor;
            _pickerCrosshair.layer.borderWidth = 2; 
            _pickerCrosshair.layer.cornerRadius = 30; 
            _pickerCrosshair.layer.shadowColor = [UIColor blackColor].CGColor; 
            _pickerCrosshair.layer.shadowOpacity = 0.8; 
            _pickerCrosshair.layer.shadowRadius = 4;
            
            UIView *hLine = [[UIView alloc] initWithFrame:CGRectMake(0, 29, 60, 2)]; 
            hLine.backgroundColor = [UIColor whiteColor]; 
            [_pickerCrosshair addSubview:hLine];
            UIView *vLine = [[UIView alloc] initWithFrame:CGRectMake(29, 0, 2, 60)]; 
            vLine.backgroundColor = [UIColor whiteColor]; 
            [_pickerCrosshair addSubview:vLine];
            
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePickerPan:)]; 
            [_pickerCrosshair addGestureRecognizer:pan]; 
            _pickerCrosshair.userInteractionEnabled = YES; 
            [_win addSubview:_pickerCrosshair];
        }
        
        _pickerCrosshair.center = CGPointMake(_win.bounds.size.width / 2, _win.bounds.size.height / 3); 
        _pickerCrosshair.hidden = NO;
        [self toast:@"拖动准星到目标，点击按钮取色"];
    }
}

- (void)handlePickerPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:_win], c = CGPointMake(_pickerCrosshair.center.x + t.x, _pickerCrosshair.center.y + t.y);
    CGFloat h = _pickerCrosshair.frame.size.width / 2; 
    c.x = MAX(h, MIN(_win.frame.size.width - h, c.x)); 
    c.y = MAX(h, MIN(_win.frame.size.height - h, c.y));
    _pickerCrosshair.center = c; 
    [g setTranslation:CGPointZero inView:_win];
}

- (void)pickColorAtPoint:(CGPoint)pt {
    @try {
        UIImage *snapshot = nil; 
        UIScreen *screen = [UIScreen mainScreen]; 
        SEL s1 = NSSelectorFromString(@"_snapshotIncludingStatusBar:");
        if ([screen respondsToSelector:s1]) { 
            snapshot = ((id (*)(id, SEL, BOOL))objc_msgSend)(screen, s1, NO); 
        }
        if (!snapshot) return; 
        CGImageRef cgImg = snapshot.CGImage; 
        if (!cgImg) return;
        size_t w = CGImageGetWidth(cgImg), h = CGImageGetHeight(cgImg);
        CGFloat scaleX = (CGFloat)w / _win.bounds.size.width, scaleY = (CGFloat)h / _win.bounds.size.height;
        CGFloat imgX = pt.x * scaleX, imgY = pt.y * scaleY;
        
        CGImageRef cropped = CGImageCreateWithImageInRect(cgImg, CGRectMake(imgX, imgY, 1, 1)); 
        if (!cropped) return;
        
        unsigned char pix[4]={0}; 
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(pix, 1, 1, 8, 4, cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGContextDrawImage(ctx, CGRectMake(0,0,1,1), cropped); 
        CGContextRelease(ctx); 
        CGImageRelease(cropped); 
        CGColorSpaceRelease(cs);
        
        CGFloat b = pix[0]/255.0;
        CGFloat g = pix[1]/255.0;
        CGFloat r = pix[2]/255.0;
        
        uint32_t packed = ((uint32_t)(r*255)<<16) | ((uint32_t)(g*255)<<8) | (uint32_t)(b*255);
        plSetMany(@{@"lightColor":@(packed), @"lightLuma":@(0.299*r + 0.587*g + 0.114*b), @"lightEnabled":@YES});
        
        if (_colorIndicator) { 
            _colorIndicator.hidden = NO; 
            _colorIndicator.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:1.0]; 
        }
        vcamLog([NSString stringWithFormat:@"Manual picked color: R=%.2f G=%.2f B=%.2f", r, g, b]);
    } @catch (NSException *e) {}
}

- (void)pickMedia { dispatch_async(dispatch_get_main_queue(), ^{ PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init]; cfg.selectionLimit = 1; cfg.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter videosFilter], [PHPickerFilter imagesFilter]]]; PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg]; p.delegate = self; [self.win.rootViewController presentViewController:p animated:YES completion:nil]; }); }
- (BOOL)isVideoProvider:(NSItemProvider *)p { if ([p hasItemConformingToTypeIdentifier:@"public.movie"]) return YES; for (NSString *t in p.registeredTypeIdentifiers) if ([t containsString:@"video"]) return YES; return NO; }
- (BOOL)isImageProvider:(NSItemProvider *)p { if ([p hasItemConformingToTypeIdentifier:@"public.image"]) return YES; for (NSString *t in p.registeredTypeIdentifiers) if ([t containsString:@"image"]) return YES; return NO; }
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results { [picker dismissViewControllerAnimated:YES completion:nil]; if (results.count == 0) return; NSItemProvider *prov = results.firstObject.itemProvider; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if ([self isVideoProvider:prov]) [self loadVideoProvider:prov]; else if ([self isImageProvider:prov]) [self loadImageProvider:prov]; }); }
- (void)loadVideoProvider:(NSItemProvider *)p { [p loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *err) { if (!url) return; NSString *dst = @"/var/mobile/Media/DCIM/vcam.mp4"; [[NSFileManager defaultManager] removeItemAtPath:dst error:nil]; if ([[NSFileManager defaultManager] copyItemAtPath:url.path toPath:dst error:nil]) dispatch_async(dispatch_get_main_queue(), ^{ plSetMany(@{@"activePlaybackPath": dst, @"enabled": @YES, @"paused": @NO, @"vcamSlotMediaType": @"video", @"vcamVideoVersion": @([plRead()[@"vcamVideoVersion"] intValue] + 1)}); [self refreshVisuals]; [self toast:@"视频已载入"]; }); }]; }
- (void)loadImageProvider:(NSItemProvider *)p { [p loadFileRepresentationForTypeIdentifier:@"public.image" completionHandler:^(NSURL *url, NSError *err) { if (!url) return; NSString *ext = url.pathExtension.lowercaseString ?: @"jpg"; NSString *dst = [NSString stringWithFormat:@"/var/mobile/Media/DCIM/vcam_main.%@", ext]; [[NSFileManager defaultManager] removeItemAtPath:dst error:nil]; if ([[NSFileManager defaultManager] copyItemAtPath:url.path toPath:dst error:nil]) dispatch_async(dispatch_get_main_queue(), ^{ plSetMany(@{@"enabled": @YES, @"vcamSlotMediaType": @"image", @"vcamActiveImagePath": dst, @"vcamImageVersion": @([plRead()[@"vcamImageVersion"] intValue] + 1)}); [self refreshVisuals]; [self toast:@"图片已载入"]; }); }]; }
- (void)toggleReplace { BOOL en = [plRead()[@"enabled"] boolValue]; plSet(@"enabled", @(!en)); [self refreshVisuals]; }
- (void)rotate { NSInteger n = ([plRead()[@"manualRotation"] integerValue] + 90) % 360; plSet(@"manualRotation", @(n)); }
- (void)togglePause { BOOL p = ![plRead()[@"paused"] boolValue]; plSet(@"paused", @(p)); [self refreshVisuals]; }
- (void)panUp { [self panByX:0 Y:-0.05]; } - (void)panDown { [self panByX:0 Y:0.05]; } - (void)panLeft { [self panByX:-0.05 Y:0]; } - (void)panRight { [self panByX:0.05 Y:0]; }
- (void)panByX:(double)dx Y:(double)dy { double nx = [plRead()[@"userPanX"] doubleValue] + dx, ny = [plRead()[@"userPanY"] doubleValue] + dy; nx = MAX(-1, MIN(1, nx)); ny = MAX(-1, MIN(1, ny)); plSetMany(@{@"userPanX": @(nx), @"userPanY": @(ny)}); }
- (void)zoomIn { [self zoomBy:1.10]; } - (void)zoomOut { [self zoomBy:1.0/1.10]; }
- (void)zoomBy:(double)f { double z = [plRead()[@"userZoom"] doubleValue] * f; z = MAX(0.5, MIN(4.0, z)); plSet(@"userZoom", @(z)); }
- (void)resetTransform { plSetMany(@{@"userPanX": @(0.0), @"userPanY": @(0.0), @"userZoom": @(1.0)}); }
- (void)toggleMirror { BOOL m = [plRead()[@"mirrored"] boolValue]; plSet(@"mirrored", @(!m)); [self refreshVisuals]; }
- (void)toast:(NSString *)msg {
    if (!_win) return; UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 200, 40)]; l.text = msg; l.textColor = CDeep(); l.backgroundColor = CGlow(); l.textAlignment = NSTextAlignmentCenter; l.font = [UIFont boldSystemFontOfSize:13]; l.layer.cornerRadius = 4; l.layer.masksToBounds = YES; l.center = CGPointMake(_win.bounds.size.width / 2, _win.bounds.size.height - 100);
    l.alpha = 0; [_win addSubview:l]; [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL f){ [UIView animateWithDuration:0.3 delay:1.2 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL f2){ [l removeFromSuperview]; }]; }];
}
@end

__attribute__((constructor))
static void vcamInit(void) {
    @autoreleasepool {
        if (vcamLoadedViaOtherPath()) return;
        NSString *name = [[NSProcessInfo processInfo] processName];
        if ([name isEqualToString:@"mediaserverd"]) {
            [[VCCore shared] startRender]; installHooks(); [[VCCore shared] startPolling];
        } else if ([name isEqualToString:@"SpringBoard"]) {
            [[VCCore shared] startPolling]; [[VCBall shared] show];
        }
    }
}
__attribute__((destructor))
static void vcamDeinit(void) {}
