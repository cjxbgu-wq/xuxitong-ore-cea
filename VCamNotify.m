#pragma mark - 彩色注入模式 / 人脸检测开关（2026-10-30 新增）

+ (int)plistInjectMode {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"injectMode"];
    int mode = v ? [v intValue] : 0;
    if (mode < 0 || mode > 1) mode = 0;
    return mode;
}

+ (void)setPlistInjectMode:(int)mode {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"injectMode"] = @(mode);
    [dict writeToFile:VCamPlistPath atomically:YES];
}

+ (BOOL)plistFaceDetect {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath];
    NSNumber *v = dict[@"faceDetect"];
    return v ? [v boolValue] : YES;  // 缺失时默认 YES
}

+ (void)setPlistFaceDetect:(BOOL)on {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:
        [NSDictionary dictionaryWithContentsOfFile:VCamPlistPath] ?: @{}];
    dict[@"faceDetect"] = @(on);
    [dict writeToFile:VCamPlistPath atomically:YES];
}
