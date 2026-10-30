//
//  GPUImageProcessor.h
//  VCamPlus
//
//  图像处理器（对标 vcameracrack.dylib 的 GPUImageProcessor 类）
//
//  2026-10-30 改造（v2）：
//    - 新增 Vision 人脸检测彩色注入（参考 Tweak.xm 功能方法）
//    - 新增 injectMode（0=人脸轮廓 1=椭圆，默认 0）
//    - 新增 faceDetectEnabled（默认 YES）
//    - 新增自动强度计算（按人脸占比 0.35/0.45/0.55/0.65 + EMA + 饱和度补偿）
//    - 强度滑块保留（alphaSliderValue，默认 0.45），拖了才覆盖（alphaManualSet）
//    - 重新开关彩色注入 → resetManualAlpha → 恢复自动
//    - bakeUserTransformIntoCanvas 出界改为边缘钳制填充 + UV 边界强制 128（参考 imageByClampingToExtent 思路）
//    - 原有 Y/CbCr 光斑路径保留作为无脸 / 关闭检测时的回退
//
//  关键约束（记忆，一行不变）：
//    1. CVPixelBufferCreate/Pool 绝对不能使用 kCVPixelBufferIOSurfacePropertiesKey（mediaserverd 立即崩溃）
//    2. CIContext 使用软件渲染（kCIContextUseSoftwareRenderer）
//    3. VTPixelRotationSession 是私有 API，通过 dlsym 动态加载
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

@interface GPUImageProcessor : NSObject

// ===== 旋转/镜像状态（原样） =====
@property (nonatomic, assign) int rotationAngle;
@property (nonatomic, assign) int sourceRotation;
@property (nonatomic, assign) BOOL mirrored;
@property (nonatomic, readonly) BOOL rotationApiAvailable;

// ===== 用户画面变换（原样） =====
@property (nonatomic, assign) double userPanX;
@property (nonatomic, assign) double userPanY;
@property (nonatomic, assign) double userZoom;

// ===== 帧代数（原样） =====
@property (nonatomic, assign) uint64_t frameToken;

// ===== 三色打光注入（原样保留，无脸时的回退路径） =====
@property (nonatomic, assign) BOOL lightEnabled;
@property (nonatomic, assign) uint32_t lightColorRGB;
@property (nonatomic, assign) int lightX;
@property (nonatomic, assign) int lightY;
@property (nonatomic, assign) int lightIntensity;
@property (nonatomic, assign) int lightDiameter;
@property (nonatomic, assign) int lightFeather;

// ===== 2026-10-30 新增：Vision 人脸检测彩色注入 =====

// 注入模式：0=人脸轮廓（严格按脸形状），1=椭圆（宽松）
// 默认 0
@property (nonatomic, assign) int injectMode;

// 人脸检测开关：YES 走 Vision + mask 混色；NO 走原 Y/CbCr 光斑
// 默认 YES
@property (nonatomic, assign) BOOL faceDetectEnabled;

// 强度滑块当前值（0.05~1.0，默认 0.45）
// 用户不拖时此值不生效（走自动），拖了才用
@property (nonatomic, assign) double alphaSliderValue;

// 用户是否拖过强度滑块
// YES: 使用 alphaSliderValue
// NO : 使用自动计算的 autoAlpha
// 重新开关彩色注入时置 NO
@property (nonatomic, assign) BOOL alphaManualSet;

// 自动强度 EMA 平滑后的当前值（只读，诊断用）
@property (nonatomic, readonly) double autoAlpha;

// 上一帧人脸位置（归一化，Vision boundingBox 原始坐标系，bottom-left origin）
@property (nonatomic, readonly) CGRect lastFaceRect;

// 上一帧人脸时间（mach_absolute_time）
@property (nonatomic, readonly) uint64_t lastFaceTime;

// 清除手动覆盖，恢复自动强度（重新开关彩色注入时由 VCamCore 调用）
- (void)resetManualAlpha;

// ===== 原有接口（一行不动） =====

- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)input
                                toWidth:(size_t)width
                                height:(size_t)height
                                format:(OSType)format CF_RETURNS_RETAINED;

- (CVPixelBufferRef)scaleToBGRA:(CVPixelBufferRef)input
                          width:(size_t)width
                         height:(size_t)height CF_RETURNS_RETAINED;

- (CVPixelBufferRef)rotateAndMirrorIfNeeded:(CVPixelBufferRef)input CF_RETURNS_RETAINED;

- (CVPixelBufferRef)bakeUserTransformIntoCanvas:(CVPixelBufferRef)input CF_RETURNS_RETAINED;

- (CVPixelBufferRef)injectLightIntoFrame:(CVPixelBufferRef)input CF_RETURNS_RETAINED;

- (CVPixelBufferRef)convertFormat:(CVPixelBufferRef)input toFormat:(OSType)format CF_RETURNS_RETAINED;

- (BOOL)renderCropFill:(CVPixelBufferRef)input toPixelBuffer:(CVPixelBufferRef)dst;

- (CVPixelBufferRef)adaptiveRotateIfNeeded:(CVPixelBufferRef)src
                               targetWidth:(size_t)targetW
                              targetHeight:(size_t)targetH
                                     token:(uint64_t)token CF_RETURNS_RETAINED;

- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst;
- (BOOL)transferPixelBuffer:(CVPixelBufferRef)src toPixelBuffer:(CVPixelBufferRef)dst token:(uint64_t)token;

- (CVPixelBufferRef)getOrCreateBGRABufferWithWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;

- (void)configureWithWidth:(size_t)width height:(size_t)height format:(OSType)format;

- (NSUInteger)activeStreamKeyCount;
- (NSString *)takeStreamStats;
- (void)releaseIdleMemory;
- (void)releaseHeavyBuffersForIdle;

@end
