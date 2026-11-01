//
//  VCamFloatingBall.m
//  VCamPlus
//
//  悬浮球 + 三页签面板(控制/打光/设置), 灰色主题
//  只在 SpringBoard 中使用（需要 UIKit）
//

#import "VCamFloatingBall.h"
#import "VCamCore.h"
#import "VCamNotify.h"
#import "ball_icon.h"
#import "btn_icons.h"
#import "VCamStr.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>

// 按钮图标解码(与悬浮球品牌图标同机制): btn_icons.h 内 XOR 8字节 rolling key
// 加密 PNG 字节, 此处运行时解密后 imageWithData —— 二进制内无 PNG 魔数, 防提取
static UIImage *vcamDecodeBtnIcon(const unsigned char *enc, NSUInteger len,
                                  const unsigned char key[8]) {
    NSMutableData *d = [NSMutableData dataWithLength:len];
    unsigned char *dst = (unsigned char *)d.mutableBytes;
    for (NSUInteger i = 0; i < len; i++) dst[i] = enc[i] ^ key[i & 7];
    return [UIImage imageWithData:d];
}

static void vcam_ball_log(NSString *msg) {
    @try {
        NSString *logPath = @"/tmp/vcam_ball_log.txt";
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

#include <dlfcn.h>
#include <pthread.h>
#import <mach/mach.h>
#import <objc/runtime.h>

typedef CGImageRef (*VcamUICreateScreenImageFn)(void);
typedef struct __VcamIOSurface *VcamIOSurfaceRef;
typedef int (*VcamCARSCaptureFn)(mach_port_t, uint32_t, uint32_t, uint32_t,
                                 uint32_t, uint32_t, uint32_t, VcamIOSurfaceRef *);
typedef kern_return_t (*VcamIOSLockFn)(VcamIOSurfaceRef, uint32_t, uint32_t *);
typedef void *(*VcamIOSBaseAddrFn)(VcamIOSurfaceRef);
typedef size_t (*VcamIOSDimFn)(VcamIOSurfaceRef);
typedef OSType (*VcamIOSFmtFn)(VcamIOSurfaceRef);

static struct {
    VcamIOSLockFn lock;
    VcamIOSLockFn unlock;
    VcamIOSBaseAddrFn base;
    VcamIOSDimFn width, height, stride;
    VcamIOSFmtFn fmt;
    int ok;
} sVcamIOS = {0};

static void vcamIOSurfaceInit(void) {
    if (sVcamIOS.ok) return;
    sVcamIOS.ok = 1;
    sVcamIOS.lock = (VcamIOSLockFn)dlsym(RTLD_DEFAULT, "IOSurfaceLock");
    sVcamIOS.unlock = (VcamIOSLockFn)dlsym(RTLD_DEFAULT, "IOSurfaceUnlock");
    sVcamIOS.base = (VcamIOSBaseAddrFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetBaseAddress");
    sVcamIOS.width = (VcamIOSDimFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetWidth");
    sVcamIOS.height = (VcamIOSDimFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetHeight");
    sVcamIOS.stride = (VcamIOSDimFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetBytesPerRow");
    sVcamIOS.fmt = (VcamIOSFmtFn)dlsym(RTLD_DEFAULT, "IOSurfaceGetPixelFormat");
}

// ===== 已知颜色集合(白光移除, 对齐 Android vcam KNOWN_COLORS) =====
static const uint32_t vcamKnownLights[6] = {
    0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0x00FFFF, 0xFF00FF
};
static NSString *vcamKnownLightName(int idx) {
    switch (idx) {
        case 0: return @"红";
        case 1: return @"绿";
        case 2: return @"蓝";
        case 3: return @"黄";
        case 4: return @"青";
        case 5: return @"紫";
    }
    return @"?";
}

__attribute__((unused))
static uint32_t vcamMatchKnownLight(const uint8_t *rgba, int n, NSString **outName, int *outCount) {
    int counts[6] = {0};
    for (int i = 0; i < n; i++) {
        int r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
        int maxc = MAX(MAX(r, g), b), minc = MIN(MIN(r, g), b);
        if (maxc < 180 || maxc - minc < 60) continue; 
        int best = -1, bestD2 = 120 * 120;
        for (int k = 0; k < 6; k++) {
            int dr = r - (int)((vcamKnownLights[k] >> 16) & 0xFF);
            int dg = g - (int)((vcamKnownLights[k] >> 8) & 0xFF);
            int db = b - (int)(vcamKnownLights[k] & 0xFF);
            int d2 = dr * dr + dg * dg + db * db;
            if (d2 < bestD2) { bestD2 = d2; best = k; }
        }
        if (best >= 0) counts[best]++;
    }
    int bestK = -1, bestC = 0;
    for (int k = 0; k < 6; k++) {
        if (counts[k] > bestC) { bestC = counts[k]; bestK = k; }
    }
    if (bestK >= 0 && bestC >= 30) { 
        if (outName) *outName = vcamKnownLightName(bestK);
        if (outCount) *outCount = bestC;
        return vcamKnownLights[bestK];
    }
    return 0;
}

// 对齐主源码 Tweak.xm 的 sampleScreenColor：
// 从屏幕截图四边边缘(各15%条带)采样彩色光, 单条带要求 sat>0.2 && maxC>0.25,
// 汇总后要求 saturation>0.15 && maxC>0.2, 否则返回 0（表示未检测到有效彩色）。
// 取到什么 RGB 就返回什么 RGB, 不再限制为 6 种已知色。
static uint32_t vcamSampleEdgeColor(CGImageRef cgImg, int *outSamples) {
    if (outSamples) *outSamples = 0;
    if (!cgImg) return 0;
    size_t w = CGImageGetWidth(cgImg);
    size_t h = CGImageGetHeight(cgImg);
    if (w == 0 || h == 0) return 0;

    size_t edgeW = w * 15 / 100;
    size_t edgeH = h * 15 / 100;
    if (edgeW < 1) edgeW = 1;
    if (edgeH < 1) edgeH = 1;
    if (edgeW >= w) edgeW = w / 2;
    if (edgeH >= h) edgeH = h / 2;

    CGRect edgeRects[4] = {
        CGRectMake(0, 0, (CGFloat)w, (CGFloat)edgeH),                                   // top
        CGRectMake(0, (CGFloat)(h - edgeH), (CGFloat)w, (CGFloat)edgeH),                // bottom
        CGRectMake(0, (CGFloat)edgeH, (CGFloat)edgeW, (CGFloat)(h - 2 * edgeH)),        // left
        CGRectMake((CGFloat)(w - edgeW), (CGFloat)edgeH, (CGFloat)edgeW, (CGFloat)(h - 2 * edgeH)), // right
    };

    CGFloat totalR = 0, totalG = 0, totalB = 0;
    int validSamples = 0;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return 0;

    for (int ei = 0; ei < 4; ei++) {
        CGImageRef cropped = CGImageCreateWithImageInRect(cgImg, edgeRects[ei]);
        if (!cropped) continue;
        unsigned char pixel[4] = {0};
        CGContextRef ctx = CGBitmapContextCreate(pixel, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast);
        if (ctx) {
            CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), cropped);
            CGContextRelease(ctx);
            CGFloat sr = pixel[0] / 255.0, sg = pixel[1] / 255.0, sb = pixel[2] / 255.0;
            CGFloat maxC = MAX(sr, MAX(sg, sb));
            CGFloat minC = MIN(sr, MIN(sg, sb));
            CGFloat sat = (maxC > 0.01) ? (maxC - minC) / maxC : 0;
            if (sat > 0.2 && maxC > 0.25) {
                totalR += sr; totalG += sg; totalB += sb;
                validSamples++;
            }
        }
        CGImageRelease(cropped);
    }
    CGColorSpaceRelease(cs);

    if (outSamples) *outSamples = validSamples;
    if (validSamples == 0) return 0;

    CGFloat r = totalR / validSamples;
    CGFloat g = totalG / validSamples;
    CGFloat b = totalB / validSamples;
    CGFloat maxC = MAX(r, MAX(g, b));
    CGFloat minC = MIN(r, MIN(g, b));
    CGFloat saturation = (maxC > 0.01) ? (maxC - minC) / maxC : 0;
    if (saturation <= 0.15 || maxC <= 0.2) return 0;

    uint32_t ri = (uint32_t)lround(r * 255.0);
    uint32_t gi = (uint32_t)lround(g * 255.0);
    uint32_t bi = (uint32_t)lround(b * 255.0);
    if (ri > 255) ri = 255;
    if (gi > 255) gi = 255;
    if (bi > 255) bi = 255;
    return (ri << 16) | (gi << 8) | bi;
}

typedef NS_ENUM(int, VcamPickPortStrategy) {
    kVcamPickStrategyBootstrap = 0,
    kVcamPickStrategySBSPort = 1,
    kVcamPickStrategyCount = 2
};
static BOOL gVcamPickStrategyFailed[kVcamPickStrategyCount] = {NO, NO};

typedef struct {
    volatile double px, py;
    volatile int running;
    volatile int threadAlive;
    volatile int currentStrategy;
    volatile uint64_t seq;
    volatile uint32_t color;
    volatile int count;
    volatile int nameIdx;
    volatile double heartbeat;
} VcamPickCaptureState;
static VcamPickCaptureState gVcamPick = {0};

// UICreateScreenImage 回退
static VcamUICreateScreenImageFn vcamUICreateScreenImage(void) {
    static VcamUICreateScreenImageFn fn = NULL;
    static int probed = 0;
    if (!probed) {
        probed = 1;
        fn = (VcamUICreateScreenImageFn)dlsym(RTLD_DEFAULT, "UICreateScreenImage");
    }
    return fn;
}

#pragma mark - 触摸穿透 window
@interface VCamOverlayWindow : UIWindow
@end
@implementation VCamOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

#pragma mark - 屏幕取色点视图
@interface VCamPickDotView : UIView
@end
@implementation VCamPickDotView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGPoint c = CGPointMake(rect.size.width / 2, rect.size.height / 2);
    CGFloat r = 14;
    CGContextSetLineWidth(ctx, 2.5);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.85].CGColor);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - r, c.y - r, r * 2, r * 2));
    CGContextSetLineWidth(ctx, 1.5);
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - r + 0.5, c.y - r + 0.5, r * 2 - 1, r * 2 - 1));
    CGContextSetLineWidth(ctx, 2);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.85].CGColor);
    for (int i = 0; i < 4; i++) {
        double ang = i * M_PI / 2;
        CGPoint p1 = CGPointMake(c.x + (CGFloat)cos(ang) * 17, c.y + (CGFloat)sin(ang) * 17);
        CGPoint p2 = CGPointMake(c.x + (CGFloat)cos(ang) * 21, c.y + (CGFloat)sin(ang) * 21);
        CGContextMoveToPoint(ctx, p1.x, p1.y);
        CGContextAddLineToPoint(ctx, p2.x, p2.y);
    }
    CGContextStrokePath(ctx);
}
@end

#pragma mark - 悬浮球视图
@interface VCamBallView : UIView
@property (nonatomic, strong) UIImageView *iconView;
@end
@implementation VCamBallView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.35 green:0.36 blue:0.38 alpha:0.92];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 2;
        self.layer.borderColor = [UIColor colorWithRed:0.75 green:0.76 blue:0.78 alpha:1.0].CGColor;
        static const unsigned char vcsIconKey[8] = {
            VCS_ICON_KEY0, VCS_ICON_KEY1, VCS_ICON_KEY2, VCS_ICON_KEY3,
            VCS_ICON_KEY4, VCS_ICON_KEY5, VCS_ICON_KEY6, VCS_ICON_KEY7,
        };
        NSMutableData *imgData = [NSMutableData dataWithLength:vcam_ball_icon_png_len];
        const unsigned char *src = vcam_ball_icon_enc;
        unsigned char *dst = (unsigned char *)imgData.mutableBytes;
        for (NSUInteger i = 0; i < vcam_ball_icon_png_len; i++) {
            dst[i] = src[i] ^ vcsIconKey[i & 7];
        }
        UIImage *icon = [UIImage imageWithData:imgData];
        _iconView = [[UIImageView alloc] initWithImage:icon];
        _iconView.frame = CGRectMake(3, 3, frame.size.width - 6, frame.size.height - 6);
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_iconView];
    }
    return self;
}
@end

#pragma mark - 面板按钮视图
@interface VCamPanelButton : UIButton
@property (nonatomic, copy) NSString *buttonKey;
@end
@implementation VCamPanelButton
@end

#pragma mark - VCamFloatingBall

@interface VCamFloatingBall () <PHPickerViewControllerDelegate>
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) VCamBallView *ballView;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIButton *tabControlBtn, *tabLightBtn, *tabSettingsBtn;
@property (nonatomic, strong) UIView *controlPageView, *lightPageView, *settingsPageView;
@property (nonatomic, strong) VCamPanelButton *replaceBtn, *mirrorBtn, *playPauseBtn;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL isFloating;
@property (nonatomic, assign) BOOL isPaused;
@property (nonatomic, assign) CGFloat panelPageTop;
@property (nonatomic, assign) CGFloat panelPad;
@property (nonatomic, assign) CGFloat controlPageH, settingsPageH, lightPageH;
@property (nonatomic, assign) NSInteger pickerSlot;

// 打光
@property (nonatomic, strong) VCamPanelButton *pickColorBtn;
@property (nonatomic, strong) UIView *lightColorSwatch;
@property (nonatomic, strong) UILabel *lightColorLabel;
@property (nonatomic, strong) UISlider *lightIntensitySlider, *lightDiameterSlider, *lightXSlider, *lightYSlider, *lightFeatherSlider;
@property (nonatomic, strong) UILabel *lightIntensityValue, *lightDiameterValue, *lightXValue, *lightYValue, *lightFeatherValue;
@property (nonatomic, strong) UIView *pickDotView;
@property (nonatomic, strong) dispatch_queue_t colorPickQueue;
@property (nonatomic, strong) dispatch_source_t colorPickTimer;
@property (nonatomic, assign) BOOL pickSuspended;
@property (nonatomic, assign) BOOL pickArmed;           // 用户已点击"屏幕取色: 开"，等待有效颜色
@property (nonatomic, assign) int pickSkipCount;
@property (nonatomic, assign) uint32_t lastDetectedColor;
@property (nonatomic, assign) uint64_t lastPickSeq;
@property (nonatomic, assign) BOOL lightFlushScheduled;
@property (nonatomic, assign) BOOL lightParamsDirty;
@end

@implementation VCamFloatingBall

+ (instancetype)sharedInstance {
    static VCamFloatingBall *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamFloatingBall alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _panelVisible = NO;
        _isFloating = NO;
        _isPaused = NO;
        _pickArmed = NO;
    }
    return self;
}

- (void)showFloatingBall {
    if (_isFloating) return;
    _isFloating = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self createOverlayWindow];
    });
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)hideFloatingBall {
    if (!_isFloating) return;
    _isFloating = NO;
    _pickArmed = NO;
    [self stopColorPickup];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.overlayWindow removeFromSuperview];
        self.overlayWindow.hidden = YES;
        self.overlayWindow = nil;
        self.ballView = nil;
        self.panelView = nil;
        self.pickDotView = nil;
    });
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI 创建

- (void)createOverlayWindow {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    UIWindowScene *windowScene = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            windowScene = (UIWindowScene *)scene;
            break;
        }
    }
    if (!windowScene) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                windowScene = (UIWindowScene *)scene;
                break;
            }
        }
    }

    if (windowScene) {
        _overlayWindow = [[VCamOverlayWindow alloc] initWithWindowScene:windowScene];
    } else {
        _overlayWindow = [[VCamOverlayWindow alloc] initWithFrame:screenBounds];
    }
    _overlayWindow.frame = screenBounds;
    _overlayWindow.windowLevel = UIWindowLevelAlert + 100;
    _overlayWindow.backgroundColor = [UIColor clearColor];
    _overlayWindow.rootViewController = [[UIViewController alloc] init];
    _overlayWindow.hidden = NO;
    _overlayWindow.userInteractionEnabled = YES;

    CGFloat ballSize = 50;
    CGFloat ballX = screenBounds.size.width - ballSize - 20;
    CGFloat ballY = screenBounds.size.height / 2 - ballSize / 2;
    _ballView = [[VCamBallView alloc] initWithFrame:CGRectMake(ballX, ballY, ballSize, ballSize)];
    [_ballView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ballTapped:)]];
    [_ballView addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(ballDragged:)]];

    [self createPanel];
    [_overlayWindow addSubview:_ballView];
}

#pragma mark - 辅助方法(颜色/反馈)

- (UIColor *)vcPanelBgColor { return [UIColor colorWithRed:0.24 green:0.25 blue:0.27 alpha:0.94]; }
- (UIColor *)vcButtonBgColor { return [UIColor colorWithRed:0.42 green:0.43 blue:0.45 alpha:1.0]; }
- (UIColor *)vcTabActiveColor { return [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1.0]; }
- (UIColor *)vcTabInactiveColor { return [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1.0]; }

// 浮动提示 (Toast)
- (void)toast:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.panelView) return;
        UILabel *l = [[UILabel alloc] init];
        l.text = msg;
        l.font = [UIFont boldSystemFontOfSize:13];
        l.textColor = [UIColor whiteColor];
        l.backgroundColor = [UIColor colorWithRed:0 green:0.5 blue:0.2 alpha:0.9];
        l.textAlignment = NSTextAlignmentCenter;
        l.layer.cornerRadius = 8;
        l.clipsToBounds = YES;
        [l sizeToFit];
        l.frame = CGRectMake(0, 0, l.frame.size.width + 24, 28);
        l.center = CGPointMake(self.panelView.bounds.size.width / 2, self.panelView.bounds.size.height - 40);
        l.alpha = 0;
        [self.panelView addSubview:l];
        [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.3 delay:0.8 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL finished) {
                [l removeFromSuperview];
            }];
        }];
    });
}

// 震动反馈
- (void)haptic:(UIImpactFeedbackStyle)style {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
        [gen impactOccurred];
    }
}

- (VCamPanelButton *)makeButton:(NSString *)title frame:(CGRect)frame selector:(SEL)sel {
    VCamPanelButton *btn = [VCamPanelButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.backgroundColor = [self vcButtonBgColor];
    btn.layer.cornerRadius = 9;
    btn.layer.masksToBounds = YES;
    [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    // 按压高亮
    [btn addTarget:self action:@selector(buttonTouchDown:) forControlEvents:UIControlEventTouchDown];
    [btn addTarget:self action:@selector(buttonTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return btn;
}

- (void)buttonTouchDown:(UIButton *)sender {
    [UIView animateWithDuration:0.05 animations:^{
        sender.backgroundColor = [UIColor colorWithRed:0.62 green:0.63 blue:0.66 alpha:1.0];
    }];
}

- (void)buttonTouchUp:(UIButton *)sender {
    [UIView animateWithDuration:0.12 animations:^{
        sender.backgroundColor = [self vcButtonBgColor];
    }];
}

#pragma mark - 面板创建

- (void)createPanel {
    CGFloat panelW = 241, pad = 10, contentW = panelW - pad * 2, tabH = 30, pageTop = pad + tabH + 6;
    CGFloat rowH = 38, gap = 8, cellW = 50, cellH = 44, gridGap = 7;
    CGFloat controlH = cellH * 4 + gridGap * 3;
    CGFloat settingsH = rowH * 5 + gap * 4 + 10 + 16;
    CGFloat lightH = 38 + 6 + 22 + 8 + (30 * 5 + 6 * 4) + 4;
    CGFloat panelH = pageTop + controlH + pad;

    _panelPageTop = pageTop;
    _panelPad = pad;
    _controlPageH = controlH;
    _settingsPageH = settingsH;
    _lightPageH = lightH;

    _panelView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelW, panelH)];
    _panelView.backgroundColor = [self vcPanelBgColor];
    _panelView.layer.cornerRadius = 12;
    _panelView.layer.masksToBounds = YES;
    _panelView.alpha = 0;
    _panelView.hidden = YES;

    // 页签
    CGFloat tabW = 64, tabGap = 8, tabX0 = (panelW - (tabW * 3 + tabGap * 2)) / 2;
    _tabControlBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _tabControlBtn.frame = CGRectMake(tabX0, pad, tabW, tabH);
    [_tabControlBtn setTitle:@"控制" forState:UIControlStateNormal];
    _tabControlBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _tabControlBtn.layer.cornerRadius = 7;
    [_tabControlBtn addTarget:self action:@selector(controlTabTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panelView addSubview:_tabControlBtn];

    _tabLightBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _tabLightBtn.frame = CGRectMake(tabX0 + tabW + tabGap, pad, tabW, tabH);
    [_tabLightBtn setTitle:@"打光" forState:UIControlStateNormal];
    _tabLightBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _tabLightBtn.layer.cornerRadius = 7;
    [_tabLightBtn addTarget:self action:@selector(lightTabTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panelView addSubview:_tabLightBtn];

    _tabSettingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _tabSettingsBtn.frame = CGRectMake(tabX0 + (tabW + tabGap) * 2, pad, tabW, tabH);
    [_tabSettingsBtn setTitle:@"设置" forState:UIControlStateNormal];
    _tabSettingsBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    _tabSettingsBtn.layer.cornerRadius = 7;
    [_tabSettingsBtn addTarget:self action:@selector(settingsTabTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panelView addSubview:_tabSettingsBtn];

    // 控制页
    _controlPageView = [[UIView alloc] initWithFrame:CGRectMake(0, pageTop, panelW, controlH)];
    [_panelView addSubview:_controlPageView];

    static const unsigned char kPlayKey[8] = { VCS_BTN_VCAM_BTN_PLAY_KEY0, VCS_BTN_VCAM_BTN_PLAY_KEY1, VCS_BTN_VCAM_BTN_PLAY_KEY2, VCS_BTN_VCAM_BTN_PLAY_KEY3, VCS_BTN_VCAM_BTN_PLAY_KEY4, VCS_BTN_VCAM_BTN_PLAY_KEY5, VCS_BTN_VCAM_BTN_PLAY_KEY6, VCS_BTN_VCAM_BTN_PLAY_KEY7 };
    static const unsigned char kMirrorKey[8] = { VCS_BTN_VCAM_BTN_MIRROR_KEY0, VCS_BTN_VCAM_BTN_MIRROR_KEY1, VCS_BTN_VCAM_BTN_MIRROR_KEY2, VCS_BTN_VCAM_BTN_MIRROR_KEY3, VCS_BTN_VCAM_BTN_MIRROR_KEY4, VCS_BTN_VCAM_BTN_MIRROR_KEY5, VCS_BTN_VCAM_BTN_MIRROR_KEY6, VCS_BTN_VCAM_BTN_MIRROR_KEY7 };
    static const unsigned char kReplaceKey[8] = { VCS_BTN_VCAM_BTN_REPLACE_KEY0, VCS_BTN_VCAM_BTN_REPLACE_KEY1, VCS_BTN_VCAM_BTN_REPLACE_KEY2, VCS_BTN_VCAM_BTN_REPLACE_KEY3, VCS_BTN_VCAM_BTN_REPLACE_KEY4, VCS_BTN_VCAM_BTN_REPLACE_KEY5, VCS_BTN_VCAM_BTN_REPLACE_KEY6, VCS_BTN_VCAM_BTN_REPLACE_KEY7 };
    static const unsigned char kRestoreKey[8] = { VCS_BTN_VCAM_BTN_RESTORE_KEY0, VCS_BTN_VCAM_BTN_RESTORE_KEY1, VCS_BTN_VCAM_BTN_RESTORE_KEY2, VCS_BTN_VCAM_BTN_RESTORE_KEY3, VCS_BTN_VCAM_BTN_RESTORE_KEY4, VCS_BTN_VCAM_BTN_RESTORE_KEY5, VCS_BTN_VCAM_BTN_RESTORE_KEY6, VCS_BTN_VCAM_BTN_RESTORE_KEY7 };
    static const unsigned char kRotateKey[8] = { VCS_BTN_VCAM_BTN_ROTATE_KEY0, VCS_BTN_VCAM_BTN_ROTATE_KEY1, VCS_BTN_VCAM_BTN_ROTATE_KEY2, VCS_BTN_VCAM_BTN_ROTATE_KEY3, VCS_BTN_VCAM_BTN_ROTATE_KEY4, VCS_BTN_VCAM_BTN_ROTATE_KEY5, VCS_BTN_VCAM_BTN_ROTATE_KEY6, VCS_BTN_VCAM_BTN_ROTATE_KEY7 };

    UIImage *iconPlay = vcamDecodeBtnIcon(vcam_btn_play_enc, vcam_btn_play_len, kPlayKey);
    UIImage *iconMirror = vcamDecodeBtnIcon(vcam_btn_mirror_enc, vcam_btn_mirror_len, kMirrorKey);
    UIImage *iconReplace = vcamDecodeBtnIcon(vcam_btn_replace_enc, vcam_btn_replace_len, kReplaceKey);
    UIImage *iconRestore = vcamDecodeBtnIcon(vcam_btn_restore_enc, vcam_btn_restore_len, kRestoreKey);
    UIImage *iconRotate = vcamDecodeBtnIcon(vcam_btn_rotate_enc, vcam_btn_rotate_len, kRotateKey);
    iconPlay = [iconPlay imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    iconMirror = [iconMirror imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    iconReplace = [iconReplace imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    iconRestore = [iconRestore imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    iconRotate = [iconRotate imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];

    typedef NS_ENUM(int, GridCellType) { CellText, CellIcon, CellSymbol };
    struct GridCell { GridCellType type; NSString *repr; UIImage *icon; UIEdgeInsets insets; SEL action; };
    struct GridCell cells[4][4] = {
        { {CellIcon, nil, iconPlay, {2, 2, 2, 2}, @selector(restartVideoTapped)},
          {CellSymbol, @"arrow.up", nil, {0, 0, 0, 0}, @selector(panUpTapped)},
          {CellIcon, nil, iconRestore, {8, 8, 8, 8}, @selector(resetTransformTapped)},
          {CellText, @"1", nil, {0, 0, 0, 0}, @selector(slot1Tapped)} },
        { {CellSymbol, @"arrow.left", nil, {0, 0, 0, 0}, @selector(panLeftTapped)},
          {CellSymbol, @"arrow.down", nil, {0, 0, 0, 0}, @selector(panDownTapped)},
          {CellSymbol, @"arrow.right", nil, {0, 0, 0, 0}, @selector(panRightTapped)},
          {CellText, @"2", nil, {0, 0, 0, 0}, @selector(slot2Tapped)} },
        { {CellSymbol, @"minus", nil, {0, 0, 0, 0}, @selector(zoomOutTapped)},
          {CellSymbol, @"play.fill", nil, {0, 0, 0, 0}, @selector(playPauseTapped)},
          {CellSymbol, @"plus", nil, {0, 0, 0, 0}, @selector(zoomInTapped)},
          {CellText, @"3", nil, {0, 0, 0, 0}, @selector(slot3Tapped)} },
        { {CellIcon, nil, iconRotate, {7, 7, 7, 7}, @selector(rotateRightTapped)},
          {CellIcon, nil, iconMirror, {7, 7, 7, 7}, @selector(mirrorTapped)},
          {CellIcon, nil, iconReplace, {4, 4, 4, 4}, @selector(toggleReplacementTapped)},
          {CellText, @"4", nil, {0, 0, 0, 0}, @selector(slot4Tapped)} },
    };
    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
            struct GridCell cell = cells[r][c];
            CGRect f = CGRectMake(pad + c * (cellW + gridGap), r * (cellH + gridGap), cellW, cellH);
            VCamPanelButton *btn;
            if (cell.type == CellIcon) {
                btn = [self makeButton:@"" frame:f selector:cell.action];
                [btn setImage:cell.icon forState:UIControlStateNormal];
                btn.imageView.contentMode = UIViewContentModeScaleAspectFit;
                btn.imageEdgeInsets = cell.insets;
            } else if (cell.type == CellSymbol) {
                btn = [self makeButton:@"" frame:f selector:cell.action];
                UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
                UIImage *sym = [UIImage systemImageNamed:cell.repr withConfiguration:cfg];
                if (sym) {
                    [btn setImage:sym forState:UIControlStateNormal];
                    btn.tintColor = [UIColor whiteColor];
                    btn.imageEdgeInsets = UIEdgeInsetsMake(9, 9, 9, 9);
                } else {
                    btn = [self makeButton:@"·" frame:f selector:cell.action];
                }
            } else {
                btn = [self makeButton:cell.repr frame:f selector:cell.action];
            }
            [_controlPageView addSubview:btn];
            if (r == 2 && c == 1) _playPauseBtn = btn;
            if (r == 3 && c == 1) _mirrorBtn = btn;
            if (r == 3 && c == 2) _replaceBtn = btn;
        }
    }

    // 打光页
    _lightPageView = [[UIView alloc] initWithFrame:CGRectMake(0, pageTop, panelW, lightH)];
    [_panelView addSubview:_lightPageView];

    _pickColorBtn = [self makeButton:@"屏幕取色: 关" frame:CGRectMake(pad, 0, contentW, rowH) selector:@selector(pickColorTapped)];
    _pickColorBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_lightPageView addSubview:_pickColorBtn];

    CGFloat colorRowY = rowH + 6;
    _lightColorSwatch = [[UIView alloc] initWithFrame:CGRectMake(pad, colorRowY + 3, 16, 16)];
    _lightColorSwatch.layer.cornerRadius = 3;
    _lightColorSwatch.layer.borderWidth = 1;
    _lightColorSwatch.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    _lightColorSwatch.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    [_lightPageView addSubview:_lightColorSwatch];
    _lightColorLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad + 24, colorRowY, contentW - 24, 22)];
    _lightColorLabel.text = @"颜色: 未检测";
    _lightColorLabel.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
    _lightColorLabel.font = [UIFont systemFontOfSize:12];
    [_lightPageView addSubview:_lightColorLabel];

    CGFloat sliderX = pad + 56, sliderW = contentW - 56 - 42, sy = colorRowY + 22 + 8, rowStep = 30 + 6;
    NSString *rowTitles[5] = {@"打光强度", @"打光直径", @"横坐标", @"纵坐标", @"边缘羽化"};
    SEL rowActions[5] = {@selector(lightIntensityChanged:), @selector(lightDiameterChanged:), @selector(lightXChanged:), @selector(lightYChanged:), @selector(lightFeatherChanged:)};
    int initVals[5] = { [VCamNotify plistLightIntensity], [VCamNotify plistLightDiameter], [VCamNotify plistLightX], [VCamNotify plistLightY], [VCamNotify plistLightFeather] };
    for (int i = 0; i < 5; i++) {
        CGFloat ry = sy + rowStep * i;
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, ry + 5, 56, 20)];
        title.text = rowTitles[i];
        title.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
        title.font = [UIFont systemFontOfSize:12];
        [_lightPageView addSubview:title];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(sliderX, ry + 1, sliderW, 28)];
        slider.minimumValue = 0; slider.maximumValue = 100;
        int v = initVals[i]; if (v < 0) v = 0; if (v > 100) v = 100;
        slider.value = (float)v;
        slider.minimumTrackTintColor = [UIColor colorWithRed:0.55 green:0.56 blue:0.58 alpha:1.0];
        [slider addTarget:self action:rowActions[i] forControlEvents:UIControlEventValueChanged];
        [_lightPageView addSubview:slider];

        UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(pad + contentW - 42, ry + 5, 42, 20)];
        val.text = [NSString stringWithFormat:@"%d%%", v];
        val.textColor = [UIColor whiteColor];
        val.font = [UIFont systemFontOfSize:12];
        val.textAlignment = NSTextAlignmentRight;
        [_lightPageView addSubview:val];

        switch (i) {
            case 0: _lightIntensitySlider = slider; _lightIntensityValue = val; break;
            case 1: _lightDiameterSlider = slider; _lightDiameterValue = val; break;
            case 2: _lightXSlider = slider; _lightXValue = val; break;
            case 3: _lightYSlider = slider; _lightYValue = val; break;
            case 4: _lightFeatherSlider = slider; _lightFeatherValue = val; break;
        }
    }

    // 设置页
    _settingsPageView = [[UIView alloc] initWithFrame:CGRectMake(0, pageTop, panelW, settingsH)];
    [_panelView addSubview:_settingsPageView];

    VCamPanelButton *selectBtn = [self makeButton:@"选择视频" frame:CGRectMake(pad, 0, contentW, rowH) selector:@selector(selectVideoTapped)];
    selectBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:selectBtn];

    VCamPanelButton *preset2 = [self makeButton:@"预设视频2" frame:CGRectMake(pad, rowH + gap, contentW, rowH) selector:@selector(preset2Tapped)];
    preset2.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:preset2];

    VCamPanelButton *preset3 = [self makeButton:@"预设视频3" frame:CGRectMake(pad, (rowH + gap) * 2, contentW, rowH) selector:@selector(preset3Tapped)];
    preset3.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:preset3];

    VCamPanelButton *preset4 = [self makeButton:@"预设视频4" frame:CGRectMake(pad, (rowH + gap) * 3, contentW, rowH) selector:@selector(preset4Tapped)];
    preset4.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:preset4];

    VCamPanelButton *channel = [self makeButton:VCS(qisheng) frame:CGRectMake(pad, (rowH + gap) * 4, contentW, rowH) selector:@selector(channelLinkTapped)];
    channel.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_settingsPageView addSubview:channel];

    UILabel *mark = [[UILabel alloc] initWithFrame:CGRectMake(pad, (rowH + gap) * 4 + rowH + 10, contentW, 16)];
    mark.text = VCS(mark);
    mark.textColor = [UIColor colorWithRed:0.72 green:0.73 blue:0.75 alpha:1.0];
    mark.textAlignment = NSTextAlignmentCenter;
    mark.font = [UIFont systemFontOfSize:11];
    [_settingsPageView addSubview:mark];

    _lightPageView.hidden = YES;
    _settingsPageView.hidden = YES;
    [self refreshTabStyles];
    [self updateReplaceButtonVisual];
    [self updateMirrorButtonVisual];

    [_overlayWindow addSubview:_panelView];

    // 恢复打光 (对齐主源码 toggleColorInject: 只有之前确实取到过有效颜色
    // 才恢复; 否则强制关闭, 避免 lightColor=0 被 VCamCore 当作红色)
    uint32_t savedLightColor = [VCamNotify plistLightColor];
    if ([VCamNotify plistLightEnabled] && savedLightColor != 0) {
        _pickArmed = YES;
        _lastDetectedColor = savedLightColor;
        _pickSkipCount = 3;
        [self showPickDot];
        [self startColorPickup];
        [_pickColorBtn setTitle:@"屏幕取色: 开" forState:UIControlStateNormal];
        [self updateColorPreview:_lastDetectedColor];
    } else {
        if ([VCamNotify plistLightEnabled]) {
            [VCamNotify setPlistLightEnabled:NO];
        }
        [VCamNotify setPlistLightColor:0];
        _pickArmed = NO;
        _lastDetectedColor = 0;
        [_pickColorBtn setTitle:@"屏幕取色: 关" forState:UIControlStateNormal];
        [self updateColorPreview:0];
    }
}

- (void)refreshTabStyles {
    BOOL controlActive = !_controlPageView.hidden;
    BOOL lightActive = !_lightPageView.hidden;
    _tabControlBtn.backgroundColor = controlActive ? [self vcTabActiveColor] : [self vcTabInactiveColor];
    _tabLightBtn.backgroundColor = lightActive ? [self vcTabActiveColor] : [self vcTabInactiveColor];
    _tabSettingsBtn.backgroundColor = (!controlActive && !lightActive) ? [self vcTabActiveColor] : [self vcTabInactiveColor];
    [_tabControlBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_tabLightBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_tabSettingsBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
}

- (void)applyPanelContentHeight:(CGFloat)contentH {
    CGFloat targetH = _panelPageTop + contentH + _panelPad;
    if (fabs(_panelView.frame.size.height - targetH) < 0.5) return;
    [UIView animateWithDuration:0.18 animations:^{
        CGRect f = self.panelView.frame;
        f.size.height = targetH;
        self.panelView.frame = f;
        [self updatePanelPosition];
    }];
}

- (void)controlTabTapped {
    [self haptic:UIImpactFeedbackStyleLight];
    _controlPageView.hidden = NO; _lightPageView.hidden = YES; _settingsPageView.hidden = YES;
    [self refreshTabStyles];
    [self applyPanelContentHeight:_controlPageH];
}

- (void)lightTabTapped {
    [self haptic:UIImpactFeedbackStyleLight];
    _controlPageView.hidden = YES; _lightPageView.hidden = NO; _settingsPageView.hidden = YES;
    [self refreshTabStyles];
    [self applyPanelContentHeight:_lightPageH];
}

- (void)settingsTabTapped {
    [self haptic:UIImpactFeedbackStyleLight];
    _controlPageView.hidden = YES; _lightPageView.hidden = YES; _settingsPageView.hidden = NO;
    [self refreshTabStyles];
    [self applyPanelContentHeight:_settingsPageH];
}

#pragma mark - 打光与取色逻辑

static NSString *vcamLightColorName(uint32_t c) {
    int r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
    if (r > 200 && g < 80 && b < 80) return @"红";
    if (r < 80 && g > 200 && b < 80) return @"绿";
    if (r < 80 && g < 80 && b > 200) return @"蓝";
    if (r > 200 && g > 200 && b < 80) return @"黄";
    if (r < 80 && g > 200 && b > 200) return @"青";
    if (r > 200 && g < 80 && b > 200) return @"紫";
    return @"自定义";
}

- (void)pickColorTapped {
    [self haptic:UIImpactFeedbackStyleMedium];
    if (!_pickArmed) {
        _pickArmed = YES;
        // 对齐主源码 toggleColorInject:
        // 开关打开后先不注入任何颜色, 等真正采到有效色才开 lightEnabled
        [VCamNotify setPlistLightEnabled:NO];
        [VCamNotify setPlistLightColor:0];
        _lastDetectedColor = 0;
        _pickSkipCount = 3;
        [self showPickDot];   // 视觉指示
        [self startColorPickup];
        [_pickColorBtn setTitle:@"屏幕取色: 开" forState:UIControlStateNormal];
        [self updateColorPreview:0];
        [self toast:@"取色已开启，请对准颜色"];
    } else {
        _pickArmed = NO;
        [self stopColorPickup];
        [self hidePickDot];
        [VCamNotify setPlistLightEnabled:NO];
        [VCamNotify setPlistLightColor:0];
        _lastDetectedColor = 0;
        [self updateColorPreview:0];
        [_pickColorBtn setTitle:@"屏幕取色: 关" forState:UIControlStateNormal];
        [self toast:@"取色已关闭"];
    }
}

- (void)showPickDot {
    if (!_overlayWindow) return;
    if (_pickDotView) { _pickDotView.hidden = NO; return; }
    NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{};
    CGFloat px = [pl[@"lightPickX"] doubleValue], py = [pl[@"lightPickY"] doubleValue];
    CGRect sb = _overlayWindow.bounds;
    if (px <= 0 || py <= 0) { px = sb.size.width / 2; py = sb.size.height / 2; }
    px = MAX(22, MIN(sb.size.width - 22, px));
    py = MAX(22, MIN(sb.size.height - 22, py));
    _pickDotView = [[VCamPickDotView alloc] initWithFrame:CGRectMake(px - 22, py - 22, 44, 44)];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pickDotDragged:)];
    [_pickDotView addGestureRecognizer:pan];
    if (_panelView) [_overlayWindow insertSubview:_pickDotView belowSubview:_panelView];
    else if (_ballView) [_overlayWindow insertSubview:_pickDotView belowSubview:_ballView];
    else [_overlayWindow insertSubview:_pickDotView atIndex:1];
}

- (void)hidePickDot { _pickDotView.hidden = YES; }

- (void)pickDotDragged:(UIPanGestureRecognizer *)g {
    if (!_pickDotView) return;
    CGPoint t = [g translationInView:_overlayWindow];
    CGPoint c = CGPointMake(_pickDotView.center.x + t.x, _pickDotView.center.y + t.y);
    c.x = MAX(22, MIN(_overlayWindow.bounds.size.width - 22, c.x));
    c.y = MAX(22, MIN(_overlayWindow.bounds.size.height - 22, c.y));
    _pickDotView.center = c;
    [g setTranslation:CGPointZero inView:_overlayWindow];
    if (g.state == UIGestureRecognizerStateBegan) {
        _pickSuspended = YES;
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _pickSuspended = NO;
        _pickSkipCount = 3;
        gVcamPick.px = c.x;
        gVcamPick.py = c.y;
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
            [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
        dict[@"lightPickX"] = @(c.x);
        dict[@"lightPickY"] = @(c.y);
        [dict writeToFile:VCamPlistPath atomically:YES];
    }
}

- (void)startColorPickup {
    if (_colorPickTimer) return;
    gVcamPick.running = 1;
    NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{};
    double px = [pl[@"lightPickX"] doubleValue], py = [pl[@"lightPickY"] doubleValue];
    if (px <= 0 || py <= 0) { px = [UIScreen mainScreen].bounds.size.width / 2; py = [UIScreen mainScreen].bounds.size.height / 2; }
    gVcamPick.px = px; gVcamPick.py = py;
    gVcamPick.seq = 0; gVcamPick.color = 0; gVcamPick.nameIdx = -1;
    _lastPickSeq = 0;

    // 全设备禁用 CARS，统一使用 UICSI (最稳的截屏回退)
    for (int i = 0; i < kVcamPickStrategyCount; i++) gVcamPickStrategyFailed[i] = YES;
    gVcamPick.currentStrategy = -1;
    gVcamPick.threadAlive = 0;

    if (!_colorPickQueue) _colorPickQueue = dispatch_get_main_queue();
    _colorPickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _colorPickQueue);
    dispatch_source_set_timer(_colorPickTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), (uint64_t)(0.04 * NSEC_PER_SEC), (uint64_t)(0.015 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_colorPickTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf colorPickTick];
    });
    dispatch_resume(_colorPickTimer);
}

- (void)stopColorPickup {
    if (_colorPickTimer) {
        dispatch_source_cancel(_colorPickTimer);
        _colorPickTimer = nil;
    }
    gVcamPick.running = 0;
}

- (uint32_t)detectWithUICreateScreenImage:(NSString **)outName count:(int *)outCount {
    if (outName) *outName = nil;
    if (outCount) *outCount = 0;
    VcamUICreateScreenImageFn capFn = vcamUICreateScreenImage();
    if (!capFn) return 0;
    CGImageRef full = capFn();
    if (!full) return 0;

    // 对齐主源码 sampleScreenColor: 固定采样屏幕四边边缘 (15% 条带),
    // 与 pickDot 位置无关。取到什么 RGB 就返回什么 RGB。
    uint32_t detected = vcamSampleEdgeColor(full, outCount);
    CFRelease(full);
    return detected;
}

- (void)colorPickTick {
    // 对齐主源码 sampleScreenColor: 与 pickDot 位置无关, 固定采样屏幕边缘。
    // 拖动 pickDot 只更新视觉位置, 不改变取色来源。
    if (_pickSuspended) return;
    if (_pickSkipCount > 0) { _pickSkipCount--; return; }

    uint32_t detected = 0;
    NSString *detName = nil;
    int detCount = 0;

    if (gVcamPick.currentStrategy >= 0 && gVcamPick.threadAlive) {
        // 兼容旧策略分支 (当前 startColorPickup 已禁用 CARS, 不会走这里)
        if (gVcamPick.seq != _lastPickSeq) {
            _lastPickSeq = gVcamPick.seq;
            detected = gVcamPick.color;
            detCount = gVcamPick.count;
            int ni = gVcamPick.nameIdx;
            if (detected && ni >= 0 && ni < 6) detName = vcamKnownLightName(ni);
        } else {
            return;
        }
    } else {
        detected = [self detectWithUICreateScreenImage:&detName count:&detCount];
    }

    if (detected != _lastDetectedColor) {
        _lastDetectedColor = detected;
        if (detected != 0) {
            // 有效颜色: 写入并开启打光 (首次开启时才翻 lightEnabled)
            [VCamNotify setPlistLightColor:detected];
            if (![VCamNotify plistLightEnabled]) {
                [VCamNotify setPlistLightEnabled:YES];
            }
            uint32_t d = detected;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateColorPreview:d];
            });
        } else {
            // 颜色丢失: 立即关打光并清色, 绝不把 0 留给 VCamCore
            [VCamNotify setPlistLightEnabled:NO];
            [VCamNotify setPlistLightColor:0];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateColorPreview:0];
            });
        }
    }
}

- (void)updateColorPreview:(uint32_t)color {
    if (color == 0) {
        _lightColorSwatch.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        _lightColorLabel.text = @"颜色: 未检测";
    } else {
        _lightColorSwatch.backgroundColor = [UIColor colorWithRed:((color >> 16) & 0xFF) / 255.0 green:((color >> 8) & 0xFF) / 255.0 blue:(color & 0xFF) / 255.0 alpha:1];
        _lightColorLabel.text = [NSString stringWithFormat:@"颜色: %@ (%d,%d,%d)", vcamLightColorName(color), (int)((color >> 16) & 0xFF), (int)((color >> 8) & 0xFF), (int)(color & 0xFF)];
    }
}

- (void)lightIntensityChanged:(UISlider *)s { _lightIntensityValue.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(s.value)]; [self scheduleLightParamsFlush]; }
- (void)lightDiameterChanged:(UISlider *)s { _lightDiameterValue.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(s.value)]; [self scheduleLightParamsFlush]; }
- (void)lightXChanged:(UISlider *)s { _lightXValue.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(s.value)]; [self scheduleLightParamsFlush]; }
- (void)lightYChanged:(UISlider *)s { _lightYValue.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(s.value)]; [self scheduleLightParamsFlush]; }
- (void)lightFeatherChanged:(UISlider *)s { _lightFeatherValue.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(s.value)]; [self scheduleLightParamsFlush]; }

- (void)scheduleLightParamsFlush {
    _lightParamsDirty = YES;
    if (_lightFlushScheduled) return;
    _lightFlushScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        _lightFlushScheduled = NO;
        if (_lightParamsDirty) {
            _lightParamsDirty = NO;
            [self flushLightParams];
        }
    });
}

- (void)flushLightParams {
    if (!_lightIntensitySlider) return;
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:[NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"lightIntensity"] = @((int)lroundf(_lightIntensitySlider.value));
    dict[@"lightDiameter"] = @((int)lroundf(_lightDiameterSlider.value));
    dict[@"lightX"] = @((int)lroundf(_lightXSlider.value));
    dict[@"lightY"] = @((int)lroundf(_lightYSlider.value));
    dict[@"lightFeather"] = @((int)lroundf(_lightFeatherSlider.value));
    [dict writeToFile:VCamPlistPath atomically:YES];
}

#pragma mark - 交互

- (void)ballTapped:(UITapGestureRecognizer *)gesture {
    [self haptic:UIImpactFeedbackStyleMedium];
    [self togglePanel];
}

- (void)ballDragged:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:_overlayWindow];
    CGPoint newCenter = CGPointMake(_ballView.center.x + translation.x, _ballView.center.y + translation.y);
    CGFloat halfW = _ballView.frame.size.width / 2;
    CGFloat halfH = _ballView.frame.size.height / 2;
    newCenter.x = MAX(halfW, MIN(_overlayWindow.frame.size.width - halfW, newCenter.x));
    newCenter.y = MAX(halfH, MIN(_overlayWindow.frame.size.height - halfH, newCenter.y));
    _ballView.center = newCenter;
    [gesture setTranslation:CGPointZero inView:_overlayWindow];
    [self updatePanelPosition];
}

- (void)togglePanel {
    _panelVisible = !_panelVisible;
    if (_panelVisible) {
        _panelView.hidden = NO;
        [self updatePanelPosition];
        [UIView animateWithDuration:0.2 animations:^{ self.panelView.alpha = 1.0; }];
    } else {
        [UIView animateWithDuration:0.2 animations:^{ self.panelView.alpha = 0; } completion:^(BOOL finished) {
            self.panelView.hidden = YES;
        }];
    }
}

- (void)updatePanelPosition {
    CGFloat panelW = _panelView.frame.size.width, panelH = _panelView.frame.size.height;
    CGFloat screenW = _overlayWindow.frame.size.width, screenH = _overlayWindow.frame.size.height;
    CGFloat gap = 8;
    CGFloat rightX = CGRectGetMaxX(_ballView.frame) + gap;
    CGFloat leftX = _ballView.frame.origin.x - panelW - gap;
    CGFloat panelX = (rightX + panelW <= screenW - 5) ? rightX : leftX;
    panelX = MAX(5, panelX);
    CGFloat panelY = _ballView.center.y - panelH / 2;
    panelY = MAX(5, MIN(screenH - panelH - 5, panelY));
    _panelView.frame = CGRectMake(panelX, panelY, panelW, panelH);
}

#pragma mark - 控制页回调(全按键反馈)

- (void)restartVideoTapped {
    [self haptic:UIImpactFeedbackStyleLight];
    [VCamNotify bumpRestartToken];
    [self toast:@"从头播放"];
}

- (void)playPauseTapped {
    [self haptic:UIImpactFeedbackStyleLight];
    _isPaused = !_isPaused;
    [VCamNotify setPlistPaused:_isPaused];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    UIImage *sym = [UIImage systemImageNamed:(_isPaused ? @"pause.fill" : @"play.fill") withConfiguration:cfg];
    [self.playPauseBtn setImage:sym forState:UIControlStateNormal];
    [self toast:(_isPaused ? @"暂停播放" : @"继续播放")];
}

- (void)toggleReplacementTapped {
    [self haptic:UIImpactFeedbackStyleMedium];
    BOOL newEnabled = ![VCamNotify isPlistEnabled];
    [VCamNotify setPlistEnabled:newEnabled];
    [[VCamCore sharedInstance] setEnabled:newEnabled];
    [self updateReplaceButtonVisual];
    [self toast:(newEnabled ? @"替换摄像头" : @"还原真实摄像头")];
}

- (void)updateReplaceButtonVisual {
    BOOL en = [VCamNotify isPlistEnabled];
    self.replaceBtn.layer.borderWidth = 2;
    self.replaceBtn.layer.borderColor = en ? [UIColor clearColor].CGColor : [UIColor whiteColor].CGColor;
}

- (void)mirrorTapped {
    [self haptic:UIImpactFeedbackStyleLight];
    BOOL newMirrored = ![VCamNotify plistMirrored];
    [VCamNotify setPlistMirrored:newMirrored];
    [self updateMirrorButtonVisual];
    [self toast:(newMirrored ? @"镜像已开启" : @"镜像已关闭")];
}

- (void)updateMirrorButtonVisual {
    BOOL mi = [VCamNotify plistMirrored];
    self.mirrorBtn.layer.borderWidth = 2;
    self.mirrorBtn.layer.borderColor = mi ? [UIColor whiteColor].CGColor : [UIColor clearColor].CGColor;
}

- (void)rotateRightTapped {
    [self haptic:UIImpactFeedbackStyleLight];
    int oldAngle = (int)[VCamNotify plistRotation];
    int newAngle = (oldAngle + 90) % 360;
    [VCamNotify setPlistRotation:newAngle];
    [self toast:[NSString stringWithFormat:@"旋转 %d°", newAngle]];
}

- (void)slot1Tapped { [self haptic:UIImpactFeedbackStyleLight]; [self playSlot:1]; }
- (void)slot2Tapped { [self haptic:UIImpactFeedbackStyleLight]; [self playSlot:2]; }
- (void)slot3Tapped { [self haptic:UIImpactFeedbackStyleLight]; [self playSlot:3]; }
- (void)slot4Tapped { [self haptic:UIImpactFeedbackStyleLight]; [self playSlot:4]; }

- (void)playSlot:(NSInteger)slot {
    NSString *path = (slot == 1) ? @"/var/mobile/Media/DCIM/vcam.mp4" : [NSString stringWithFormat:@"/var/mobile/Media/DCIM/6/%ld.mp4", (long)slot];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self toast:[NSString stringWithFormat:@"预设视频%d 未找到", (int)slot]];
        return;
    }
    [VCamNotify setActivePlaybackPath:path];
    [self resetOrientationState];
    [self updateMirrorButtonVisual];
    if (![VCamNotify isPlistEnabled]) {
        [VCamNotify setPlistEnabled:YES];
        [[VCamCore sharedInstance] setEnabled:YES];
        [self updateReplaceButtonVisual];
    }
    [self toast:[NSString stringWithFormat:@"已切换至视频%d", (int)slot]];
}

- (void)resetOrientationState {
    [VCamNotify setPlistRotation:0];
    [VCamNotify setPlistMirrored:NO];
    [VCamNotify resetPlistTransform];
    [self updateMirrorButtonVisual];
}

static const double kVcamPanStep = 0.05;
static const double kVcamZoomFactor = 1.10;
static const double kVcamZoomMin = 0.5;
static const double kVcamZoomMax = 4.0;

static double vcamClamp(double v, double lo, double hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

- (void)panByX:(double)dx Y:(double)dy {
    [self haptic:UIImpactFeedbackStyleLight];
    double nx = vcamClamp([VCamNotify plistPanX] + dx, -1.0, 1.0);
    double ny = vcamClamp([VCamNotify plistPanY] + dy, -1.0, 1.0);
    [VCamNotify setPlistPanX:nx];
    [VCamNotify setPlistPanY:ny];
}

- (void)panLeftTapped  { [self panByX:-kVcamPanStep Y:0]; }
- (void)panRightTapped { [self panByX: kVcamPanStep Y:0]; }
- (void)panUpTapped    { [self panByX:0 Y:-kVcamPanStep]; }
- (void)panDownTapped  { [self panByX:0 Y: kVcamPanStep]; }

- (void)zoomInTapped {
    [self haptic:UIImpactFeedbackStyleLight];
    double nz = vcamClamp([VCamNotify plistZoom] * kVcamZoomFactor, kVcamZoomMin, kVcamZoomMax);
    [VCamNotify setPlistZoom:nz];
    [self toast:[NSString stringWithFormat:@"放大至 %.0f%%", nz * 100]];
}

- (void)zoomOutTapped {
    [self haptic:UIImpactFeedbackStyleLight];
    double nz = vcamClamp([VCamNotify plistZoom] / kVcamZoomFactor, kVcamZoomMin, kVcamZoomMax);
    [VCamNotify setPlistZoom:nz];
    [self toast:[NSString stringWithFormat:@"缩小至 %.0f%%", nz * 100]];
}

- (void)resetTransformTapped {
    [self haptic:UIImpactFeedbackStyleLight];
    [VCamNotify resetPlistTransform];
    [self toast:@"画面已复位"];
}

#pragma mark - 视频选择
- (void)selectVideoTapped { [self haptic:UIImpactFeedbackStyleLight]; [self openPickerForSlot:0]; }
- (void)preset2Tapped     { [self haptic:UIImpactFeedbackStyleLight]; [self openPickerForSlot:2]; }
- (void)preset3Tapped     { [self haptic:UIImpactFeedbackStyleLight]; [self openPickerForSlot:3]; }
- (void)preset4Tapped     { [self haptic:UIImpactFeedbackStyleLight]; [self openPickerForSlot:4]; }

- (void)openPickerForSlot:(NSInteger)slot {
    _pickerSlot = slot;
    if (!NSClassFromString(@"PHPickerViewController")) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = self;
        [self.overlayWindow.rootViewController presentViewController:picker animated:YES completion:nil];
    });
}

- (BOOL)providerLooksLikeVideo:(NSItemProvider *)provider {
    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) return YES;
    if ([provider hasItemConformingToTypeIdentifier:@"public.audiovisual-content"]) return YES;
    for (NSString *tid in provider.registeredTypeIdentifiers) {
        if ([tid containsString:@"movie"] || [tid containsString:@"video"] || [tid containsString:@"mpeg-4"] || [tid containsString:@"quicktime"]) return YES;
    }
    return NO;
}

- (void)loadVideoFromProvider:(NSItemProvider *)provider candidates:(NSArray<NSString *> *)cands slot:(NSInteger)slot {
    __weak typeof(self) weakSelf = self;
    NSString *tid = cands.firstObject;
    [provider loadFileRepresentationForTypeIdentifier:tid completionHandler:^(NSURL *url, NSError *error) {
        VCamFloatingBall *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!url) {
            if (cands.count > 1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf loadVideoFromProvider:provider candidates:[cands subarrayWithRange:NSMakeRange(1, cands.count - 1)] slot:slot];
                });
            }
            return;
        }
        [strongSelf savePickedVideoAt:url toSlot:slot];
    }];
}

- (void)savePickedVideoAt:(NSURL *)srcUrl toSlot:(NSInteger)slot {
    NSString *dest = (slot == 0) ? @"/var/mobile/Media/DCIM/vcam.mp4" : [NSString stringWithFormat:@"/var/mobile/Media/DCIM/6/%ld.mp4", (long)slot];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dest.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:dest error:nil];
    NSError *copyErr = nil;
    BOOL ok = [fm copyItemAtPath:srcUrl.path toPath:dest error:&copyErr];

    if (ok && slot == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [VCamNotify setActivePlaybackPath:dest];
            [self resetOrientationState];
            if (![VCamNotify isPlistEnabled]) {
                [VCamNotify setPlistEnabled:YES];
                [[VCamCore sharedInstance] setEnabled:YES];
                [self updateReplaceButtonVisual];
            }
            [self toast:@"视频已载入并播放"];
        });
    } else if (ok) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self toast:[NSString stringWithFormat:@"已保存至预设视频%d", (int)slot]];
        });
    }
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;
    NSItemProvider *provider = results.firstObject.itemProvider;
    NSInteger slot = _pickerSlot;
    if (![self providerLooksLikeVideo:provider]) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            VCamFloatingBall *strongSelf = weakSelf;
            if (!strongSelf) return;
            if ([strongSelf providerLooksLikeVideo:provider]) {
                [strongSelf startVideoLoadFromProvider:provider slot:slot];
            } else {
                [self toast:@"不支持的文件类型"];
            }
        });
        return;
    }
    [self startVideoLoadFromProvider:provider slot:slot];
}

- (void)startVideoLoadFromProvider:(NSItemProvider *)provider slot:(NSInteger)slot {
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) [cands addObject:@"public.movie"];
    for (NSString *tid in provider.registeredTypeIdentifiers) {
        if ([cands containsObject:tid]) continue;
        if ([tid containsString:@"movie"] || [tid containsString:@"video"] || [tid containsString:@"mpeg-4"] || [tid containsString:@"quicktime"]) [cands addObject:tid];
    }
    if (cands.count == 0) [cands addObject:@"public.movie"];
    [self loadVideoFromProvider:provider candidates:cands slot:slot];
}

#pragma mark - 频道链接
- (void)channelLinkTapped {
    [self haptic:UIImpactFeedbackStyleLight];
    NSURL *url = [NSURL URLWithString:VCS(tglink)];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)appDidBecomeActive:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_isFloating && self.overlayWindow && self.overlayWindow.windowScene == nil) {
            [self.overlayWindow removeFromSuperview];
            self.overlayWindow = nil;
            [self createOverlayWindow];
        }
    });
}

@end
