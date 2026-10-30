// 彩色注入模式 / 人脸检测开关（2026-10-30 新增）
// injectMode: 0=人脸轮廓 1=椭圆
// faceDetect: YES=Vision 人脸检测（默认），NO=原 Y/CbCr 光斑
+ (int)plistInjectMode;
+ (void)setPlistInjectMode:(int)mode;
+ (BOOL)plistFaceDetect;
+ (void)setPlistFaceDetect:(BOOL)on;
