        // 彩色注入模式 / 人脸检测开关同步（2026-10-30 新增）
        static NSInteger lastInjectMode = -1;
        static NSInteger lastFaceDetect = -1;
        NSInteger plistInjectMode = [pl[@"injectMode"] integerValue];
        NSInteger plistFaceDetect = pl[@"faceDetect"] ? ([pl[@"faceDetect"] boolValue] ? 1 : 0) : 1;
        if (plistInjectMode != lastInjectMode) {
            strongSelf.gpuProcessor.injectMode = (int)plistInjectMode;
            lastInjectMode = plistInjectMode;
            vcam_core_log([NSString stringWithFormat:@"[vcam] injectMode synced: %ld", (long)plistInjectMode]);
        }
        if (plistFaceDetect != lastFaceDetect) {
            strongSelf.gpuProcessor.faceDetectEnabled = (plistFaceDetect == 1);
            lastFaceDetect = plistFaceDetect;
            vcam_core_log([NSString stringWithFormat:@"[vcam] faceDetect synced: %d", (int)plistFaceDetect]);
        }
