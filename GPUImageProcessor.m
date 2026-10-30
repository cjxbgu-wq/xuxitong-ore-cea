//
//  GPUImageProcessor.m
//  VCamPlus
//
//  2026-10-30 改造 v2（彩色注入 Vision 引擎 + 绿边钳制填充）
//

#import "GPUImageProcessor.h"
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Vision/Vision.h>
#import <dlfcn.h>
#import <math.h>

// 手动声明 VideoToolbox 类型和函数（不依赖 SDK 头文件，避免类型冲突）
typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
typedef struct OpaqueVTPixelRotationSession *VTPixelRotationSessionRef;
OSStatus VTPixelTransferSessionCreate(CFAllocatorRef, VTPixelTransferSessionRef *);
OSStatus VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);
OSStatus VTSessionSetProperty(CFTypeRef session, CFStringRef propertyKey, CFTypeRef propertyValue);

// VTPixelRotationSession 私有 API 函数指针类型
typedef OSStatus (*VTPixelRotationSessionCreateFunc)(CFAllocatorRef, VTPixelRotationSessionRef *);
typedef OSStatus (*VTPixelRotationSessionTransferImageFunc)(VTPixelRotationSessionRef, CVPixelBufferRef, CVPixelBufferRef);

// 日志全局限速令牌桶（定义在 VCamCore.m）
extern BOOL vcam_log_budget_take(void);

// 日志总开关
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

static void vcam_gpu_log(NSString *msg) {
    if (!vcam_log_enabled()) return;
    if (!vcam_log_budget_take()) return;
    @try {
        NSString *logPath = @"/tmp/vcam_gpu_log.txt";
        NSString *ts = [NSDate date].description;
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", ts, msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) {
            [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

// ============================================================================
//  类扩展（保留原有全部属性，追加 2026-10-30 新增属性）
// ============================================================================

@interface GPUImageProcessor ()

// ===== 原有 VT 会话（一行不动） =====
@property (nonatomic, assign) VTPixelTransferSessionRef bgraTransferSession;
@property (nonatomic, assign) VTPixelTransferSessionRef yuvTransferSession;
@property (nonatomic, assign) VTPixelTransferSessionRef privateTransferSession;
@property (nonatomic, assign) VTPixelTransferSessionRef prerenderTransferSession;

// ===== 千面模型固定车道（一行不动） =====
@property (nonatomic, strong) NSLock *laneLockBGRA;
@property (nonatomic, strong) NSLock *laneLockYUV;
@property (nonatomic, strong) NSLock *laneLockPrivate;
@property (nonatomic, assign) VTPixelTransferSessionRef twoStepS1Session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *laneFailCounts;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *laneDisabled;

// ===== 两步法按流池（一行不动） =====
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *twoStepSessionPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *twoStepStagingPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepTokenPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepFailCountPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *twoStepDisabledPool;

// ===== 一步法按流池（一行不动） =====
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *oneStepSessionPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSLock *> *oneStepKeyLockPool;
@property (nonatomic, strong) NSLock *rotationRenderLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSLock *> *twoStepKeyLockPool;

// ===== 前置多流优化（一行不动） =====
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *groupStagingPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *groupTokenPool;
@property (nonatomic, strong) NSLock *groupGlobalLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *groupSessionPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *groupSizePool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *resultCachePool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *resultBlitSessionPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *resultCacheTokenPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastReqTokenPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *resultBlitDisabledPool;

// ===== 旋转 session（一行不动） =====
@property (nonatomic, assign) VTPixelRotationSessionRef pixelRotationSession;
@property (nonatomic, assign) VTPixelRotationSessionRef renderRotationSession;
@property (nonatomic, assign) CVPixelBufferRef adaptiveRotateCache;
@property (nonatomic, assign) size_t adaptiveRotateCacheW;
@property (nonatomic, assign) size_t adaptiveRotateCacheH;
@property (nonatomic, assign) OSType adaptiveRotateCacheFmt;
@property (nonatomic, assign) uint64_t adaptiveRotatedGen;

// ===== 流 key LRU（一行不动） =====
@property (nonatomic, strong) NSMutableArray<NSString *> *streamKeyOrder;
@property (nonatomic, strong) NSLock *statsLock;
@property (nonatomic, strong) NSLock *poolDictLock;

// ===== 私有 API 函数指针（一行不动） =====
@property (nonatomic, assign) VTPixelRotationSessionCreateFunc createRotationSession;
@property (nonatomic, assign) VTPixelRotationSessionTransferImageFunc transferRotationImage;
@property (nonatomic, assign) CFStringRef rotationPropertyKey;
@property (nonatomic, assign) CFStringRef rotationCCW90Value;
@property (nonatomic, assign) CFStringRef rotationCW90Value;
@property (nonatomic, assign) CFStringRef rotation180Value;
@property (nonatomic, assign) CFStringRef flipHorizontalKey;

// ===== 预渲染旋转 3 槽池（一行不动） =====
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool0;
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool1;
@property (nonatomic, assign) CVPixelBufferRef prerenderRotatePool2;
@property (nonatomic, assign) int prerenderRotateSlot;

// ===== 用户变换画布 3 槽池（一行不动） =====
@property (nonatomic, assign) CVPixelBufferRef userCanvasPool0;
@property (nonatomic, assign) CVPixelBufferRef userCanvasPool1;
@property (nonatomic, assign) CVPixelBufferRef userCanvasPool2;
@property (nonatomic, assign) int userCanvasSlot;
@property (nonatomic, assign) CVPixelBufferRef userShrinkBuffer;
@property (nonatomic, assign) CVPixelBufferRef userPieceBuffer;
@property (nonatomic, assign) VTPixelTransferSessionRef userTransferSession;

// ===== 三色打光画布 3 槽池（一行不动） =====
@property (nonatomic, assign) CVPixelBufferRef lightCanvasPool0;
@property (nonatomic, assign) CVPixelBufferRef lightCanvasPool1;
@property (nonatomic, assign) CVPixelBufferRef lightCanvasPool2;
@property (nonatomic, assign) int lightCanvasSlot;

// ===== CIContext（一行不动） =====
@property (nonatomic, strong) CIContext *preprocessContext;
@property (nonatomic, strong) CIContext *renderContext;

// ===== GPU 渲染路径（一行不动） =====
@property (nonatomic, strong) CIContext *ciGPUContext;
@property (nonatomic, assign) BOOL metalAvailable;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *gpuImgTokenPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CIImage *> *gpuImgOutPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *oneStepFailPool;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *oneStepDisabledPool;

// ===== 缓冲池字典（一行不动） =====
@property (nonatomic, strong) NSMutableDictionary *bgraBufferPoolMap;

// ===== 内部方法前向声明（一行不动） =====
- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input width:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;

// ============================================================================
//  2026-10-30 新增：Vision 人脸检测彩色注入内部属性
// ============================================================================
// 自动强度 EMA（每帧更新，人脸变化时平滑过渡）
@property (nonatomic, assign) double _autoAlphaInternal;
// 上一帧人脸位置（归一化 bbox，Vision 原始坐标系 bottom-left origin）
@property (nonatomic, assign) CGRect _lastFaceRectInternal;
// 上一帧人脸时间（mach_absolute_time）
@property (nonatomic, assign) uint64_t _lastFaceTimeInternal;
// 上一帧人脸轮廓（CGPathRef，模式 0 使用）
@property (nonatomic, assign) CGPathRef _lastFaceContourInternal;
// 人工覆盖标记（与 alphaManualSet 同步，内部独立实例避免跨线程竞态）
@property (nonatomic, assign) BOOL _alphaManualSetInternal;

@end

// ============================================================================
//  文件级零分配数据结构（保留原有，一行不动）
// ============================================================================

// 按流渲染统计定长槽位
typedef struct {
    uint32_t fmt;
    uint32_t w, h;
    uint64_t renders;
    uint64_t pixels;
    double   s1TotalMs;
    uint64_t s1Cnt;
    double   s2TotalMs;
    uint64_t s2Cnt;
} VCamStatSlot;
#define kVcamStatSlots 12
static VCamStatSlot gVcamStatSlots[kVcamStatSlots];

// 私有车道 staging 定长槽位
typedef struct {
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
} VCamLaneStagingSlot;
#define kVcamLaneStagingMax 4
static VCamLaneStagingSlot gVcamLaneStaging[kVcamLaneStagingMax];

// 绿线修复 v2：per-ratio 预裁剪 staging 槽
typedef struct {
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
    CFAbsoluteTime lastUse;
} VCamCropStagingSlot;
#define kVcamCropStagingMax 4
static VCamCropStagingSlot gVcamCropStaging[kVcamCropStagingMax];
static VTPixelTransferSessionRef gVcamNormalSession = NULL;

// 发热优化：YUV 域上采样中转槽
typedef struct {
    uint32_t fmt;
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
    CFAbsoluteTime lastUse;
} VCamYuvStagingSlot;
#define kVcamYuvStagingMax 4
static VCamYuvStagingSlot gVcamYuvStaging[kVcamYuvStagingMax];

// 拆段支持 memo
static uint32_t gVcamYuvSplitFmt[4] = {0, 0, 0, 0};
static int8_t gVcamYuvSplitOk[4] = {0, 0, 0, 0};
static int8_t vcamYuvSplitState(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvSplitFmt[i] == fmt) return gVcamYuvSplitOk[i];
    }
    return 0;
}
static void vcamYuvSplitDisable(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvSplitFmt[i] == fmt) { gVcamYuvSplitOk[i] = -1; return; }
    }
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvSplitFmt[i] == 0) { gVcamYuvSplitFmt[i] = fmt; gVcamYuvSplitOk[i] = -1; return; }
    }
}

// 直转快路径 memo
static uint32_t gVcamYuvDirectFmt[4] = {0, 0, 0, 0};
static int8_t gVcamYuvDirectOk[4] = {0, 0, 0, 0};
static uint8_t gVcamYuvDirectFails[4] = {0, 0, 0, 0};
static CFAbsoluteTime gVcamYuvDirectFailAt[4] = {0, 0, 0, 0};
static int8_t vcamYuvDirectState(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvDirectFmt[i] == fmt) {
            if (gVcamYuvDirectOk[i] == -1 &&
                gVcamYuvDirectFails[i] < 3 && gVcamYuvDirectFailAt[i] > 0 &&
                (CFAbsoluteTimeGetCurrent() - gVcamYuvDirectFailAt[i]) > 30.0) {
                return 0;
            }
            return gVcamYuvDirectOk[i];
        }
    }
    return 0;
}
static void vcamYuvDirectSet(uint32_t fmt, int8_t ok) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvDirectFmt[i] == fmt) {
            if (ok == -1) {
                gVcamYuvDirectFails[i]++;
                gVcamYuvDirectFailAt[i] = CFAbsoluteTimeGetCurrent();
            }
            gVcamYuvDirectOk[i] = ok; return;
        }
    }
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvDirectFmt[i] == 0) {
            gVcamYuvDirectFmt[i] = fmt; gVcamYuvDirectOk[i] = ok;
            if (ok == -1) {
                gVcamYuvDirectFails[i] = 1;
                gVcamYuvDirectFailAt[i] = CFAbsoluteTimeGetCurrent();
            }
            return;
        }
    }
}

// YUV staging 两步法 memo
static uint32_t gVcamYuvStageFmt[4] = {0, 0, 0, 0};
static int8_t gVcamYuvStageOk[4] = {0, 0, 0, 0};
static int8_t vcamYuvStageState(uint32_t fmt) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvStageFmt[i] == fmt) return gVcamYuvStageOk[i];
    }
    return 0;
}
static void vcamYuvStageSet(uint32_t fmt, int8_t ok) {
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvStageFmt[i] == fmt) { gVcamYuvStageOk[i] = ok; return; }
    }
    for (int i = 0; i < 4; i++) {
        if (gVcamYuvStageFmt[i] == 0) { gVcamYuvStageFmt[i] = fmt; gVcamYuvStageOk[i] = ok; return; }
    }
}

// YUV 中转 staging 槽
typedef struct {
    size_t w, h;
    CVPixelBufferRef staging;
    uint64_t token;
} VCamYuvLaneSlot;
#define kVcamYuvLaneMax 4
static VCamYuvLaneSlot gVcamYuvLane[kVcamYuvLaneMax];

// 车道熔断 memo
static uint32_t gVcamLaneMemoFmt[4] = {0, 0, 0, 0};
static BOOL gVcamLaneMemoOff[4] = {NO, NO, NO, NO};
static void vcamLaneMemoInvalidate(uint32_t fmt, BOOL off) {
    for (int i = 0; i < 4; i++) {
        if (gVcamLaneMemoFmt[i] == fmt) { gVcamLaneMemoOff[i] = off; return; }
    }
    gVcamLaneMemoFmt[fmt & 3] = fmt;
    gVcamLaneMemoOff[fmt & 3] = off;
}

// ============================================================================
//  2026-10-30 新增：Vision 人脸检测彩注入的辅助静态变量
// ============================================================================
// Vision 请求队列（串行，避免多线程并发 Vision）
static dispatch_queue_t gVisionQueue = NULL;
static dispatch_once_t gVisionOnce = NULL;
// 上一帧人脸 bbox 保留窗口（500ms，纳秒）
static const uint64_t kFaceKeepTimeoutNs = 500000000ULL;
// 自动强度档位（按人脸占比）
static inline double vcamAutoAlphaFromRatio(double ratio) {
    if (ratio > 0.20) return 0.35;
    if (ratio > 0.10) return 0.45;
    if (ratio > 0.05) return 0.55;
    if (ratio > 0.0)  return 0.65;
    return 0.0;
}

// ============================================================================
//  @implementation
// ============================================================================

@implementation GPUImageProcessor

- (instancetype)init {
    self = [super init];
    if (self) {
        _rotationAngle = 0;
        _mirrored = NO;
        _userPanX = 0.0;
        _userPanY = 0.0;
        _userZoom = 1.0;
        _rotationApiAvailable = NO;
        _bgraTransferSession = NULL;
        _yuvTransferSession = NULL;
        _privateTransferSession = NULL;
        _prerenderTransferSession = NULL;
        _pixelRotationSession = NULL;
        _bgraBufferPoolMap = [[NSMutableDictionary alloc] init];
        _twoStepSessionPool = [[NSMutableDictionary alloc] init];
        _twoStepStagingPool = [[NSMutableDictionary alloc] init];
        _twoStepTokenPool = [[NSMutableDictionary alloc] init];
        _twoStepFailCountPool = [[NSMutableDictionary alloc] init];
        _twoStepDisabledPool = [[NSMutableDictionary alloc] init];
        _oneStepSessionPool = [[NSMutableDictionary alloc] init];
        _oneStepKeyLockPool = [[NSMutableDictionary alloc] init];
        _rotationRenderLock = [[NSLock alloc] init];
        _twoStepKeyLockPool = [[NSMutableDictionary alloc] init];
        _adaptiveRotatedGen = 0;
        _streamKeyOrder = [NSMutableArray array];
        memset(gVcamStatSlots, 0, sizeof(gVcamStatSlots));
        _gpuImgTokenPool = [NSMutableDictionary dictionary];
        _gpuImgOutPool = [NSMutableDictionary dictionary];
        _oneStepFailPool = [NSMutableDictionary dictionary];
        _oneStepDisabledPool = [NSMutableDictionary dictionary];
        _groupStagingPool = [[NSMutableDictionary alloc] init];
        _groupTokenPool = [[NSMutableDictionary alloc] init];
        _groupGlobalLock = [[NSLock alloc] init];
        _groupSessionPool = [[NSMutableDictionary alloc] init];
        _groupSizePool = [[NSMutableDictionary alloc] init];
        _resultCachePool = [[NSMutableDictionary alloc] init];
        _resultBlitSessionPool = [[NSMutableDictionary alloc] init];
        _resultCacheTokenPool = [[NSMutableDictionary alloc] init];
        _lastReqTokenPool = [[NSMutableDictionary alloc] init];
        _resultBlitDisabledPool = [[NSMutableDictionary dictionary] init];
        _statsLock = [[NSLock alloc] init];
        _poolDictLock = [[NSLock alloc] init];

        // 千面模型固定车道
        _laneLockBGRA = [[NSLock alloc] init];
        _laneLockYUV = [[NSLock alloc] init];
        _laneLockPrivate = [[NSLock alloc] init];
        _twoStepS1Session = NULL;
        _laneFailCounts = [NSMutableDictionary dictionary];
        _laneDisabled = [NSMutableDictionary dictionary];

        // 软件渲染 CIContext（回退用）
        @try {
            _preprocessContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @YES
            }];
            _renderContext = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @YES
            }];
        } @catch (NSException *e) {
            _preprocessContext = nil;
            _renderContext = nil;
        }

        // Metal GPU probe（保留，路径永久禁用）
        _metalAvailable = NO;
        @try {
            typedef void *(*CreateDeviceFn)(void);
            CreateDeviceFn createDevice = (CreateDeviceFn)dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
            if (createDevice) {
                id device = (__bridge id)createDevice();
                BOOL devicePresent = (device != nil);
                vcam_gpu_log([NSString stringWithFormat:@"[vcam] Metal device probe: %@ (CI/MTL path DISABLED)",
                              devicePresent ? @"present" : @"absent"]);
            }
        } @catch (NSException *e) {
        }

        [self setupBGRATransferSession];
        [self setupYUVTransferSession];
        [self setupPrerenderTransferSession];
        [self setupPixelRotationSession];

        // ===== 2026-10-30 新增：彩色注入默认值 =====
        _injectMode = 0;                    // 0=人脸轮廓
        _faceDetectEnabled = YES;           // 默认开启人脸检测
        _alphaSliderValue = 0.45;           // 强度滑块默认 45%
        _alphaManualSet = NO;               // 默认自动
        _autoAlphaInternal = 0.45;          // 自动强度初始 0.45
        _lastFaceRectInternal = CGRectZero;
        _lastFaceTimeInternal = 0;
        _lastFaceContourInternal = NULL;
        _alphaManualSetInternal = NO;

        vcam_gpu_log(@"[vcam] GPUImageProcessor initialized (VT token-reuse path, Vision face detect color inject)");
    }
    return self;
}

- (void)dealloc {
    typedef void (*InvalidateFunc)(VTPixelTransferSessionRef);
    if (_bgraTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_bgraTransferSession);
    }
    if (_yuvTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_yuvTransferSession);
    }
    if (_prerenderTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_prerenderTransferSession);
    }
    if (_userTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_userTransferSession);
    }
    if (_privateTransferSession) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_privateTransferSession);
    }
    if (_twoStepS1Session) {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        if (invalidate) invalidate(_twoStepS1Session);
    }
    for (int i = 0; i < kVcamLaneStagingMax; i++) {
        if (gVcamLaneStaging[i].staging) {
            CVPixelBufferRelease(gVcamLaneStaging[i].staging);
            gVcamLaneStaging[i].staging = NULL;
            gVcamLaneStaging[i].w = gVcamLaneStaging[i].h = 0;
            gVcamLaneStaging[i].token = 0;
        }
    }
    {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");
        for (NSValue *v in _twoStepSessionPool.allValues) {
            VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[v pointerValue];
            if (s && invalidate) invalidate(s);
        }
        for (NSValue *v in _twoStepStagingPool.allValues) {
            CVPixelBufferRef b = (CVPixelBufferRef)[v pointerValue];
            if (b) CVPixelBufferRelease(b);
        }
        [_twoStepSessionPool removeAllObjects];
        [_twoStepStagingPool removeAllObjects];
        [_twoStepTokenPool removeAllObjects];
        {
            for (NSString *k in _groupSessionPool.allKeys) {
                NSValue *sv = _groupSessionPool[k];
                VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[sv pointerValue];
                if (s && invalidate) invalidate(s);
            }
            for (NSValue *v in _groupStagingPool.allValues) {
                CVPixelBufferRef b = (CVPixelBufferRef)[v pointerValue];
                if (b) CVPixelBufferRelease(b);
            }
            [_groupSessionPool removeAllObjects];
            [_groupStagingPool removeAllObjects];
            [_groupTokenPool removeAllObjects];
            for (NSValue *v in _resultCachePool.allValues) {
                CVPixelBufferRef b = (CVPixelBufferRef)[v pointerValue];
                if (b) CVPixelBufferRelease(b);
            }
            [_resultCachePool removeAllObjects];
            [_resultCacheTokenPool removeAllObjects];
            for (NSValue *v in _resultBlitSessionPool.allValues) {
                VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[v pointerValue];
                if (s && invalidate) invalidate(s);
            }
            [_resultBlitSessionPool removeAllObjects];
        }
        for (NSValue *v in _oneStepSessionPool.allValues) {
            VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[v pointerValue];
            if (s && invalidate) invalidate(s);
        }
        [_oneStepSessionPool removeAllObjects];
    }
    {
        InvalidateFunc invalidate = (InvalidateFunc)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionInvalidate");
        if (invalidate) {
            if (_pixelRotationSession) invalidate((VTPixelTransferSessionRef)_pixelRotationSession);
            if (_renderRotationSession) invalidate((VTPixelTransferSessionRef)_renderRotationSession);
        }
    }
    if (_adaptiveRotateCache) {
        CVPixelBufferRelease(_adaptiveRotateCache);
        _adaptiveRotateCache = NULL;
    }
    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef b = [self prerenderRotateBufferAtSlot:i];
        if (b) CVPixelBufferRelease(b);
        [self setPrerenderRotateBuffer:NULL atSlot:i];
    }
    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef b = [self userCanvasAtSlot:i];
        if (b) CVPixelBufferRelease(b);
        [self setUserCanvas:NULL atSlot:i];
    }
    if (_userShrinkBuffer) {
        CVPixelBufferRelease(_userShrinkBuffer);
        _userShrinkBuffer = NULL;
    }
    if (_userPieceBuffer) {
        CVPixelBufferRelease(_userPieceBuffer);
        _userPieceBuffer = NULL;
    }
    // 三色打光画布释放（原有）
    for (int i = 0; i < 3; i++) {
        CVPixelBufferRef b = [self lightCanvasAtSlot:i];
        if (b) CVPixelBufferRelease(b);
        [self setLightCanvas:NULL atSlot:i];
    }
    // 缓冲池释放（原有）
    for (id key in _bgraBufferPoolMap) {
        CVPixelBufferPoolRef pool = (__bridge CVPixelBufferPoolRef)_bgraBufferPoolMap[key];
        CVPixelBufferPoolRelease(pool);
    }
    [_bgraBufferPoolMap removeAllObjects];

    // ===== 2026-10-30 新增：清理人脸轮廓路径 =====
    if (_lastFaceContourInternal) {
        CGPathRelease(_lastFaceContourInternal);
        _lastFaceContourInternal = NULL;
    }

    vcam_gpu_log(@"[vcam] GPUImageProcessor deallocated");
}

// ============================================================================
//  Session 初始化（保留原有）
// ============================================================================

- (void)setupBGRATransferSession {
    if (_bgraTransferSession) return;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_bgraTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_bgraTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] BGRA VTPixelTransferSession created (Trim only)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create BGRA session: %d", (int)status]);
    }
}

- (void)setupYUVTransferSession {
    if (_yuvTransferSession) return;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_yuvTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_yuvTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] YUV VTPixelTransferSession created (Trim only)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create YUV session: %d", (int)status]);
    }
}

- (void)setupPrerenderTransferSession {
    if (_prerenderTransferSession) return;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_prerenderTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_prerenderTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] Prerender VTPixelTransferSession created (Trim)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create prerender session: %d", (int)status]);
    }
}

- (void)setupPrivateTransferSession {
    if (_privateTransferSession) return;
    OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_privateTransferSession);
    if (status == noErr) {
        VTSessionSetProperty(_privateTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
        vcam_gpu_log(@"[vcam] Private-format VTPixelTransferSession created (Trim)");
    } else {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create private session: %d", (int)status]);
    }
}

- (void)setupPixelRotationSession {
    if (_pixelRotationSession) return;

    void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_LAZY | RTLD_GLOBAL);
    void *base = vt ? vt : RTLD_DEFAULT;

    _createRotationSession = (VTPixelRotationSessionCreateFunc)dlsym(base, "VTPixelRotationSessionCreate");
    _transferRotationImage = (VTPixelRotationSessionTransferImageFunc)dlsym(base, "VTPixelRotationSessionRotateImage");

    void *rotSym = dlsym(base, "kVTPixelRotationPropertyKey_Rotation");
    _rotationPropertyKey = rotSym ? *(CFStringRef *)rotSym : CFSTR("Rotation");
    void *ccwSym = dlsym(base, "kVTRotation_CCW90");
    _rotationCCW90Value = ccwSym ? *(CFStringRef *)ccwSym : CFSTR("CCW90");
    void *cwSym = dlsym(base, "kVTRotation_CW90");
    _rotationCW90Value = cwSym ? *(CFStringRef *)cwSym : CFSTR("CW90");
    void *r180Sym = dlsym(base, "kVTRotation_180");
    _rotation180Value = r180Sym ? *(CFStringRef *)r180Sym : CFSTR("180");
    void *flipSym = dlsym(base, "kVTPixelRotationPropertyKey_FlipHorizontalOrientation");
    _flipHorizontalKey = flipSym ? *(CFStringRef *)flipSym : CFSTR("FlipHorizontalOrientation");

    vcam_gpu_log([NSString stringWithFormat:@"[vcam] rotation api probe: handle=%d create=%d rotate=%d rotKey=%d ccw=%d cw=%d r180=%d flipKey=%d",
                  vt != NULL, _createRotationSession != NULL, _transferRotationImage != NULL,
                  rotSym != NULL, ccwSym != NULL, cwSym != NULL, r180Sym != NULL, flipSym != NULL]);

    if (!_createRotationSession || !_transferRotationImage) {
        _rotationApiAvailable = NO;
        vcam_gpu_log(@"[vcam] VTPixelRotationSession API unavailable (adaptive rotation disabled)");
        return;
    }

    OSStatus status = _createRotationSession(kCFAllocatorDefault, &_pixelRotationSession);
    if (status == noErr) {
        _rotationApiAvailable = YES;
        OSStatus st2 = _createRotationSession(kCFAllocatorDefault, &_renderRotationSession);
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelRotationSession created (render session: %d)", (int)st2]);
    } else {
        _rotationApiAvailable = NO;
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create VTPixelRotationSession: %d", (int)status]);
    }
}

// ============================================================================
//  缓冲池（保留原有）
// ============================================================================

- (CVPixelBufferPoolRef)getOrCreatePoolForWidth:(size_t)width height:(size_t)height format:(OSType)format {
    if (width == 0 || height == 0) return NULL;

    @synchronized(self) {
        NSString *key = [NSString stringWithFormat:@"%zu_%zu_%u", width, height, (unsigned)format];
        id existing = _bgraBufferPoolMap[key];
        if (existing) {
            return (__bridge CVPixelBufferPoolRef)existing;
        }
        [self touchStreamKeyLRU:key];

        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @2,
        };
        NSDictionary *pixelBufferAttributes = @{
            (id)kCVPixelBufferWidthKey:  @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferPixelFormatTypeKey: @(format),
        };

        CVPixelBufferPoolRef pool = NULL;
        OSStatus status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            (__bridge CFDictionaryRef)poolAttributes,
            (__bridge CFDictionaryRef)pixelBufferAttributes,
            &pool
        );

        if (status != noErr) {
            status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                NULL,
                (__bridge CFDictionaryRef)pixelBufferAttributes,
                &pool
            );
        }

        if (status == noErr && pool) {
            _bgraBufferPoolMap[key] = (__bridge id)pool;
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] Created buffer pool: %zux%zu fmt=%u (key=%@)", width, height, (unsigned)format, key]);
            return pool;
        }

        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create buffer pool: %d, %zux%zu", (int)status, width, height]);
        return NULL;
    }
}

- (CVPixelBufferRef)getOrCreateBGRABufferWithWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED {
    @synchronized(self) {
        CVPixelBufferPoolRef pool = [self getOrCreatePoolForWidth:width height:height format:kCVPixelFormatType_32BGRA];

        CVPixelBufferRef buffer = NULL;
        if (pool) {
            OSStatus status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer);
            if (status == noErr && buffer) {
                return buffer;
            }
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to get buffer from pool: %d", (int)status]);
        }

        OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, NULL, &buffer);
        if (status != noErr) {
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create pixel buffer: %d, %zux%zu BGRA", (int)status, width, height]);
            return NULL;
        }
        return buffer;
    }
}

- (void)configureWithWidth:(size_t)width height:(size_t)height format:(OSType)format {
    [self getOrCreatePoolForWidth:width height:height format:format];
    NSString *fmtStr = [self stringForFormat:format];
    vcam_gpu_log([NSString stringWithFormat:@"[vcam] GPUImageProcessor configured: %zux%zu format: %@", width, height, fmtStr]);
}
#pragma mark - 核心处理

- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)input
                                toWidth:(size_t)width
                                height:(size_t)height
                                format:(OSType)format CF_RETURNS_RETAINED {
    if (!input) return NULL;

    @try {
        size_t inW = CVPixelBufferGetWidth(input);
        size_t inH = CVPixelBufferGetHeight(input);

        int total = (_sourceRotation + _rotationAngle) % 360;
        if (total < 0) total += 360;

        size_t rotW = inW, rotH = inH;
        if (total == 90 || total == 270) {
            rotW = inH;
            rotH = inW;
        }

        CVPixelBufferRef processedBuffer = NULL;
        if ((total != 0 || _mirrored) && _rotationApiAvailable && _pixelRotationSession) {
            processedBuffer = [self rotateAndMirror:input width:rotW height:rotH angle:total];
        }
        if (!processedBuffer) {
            processedBuffer = input;
            CVPixelBufferRetain(processedBuffer);
        }

        size_t curW = CVPixelBufferGetWidth(processedBuffer);
        size_t curH = CVPixelBufferGetHeight(processedBuffer);
        if (curW != width || curH != height) {
            CVPixelBufferRef scaledBGRA = [self scaleToBGRA:processedBuffer width:width height:height];
            CVPixelBufferRelease(processedBuffer);
            processedBuffer = scaledBGRA;
            if (!processedBuffer) {
                return NULL;
            }
        }

        CVPixelBufferRef outputBuffer = NULL;
        if (format == kCVPixelFormatType_32BGRA) {
            outputBuffer = processedBuffer;
        } else {
            outputBuffer = [self createBufferWithWidth:width height:height format:format];
            if (outputBuffer) {
                OSStatus status = VTPixelTransferSessionTransferImage(_yuvTransferSession, processedBuffer, outputBuffer);
                if (status != noErr) {
                    NSString *fmtStr = [self stringForFormat:format];
                    vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelTransferSession failed: %d, format: %@", (int)status, fmtStr]);
                    CVPixelBufferRelease(outputBuffer);
                    outputBuffer = [self convertWithCoreImage:processedBuffer toFormat:format width:width height:height];
                }
            }
            CVPixelBufferRelease(processedBuffer);
        }

        return outputBuffer;
    } @catch (NSException *e) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Exception in processPixelBuffer: %@", e]);
        return NULL;
    }
}

// crop fill: 保持宽高比, 填充整个目标, 裁剪超出部分（无黑边, 居中）
- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input
                          width:(size_t)width
                         height:(size_t)height CF_RETURNS_RETAINED {
    if (!input || !_preprocessContext) return NULL;

    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    if (inW == 0 || inH == 0 || width == 0 || height == 0) return NULL;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NULL;

    CVPixelBufferRef output = [self getOrCreateBGRABufferWithWidth:width height:height];
    if (!output) return NULL;

    // crop fill: 取较大缩放比填充整个目标, 超出部分裁剪（无黑边）
    CGFloat scale = MAX((CGFloat)width / (CGFloat)inW, (CGFloat)height / (CGFloat)inH);
    CGFloat scaledW = (CGFloat)inW * scale;
    CGFloat scaledH = (CGFloat)inH * scale;
    CGFloat offsetX = ((CGFloat)width - scaledW) / 2.0;
    CGFloat offsetY = ((CGFloat)height - scaledH) / 2.0;

    CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
    t = CGAffineTransformTranslate(t, offsetX / scale, offsetY / scale);
    CIImage *scaled = [image imageByApplyingTransform:t];

    // 千面用 DeviceRGB 渲染
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_preprocessContext render:scaled toCVPixelBuffer:output
                        bounds:CGRectMake(0, 0, (CGFloat)width, (CGFloat)height)
                    colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    return output;
}

- (CVPixelBufferRef)rotateAndMirror:(CVPixelBufferRef)input width:(size_t)width height:(size_t)height angle:(int)angle CF_RETURNS_RETAINED {
    if (!input || !_pixelRotationSession) return NULL;

    // 目标缓冲保持源格式
    OSType srcFormat = CVPixelBufferGetPixelFormatType(input);
    CVPixelBufferRef dst = NULL;
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, srcFormat, NULL, &dst);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create rotation buffer: %d", (int)status]);
        return NULL;
    }

    // 设置旋转角度（angle==0 也显式设置: 不设置会残留上一次的角度）
    if (angle == 90) {
        VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, _rotationCW90Value);
    } else if (angle == 180) {
        VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, _rotation180Value);
    } else if (angle == 270) {
        VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, _rotationCCW90Value);
    } else {
        VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, kCFBooleanFalse);
    }
    VTSessionSetProperty(_pixelRotationSession, _flipHorizontalKey, _mirrored ? kCFBooleanTrue : kCFBooleanFalse);

    status = _transferRotationImage(_pixelRotationSession, input, dst);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] VTPixelRotationSession failed: %d", (int)status]);
        CVPixelBufferRelease(dst);
        return NULL;
    }

    return dst;
}

// 3 槽存取 helper（仅预渲染线程 + dealloc 调用）
- (CVPixelBufferRef)prerenderRotateBufferAtSlot:(int)slot {
    if (slot == 0) return _prerenderRotatePool0;
    if (slot == 1) return _prerenderRotatePool1;
    return _prerenderRotatePool2;
}

- (void)setPrerenderRotateBuffer:(CVPixelBufferRef)buf atSlot:(int)slot {
    if (slot == 0) _prerenderRotatePool0 = buf;
    else if (slot == 1) _prerenderRotatePool1 = buf;
    else _prerenderRotatePool2 = buf;
}

// CPU 水平镜像（原地行反转）
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

// 色彩附件同步
static void vcamSyncColorAttachments(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return;
    static CFStringRef keys[3];
    static dispatch_once_t onceTok;
    dispatch_once(&onceTok, ^{
        keys[0] = kCVImageBufferColorPrimariesKey;
        keys[1] = kCVImageBufferTransferFunctionKey;
        keys[2] = kCVImageBufferYCbCrMatrixKey;
    });
    for (int i = 0; i < 3; i++) {
        CFTypeRef v = CVBufferGetAttachment(src, keys[i], NULL);
        if (v) CVBufferSetAttachment(dst, keys[i], v, kCVAttachmentMode_ShouldPropagate);
    }
}

// Trim crop offset 非整数判定
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

// 逐平面复制
static BOOL vcamCopyPlanes(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return NO;
    if (CVPixelBufferGetPixelFormatType(src) != CVPixelBufferGetPixelFormatType(dst)) return NO;
    int planes = (int)CVPixelBufferGetPlaneCount(src);
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);
    if (planes <= 0) {
        uint8_t *s = (uint8_t *)CVPixelBufferGetBaseAddress(src);
        uint8_t *d = (uint8_t *)CVPixelBufferGetBaseAddress(dst);
        size_t sbpr = CVPixelBufferGetBytesPerRow(src), dbpr = CVPixelBufferGetBytesPerRow(dst);
        size_t w = CVPixelBufferGetWidth(src) * 4, h = CVPixelBufferGetHeight(src);
        for (size_t y = 0; y < h && s && d; y++)
            memcpy(d + y * dbpr, s + y * sbpr, w);
    } else {
        for (int p = 0; p < planes; p++) {
            uint8_t *s = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, p);
            uint8_t *d = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t dbpr = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            size_t px = (p == 0) ? 1 : 2;
            size_t w = CVPixelBufferGetWidthOfPlane(src, p) * px;
            size_t h = CVPixelBufferGetHeightOfPlane(src, p);
            for (size_t y = 0; y < h && s && d; y++)
                memcpy(d + y * dbpr, s + y * sbpr, w);
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return YES;
}

// 预渲染用: 旋转（VT 纯旋转，永不设 flip 属性）+ 镜像（CPU 行反转）。保持源格式。
// 总旋转 = 视频自带（sourceRotation）+ 用户手动（rotationAngle）
- (CVPixelBufferRef)rotateAndMirrorIfNeeded:(CVPixelBufferRef)input CF_RETURNS_RETAINED {
    if (!input) return NULL;
    int total = (_sourceRotation + _rotationAngle) % 360;
    if (total < 0) total += 360;
    BOOL needRotate = (total != 0);
    BOOL needMirror = _mirrored;
    if (!needRotate && !needMirror) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    OSType fmt = CVPixelBufferGetPixelFormatType(input);

    // 阶段1: 纯旋转（VT）→ 产出可写池 buffer; 失败/不需要时用原帧
    CVPixelBufferRef work = NULL;
    BOOL workIsWritable = NO;
    if (needRotate && _rotationApiAvailable && _pixelRotationSession && _transferRotationImage) {
        size_t rotW = (total == 90 || total == 270) ? inH : inW;
        size_t rotH = (total == 90 || total == 270) ? inW : inH;
        int slot = _prerenderRotateSlot;
        _prerenderRotateSlot = (slot + 1) % 3;
        CVPixelBufferRef dst = [self prerenderRotateBufferAtSlot:slot];
        if (!dst || CVPixelBufferGetWidth(dst) != rotW || CVPixelBufferGetHeight(dst) != rotH ||
            CVPixelBufferGetPixelFormatType(dst) != fmt) {
            if (dst) CVPixelBufferRelease(dst);
            dst = NULL;
            OSStatus cst = CVPixelBufferCreate(kCFAllocatorDefault, rotW, rotH, fmt, NULL, &dst);
            if (cst != noErr || !dst) {
                [self setPrerenderRotateBuffer:NULL atSlot:slot];
            } else {
                [self setPrerenderRotateBuffer:dst atSlot:slot];
            }
        }
        if (dst) {
            CFTypeRef rotValue;
            if (total == 90)       rotValue = _rotationCW90Value;
            else if (total == 270) rotValue = _rotationCCW90Value;
            else                   rotValue = _rotation180Value;
            VTSessionSetProperty(_pixelRotationSession, _rotationPropertyKey, rotValue);
            OSStatus st = _transferRotationImage(_pixelRotationSession, input, dst);
            if (st == noErr) {
                work = CVPixelBufferRetain(dst);
                workIsWritable = YES;
            } else {
                static int rotFailLogged = 0;
                if (rotFailLogged++ < 2) {
                    vcam_gpu_log([NSString stringWithFormat:@"[vcam] prerender rotate failed: %d (keep unrotated)", (int)st]);
                }
            }
        }
    }
    if (!work) {
        work = (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    // 阶段2: 镜像（CPU 行反转）
    if (!needMirror) return work;
    if (workIsWritable) {
        vcamMirrorRowsInPlace(work);
        return work;
    }
    // mirror-only: 复制到几何槽再反转
    int mslot = _prerenderRotateSlot;
    _prerenderRotateSlot = (mslot + 1) % 3;
    CVPixelBufferRef mb = [self prerenderRotateBufferAtSlot:mslot];
    if (!mb || CVPixelBufferGetWidth(mb) != inW || CVPixelBufferGetHeight(mb) != inH ||
        CVPixelBufferGetPixelFormatType(mb) != fmt) {
        if (mb) CVPixelBufferRelease(mb);
        mb = NULL;
        CVPixelBufferRef created = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, inW, inH, fmt, NULL, &created) == noErr && created) {
            [self setPrerenderRotateBuffer:created atSlot:mslot];
            mb = created;
        } else {
            [self setPrerenderRotateBuffer:NULL atSlot:mslot];
        }
    }
    if (mb && vcamCopyPlanes(work, mb)) {
        vcamMirrorRowsInPlace(mb);
        CVPixelBufferRelease(work);
        return CVPixelBufferRetain(mb);
    }
    // 复制失败（罕见）：返回未镜像帧，不崩溃
    return work;
}
#pragma mark - 用户画面变换画布池

- (CVPixelBufferRef)userCanvasAtSlot:(int)slot {
    if (slot == 0) return _userCanvasPool0;
    if (slot == 1) return _userCanvasPool1;
    return _userCanvasPool2;
}

- (void)setUserCanvas:(CVPixelBufferRef)buf atSlot:(int)slot {
    if (slot == 0) _userCanvasPool0 = buf;
    else if (slot == 1) _userCanvasPool1 = buf;
    else _userCanvasPool2 = buf;
}

- (CVPixelBufferRef)userPieceBuffer:(CVPixelBufferRef *)slot
                              width:(size_t)w height:(size_t)h format:(OSType)fmt {
    if (*slot && CVPixelBufferGetWidth(*slot) == w && CVPixelBufferGetHeight(*slot) == h &&
        CVPixelBufferGetPixelFormatType(*slot) == fmt) {
        return *slot;
    }
    if (*slot) CVPixelBufferRelease(*slot);
    *slot = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, NULL, slot);
    return *slot;
}

// 双平面 YUV（420f/420v）区域拷贝
static void vcamCopyRegionBiPlanar(CVPixelBufferRef dst, CVPixelBufferRef src,
                                   size_t dstX, size_t dstY,
                                   size_t srcX, size_t srcY,
                                   size_t w, size_t h) {
    if (!dst || !src || !w || !h) return;
    for (int p = 0; p < 2; p++) {
        uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, p);
        uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, p);
        if (!sb || !db) continue;
        size_t sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, p);
        size_t dbpr = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
        size_t rowBytes = w;
        size_t rows = (p == 0) ? h : h / 2;
        size_t yDiv = (p == 0) ? 1 : 2;
        for (size_t y = 0; y < rows; y++) {
            memcpy(db + (dstY / yDiv + y) * dbpr + dstX,
                   sb + (srcY / yDiv + y) * sbpr + srcX,
                   rowBytes);
        }
    }
}

// 双平面 YUV 清黑（保留作为"窗口完全出界"的极端兜底）
static void vcamClearBiPlanarBlack(CVPixelBufferRef buf, OSType fmt) {
    if (!buf) return;
    int yBlack = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? 0 : 16;
    uint8_t *yb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 0);
    uint8_t *uvb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 1);
    size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
    size_t uvbpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 1);
    size_t w = CVPixelBufferGetWidth(buf);
    size_t h = CVPixelBufferGetHeight(buf);
    if (yb) for (size_t y = 0; y < h; y++) memset(yb + y * ybpr, yBlack, w);
    if (uvb) for (size_t y = 0; y < h / 2; y++) memset(uvb + y * uvbpr, 128, w);
}

// ============================================================================
//  2026-10-30 新增：边缘钳制填充（参考 imageByClampingToExtent 思路）
//  用画布内容区的边界行/列向外扩展填充出界区：
//    - 左出界 [0, dx0)：用 canvas[dx0] 列填
//    - 右出界 [dx1, W)：用 canvas[dx1] 列填
//    - 上出界 [0, dy0)：用 canvas[dy0] 行填
//    - 下出界 [dy1, H)：用 canvas[dy1] 行填
//  执行顺序：先左右，后上下（角部被上下填充自动覆盖）
//  双平面 YUV 的 UV 边界用真实边缘 UV（不是 128 灰），彻底消除绿边
// ============================================================================
static void vcamExtendCanvasEdges(CVPixelBufferRef canvas, long dx0, long dy0, long dx1, long dy1) {
    if (!canvas) return;
    size_t W = CVPixelBufferGetWidth(canvas);
    size_t H = CVPixelBufferGetHeight(canvas);
    if (W == 0 || H == 0) return;

    int planes = (int)CVPixelBufferGetPlaneCount(canvas);

    if (planes <= 0) {
        // ===== BGRA 单平面 =====
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(canvas);
        size_t bpr = CVPixelBufferGetBytesPerRow(canvas);
        if (!base) return;
        size_t px = 4;

        // 左出界
        if (dx0 > 0 && dx0 < (long)W) {
            for (size_t y = 0; y < H; y++) {
                uint8_t *row = base + y * bpr;
                uint32_t edgePx = *(uint32_t *)(row + dx0 * px);
                for (long x = 0; x < dx0; x++) {
                    *(uint32_t *)(row + x * px) = edgePx;
                }
            }
        }
        // 右出界
        if (dx1 >= 0 && dx1 < (long)W) {
            for (size_t y = 0; y < H; y++) {
                uint8_t *row = base + y * bpr;
                uint32_t edgePx = *(uint32_t *)(row + dx1 * px);
                for (long x = dx1; x < (long)W; x++) {
                    *(uint32_t *)(row + x * px) = edgePx;
                }
            }
        }
        // 上出界
        if (dy0 > 0 && dy0 < (long)H) {
            uint8_t *srcRow = base + dy0 * bpr;
            for (long y = 0; y < dy0; y++) {
                uint8_t *dstRow = base + y * bpr;
                memcpy(dstRow, srcRow, W * px);
            }
        }
        // 下出界
        if (dy1 >= 0 && dy1 < (long)H) {
            uint8_t *srcRow = base + dy1 * bpr;
            for (long y = dy1; y < (long)H; y++) {
                uint8_t *dstRow = base + y * bpr;
                memcpy(dstRow, srcRow, W * px);
            }
        }
    } else {
        // ===== 420f / 420v 双平面 =====
        for (int p = 0; p < planes && p < 2; p++) {
            uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, p);
            size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(canvas, p);
            size_t pw = CVPixelBufferGetWidthOfPlane(canvas, p);
            size_t ph = CVPixelBufferGetHeightOfPlane(canvas, p);
            size_t px = (p == 0) ? 1 : 2;
            if (!base) continue;

            // UV 平面坐标减半
            long pdx0 = (p == 0) ? dx0 : (dx0 / 2);
            long pdy0 = (p == 0) ? dy0 : (dy0 / 2);
            long pdx1 = (p == 0) ? dx1 : (dx1 / 2);
            long pdy1 = (p == 0) ? dy1 : (dy1 / 2);
            long pW = (long)pw;
            long pH = (long)ph;

            // 左出界
            if (pdx0 > 0 && pdx0 < pW) {
                for (size_t y = 0; y < ph; y++) {
                    uint8_t *row = base + y * bpr;
                    if (px == 1) {
                        uint8_t v = row[pdx0];
                        memset(row, v, pdx0);
                    } else {
                        uint8_t u = row[pdx0 * 2];
                        uint8_t v = row[pdx0 * 2 + 1];
                        for (long x = 0; x < pdx0; x++) {
                            row[x * 2] = u;
                            row[x * 2 + 1] = v;
                        }
                    }
                }
            }
            // 右出界
            if (pdx1 >= 0 && pdx1 < pW) {
                for (size_t y = 0; y < ph; y++) {
                    uint8_t *row = base + y * bpr;
                    if (px == 1) {
                        uint8_t v = row[pdx1];
                        memset(row + pdx1, v, pW - pdx1);
                    } else {
                        uint8_t u = row[pdx1 * 2];
                        uint8_t v = row[pdx1 * 2 + 1];
                        for (long x = pdx1; x < pW; x++) {
                            row[x * 2] = u;
                            row[x * 2 + 1] = v;
                        }
                    }
                }
            }
            // 上出界
            if (pdy0 > 0 && pdy0 < pH) {
                uint8_t *srcRow = base + pdy0 * bpr;
                for (long y = 0; y < pdy0; y++) {
                    memcpy(base + y * bpr, srcRow, pW * px);
                }
            }
            // 下出界
            if (pdy1 >= 0 && pdy1 < pH) {
                uint8_t *srcRow = base + pdy1 * bpr;
                for (long y = pdy1; y < pH; y++) {
                    memcpy(base + y * bpr, srcRow, pW * px);
                }
            }
        }
    }
}

// ============================================================================
//  用户画面变换烘焙（核心修改：出界区从清黑改为边缘钳制填充）
// ============================================================================
- (CVPixelBufferRef)bakeUserTransformIntoCanvas:(CVPixelBufferRef)input CF_RETURNS_RETAINED {
    if (!input) return NULL;
    double z = _userZoom;
    if (z < 0.5) z = 0.5;
    if (z > 4.0) z = 4.0;
    if (fabs(z - 1.0) < 0.001 && _userPanX == 0.0 && _userPanY == 0.0) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    OSType fmt = CVPixelBufferGetPixelFormatType(input);
    if (CVPixelBufferGetPlaneCount(input) != 2) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    size_t W = CVPixelBufferGetWidth(input);
    size_t H = CVPixelBufferGetHeight(input);
    if (W < 16 || H < 16) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    // 画布 3 槽轮转（恒 W×H 固定尺寸）
    int slot = _userCanvasSlot;
    _userCanvasSlot = (slot + 1) % 3;
    CVPixelBufferRef canvas = [self userCanvasAtSlot:slot];
    if (!canvas || CVPixelBufferGetWidth(canvas) != W || CVPixelBufferGetHeight(canvas) != H ||
        CVPixelBufferGetPixelFormatType(canvas) != fmt) {
        if (canvas) CVPixelBufferRelease(canvas);
        canvas = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, W, H, fmt, NULL, &canvas) != noErr || !canvas) {
            [self setUserCanvas:NULL atSlot:slot];
            return (CVPixelBufferRef)CVPixelBufferRetain(input);
        }
        [self setUserCanvas:canvas atSlot:slot];
    }

    // 色彩附件复制（变色修复）
    CFDictionaryRef colorAtts = CVBufferCopyAttachments(input, kCVAttachmentMode_ShouldPropagate);
    if (colorAtts) {
        CVBufferSetAttachments(canvas, colorAtts, kCVAttachmentMode_ShouldPropagate);
        CFRelease(colorAtts);
    }

    // ===== 窗口（等比，可出界） =====
    double ww = (double)W / z;
    double wh = (double)H / z;
    double wx = ((double)W - ww) / 2.0 - _userPanX * (double)W;
    double wy = ((double)H - wh) / 2.0 - _userPanY * (double)W;

    // 交集 srcRect（窗口∩视频），偶对齐
    long sx0 = (long)MAX(wx, 0.0), sy0 = (long)MAX(wy, 0.0);
    long sx1 = (long)MIN(wx + ww, (double)W), sy1 = (long)MIN(wy + wh, (double)H);
    sx0 &= ~1L; sy0 &= ~1L;
    sx1 &= ~1L; sy1 &= ~1L;

    CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(canvas, 0);

    if (sx1 <= sx0 || sy1 <= sy0) {
        // 窗口完全出界（罕见场景）：清黑兜底
        vcamClearBiPlanarBlack(canvas, fmt);
    } else {
        size_t sw = (size_t)(sx1 - sx0), sh = (size_t)(sy1 - sy0);

        // canvasRect = (srcRect − 窗口原点) × z（等比，同宽高比），偶对齐 + clamp 画布内
        double kx = (double)W / ww;
        long dx0 = lround(((double)sx0 - wx) * kx) & ~1L;
        long dy0 = lround(((double)sy0 - wy) * kx) & ~1L;
        long dx1 = lround(((double)sx1 - wx) * kx) & ~1L;
        long dy1 = lround(((double)sy1 - wy) * kx) & ~1L;
        if (dx0 < 0) dx0 = 0;
        if (dy0 < 0) dy0 = 0;
        if (dx1 > (long)W) dx1 = (long)W;
        if (dy1 > (long)H) dy1 = (long)H;

        if (dx1 > dx0 && dy1 > dy0) {
            size_t dw = (size_t)(dx1 - dx0), dh = (size_t)(dy1 - dy0);

            if (fabs(kx - 1.0) < 0.001) {
                // z=1（纯平移）：源区域直接贴到画布
                vcamCopyRegionBiPlanar(canvas, input, (size_t)dx0, (size_t)dy0,
                                       (size_t)sx0, (size_t)sy0, dw, dh);
            } else {
                // 通用：memcpy 裁剪 srcRect → pieceA，VT 等比缩放 pieceA → pieceB（×z）
                CVPixelBufferRef pieceA = [self userPieceBuffer:&_userShrinkBuffer
                                                          width:sw height:sh format:fmt];
                if (pieceA) {
                    CVPixelBufferLockBaseAddress(pieceA, 0);
                    vcamCopyRegionBiPlanar(pieceA, input, 0, 0, (size_t)sx0, (size_t)sy0, sw, sh);
                    CVPixelBufferUnlockBaseAddress(pieceA, 0);
                    if (!_userTransferSession) {
                        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_userTransferSession) == noErr) {
                            VTSessionSetProperty(_userTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
                            VTSessionSetProperty(_userTransferSession, CFSTR("RealTime"), kCFBooleanTrue);
                            vcam_gpu_log(@"[vcam] user-transform VT session created (Trim)");
                        }
                    }
                    if (_userTransferSession) {
                        CVPixelBufferRef pieceB = [self userPieceBuffer:&_userPieceBuffer
                                                                  width:dw height:dh format:fmt];
                        if (pieceB) {
                            if (VTPixelTransferSessionTransferImage(_userTransferSession,
                                                                    pieceA, pieceB) == noErr) {
                                CVPixelBufferLockBaseAddress(pieceB, kCVPixelBufferLock_ReadOnly);
                                vcamCopyRegionBiPlanar(canvas, pieceB, (size_t)dx0, (size_t)dy0,
                                                       0, 0, dw, dh);
                                CVPixelBufferUnlockBaseAddress(pieceB, kCVPixelBufferLock_ReadOnly);
                            } else {
                                // VT 失败保底：pieceA 1:1 贴画布左上角
                                vcamCopyRegionBiPlanar(canvas, pieceA, 0, 0, 0, 0,
                                                       MIN(sw, W), MIN(sh, H));
                            }
                        }
                    } else {
                        // session 建不出：1:1 贴左上角保底
                        vcamCopyRegionBiPlanar(canvas, pieceA, 0, 0, 0, 0, MIN(sw, W), MIN(sh, H));
                    }
                }
            }

            // ===== 2026-10-30 新增：边缘钳制填充 =====
            // 交集区已填好，出界区用源边缘像素向外扩展（替代原清黑）
            // 参考 imageByClampingToExtent 思路，在 YUV 双平面上用边界行/列重复实现
            vcamExtendCanvasEdges(canvas, dx0, dy0, dx1, dy1);
        } else {
            vcamClearBiPlanarBlack(canvas, fmt);
        }
    }

    CVPixelBufferUnlockBaseAddress(canvas, 0);
    CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    return (CVPixelBufferRef)CVPixelBufferRetain(canvas);
}
#pragma mark - 彩色注入（Vision 人脸检测 + 无脸回退 Y/CbCr）

// ============================================================================
//  原有 Y/CbCr 光斑（无脸 / 关闭检测 / Vision 异常时的回退路径，一行不动）
//  420f/420v 是 bi-planar: plane0 = Y(W×H), plane1 = CbCr 交织(W/2 对 × 2 字节/行 H/2)
//  公式与 Android 完全一致:
//    inner_r = radius*(100-feather)*80/10000
//    max_alpha_256 = intensity*192/100
// ============================================================================
static void vcamApplyLightBiPlanar(CVPixelBufferRef buf, uint32_t rgb,
                                   int px, int py, int intensity,
                                   int diameter, int feather) {
    if (!buf || rgb == 0) return;
    if (intensity > 100) intensity = 100;
    if (diameter == 0) diameter = 50;
    if (feather > 100) feather = 100;
    if (px > 100) px = 50;
    if (py > 100) py = 50;

    size_t fw = CVPixelBufferGetWidth(buf);
    size_t fh = CVPixelBufferGetHeight(buf);
    if (fw < 8 || fh < 8) return;

    int cx = (int)((int64_t)px * (int64_t)fw / 100);
    int cy = (int)((int64_t)py * (int64_t)fh / 100);
    int minDim = (int)((fw < fh) ? fw : fh);
    int radius = (int)((int64_t)diameter * minDim / 200);
    if (radius < 2) return;
    int innerR = radius * (100 - feather) * 80 / 10000;
    int maxAlpha256 = intensity * 192 / 100;

    uint8_t r = (rgb >> 16) & 0xFF;
    uint8_t g = (rgb >> 8) & 0xFF;
    uint8_t b = rgb & 0xFF;
    uint8_t colorY = (uint8_t)((299 * r + 587 * g + 114 * b) / 1000);
    uint8_t colorU = (uint8_t)((-169 * r - 331 * g + 500 * b) / 1000 + 128);
    uint8_t colorV = (uint8_t)((500 * r - 419 * g - 81 * b) / 1000 + 128);

    uint8_t *yPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 0);
    uint8_t *cPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 1);
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
    size_t cStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 1);
    if (!yPlane || !cPlane) return;

    // Y 平面：圆形渐变
    int radiusSq = radius * radius;
    int innerSq = innerR * innerR;
    int featherRange = radiusSq - innerSq;
    double invAlphaY = (featherRange > 0) ? (double)maxAlpha256 / (double)featherRange : 0.0;
    const int cInvA = 256 - maxAlpha256;
    const int cAdd = colorY * maxAlpha256;
    int yStart = cy - radius; if (yStart < 0) yStart = 0;
    int yEnd = cy + radius;   if (yEnd > (int)fh) yEnd = (int)fh;

    for (int y = yStart; y < yEnd; y++) {
        int dy = y - cy;
        int dySq = dy * dy;
        if (dySq >= radiusSq) continue;
        uint8_t *row = yPlane + (size_t)y * yStride;

        int remain = radiusSq - dySq;
        int dxMax = radius;
        dxMax = (dxMax + remain / dxMax) / 2;
        if (dxMax > radius) dxMax = radius;

        int rxStart = cx - dxMax; if (rxStart < 0) rxStart = 0;
        int rxEnd = cx + dxMax;   if (rxEnd > (int)fw) rxEnd = (int)fw;
        int cStart = cx - innerR; if (cStart < rxStart) cStart = rxStart;
        int cEnd = cx + innerR;   if (cEnd > rxEnd) cEnd = rxEnd;

        for (int x = rxStart; x < cStart; x++) {
            int dx = x - cx;
            int distSq = dx * dx + dySq;
            if (distSq <= innerSq || distSq >= radiusSq) continue;
            int alpha256 = (int)((radiusSq - distSq) * invAlphaY);
            row[x] = (uint8_t)((row[x] * (256 - alpha256) + colorY * alpha256) >> 8);
        }
        for (int x = cStart; x < cEnd; x++) {
            row[x] = (uint8_t)((row[x] * cInvA + cAdd) >> 8);
        }
        for (int x = cEnd; x < rxEnd; x++) {
            int dx = x - cx;
            int distSq = dx * dx + dySq;
            if (distSq <= innerSq || distSq >= radiusSq) continue;
            int alpha256 = (int)((radiusSq - distSq) * invAlphaY);
            row[x] = (uint8_t)((row[x] * (256 - alpha256) + colorY * alpha256) >> 8);
        }
    }

    // CbCr 平面（半分辨率）
    int bw2 = (int)fw / 2, bh2 = (int)fh / 2;
    if (bw2 < 2 || bh2 < 2) return;
    int cx2 = cx / 2, cy2 = cy / 2;
    int radius2 = radius / 2;
    int innerR2 = innerR / 2;
    int radius2Sq = radius2 * radius2;
    int inner2Sq = innerR2 * innerR2;
    int feather2 = radius2Sq - inner2Sq;
    double invAlphaC = (feather2 > 0) ? (double)maxAlpha256 / (double)feather2 : 0.0;
    const int cInvU = 256 - maxAlpha256;
    const int cAddU = colorU * maxAlpha256;
    const int cAddV = colorV * maxAlpha256;

    int y2Start = cy2 - radius2; if (y2Start < 0) y2Start = 0;
    int y2End = cy2 + radius2;   if (y2End > bh2) y2End = bh2;

    for (int y = y2Start; y < y2End; y++) {
        int dy = y - cy2;
        int dySq = dy * dy;
        if (dySq >= radius2Sq) continue;
        uint8_t *row = cPlane + (size_t)y * cStride;

        int remain2 = radius2Sq - dySq;
        int dxMax2 = radius2;
        if (dxMax2 < 1) dxMax2 = 1;
        dxMax2 = (dxMax2 + remain2 / dxMax2) / 2;
        if (dxMax2 > radius2) dxMax2 = radius2;

        int rx2Start = cx2 - dxMax2; if (rx2Start < 0) rx2Start = 0;
        int rx2End = cx2 + dxMax2;   if (rx2End > bw2) rx2End = bw2;
        int c2Start = cx2 - innerR2; if (c2Start < rx2Start) c2Start = rx2Start;
        int c2End = cx2 + innerR2;   if (c2End > rx2End) c2End = rx2End;

        for (int x = rx2Start; x < c2Start; x++) {
            int dx = x - cx2;
            int distSq = dx * dx + dySq;
            if (distSq <= inner2Sq || distSq >= radius2Sq) continue;
            int alpha256 = (int)((radius2Sq - distSq) * invAlphaC);
            int idx = x * 2;
            row[idx]     = (uint8_t)((row[idx]     * (256 - alpha256) + colorU * alpha256) >> 8);
            row[idx + 1] = (uint8_t)((row[idx + 1] * (256 - alpha256) + colorV * alpha256) >> 8);
        }
        for (int x = c2Start; x < c2End; x++) {
            int idx = x * 2;
            row[idx]     = (uint8_t)((row[idx]     * cInvU + cAddU) >> 8);
            row[idx + 1] = (uint8_t)((row[idx + 1] * cInvU + cAddV) >> 8);
        }
        for (int x = c2End; x < rx2End; x++) {
            int dx = x - cx2;
            int distSq = dx * dx + dySq;
            if (distSq <= inner2Sq || distSq >= radius2Sq) continue;
            int alpha256 = (int)((radius2Sq - distSq) * invAlphaC);
            int idx = x * 2;
            row[idx]     = (uint8_t)((row[idx]     * (256 - alpha256) + colorU * alpha256) >> 8);
            row[idx + 1] = (uint8_t)((row[idx + 1] * (256 - alpha256) + colorV * alpha256) >> 8);
        }
    }
}

- (CVPixelBufferRef)lightCanvasAtSlot:(int)slot {
    if (slot == 0) return _lightCanvasPool0;
    if (slot == 1) return _lightCanvasPool1;
    return _lightCanvasPool2;
}

- (void)setLightCanvas:(CVPixelBufferRef)buf atSlot:(int)slot {
    if (slot == 0) _lightCanvasPool0 = buf;
    else if (slot == 1) _lightCanvasPool1 = buf;
    else _lightCanvasPool2 = buf;
}

// ============================================================================
//  2026-10-30 新增：Vision 人脸检测
//  输入：CIImage（来自 YUV buffer）
//  输出：boundingBox（Vision 归一化坐标）、可选人脸轮廓 CGPath（image 坐标系，top-left origin）
//  返回：YES=检测到人脸，NO=无脸/异常
//  注意：mediaserverd 里 Vision 有时抛异常，全部 @try @catch 包裹
// ============================================================================
static BOOL vcamDetectFaceInImage(CIImage *img, CGRect *outBBox, CGPathRef *outContour) {
    if (!img || !outBBox) return NO;
    @try {
        VNDetectFaceLandmarksRequest *req = [[VNDetectFaceLandmarksRequest alloc] init];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:img options:@{}];
        NSError *err = nil;
        if (![handler performRequests:@[req] error:&err]) {
            return NO;
        }
        NSArray<VNFaceObservation *> *results = req.results;
        if (!results || results.count == 0) return NO;

        VNFaceObservation *obs = results[0];
        *outBBox = obs.boundingBox;

        if (outContour) {
            *outContour = NULL;
            if (obs.landmarks && obs.landmarks.faceContour) {
                VNFaceLandmarkRegion2D *contour = obs.landmarks.faceContour;
                if (contour.pointCount > 2) {
                    CGSize imgSize = img.extent.size;
                    const CGPoint *pts = [contour pointsInImageOfSize:imgSize];
                    if (pts) {
                        CGMutablePathRef path = CGPathCreateMutable();
                        for (NSUInteger i = 0; i < contour.pointCount; i++) {
                            if (i == 0) CGPathMoveToPoint(path, NULL, pts[i].x, pts[i].y);
                            else        CGPathAddLineToPoint(path, NULL, pts[i].x, pts[i].y);
                        }
                        CGPathCloseSubpath(path);
                        *outContour = path;
                    }
                }
            }
        }
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

// ============================================================================
//  2026-10-30 新增：人脸轮廓 → 灰度 mask
//  背景全黑，轮廓内全白；CIBlendWithMask 白区 = 前景（彩色），黑区 = 背景（原图）
// ============================================================================
- (CIImage *)createContourMask:(CGPathRef)path extent:(CGRect)extent {
    if (!path) return nil;
    size_t w = (size_t)extent.size.width;
    size_t h = (size_t)extent.size.height;
    if (w == 0 || h == 0) return nil;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;

    CGContextSetFillColorWithColor(ctx, [UIColor blackColor].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    // path 坐标是 image 坐标（top-left origin），CGBitmapContext 也是 top-left，直接画
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);

    CGImageRef cgImg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!cgImg) return nil;
    CIImage *mask = [CIImage imageWithCGImage:cgImg];
    CGImageRelease(cgImg);
    return mask;
}

// ============================================================================
//  2026-10-30 新增：椭圆 radial gradient mask（边缘羽化）
// ============================================================================
- (CIImage *)createEllipseMask:(CGRect)faceRect extent:(CGRect)extent {
    CGFloat cx = CGRectGetMidX(faceRect);
    CGFloat cy = CGRectGetMidY(faceRect);
    CGFloat radius = MAX(faceRect.size.width, faceRect.size.height) * 0.5;
    if (radius < 2) return nil;

    CIFilter *radial = [CIFilter filterWithName:@"CIRadialGradient"];
    if (!radial) return nil;
    [radial setValue:[CIVector vectorWithX:cx Y:cy] forKey:@"inputCenter"];
    [radial setValue:@(radius * 0.6) forKey:@"inputRadius0"];
    [radial setValue:@(radius) forKey:@"inputRadius1"];
    [radial setValue:[CIColor colorWithRed:1 green:1 blue:1 alpha:1] forKey:@"inputColor0"];
    [radial setValue:[CIColor colorWithRed:1 green:1 blue:1 alpha:0] forKey:@"inputColor1"];
    CIImage *mask = [radial.outputImage imageByCroppingToRect:extent];
    return mask;
}

// ============================================================================
//  2026-10-30 新增：自动强度计算
//  按人脸占比分档：>20%→0.35，10~20%→0.45，5~10%→0.55，<5%→0.65
//  EMA 平滑：autoAlpha = autoAlpha*0.8 + target*0.2，防闪变
//  饱和度补偿：采样色饱和度 <0.3 时 alpha +0.1（最多 0.75）
//  结果存 _autoAlphaInternal，返回最终建议 alpha
// ============================================================================
- (double)computeAutoAlpha:(CGRect)faceRect imageExtent:(CGRect)extent {
    if (CGRectIsEmpty(faceRect) || extent.size.width <= 0 || extent.size.height <= 0) {
        return 0.0;
    }
    double imgArea = extent.size.width * extent.size.height;
    double faceArea = faceRect.size.width * faceRect.size.height;
    if (imgArea <= 0) return 0.45;

    double ratio = faceArea / imgArea;
    double target = vcamAutoAlphaFromRatio(ratio);

    // EMA 平滑
    if (_autoAlphaInternal <= 0.01) {
        _autoAlphaInternal = target;
    } else {
        _autoAlphaInternal = _autoAlphaInternal * 0.8 + target * 0.2;
    }

    // 采样色饱和度补偿
    double r = ((_lightColorRGB >> 16) & 0xFF) / 255.0;
    double g = ((_lightColorRGB >> 8) & 0xFF) / 255.0;
    double b = (_lightColorRGB & 0xFF) / 255.0;
    double maxC = MAX(r, MAX(g, b));
    double minC = MIN(r, MIN(g, b));
    double sat = maxC > 0.01 ? (maxC - minC) / maxC : 0;
    double alpha = _autoAlphaInternal;
    if (sat < 0.3) {
        alpha += 0.1;
        if (alpha > 0.75) alpha = 0.75;
    }
    return alpha;
}

// ============================================================================
//  2026-10-30 新增：清除手动强度覆盖，恢复自动
//  由 VCamCore 在"重新开关彩色注入"时调用
// ============================================================================
- (void)resetManualAlpha {
    _alphaManualSet = NO;
    _alphaManualSetInternal = NO;
    _autoAlphaInternal = 0.45;  // 重置到初始档位
    vcam_gpu_log(@"[vcam] resetManualAlpha → auto mode restored (0.45 base)");
}

// ============================================================================
//  彩色注入主入口
//  分支 1：faceDetectEnabled && Vision 检测到人脸 → 人脸 mask + CIBlendWithMask
//  分支 2：无脸 / 关闭检测 / Vision 异常 → 原 Y/CbCr 光斑回退
//  强度：alphaManualSet ? lightIntensity/100 : autoAlpha
// ============================================================================
- (CVPixelBufferRef)injectLightIntoFrame:(CVPixelBufferRef)input CF_RETURNS_RETAINED {
    if (!input) return NULL;
    // 关闭/无色 → 直通零开销
    if (!_lightEnabled || _lightColorRGB == 0) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }
    if (CVPixelBufferGetPlaneCount(input) != 2) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    OSType fmt = CVPixelBufferGetPixelFormatType(input);
    size_t W = CVPixelBufferGetWidth(input);
    size_t H = CVPixelBufferGetHeight(input);
    if (W < 16 || H < 16) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }

    // 内部覆盖标志初始化（首次调用时从 _alphaManualSet 同步）
    static dispatch_once_t onceSync;
    dispatch_once(&onceSync, ^{
        _alphaManualSetInternal = _alphaManualSet;
    });

    // ===== 分支 1：Vision 人脸检测 =====
    if (_faceDetectEnabled) {
        @try {
            CIImage *img = [CIImage imageWithCVPixelBuffer:input];
            if (img) {
                CGRect bbox = CGRectZero;
                CGPathRef contour = NULL;
                BOOL detected = vcamDetectFaceInImage(img, &bbox, &contour);
                uint64_t now = mach_absolute_time();

                if (detected) {
                    // 更新人脸缓存
                    _lastFaceRectInternal = bbox;
                    _lastFaceTimeInternal = now;
                    if (_lastFaceContourInternal) CGPathRelease(_lastFaceContourInternal);
                    _lastFaceContourInternal = contour;

                    // bbox 转图像像素坐标
                    CGFloat imgW = img.extent.size.width;
                    CGFloat imgH = img.extent.size.height;
                    CGFloat bx = bbox.origin.x * imgW;
                    CGFloat by = bbox.origin.y * imgH;
                    CGFloat bw = bbox.size.width * imgW;
                    CGFloat bh = bbox.size.height * imgH;

                    // 直径扩展（默认 48 → 1.0 倍）
                    CGFloat diamScale = _lightDiameter / 48.0;
                    if (diamScale < 0.2) diamScale = 0.2;
                    CGFloat cx = bx + bw * 0.5;
                    CGFloat cy = by + bh * 0.5;
                    CGFloat nw = bw * diamScale * 2.0;
                    CGFloat nh = bh * diamScale * 2.0;
                    CGRect faceRect = CGRectMake(cx - nw * 0.5, cy - nh * 0.5, nw, nh);
                    faceRect = CGRectIntersection(faceRect, CGRectMake(0, 0, imgW, imgH));

                    if (!CGRectIsEmpty(faceRect)) {
                        // 计算使用强度
                        double autoA = [self computeAutoAlpha:faceRect imageExtent:img.extent];
                        double manualA = _lightIntensity / 100.0;
                        if (manualA < 0.05) manualA = 0.05;
                        if (manualA > 1.0) manualA = 1.0;
                        double useA = _alphaManualSetInternal ? manualA : autoA;

                        if (useA > 0.01) {
                            // 生成 mask
                            CIImage *mask = nil;
                            if (_injectMode == 0 && _lastFaceContourInternal) {
                                mask = [self createContourMask:_lastFaceContourInternal extent:img.extent];
                            }
                            if (!mask) {
                                mask = [self createEllipseMask:faceRect extent:img.extent];
                            }

                            if (mask) {
                                CGFloat r = ((_lightColorRGB >> 16) & 0xFF) / 255.0;
                                CGFloat g = ((_lightColorRGB >> 8) & 0xFF) / 255.0;
                                CGFloat b = (_lightColorRGB & 0xFF) / 255.0;
                                CIColor *overlayColor = [CIColor colorWithRed:r green:g blue:b alpha:useA];
                                CIImage *colorImg = [[CIImage imageWithColor:overlayColor]
                                                     imageByCroppingToRect:img.extent];

                                CIFilter *blend = [CIFilter filterWithName:@"CIBlendWithMask"];
                                if (blend) {
                                    [blend setValue:colorImg forKey:kCIInputImageKey];
                                    [blend setValue:img forKey:kCIInputBackgroundImageKey];
                                    [blend setValue:mask forKey:@"inputMaskImage"];
                                    CIImage *out = blend.outputImage;

                                    if (out && _preprocessContext) {
                                        // CIContext 对 planar YUV 支持不可靠（原仓库教训），
                                        // 先渲染到 BGRA 临时 buffer，再 VT 转回 YUV
                                        CVPixelBufferRef bgraTmp = NULL;
                                        if (CVPixelBufferCreate(kCFAllocatorDefault,
                                                                (size_t)imgW, (size_t)imgH,
                                                                kCVPixelFormatType_32BGRA,
                                                                NULL, &bgraTmp) == noErr && bgraTmp) {
                                            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                                            [_preprocessContext render:out toCVPixelBuffer:bgraTmp
                                                                bounds:img.extent colorSpace:cs];
                                            CGColorSpaceRelease(cs);

                                            VTPixelTransferSessionRef tmpSess = NULL;
                                            if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &tmpSess) == noErr && tmpSess) {
                                                VTSessionSetProperty(tmpSess, CFSTR("ScalingMode"), CFSTR("Normal"));
                                                VTSessionSetProperty(tmpSess, CFSTR("RealTime"), kCFBooleanTrue);
                                                OSStatus st = VTPixelTransferSessionTransferImage(tmpSess, bgraTmp, input);
                                                VTPixelTransferSessionInvalidate(tmpSess);
                                                CVPixelBufferRelease(bgraTmp);
                                                if (st == noErr) {
                                                    // 成功：直接返回（已在 input 上完成混色）
                                                    if (contour) CGPathRelease(contour);
                                                    return (CVPixelBufferRef)CVPixelBufferRetain(input);
                                                }
                                            } else {
                                                CVPixelBufferRelease(bgraTmp);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Vision 成功但渲染失败 → 继续往下走 Y/CbCr 回退
                    if (contour) CGPathRelease(contour);
                } else {
                    // 检测失败：检查 500ms 保留期
                    if (_lastFaceTimeInternal > 0) {
                        mach_timebase_info_data_t tbi;
                        mach_timebase_info(&tbi);
                        uint64_t elapsed = (now - _lastFaceTimeInternal) * tbi.numer / tbi.denom;
                        if (elapsed > kFaceKeepTimeoutNs) {
                            // 超时：清除人脸缓存
                            _lastFaceRectInternal = CGRectZero;
                            _lastFaceTimeInternal = 0;
                            if (_lastFaceContourInternal) {
                                CGPathRelease(_lastFaceContourInternal);
                                _lastFaceContourInternal = NULL;
                            }
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] Vision face inject exception: %@", e]);
            // 异常回退 Y/CbCr
        }
    }

    // ===== 分支 2：无脸 / 关闭检测 / 异常 → 原 Y/CbCr 光斑回退 =====
    int slot = _lightCanvasSlot;
    _lightCanvasSlot = (slot + 1) % 3;
    CVPixelBufferRef canvas = [self lightCanvasAtSlot:slot];
    if (!canvas || CVPixelBufferGetWidth(canvas) != W || CVPixelBufferGetHeight(canvas) != H ||
        CVPixelBufferGetPixelFormatType(canvas) != fmt) {
        if (canvas) CVPixelBufferRelease(canvas);
        canvas = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, W, H, fmt, NULL, &canvas) != noErr || !canvas) {
            [self setLightCanvas:NULL atSlot:slot];
            return (CVPixelBufferRef)CVPixelBufferRetain(input);
        }
        [self setLightCanvas:canvas atSlot:slot];
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] light canvas built %zux%zu (slot %d)", W, H, slot]);
    }

    // 整帧复制到画布
    CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(canvas, 0);
    for (int p = 0; p < 2; p++) {
        const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(input, p);
        uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(canvas, p);
        size_t rows = (p == 0) ? H : H / 2;
        size_t srs = CVPixelBufferGetBytesPerRowOfPlane(input, p);
        size_t drs = CVPixelBufferGetBytesPerRowOfPlane(canvas, p);
        size_t rowBytes = MIN(srs, drs);
        if (!src || !dst) continue;
        for (size_t y = 0; y < rows; y++) {
            memcpy(dst + y * drs, src + y * srs, rowBytes);
        }
    }
    CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);

    // 色彩附件复制
    CFDictionaryRef colorAtts = CVBufferCopyAttachments(input, kCVAttachmentMode_ShouldPropagate);
    if (colorAtts) {
        CVBufferSetAttachments(canvas, colorAtts, kCVAttachmentMode_ShouldPropagate);
        CFRelease(colorAtts);
    }

    // Y/CbCr 光斑：强度用 useA 换算成 0~100
    // 自动模式：autoAlpha × 100；手动模式：lightIntensity
    int intensity;
    if (_alphaManualSetInternal) {
        intensity = _lightIntensity;
    } else {
        double a = _autoAlphaInternal;
        if (a <= 0.01) a = 0.35;  // 无脸时给最低档，避免完全不亮
        intensity = (int)(a * 100);
    }
    if (intensity < 1) intensity = 1;
    if (intensity > 100) intensity = 100;

    vcamApplyLightBiPlanar(canvas, _lightColorRGB, _lightX, _lightY,
                           intensity, _lightDiameter, _lightFeather);

    CVPixelBufferUnlockBaseAddress(canvas, 0);
    return (CVPixelBufferRef)CVPixelBufferRetain(canvas);
}
// 预渲染用: 同尺寸格式转换（如 BGRA -> 420f），VT 主路径 + CoreImage 回退
- (CVPixelBufferRef)convertFormat:(CVPixelBufferRef)input toFormat:(OSType)format CF_RETURNS_RETAINED {
    if (!input) return NULL;
    if (CVPixelBufferGetPixelFormatType(input) == format) {
        return (CVPixelBufferRef)CVPixelBufferRetain(input);
    }
    size_t w = CVPixelBufferGetWidth(input);
    size_t h = CVPixelBufferGetHeight(input);

    CVPixelBufferRef out = [self createBufferWithWidth:w height:h format:format];
    if (out) {
        if (!_prerenderTransferSession) {
            [self setupPrerenderTransferSession];
        }
        if (_prerenderTransferSession &&
            VTPixelTransferSessionTransferImage(_prerenderTransferSession, input, out) == noErr) {
            return out;
        }
        CVPixelBufferRelease(out);
    }

    return [self convertWithCoreImage:input toFormat:format width:w height:h];
}

// writeFrame 回退路径: crop fill 渲染到任意格式目标 buffer
- (BOOL)renderCropFill:(CVPixelBufferRef)input toPixelBuffer:(CVPixelBufferRef)dst {
    if (!input || !dst || !_renderContext) return NO;

    size_t inW = CVPixelBufferGetWidth(input);
    size_t inH = CVPixelBufferGetHeight(input);
    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    if (inW == 0 || inH == 0 || w == 0 || h == 0) return NO;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NO;

    CGFloat scale = MAX((CGFloat)w / (CGFloat)inW, (CGFloat)h / (CGFloat)inH);
    CGFloat offsetX = ((CGFloat)w - (CGFloat)inW * scale) / 2.0;
    CGFloat offsetY = ((CGFloat)h - (CGFloat)inH * scale) / 2.0;
    CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
    t = CGAffineTransformTranslate(t, offsetX / scale, offsetY / scale);
    CIImage *scaled = [image imageByApplyingTransform:t];

    [_rotationRenderLock lock];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_renderContext render:scaled toCVPixelBuffer:dst
                    bounds:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)
                colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);
    [_rotationRenderLock unlock];

    return YES;
}

// render 路径用: 自适应正交旋转
- (CVPixelBufferRef)adaptiveRotateIfNeeded:(CVPixelBufferRef)src
                               targetWidth:(size_t)targetW
                              targetHeight:(size_t)targetH
                                     token:(uint64_t)token CF_RETURNS_RETAINED {
    if (!src) return NULL;
    if (!_rotationApiAvailable || !_renderRotationSession) {
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }

    size_t srcW = CVPixelBufferGetWidth(src);
    size_t srcH = CVPixelBufferGetHeight(src);
    if (!srcW || !srcH || !targetW || !targetH) {
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }

    int manualRot = _rotationAngle % 360;
    if (manualRot < 0) manualRot += 360;
    size_t baseW = srcW, baseH = srcH;
    if (manualRot % 180 == 90) {
        baseW = srcH;
        baseH = srcW;
    }

    double srcRatio = (double)baseW / (double)baseH;
    double dstRatio = (double)targetW / (double)targetH;
    BOOL orthogonal = (srcRatio > 1.0 && dstRatio < 1.0) || (srcRatio < 1.0 && dstRatio > 1.0);
    if (!orthogonal) {
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }

    [_rotationRenderLock lock];

    OSType fmt = CVPixelBufferGetPixelFormatType(src);

    if (token != 0 && _adaptiveRotatedGen == token && _adaptiveRotateCache &&
        _adaptiveRotateCacheW == srcH && _adaptiveRotateCacheH == srcW &&
        _adaptiveRotateCacheFmt == fmt) {
        CVPixelBufferRef hit = CVPixelBufferRetain(_adaptiveRotateCache);
        [_rotationRenderLock unlock];
        return hit;
    }

    CVPixelBufferRef rotated = NULL;
    if (_adaptiveRotateCache && _adaptiveRotateCacheW == srcH && _adaptiveRotateCacheH == srcW && _adaptiveRotateCacheFmt == fmt) {
        rotated = CVPixelBufferRetain(_adaptiveRotateCache);
    } else {
        rotated = [self createBufferWithWidth:srcH height:srcW format:fmt];
        if (!rotated) {
            [_rotationRenderLock unlock];
            return (CVPixelBufferRef)CVPixelBufferRetain(src);
        }
        if (_adaptiveRotateCache) CVPixelBufferRelease(_adaptiveRotateCache);
        _adaptiveRotateCache = CVPixelBufferRetain(rotated);
        _adaptiveRotateCacheW = srcH;
        _adaptiveRotateCacheH = srcW;
        _adaptiveRotateCacheFmt = fmt;
    }

    VTSessionSetProperty(_renderRotationSession, _rotationPropertyKey, _rotationCCW90Value);
    OSStatus st = _transferRotationImage(_renderRotationSession, src, rotated);
    if (st == noErr && token != 0) {
        _adaptiveRotatedGen = token;
    }
    [_rotationRenderLock unlock];
    if (st != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] adaptive CCW90 failed: %d fmt=%@ (keep unrotated)",
                      (int)st, [self stringForFormat:fmt]]);
        CVPixelBufferRelease(rotated);
        return (CVPixelBufferRef)CVPixelBufferRetain(src);
    }
    return rotated;
}

// CoreImage 回退
- (CVPixelBufferRef)convertWithCoreImage:(CVPixelBufferRef)input
                                toFormat:(OSType)format
                                  width:(size_t)width
                                 height:(size_t)height CF_RETURNS_RETAINED {
    if (!input || !_preprocessContext) return NULL;

    CIImage *image = [CIImage imageWithCVPixelBuffer:input];
    if (!image) return NULL;

    CVPixelBufferRef bgra = [self getOrCreateBGRABufferWithWidth:width height:height];
    if (!bgra) return NULL;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [_preprocessContext render:image toCVPixelBuffer:bgra
                        bounds:CGRectMake(0, 0, (CGFloat)width, (CGFloat)height)
                    colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    if (format == kCVPixelFormatType_32BGRA) {
        return bgra;
    }

    CVPixelBufferRef output = [self createBufferWithWidth:width height:height format:format];
    if (!output) {
        CVPixelBufferRelease(bgra);
        return NULL;
    }
    if (!_prerenderTransferSession) {
        [self setupPrerenderTransferSession];
    }
    if (!_prerenderTransferSession ||
        VTPixelTransferSessionTransferImage(_prerenderTransferSession, bgra, output) != noErr) {
        CVPixelBufferRelease(output);
        CVPixelBufferRelease(bgra);
        vcam_gpu_log(@"[vcam] convertWithCoreImage: VT BGRA->YUV failed, return NULL");
        return NULL;
    }
    CVPixelBufferRelease(bgra);
    return output;
}

- (CVPixelBufferRef)createBufferWithWidth:(size_t)width height:(size_t)height format:(OSType)format CF_RETURNS_RETAINED {
    CVPixelBufferRef buffer = NULL;
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, NULL, &buffer);
    if (status != noErr) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Failed to create pixel buffer: %d, size: %zux%zu, format: %@",
                      (int)status, width, height, [self stringForFormat:format]]);
        return NULL;
    }
    return buffer;
}

- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst {
    return [self transferPixelBuffer:src toPixelBuffer:dst token:0];
}

- (NSLock *)twoStepLockForKey:(NSString *)key {
    @synchronized(self) {
        NSLock *l = _twoStepKeyLockPool[key];
        if (!l) {
            l = [[NSLock alloc] init];
            _twoStepKeyLockPool[key] = l;
        }
        return l;
    }
}

- (VTPixelTransferSessionRef)oneStepSessionForKey:(NSString *)key {
    NSValue *v = nil;
    [_poolDictLock lock];
    v = _oneStepSessionPool[key];
    [_poolDictLock unlock];
    if (v) return (VTPixelTransferSessionRef)[v pointerValue];
    VTPixelTransferSessionRef s = NULL;
    if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &s) == noErr && s) {
        VTSessionSetProperty(s, CFSTR("ScalingMode"), CFSTR("Trim"));
        VTSessionSetProperty(s, CFSTR("RealTime"), kCFBooleanTrue);
        [_poolDictLock lock];
        _oneStepSessionPool[key] = [NSValue valueWithPointer:s];
        [_poolDictLock unlock];
        return s;
    }
    return NULL;
}

- (NSLock *)oneStepLockForKey:(NSString *)key {
    @synchronized(self) {
        NSLock *l = _oneStepKeyLockPool[key];
        if (!l) {
            l = [[NSLock alloc] init];
            _oneStepKeyLockPool[key] = l;
        }
        return l;
    }
}

- (VTPixelTransferSessionRef)normalTransferSession {
    if (!gVcamNormalSession) {
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &gVcamNormalSession) == noErr) {
            VTSessionSetProperty(gVcamNormalSession, CFSTR("ScalingMode"), CFSTR("Normal"));
            VTSessionSetProperty(gVcamNormalSession, CFSTR("RealTime"), kCFBooleanTrue);
            vcam_gpu_log(@"[vcam] Lane S2-Normal session created (green-line fix)");
        }
    }
    return gVcamNormalSession;
}

// 绿线修复 v2: 源尺寸 staging 中心整数预裁剪到 dst 比例
- (CVPixelBufferRef)cropStagingForRatio:(CVPixelBufferRef)staging dst:(CVPixelBufferRef)dst srcToken:(uint64_t)srcToken {
    if (!staging || !dst) return NULL;
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

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    VCamCropStagingSlot *slot = NULL;
    int lruIdx = 0;
    for (int i = 0; i < kVcamCropStagingMax; i++) {
        if (gVcamCropStaging[i].staging &&
            gVcamCropStaging[i].w == cw && gVcamCropStaging[i].h == ch) { slot = &gVcamCropStaging[i]; break; }
        if (gVcamCropStaging[i].lastUse < gVcamCropStaging[lruIdx].lastUse) lruIdx = i;
    }
    if (!slot) {
        int idx = -1;
        for (int i = 0; i < kVcamCropStagingMax; i++) {
            if (!gVcamCropStaging[i].staging) { idx = i; break; }
        }
        if (idx < 0) {
            idx = lruIdx;
            CVPixelBufferRelease(gVcamCropStaging[idx].staging);
            gVcamCropStaging[idx].staging = NULL;
        }
        CVPixelBufferRef nb = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, cw, ch,
                                kCVPixelFormatType_32BGRA, NULL, &nb) != noErr || !nb) return NULL;
        gVcamCropStaging[idx].w = cw; gVcamCropStaging[idx].h = ch;
        gVcamCropStaging[idx].staging = nb;
        gVcamCropStaging[idx].token = 0;
        gVcamCropStaging[idx].lastUse = now;
        slot = &gVcamCropStaging[idx];
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Crop staging built %zux%zu (slot %d)", cw, ch, idx]);
    }
    slot->lastUse = now;
    if (slot->token == srcToken && srcToken != 0) return slot->staging;

    BOOL copied = NO;
    if (CVPixelBufferLockBaseAddress(staging, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
        if (CVPixelBufferLockBaseAddress(slot->staging, 0) == kCVReturnSuccess) {
            uint8_t *sb = (uint8_t *)CVPixelBufferGetBaseAddress(staging);
            uint8_t *db = (uint8_t *)CVPixelBufferGetBaseAddress(slot->staging);
            size_t srb = CVPixelBufferGetBytesPerRow(staging);
            size_t drb = CVPixelBufferGetBytesPerRow(slot->staging);
            if (sb && db && srb >= cw * 4 && drb >= cw * 4) {
                size_t rowBytes = cw * 4;
                for (size_t y = 0; y < ch; y++) {
                    memcpy(db + y * drb, sb + (cy + y) * srb + cx * 4, rowBytes);
                }
                slot->token = srcToken;
                copied = YES;
            }
            vcamSyncColorAttachments(staging, slot->staging);
            CVPixelBufferUnlockBaseAddress(slot->staging, 0);
        }
        CVPixelBufferUnlockBaseAddress(staging, kCVPixelBufferLock_ReadOnly);
    }
    return copied ? slot->staging : NULL;
}

- (CVPixelBufferRef)yuvStagingForSrc:(CVPixelBufferRef)s2src
                                  fmt:(uint32_t)dstFormat
                             srcToken:(uint64_t)srcToken {
    if (!s2src) return NULL;
    size_t sw = CVPixelBufferGetWidth(s2src), sh = CVPixelBufferGetHeight(s2src);
    if (!sw || !sh) return NULL;
    size_t mw = (sw + 2) & ~(size_t)1, mh = (sh + 2) & ~(size_t)1;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    VCamYuvStagingSlot *slot = NULL;
    int lruIdx = 0;
    for (int i = 0; i < kVcamYuvStagingMax; i++) {
        if (gVcamYuvStaging[i].staging && gVcamYuvStaging[i].fmt == dstFormat &&
            gVcamYuvStaging[i].w == mw && gVcamYuvStaging[i].h == mh) {
            slot = &gVcamYuvStaging[i]; break;
        }
        if (gVcamYuvStaging[i].lastUse < gVcamYuvStaging[lruIdx].lastUse) lruIdx = i;
    }
    if (!slot) {
        int idx = -1;
        for (int i = 0; i < kVcamYuvStagingMax; i++) {
            if (!gVcamYuvStaging[i].staging) { idx = i; break; }
        }
        if (idx < 0) {
            idx = lruIdx;
            CVPixelBufferRelease(gVcamYuvStaging[idx].staging);
            gVcamYuvStaging[idx].staging = NULL;
        }
        CVPixelBufferRef nb = NULL;
        OSStatus cc = CVPixelBufferCreate(kCFAllocatorDefault, mw, mh, dstFormat, NULL, &nb);
        if (cc != noErr || !nb) {
            vcamYuvSplitDisable(dstFormat);
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] YUV mid create failed (%d) %zux%zu fmt=0x%x, split disabled", (int)cc, mw, mh, (unsigned)dstFormat]);
            return NULL;
        }
        gVcamYuvStaging[idx].fmt = dstFormat;
        gVcamYuvStaging[idx].w = mw; gVcamYuvStaging[idx].h = mh;
        gVcamYuvStaging[idx].staging = nb;
        gVcamYuvStaging[idx].token = 0;
        gVcamYuvStaging[idx].lastUse = now;
        slot = &gVcamYuvStaging[idx];
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] YUV upscale staging built %zux%zu fmt=0x%x (slot %d, heat fix)", mw, mh, (unsigned)dstFormat, idx]);
    }
    slot->lastUse = now;
    if (slot->token == srcToken && srcToken != 0) return slot->staging;

    OSStatus st = VTPixelTransferSessionTransferImage([self normalTransferSession], s2src, slot->staging);
    if (st != noErr) {
        slot->token = 0;
        vcamYuvSplitDisable(dstFormat);
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] YUV s2a failed (%d) fmt=0x%x, split disabled", (int)st, (unsigned)dstFormat]);
        return NULL;
    }
    slot->token = srcToken;
    return slot->staging;
}

- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst token:(uint64_t)token {
    if (!src || !dst) return NO;

    OSType dstFormat = CVPixelBufferGetPixelFormatType(dst);
    size_t dstW = CVPixelBufferGetWidth(dst);
    size_t dstH = CVPixelBufferGetHeight(dst);
    size_t srcW = CVPixelBufferGetWidth(src);
    size_t srcH = CVPixelBufferGetHeight(src);

    // ===== 千面模型固定车道 =====
    {
        BOOL laneOff = NO;
        int hit = -1;
        for (int i = 0; i < 4; i++) {
            if (gVcamLaneMemoFmt[i] == dstFormat) { hit = i; laneOff = gVcamLaneMemoOff[i]; break; }
        }
        if (hit < 0) {
            laneOff = [_laneDisabled[@(dstFormat)] boolValue];
            vcamLaneMemoInvalidate((uint32_t)dstFormat, laneOff);
        }
        if (laneOff) return NO;
    }

    BOOL isYuvLane = ((dstFormat & 0xffffffef) == '420f' || dstFormat == 0x70343230 /* p420 */);
    BOOL isBgraLane = (dstFormat == kCVPixelFormatType_32BGRA);

    // ---- 私有格式车道: 两步法 ----
    if (!isBgraLane && !isYuvLane) {
        [_laneLockPrivate lock];
        if (!_twoStepS1Session) {
            if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_twoStepS1Session) == noErr) {
                VTSessionSetProperty(_twoStepS1Session, CFSTR("ScalingMode"), CFSTR("Trim"));
                VTSessionSetProperty(_twoStepS1Session, CFSTR("RealTime"), kCFBooleanTrue);
                vcam_gpu_log(@"[vcam] Lane S1 session created (Trim)");
            }
        }
        if (!_privateTransferSession) {
            if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &_privateTransferSession) == noErr) {
                VTSessionSetProperty(_privateTransferSession, CFSTR("ScalingMode"), CFSTR("Trim"));
                VTSessionSetProperty(_privateTransferSession, CFSTR("RealTime"), kCFBooleanTrue);
                vcam_gpu_log(@"[vcam] Lane S2(private) session created (Trim)");
            }
        }

        // 直转快路径
        {
            OSType srcFmtD = CVPixelBufferGetPixelFormatType(src);
            BOOL srcYuvPlanar = (srcFmtD == '420f' || srcFmtD == '420v' ||
                                 srcFmtD == 0x70343230);
            if (srcYuvPlanar && (srcW != dstW || srcH != dstH) &&
                vcamYuvDirectState(dstFormat) >= 0 && _privateTransferSession) {
                int8_t prevState = vcamYuvDirectState(dstFormat);
                OSStatus stD = VTPixelTransferSessionTransferImage(_privateTransferSession, src, dst);
                if (stD == noErr) {
                    if (prevState == 0) {
                        vcamYuvDirectSet(dstFormat, 1);
                        vcam_gpu_log([NSString stringWithFormat:
                            @"[vcam] lane direct YUV->0x%x OK (fast path, BGRA detour skipped)",
                            (unsigned)dstFormat]);
                    }
                    [self noteStreamRenderFmt:(uint32_t)dstFormat w:(uint32_t)dstW h:(uint32_t)dstH pixels:(uint64_t)dstW * dstH];
                    [_laneLockPrivate unlock];
                    return YES;
                }
                vcamYuvDirectSet(dstFormat, -1);
                vcam_gpu_log([NSString stringWithFormat:
                    @"[vcam] lane direct YUV->0x%x failed (%d), fallback two-step",
                    (unsigned)dstFormat, (int)stD]);
            }

            // YUV staging 两步法
            if (srcYuvPlanar && (srcW != dstW || srcH != dstH) &&
                vcamYuvDirectState(dstFormat) == -1 &&
                vcamYuvStageState(dstFormat) >= 0 && _privateTransferSession) {
                VCamYuvLaneSlot *yslot = NULL;
                for (int i = 0; i < kVcamYuvLaneMax; i++) {
                    if (gVcamYuvLane[i].staging &&
                        gVcamYuvLane[i].w == srcW && gVcamYuvLane[i].h == srcH) {
                        yslot = &gVcamYuvLane[i];
                        break;
                    }
                }
                if (!yslot) {
                    for (int i = 0; i < kVcamYuvLaneMax; i++) {
                        if (!gVcamYuvLane[i].staging) {
                            CVPixelBufferRef nb = NULL;
                            if (CVPixelBufferCreate(kCFAllocatorDefault, srcW, srcH,
                                                    '420f', NULL, &nb) == noErr && nb) {
                                gVcamYuvLane[i].w = srcW;
                                gVcamYuvLane[i].h = srcH;
                                gVcamYuvLane[i].staging = nb;
                                gVcamYuvLane[i].token = 0;
                                yslot = &gVcamYuvLane[i];
                                vcam_gpu_log([NSString stringWithFormat:
                                    @"[vcam] YUV lane staging built %zux%zu (slot %d)",
                                    srcW, srcH, i]);
                            }
                            break;
                        }
                    }
                }
                BOOL ysOk = NO;
                if (yslot && _twoStepS1Session) {
                    if (token != 0 && yslot->token == token) {
                        ysOk = YES;
                    } else {
                        OSStatus st1 = VTPixelTransferSessionTransferImage(_twoStepS1Session, src, yslot->staging);
                        if (st1 == noErr) {
                            yslot->token = token;
                            ysOk = YES;
                        } else {
                            yslot->token = 0;
                        }
                    }
                    if (ysOk) {
                        OSStatus st2 = VTPixelTransferSessionTransferImage(_privateTransferSession, yslot->staging, dst);
                        if (st2 == noErr) {
                            if (vcamYuvStageState(dstFormat) == 0) {
                                vcamYuvStageSet(dstFormat, 1);
                                vcam_gpu_log([NSString stringWithFormat:
                                    @"[vcam] lane YUV-staging 0x%x OK (YUV detour, BGRA detour skipped)",
                                    (unsigned)dstFormat]);
                            }
                            [self noteStreamRenderFmt:(uint32_t)dstFormat w:(uint32_t)dstW h:(uint32_t)dstH pixels:(uint64_t)dstW * dstH];
                            [_laneLockPrivate unlock];
                            return YES;
                        }
                        vcamYuvStageSet(dstFormat, -1);
                        vcam_gpu_log([NSString stringWithFormat:
                            @"[vcam] lane YUV-staging 0x%x failed (%d), fallback BGRA two-step",
                            (unsigned)dstFormat, (int)st2]);
                    }
                }
            }
        }

        // staging 按源尺寸缓存
        VCamLaneStagingSlot *slot = NULL;
        for (int i = 0; i < kVcamLaneStagingMax; i++) {
            if (gVcamLaneStaging[i].staging &&
                gVcamLaneStaging[i].w == srcW && gVcamLaneStaging[i].h == srcH) {
                slot = &gVcamLaneStaging[i];
                break;
            }
        }
        if (!slot) {
            for (int i = 0; i < kVcamLaneStagingMax; i++) {
                if (!gVcamLaneStaging[i].staging) {
                    CVPixelBufferRef nb = NULL;
                    if (CVPixelBufferCreate(kCFAllocatorDefault, srcW, srcH,
                                            kCVPixelFormatType_32BGRA, NULL, &nb) == noErr && nb) {
                        gVcamLaneStaging[i].w = srcW;
                        gVcamLaneStaging[i].h = srcH;
                        gVcamLaneStaging[i].staging = nb;
                        gVcamLaneStaging[i].token = 0;
                        slot = &gVcamLaneStaging[i];
                        vcam_gpu_log([NSString stringWithFormat:@"[vcam] Lane staging built %zux%zu (slot %d)", srcW, srcH, i]);
                    }
                    break;
                }
            }
        }

        BOOL ok = NO;
        if (_twoStepS1Session && _privateTransferSession && slot) {
            CVPixelBufferRef staging = slot->staging;
            if (token != 0 && slot->token == token) {
                ok = YES;
            } else {
                OSStatus st1 = VTPixelTransferSessionTransferImage(_twoStepS1Session, src, staging);
                if (st1 == noErr) {
                    slot->token = token;
                    ok = YES;
                } else {
                    slot->token = 0;
                    vcam_gpu_log([NSString stringWithFormat:@"[vcam] lane s1 failed (%d)", (int)st1]);
                }
            }
            if (ok) {
                CVPixelBufferRef s2src = staging;
                {
                    BOOL fixH = NO, fixV = NO;
                    vcamTrimFractionalCrop(staging, dst, &fixH, &fixV);
                    if (fixH || fixV) {
                        CVPixelBufferRef cropped = [self cropStagingForRatio:staging dst:dst srcToken:slot->token];
                        if (cropped) s2src = cropped;
                    }
                }
                CFAbsoluteTime t2 = CFAbsoluteTimeGetCurrent();
                BOOL useNormal = (s2src != staging);
                VTPixelTransferSessionRef s2sess = useNormal
                    ? [self normalTransferSession] : _privateTransferSession;
                OSStatus st2 = -1;
                uint64_t dstPx = (uint64_t)dstW * dstH;
                uint64_t srcPx = (uint64_t)CVPixelBufferGetWidth(s2src) * CVPixelBufferGetHeight(s2src);
                if (dstPx > 4 * srcPx && vcamYuvSplitState((uint32_t)dstFormat) >= 0) {
                    CVPixelBufferRef yuvMid = [self yuvStagingForSrc:s2src fmt:(uint32_t)dstFormat srcToken:slot->token];
                    if (yuvMid) {
                        st2 = VTPixelTransferSessionTransferImage(s2sess, yuvMid, dst);
                        if (st2 != noErr) {
                            vcamYuvSplitDisable((uint32_t)dstFormat);
                            vcam_gpu_log([NSString stringWithFormat:@"[vcam] YUV s2b failed (%d) fmt=0x%x, split disabled", (int)st2, (unsigned)dstFormat]);
                        }
                    }
                }
                if (st2 != noErr) {
                    st2 = VTPixelTransferSessionTransferImage(s2sess, s2src, dst);
                }
                [self noteStageTimingFmt:(uint32_t)dstFormat w:(uint32_t)dstW h:(uint32_t)dstH stage:2 ms:(CFAbsoluteTimeGetCurrent() - t2) * 1000.0];
                if (st2 != noErr) ok = NO;
            }
        }
        [_laneLockPrivate unlock];

        if (ok) {
            [self noteStreamRenderFmt:(uint32_t)dstFormat w:(uint32_t)dstW h:(uint32_t)dstH pixels:(uint64_t)dstW * dstH];
            return YES;
        }
        @synchronized(self) {
            NSInteger fails = [_laneFailCounts[@(dstFormat)] integerValue] + 1;
            _laneFailCounts[@(dstFormat)] = @(fails);
            if (fails >= 2) {
                _laneDisabled[@(dstFormat)] = @YES;
                vcamLaneMemoInvalidate(dstFormat, YES);
                vcam_gpu_log([NSString stringWithFormat:@"[vcam] lane CIRCUIT-BROKEN format %u (err, keep camera)", (unsigned)dstFormat]);
            }
        }
        return NO;
    }

    // ---- 标准格式车道: 一步直转 ----
    VTPixelTransferSessionRef session = isBgraLane ? _bgraTransferSession : _yuvTransferSession;
    NSLock *laneLock = isBgraLane ? _laneLockBGRA : _laneLockYUV;
    if (!session) {
        if (isBgraLane) [self setupBGRATransferSession]; else [self setupYUVTransferSession];
        session = isBgraLane ? _bgraTransferSession : _yuvTransferSession;
    }
    if (!session || !laneLock) return NO;

    [laneLock lock];
    CFAbsoluteTime tOp = CFAbsoluteTimeGetCurrent();
    OSStatus status = VTPixelTransferSessionTransferImage(session, src, dst);
    [self noteStageTimingFmt:(uint32_t)dstFormat w:(uint32_t)dstW h:(uint32_t)dstH stage:2 ms:(CFAbsoluteTimeGetCurrent() - tOp) * 1000.0];
    [laneLock unlock];

    if (status == noErr) {
        [self noteStreamRenderFmt:(uint32_t)dstFormat w:(uint32_t)dstW h:(uint32_t)dstH pixels:(uint64_t)dstW * dstH];
        return YES;
    }
    @synchronized(self) {
        NSInteger fails = [_laneFailCounts[@(dstFormat)] integerValue] + 1;
        _laneFailCounts[@(dstFormat)] = @(fails);
        if (fails >= 2) {
            _laneDisabled[@(dstFormat)] = @YES;
            vcamLaneMemoInvalidate(dstFormat, YES);
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] lane CIRCUIT-BROKEN format %u (err %d, keep camera)",
                          (unsigned)dstFormat, (int)status]);
        }
    }
    return NO;
}

static VCamStatSlot *vcam_stat_slot(uint32_t fmt, uint32_t w, uint32_t h) {
    for (int i = 0; i < kVcamStatSlots; i++) {
        if (gVcamStatSlots[i].fmt == fmt && gVcamStatSlots[i].w == w && gVcamStatSlots[i].h == h) {
            return &gVcamStatSlots[i];
        }
        if (gVcamStatSlots[i].fmt == 0 && gVcamStatSlots[i].renders == 0) {
            gVcamStatSlots[i].fmt = fmt;
            gVcamStatSlots[i].w = w;
            gVcamStatSlots[i].h = h;
            return &gVcamStatSlots[i];
        }
    }
    return NULL;
}

- (void)noteStreamRenderFmt:(uint32_t)fmt w:(uint32_t)w h:(uint32_t)h pixels:(uint64_t)px {
    [_statsLock lock];
    VCamStatSlot *s = vcam_stat_slot(fmt, w, h);
    if (s) { s->renders++; s->pixels += px; }
    [_statsLock unlock];
}

- (void)noteStageTimingFmt:(uint32_t)fmt w:(uint32_t)w h:(uint32_t)h stage:(int)stage ms:(double)ms {
    [_statsLock lock];
    VCamStatSlot *s = vcam_stat_slot(fmt, w, h);
    if (s) {
        if (stage == 1) { s->s1TotalMs += ms; s->s1Cnt++; }
        else            { s->s2TotalMs += ms; s->s2Cnt++; }
    }
    [_statsLock unlock];
}

static const NSUInteger kVcamMaxStreamKeys = 6;

- (void)evictStreamKeyResourcesLocked:(NSString *)old {
    if (!old) return;
    NSLock *olock = _oneStepKeyLockPool[old];
    NSLock *tlock = _twoStepKeyLockPool[old];
    if (olock) [olock lock];
    if (tlock) [tlock lock];

    void (*invalidateSession)(VTPixelTransferSessionRef) =
        (void (*)(VTPixelTransferSessionRef))dlsym(RTLD_DEFAULT, "VTPixelTransferSessionInvalidate");

    NSValue *osv = nil, *tsv = nil, *stv = nil, *rcv = nil, *rbsv = nil;
    id poolObj = nil;
    [_poolDictLock lock];
    osv = _oneStepSessionPool[old];
    if (osv) [_oneStepSessionPool removeObjectForKey:old];
    tsv = _twoStepSessionPool[old];
    if (tsv) [_twoStepSessionPool removeObjectForKey:old];
    stv = _twoStepStagingPool[old];
    if (stv) [_twoStepStagingPool removeObjectForKey:old];
    [_twoStepTokenPool removeObjectForKey:old];
    [_twoStepFailCountPool removeObjectForKey:old];
    poolObj = _bgraBufferPoolMap[old];
    if (poolObj) [_bgraBufferPoolMap removeObjectForKey:old];
    if (![old hasPrefix:@"g:"]) {
        rcv = _resultCachePool[old];
        if (rcv) [_resultCachePool removeObjectForKey:old];
        [_resultCacheTokenPool removeObjectForKey:old];
        [_lastReqTokenPool removeObjectForKey:old];
        rbsv = _resultBlitSessionPool[old];
        if (rbsv) [_resultBlitSessionPool removeObjectForKey:old];
    }
    [_poolDictLock unlock];

    if (osv) {
        VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[osv pointerValue];
        if (s && invalidateSession) invalidateSession(s);
    }
    if (tsv) {
        VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[tsv pointerValue];
        if (s && invalidateSession) invalidateSession(s);
    }
    if (stv) {
        CVPixelBufferRef b = (CVPixelBufferRef)[stv pointerValue];
        if (b) CVPixelBufferRelease(b);
    }
    if (poolObj) {
        CVPixelBufferPoolRelease((__bridge CVPixelBufferPoolRef)poolObj);
    }

    if ([old hasPrefix:@"g:"]) {
        NSLock *gLock = _groupGlobalLock;
        if (gLock) [gLock lock];
        NSValue *gsv = nil, *gssv = nil;
        [_poolDictLock lock];
        gsv = _groupStagingPool[old];
        if (gsv) [_groupStagingPool removeObjectForKey:old];
        gssv = _groupSessionPool[old];
        if (gssv) [_groupSessionPool removeObjectForKey:old];
        [_groupTokenPool removeObjectForKey:old];
        [_groupSizePool removeObjectForKey:old];
        [_poolDictLock unlock];
        if (gsv) {
            CVPixelBufferRef b = (CVPixelBufferRef)[gsv pointerValue];
            if (b) CVPixelBufferRelease(b);
        }
        if (gssv) {
            VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[gssv pointerValue];
            if (s && invalidateSession) invalidateSession(s);
        }
        if (gLock) [gLock unlock];
    } else {
        if (rcv) {
            CVPixelBufferRef b = (CVPixelBufferRef)[rcv pointerValue];
            if (b) CVPixelBufferRelease(b);
        }
        if (rbsv) {
            VTPixelTransferSessionRef s = (VTPixelTransferSessionRef)[rbsv pointerValue];
            if (s && invalidateSession) invalidateSession(s);
        }
    }

    [_oneStepKeyLockPool removeObjectForKey:old];
    [_twoStepKeyLockPool removeObjectForKey:old];

    if (tlock) [tlock unlock];
    if (olock) [olock unlock];
}

- (void)touchStreamKeyLRU:(NSString *)key {
    if (!key) return;
    @synchronized(self) {
        NSUInteger idx = [_streamKeyOrder indexOfObject:key];
        if (idx != NSNotFound) {
            [_streamKeyOrder removeObjectAtIndex:idx];
        }
        [_streamKeyOrder addObject:key];

        while (_streamKeyOrder.count > kVcamMaxStreamKeys) {
            NSString *old = _streamKeyOrder.firstObject;
            [_streamKeyOrder removeObjectAtIndex:0];
            if (!old) break;
            [self evictStreamKeyResourcesLocked:old];
            vcam_gpu_log([NSString stringWithFormat:@"[vcam] LRU evict stream key %@ (pool now %lu)", old, (unsigned long)_streamKeyOrder.count]);
        }
    }
}

- (void)releaseIdleMemory {
    NSUInteger freed = 0;
    @synchronized(self) {
        while (_streamKeyOrder.count > 0) {
            NSString *old = _streamKeyOrder.firstObject;
            [_streamKeyOrder removeObjectAtIndex:0];
            if (!old) break;
            [self evictStreamKeyResourcesLocked:old];
            freed++;
        }
    }
    if (freed > 0) {
        vcam_gpu_log([NSString stringWithFormat:@"[vcam] idle memory release: %lu stream/group entries freed", (unsigned long)freed]);
    }
}

- (NSUInteger)activeStreamKeyCount {
    @synchronized(self) {
        return _streamKeyOrder.count;
    }
}

- (void)releaseHeavyBuffersForIdle {
    NSUInteger released = 0;
    @synchronized(self) {
        if (_adaptiveRotateCache) {
            CVPixelBufferRelease(_adaptiveRotateCache);
            _adaptiveRotateCache = NULL;
            released++;
        }
        for (int i = 0; i < 3; i++) {
            CVPixelBufferRef b = [self prerenderRotateBufferAtSlot:i];
            if (b) {
                CVPixelBufferRelease(b);
                [self setPrerenderRotateBuffer:NULL atSlot:i];
                released++;
            }
        }
        for (int i = 0; i < 3; i++) {
            CVPixelBufferRef b = [self userCanvasAtSlot:i];
            if (b) {
                CVPixelBufferRelease(b);
                [self setUserCanvas:NULL atSlot:i];
                released++;
            }
        }
        if (_userShrinkBuffer) {
            CVPixelBufferRelease(_userShrinkBuffer);
            _userShrinkBuffer = NULL;
            released++;
        }
        if (_userPieceBuffer) {
            CVPixelBufferRelease(_userPieceBuffer);
            _userPieceBuffer = NULL;
            released++;
        }
        for (int i = 0; i < 3; i++) {
            CVPixelBufferRef b = [self lightCanvasAtSlot:i];
            if (b) {
                CVPixelBufferRelease(b);
                [self setLightCanvas:NULL atSlot:i];
                released++;
            }
        }
        for (id key in _bgraBufferPoolMap) {
            CVPixelBufferPoolRelease((__bridge CVPixelBufferPoolRef)_bgraBufferPoolMap[key]);
            released++;
        }
        [_bgraBufferPoolMap removeAllObjects];
    }
    [_laneLockPrivate lock];
    for (int i = 0; i < kVcamLaneStagingMax; i++) {
        if (gVcamLaneStaging[i].staging) {
            CVPixelBufferRelease(gVcamLaneStaging[i].staging);
            gVcamLaneStaging[i].staging = NULL;
            gVcamLaneStaging[i].w = gVcamLaneStaging[i].h = 0;
            gVcamLaneStaging[i].token = 0;
            released++;
        }
    }
    for (int i = 0; i < kVcamCropStagingMax; i++) {
        if (gVcamCropStaging[i].staging) {
            CVPixelBufferRelease(gVcamCropStaging[i].staging);
            gVcamCropStaging[i].staging = NULL;
            gVcamCropStaging[i].w = gVcamCropStaging[i].h = 0;
            gVcamCropStaging[i].token = 0;
            gVcamCropStaging[i].lastUse = 0;
            released++;
        }
    }
    for (int i = 0; i < kVcamYuvStagingMax; i++) {
        if (gVcamYuvStaging[i].staging) {
            CVPixelBufferRelease(gVcamYuvStaging[i].staging);
            gVcamYuvStaging[i].staging = NULL;
            gVcamYuvStaging[i].w = gVcamYuvStaging[i].h = 0;
            gVcamYuvStaging[i].fmt = 0;
            gVcamYuvStaging[i].token = 0;
            gVcamYuvStaging[i].lastUse = 0;
            released++;
        }
    }
    [_laneLockPrivate unlock];
    vcam_gpu_log([NSString stringWithFormat:@"[vcam] idle heavy buffers released: %lu entries (jetsam guard)", (unsigned long)released]);
}

- (NSString *)takeStreamStats {
    [_statsLock lock];
    NSString *out = @"";
    NSMutableArray *parts = [NSMutableArray array];
    for (int i = 0; i < kVcamStatSlots; i++) {
        VCamStatSlot *s = &gVcamStatSlots[i];
        if (s->fmt == 0 || s->renders == 0) continue;
        uint64_t mb = (s->pixels * 4ull) >> 20;
        double s1Avg = s->s1Cnt > 0 ? (s->s1TotalMs / s->s1Cnt) : -1.0;
        double s2Avg = s->s2Cnt > 0 ? (s->s2TotalMs / s->s2Cnt) : -1.0;
        [parts addObject:[NSString stringWithFormat:@"%ux%u_%u:%llu/%lluMB(%.1f,%.1fms)",
                          s->w, s->h, s->fmt, s->renders, mb, s1Avg, s2Avg]];
    }
    if (parts.count > 0) out = [parts componentsJoinedByString:@" "];
    memset(gVcamStatSlots, 0, sizeof(gVcamStatSlots));
    [_statsLock unlock];
    return out;
}

- (NSString *)stringForFormat:(OSType)format {
    char fstr[5] = {0};
    fstr[0] = (char)(format >> 24);
    fstr[1] = (char)(format >> 16);
    fstr[2] = (char)(format >> 8);
    fstr[3] = (char)format;
    return [NSString stringWithUTF8String:fstr];
}

@end
