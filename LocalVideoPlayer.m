- (void)loadImageFile:(NSString *)path completion:(void(^)(BOOL success, NSError *error))completion {
    vcam_player_log([NSString stringWithFormat:@"[vcam] Loading image: %@", path]);

    [self stopDecodingThread];
    [self clearFrameQueue];

    _currentVideoPath = path;
    _mediaType = VCamMediaTypeImage;

    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nil);
    if (!source) {
        vcam_player_log(@"[vcam] Image file not found");
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:6 userInfo:@{NSLocalizedDescriptionKey:@"Image not found"}]);
        return;
    }

    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil);
    CFRelease(source);
    if (!cgImage) {
        vcam_player_log(@"Failed to decode image");
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:7 userInfo:@{NSLocalizedDescriptionKey:@"Decode failed"}]);
        return;
    }

    // 宽高偶对齐（YUV 420 要求偶数尺寸）
    size_t width = CGImageGetWidth(cgImage) & ~(size_t)1;
    size_t height = CGImageGetHeight(cgImage) & ~(size_t)1;
    if (width < 2 || height < 2) {
        vcam_player_log(@"[vcam] Image too small");
        CGImageRelease(cgImage);
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:9 userInfo:@{NSLocalizedDescriptionKey:@"Image too small"}]);
        return;
    }

    // ===== 1. 解码到临时 BGRA =====
    CVPixelBufferRef bgraBuf = NULL;
    OSStatus status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                           kCVPixelFormatType_32BGRA, NULL, &bgraBuf);
    if (status != noErr || !bgraBuf) {
        vcam_player_log([NSString stringWithFormat:@"[vcam] BGRA CVPixelBufferCreate failed: %d", (int)status]);
        CGImageRelease(cgImage);
        if (completion) completion(NO, [NSError errorWithDomain:@"VCam" code:8 userInfo:@{NSLocalizedDescriptionKey:@"Buffer create failed"}]);
        return;
    }

    CVPixelBufferLockBaseAddress(bgraBuf, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        CVPixelBufferGetBaseAddress(bgraBuf),
        width, height, 8, CVPixelBufferGetBytesPerRow(bgraBuf),
        cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    );
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cgImage);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(bgraBuf, 0);
    CGImageRelease(cgImage);

    // ===== 2. BGRA → 420f（下游预渲染需要双平面 YUV） =====
    CVPixelBufferRef yuvBuf = NULL;
    if (_gpuProcessor) {
        yuvBuf = [_gpuProcessor convertFormat:bgraBuf toFormat:(OSType)'420f'];
    }
    if (yuvBuf) {
        CVPixelBufferRelease(bgraBuf);
    } else {
        // convertFormat 失败：保留 BGRA 直通（下游会走旋转/镜像，但方向/缩放/打光不生效）
        // 这样至少不会黑屏，作为兜底
        yuvBuf = bgraBuf;
        vcam_player_log(@"[vcam] convertFormat BGRA→420f failed, keep BGRA (transform/directional/zoom/light will be skipped)");
    }

    // ===== 3. 缓存 + 入队（420f） =====
    if (_cachedImageBuffer) {
        CVPixelBufferRelease(_cachedImageBuffer);
    }
    _cachedImageBuffer = CVPixelBufferRetain(yuvBuf);

    [_frameQueue enqueuePixelBuffer:yuvBuf];
    CVPixelBufferRelease(yuvBuf);

    _videoWidth = width;
    _videoHeight = height;
    vcam_player_log([NSString stringWithFormat:@"[vcam] Image loaded: %@ (%zux%zu, 420f=%d)",
                     path, width, height, (_gpuProcessor && yuvBuf) ? 1 : 0]);

    if (completion) completion(YES, nil);
}
