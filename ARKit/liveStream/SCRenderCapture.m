/*
  SCRenderCapture.m
  glReadPixels(BGRA) → CVPixelBuffer → CMSampleBuffer（竖向翻转）。
  后续可换成 CVOpenGLESTextureCache / FBO 共享，避免 readback。
*/

#import "SCRenderCapture.h"
#import "SCRenderer.h"
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface SCRenderCapture ()
@property (nonatomic, weak) SCRenderer *renderer;
@property (nonatomic, assign) BOOL capturing;
@property (nonatomic, assign) CGSize captureSize;
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, assign) CFTimeInterval lastCaptureTime;
@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic, assign) int poolWidth;
@property (nonatomic, assign) int poolHeight;
@property (nonatomic, assign) CMFormatDescriptionRef formatDescription;
@end

@implementation SCRenderCapture

- (instancetype)init {
    self = [super init];
    if (self) {
        _maxFPS = 30;
        _outputSize = CGSizeZero;
    }
    return self;
}

- (void)dealloc {
    [self stopCapture];
    [self detachFromRenderer];
    [self destroyPool];
}

- (void)attachToRenderer:(SCRenderer *)renderer {
    if (self.renderer == renderer) return;
    [self detachFromRenderer];
    self.renderer = renderer;
    renderer.renderCapture = self;
}

- (void)detachFromRenderer {
    if (self.renderer.renderCapture == self) {
        self.renderer.renderCapture = nil;
    }
    self.renderer = nil;
}

- (void)startCapture {
    self.capturing = YES;
    self.startTime = CACurrentMediaTime();
    self.lastCaptureTime = 0;
}

- (void)stopCapture {
    self.capturing = NO;
}

- (void)destroyPool {
    if (self.formatDescription) {
        CFRelease(self.formatDescription);
        self.formatDescription = NULL;
    }
    if (self.pixelBufferPool) {
        CVPixelBufferPoolRelease(self.pixelBufferPool);
        self.pixelBufferPool = NULL;
    }
    self.poolWidth = 0;
    self.poolHeight = 0;
}

- (BOOL)ensurePoolWidth:(int)width height:(int)height {
    // H.264 常见要求偶数边长
    width &= ~1;
    height &= ~1;
    if (width < 2 || height < 2) return NO;
    if (self.pixelBufferPool && self.poolWidth == width && self.poolHeight == height) {
        return YES;
    }
    [self destroyPool];

    NSDictionary *poolAttrs = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
    };
    NSDictionary *pbAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferBytesPerRowAlignmentKey: @64,
    };
    CVReturn cr = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                          (__bridge CFDictionaryRef)poolAttrs,
                                          (__bridge CFDictionaryRef)pbAttrs,
                                          &_pixelBufferPool);
    if (cr != kCVReturnSuccess || !self.pixelBufferPool) {
        NSLog(@"[SCRenderCapture] CVPixelBufferPoolCreate failed: %d", (int)cr);
        return NO;
    }
    self.poolWidth = width;
    self.poolHeight = height;
    self.captureSize = CGSizeMake(width, height);
    return YES;
}

- (void)onFramebufferReadyWidth:(int)width height:(int)height {
    if (!self.capturing) return;
    if (![self.delegate respondsToSelector:@selector(didOutputSampleBuffer:)]) return;

    NSInteger fps = self.maxFPS > 0 ? self.maxFPS : 30;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval minInterval = 1.0 / (CFTimeInterval)fps;
    if (self.lastCaptureTime > 0 && (now - self.lastCaptureTime) < minInterval) {
        return;
    }

    int srcW = width & ~1;
    int srcH = height & ~1;
    if (srcW < 2 || srcH < 2) return;

    int outW = srcW;
    int outH = srcH;
    if (self.outputSize.width >= 2 && self.outputSize.height >= 2) {
        outW = ((int)self.outputSize.width) & ~1;
        outH = ((int)self.outputSize.height) & ~1;
    }
    if (![self ensurePoolWidth:outW height:outH]) return;

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn cr = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pixelBufferPool, &pixelBuffer);
    if (cr != kCVReturnSuccess || !pixelBuffer) return;

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bpr = CVPixelBufferGetBytesPerRow(pixelBuffer);
    const int w = self.poolWidth;
    const int h = self.poolHeight;
    if (!base || bpr < (size_t)w * 4) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    size_t srcRowBytes = (size_t)srcW * 4;
    uint8_t *tmp = (uint8_t *)malloc(srcRowBytes * (size_t)srcH);
    if (!tmp) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    while (glGetError() != GL_NO_ERROR) {}
    glReadPixels(0, 0, srcW, srcH, GL_BGRA, GL_UNSIGNED_BYTE, tmp);
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        glReadPixels(0, 0, srcW, srcH, GL_RGBA, GL_UNSIGNED_BYTE, tmp);
        for (int y = 0; y < srcH; ++y) {
            uint8_t *row = tmp + (size_t)y * srcRowBytes;
            for (int x = 0; x < srcW; ++x) {
                uint8_t *p = row + (size_t)x * 4;
                uint8_t r = p[0], b = p[2];
                p[0] = b;
                p[2] = r;
            }
        }
    }

    // GL 原点左下 → 竖翻；等比缩放到 output（letterbox），避免比例不一致被拉胖
    memset(base, 0, bpr * (size_t)h);
    float scale = MIN((float)w / (float)srcW, (float)h / (float)srcH);
    int dw = MAX(2, ((int)(srcW * scale)) & ~1);
    int dh = MAX(2, ((int)(srcH * scale)) & ~1);
    int ox = (w - dw) / 2;
    int oy = (h - dh) / 2;
    for (int y = 0; y < dh; ++y) {
        int sy = (srcH - 1) - (int)((int64_t)y * srcH / dh);
        if (sy < 0) sy = 0;
        if (sy >= srcH) sy = srcH - 1;
        const uint8_t *srcRow = tmp + (size_t)sy * srcRowBytes;
        uint8_t *dst = base + (size_t)(oy + y) * bpr + (size_t)ox * 4;
        if (dw == srcW) {
            memcpy(dst, srcRow, srcRowBytes);
        } else {
            for (int x = 0; x < dw; ++x) {
                int sx = (int)((int64_t)x * srcW / dw);
                if (sx >= srcW) sx = srcW - 1;
                memcpy(dst + (size_t)x * 4, srcRow + (size_t)sx * 4, 4);
            }
        }
    }
    free(tmp);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    if (!self.formatDescription) {
        OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                   pixelBuffer,
                                                                   &_formatDescription);
        if (st != noErr || !self.formatDescription) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
    }

    CMTime pts = CMTimeMakeWithSeconds(now - self.startTime, 1000000);
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, (int32_t)fps),
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus st = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                                     pixelBuffer,
                                                     true,
                                                     NULL,
                                                     NULL,
                                                     self.formatDescription,
                                                     &timing,
                                                     &sampleBuffer);
    CVPixelBufferRelease(pixelBuffer);
    if (st != noErr || !sampleBuffer) return;

    self.lastCaptureTime = now;
    [self.delegate didOutputSampleBuffer:sampleBuffer];
    static int sCap = 0;
    if ((++sCap % 30) == 1) {
        NSLog(@"[SCRenderCapture] → delegate didOutput #%d %dx%d (fb %dx%d)", sCap, w, h, srcW, srcH);
    }
    CFRelease(sampleBuffer);
}

@end
