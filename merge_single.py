#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""merge_single.py — 项目1全部源文件合并成单文件 Tweak.m

用法：把此脚本放到项目1源码目录（所有 .h/.m 同级），运行
    python3 merge_single.py
生成 Tweak.m，覆盖仓库里的同名文件；仓库里其他 .m 删除；Makefile 保持原样即可编译。

脚本自动处理：
  1. 依赖顺序拼接（VCamStr.h → ... → Tweak.m）
  2. 删除项目内 #import "xxx.h" 和 include guard
  3. 重名 static 函数（vcam_log_enabled ×7）自动改名加后缀
  4. Tweak.m 的 VCamFloatingBall.h import 改为内联声明
  5. VCamFloatingBall.m 的彩色注入 3 处修复
"""
import os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "Tweak.m")

ORDER = [
    "VCamStr.h",
    "ball_icon.h",
    "btn_icons.h",
    "NSQueue.h", "NSQueue.m",
    "VCamNotify.h", "VCamNotify.m",
    "GPUImageProcessor.h", "GPUImageProcessor.m",
    "LocalVideoPlayer.h", "LocalVideoPlayer.m",
    "VCamCore.h", "VCamCore.m",
    "VCamFloatingBall.h", "VCamFloatingBall.m",
    "Tweak.m",
]

# 彩色注入修复：3 处替换（old -> new）
FLOATING_BALL_FIXES = [
    # 1. pickColorTapped：先清色再开模式，关闭时双清
    ('''    BOOL on = ![VCamNotify plistLightEnabled];
    [VCamNotify setPlistLightEnabled:on];
    if (on) {
        [VCamNotify setPlistLightColor:0];
        _lastDetectedColor = 0;
        _pickSkipCount = 3;
        [self showPickDot];
        [self startColorPickup];
        [_pickColorBtn setTitle:@"屏幕取色: 开" forState:UIControlStateNormal];
        vcam_ball_log(@"[vcam][light] screen color pickup ON");
    } else {
        [self stopColorPickup];
        [self hidePickDot];
        [VCamNotify setPlistLightColor:0];
        _lastDetectedColor = 0;
        [self updateColorPreview:0];
        [_pickColorBtn setTitle:@"屏幕取色: 关" forState:UIControlStateNormal];
        vcam_ball_log(@"[vcam][light] screen color pickup OFF");
    }''',
     '''    BOOL on = ![VCamNotify plistLightEnabled];
    if (on) {
        [VCamNotify setPlistLightColor:0];
        [VCamNotify setPlistLightEnabled:YES];
        _lastDetectedColor = 0;
        _pickSkipCount = 1;
        [self showPickDot];
        [self startColorPickup];
        [_pickColorBtn setTitle:@"屏幕取色: 开" forState:UIControlStateNormal];
        [self updateColorPreview:0];
        vcam_ball_log(@"[vcam][light] screen color pickup ON (no injection until color detected)");
    } else {
        [self stopColorPickup];
        [self hidePickDot];
        [VCamNotify setPlistLightColor:0];
        [VCamNotify setPlistLightEnabled:NO];
        _lastDetectedColor = 0;
        [self updateColorPreview:0];
        [_pickColorBtn setTitle:@"屏幕取色: 关" forState:UIControlStateNormal];
        vcam_ball_log(@"[vcam][light] screen color pickup OFF");
    }'''),

    # 2. createPanel 恢复段：强制清色，重新吸
    ('''    if ([VCamNotify plistLightEnabled]) {
        _lastDetectedColor = [VCamNotify plistLightColor];
        _pickSkipCount = 3;
        [self showPickDot];
        [self startColorPickup];
        [_pickColorBtn setTitle:@"屏幕取色: 开" forState:UIControlStateNormal];
        [self updateColorPreview:_lastDetectedColor];
    }''',
     '''    if ([VCamNotify plistLightEnabled]) {
        [VCamNotify setPlistLightColor:0];
        _lastDetectedColor = 0;
        _pickSkipCount = 1;
        [self showPickDot];
        [self startColorPickup];
        [_pickColorBtn setTitle:@"屏幕取色: 开" forState:UIControlStateNormal];
        [self updateColorPreview:0];
    }'''),

    # 3. pickDotDragged 松手：立即取色
    ('''    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _pickSuspended = NO;
        _pickSkipCount = 3;
        gVcamPick.px = c.x;''',
     '''    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _pickSuspended = NO;
        _pickSkipCount = 1;
        gVcamPick.px = c.x;'''),
]

def strip_imports_and_guards(text):
    out = []
    for ln in text.split("\n"):
        s = ln.strip()
        if re.match(r'#\s*import\s+"', s):
            continue
        if re.match(r'#\s*include\s+"', s):
            continue
        if re.match(r'#\s*ifndef\s+\w+_H\s*$', s):
            continue
        if re.match(r'#\s*define\s+\w+_H\s*$', s):
            continue
        if re.match(r'#\s*endif\s*//\s*\w+_H\s*$', s):
            continue
        out.append(ln)
    return "\n".join(out)

def apply_fb_fixes(text):
    for old, new in FLOATING_BALL_FIXES:
        if old in text:
            text = text.replace(old, new, 1)
        else:
            print("WARN: FLOATING_BALL fix 未命中（源版本不一致）")
    return text

def apply_tweak_fixes(text):
    text = re.sub(r'^#import "VCamFloatingBall\.h"\n', '', text, flags=re.MULTILINE)
    if '#import "VCamCore.h"' in text:
        inline = ('#import "VCamCore.h"\n'
                  '#import "VCamNotify.h"\n'
                  '\n'
                  '@interface VCamFloatingBall : NSObject\n'
                  '+ (instancetype)sharedInstance;\n'
                  '- (void)showFloatingBall;\n'
                  '- (void)hideFloatingBall;\n'
                  '@end\n')
        text = text.replace('#import "VCamCore.h"\n#import "VCamNotify.h"\n', inline, 1)
    return text

def rename_duplicate_statics(files):
    def_re = re.compile(
        r'static\s+(?:BOOL|int|void|double|uint32_t|NSString\s*\*|char|const\s+[\w\s\*]+|struct\s+\w+|CGImageRef|CVPixelBufferRef|VTPixelTransferSessionRef|VTPixelRotationSessionRef|OSStatus|kern_return_t|mach_port_t|CFStringRef)\s+[\*]?(\w+)\s*\(',
        re.MULTILINE)
    seen = {}
    for _, t in files:
        for m in def_re.finditer(t):
            seen[m.group(1)] = seen.get(m.group(1), 0) + 1
    dup = {n for n, c in seen.items() if c > 1}
    if not dup:
        return files
    counter = {}
    result = []
    for fname, t in files:
        local = set()
        def repl(m):
            n = m.group(1)
            if n not in dup:
                return m.group(0)
            counter[n] = counter.get(n, 0) + 1
            if counter[n] == 1:
                return m.group(0)
            new = f"{n}_{counter[n]}"
            local.add((n, new))
            return m.group(0).replace(n, new, 1)
        new_t = def_re.sub(repl, t)
        for orig, new in local:
            new_t = re.sub(r'\b%s\b' % re.escape(orig), new, new_t)
        result.append((fname, new_t))
    return result

def main():
    files = []
    for fname in ORDER:
        p = os.path.join(ROOT, fname)
        if not os.path.exists(p):
            print(f"WARN: {fname} 缺失，跳过")
            continue
        text = open(p, encoding="utf-8").read()
        text = strip_imports_and_guards(text)
        if fname == "VCamFloatingBall.m":
            text = apply_fb_fixes(text)
        elif fname == "Tweak.m":
            text = apply_tweak_fixes(text)
        files.append((fname, text))
    if not files:
        sys.exit("ERROR: 没有找到任何源文件，请检查脚本目录")
    files = rename_duplicate_statics(files)

    header = '''//
//  Tweak.m —— 项目1全部源码合并单文件（由 merge_single.py 生成，勿手改）
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <PhotosUI/PhotosUI.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <signal.h>
#import <execinfo.h>
#import <fcntl.h>
#import <unistd.h>
#import <time.h>
#import <string.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>

'''
    parts = [header]
    for fname, t in files:
        parts.append(f"\n// ==================== {fname} ====================\n")
        parts.append(t)
        parts.append("\n")
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(parts))
    print(f"OK -> {OUT} ({os.path.getsize(OUT)} bytes, {sum(len(p) for p in parts)} chars)")

if __name__ == "__main__":
    main()
