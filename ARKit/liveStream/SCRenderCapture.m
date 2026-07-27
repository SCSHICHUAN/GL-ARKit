/*
  SCRenderCapture.m
  CVOpenGLESTextureCache：场景直接渲到 CVPixelBuffer，再送 H264（无全屏 glReadPixels）。
*/

#import "SCRenderCapture.h"
#import "SCRenderer.h"
#import <OpenGLES/EAGL.h>
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
@property (nonatomic, assign) CVOpenGLESTextureCacheRef textureCache;
@property (nonatomic, assign) GLuint captureFBO;
@property (nonatomic, assign) GLuint depthRBO;
@property (nonatomic, assign) int poolWidth;
@property (nonatomic, assign) int poolHeight;
@property (nonatomic, assign) CMFormatDescriptionRef formatDescription;
@property (nonatomic, assign) CVPixelBufferRef pendingPixelBuffer;
@property (nonatomic, assign) CVOpenGLESTextureRef pendingTexture;
@property (nonatomic, assign) CFTimeInterval pendingPTSSeconds;
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
    // GL 资源需在 context 下释放；若仍残留则仅释放 CPU 侧
    [self destroyCPUResources];
}

- (int)captureWidth { return self.poolWidth; }
- (int)captureHeight { return self.poolHeight; }

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
    [self abandonPendingFrame];
}

- (void)destroyCPUResources {
    [self abandonPendingFrame];
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

- (void)destroyGLResources {
    if (self.captureFBO) {
        glBindFramebuffer(GL_FRAMEBUFFER, self.captureFBO);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }
    [self abandonPendingFrame];
    if (self.captureFBO) {
        glDeleteFramebuffers(1, &_captureFBO);
        self.captureFBO = 0;
    }
    if (self.depthRBO) {
        glDeleteRenderbuffers(1, &_depthRBO);
        self.depthRBO = 0;
    }
    if (self.textureCache) {
        CFRelease(self.textureCache);
        self.textureCache = NULL;
    }
    [self destroyCPUResources];
}

- (void)abandonPendingFrame {
    if (self.pendingTexture) {
        CFRelease(self.pendingTexture);
        self.pendingTexture = NULL;
    }
    if (self.pendingPixelBuffer) {
        CVPixelBufferRelease(self.pendingPixelBuffer);
        self.pendingPixelBuffer = NULL;
    }
}

- (BOOL)ensurePoolWidth:(int)width height:(int)height {
    width &= ~1;
    height &= ~1;
    if (width < 2 || height < 2) return NO;
    if (self.pixelBufferPool && self.poolWidth == width && self.poolHeight == height) {
        return YES;
    }
    [self destroyCPUResources];

    NSDictionary *poolAttrs = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
    };
    NSDictionary *pbAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
        (id)kCVPixelBufferBytesPerRowAlignmentKey: @64,
    };
    CVReturn cr = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                          (__bridge CFDictionaryRef)poolAttrs,
                                          (__bridge CFDictionaryRef)pbAttrs,
                                          &_pixelBufferPool);
    if (cr != kCVReturnSuccess || !self.pixelBufferPool) {
        NSLog(@"[SCRenderCapture] pool create failed: %d", (int)cr);
        return NO;
    }
    self.poolWidth = width;
    self.poolHeight = height;
    self.captureSize = CGSizeMake(width, height);
    return YES;
}

- (BOOL)ensureTextureCache:(EAGLContext *)context {
    if (self.textureCache) return YES;
    if (!context) return NO;
    CVReturn cr = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL,
                                               context, NULL, &_textureCache);
    if (cr != kCVReturnSuccess || !self.textureCache) {
        NSLog(@"[SCRenderCapture] texture cache failed: %d", (int)cr);
        return NO;
    }
    return YES;
}

- (BOOL)ensureCaptureFBO {
    const int w = self.poolWidth;
    const int h = self.poolHeight;
    if (!self.captureFBO) {
        glGenFramebuffers(1, &_captureFBO);
    }
    if (!self.depthRBO) {
        glGenRenderbuffers(1, &_depthRBO);
    }
    glBindRenderbuffer(GL_RENDERBUFFER, self.depthRBO);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, w, h);
    return self.captureFBO != 0 && self.depthRBO != 0;
}

- (BOOL)beginEncodePassWithContext:(EAGLContext *)context {
    if (!self.capturing) return NO;
    if (![self.delegate respondsToSelector:@selector(didOutputSampleBuffer:)]) return NO;

    NSInteger fps = self.maxFPS > 0 ? self.maxFPS : 30;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval minInterval = 1.0 / (CFTimeInterval)fps;
    if (self.lastCaptureTime > 0 && (now - self.lastCaptureTime) < minInterval) {
        return NO;
    }

    int outW = 0, outH = 0;
    if (self.outputSize.width >= 2 && self.outputSize.height >= 2) {
        outW = ((int)self.outputSize.width) & ~1;
        outH = ((int)self.outputSize.height) & ~1;
    }
    if (outW < 2 || outH < 2) return NO;

    if (![self ensurePoolWidth:outW height:outH]) return NO;
    if (![self ensureTextureCache:context]) return NO;
    if (![self ensureCaptureFBO]) return NO;

    [self abandonPendingFrame];

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn cr = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pixelBufferPool, &pixelBuffer);
    if (cr != kCVReturnSuccess || !pixelBuffer) return NO;

    CVOpenGLESTextureRef texture = NULL;
    cr = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                      self.textureCache,
                                                      pixelBuffer,
                                                      NULL,
                                                      GL_TEXTURE_2D,
                                                      GL_RGBA,
                                                      outW,
                                                      outH,
                                                      GL_BGRA,
                                                      GL_UNSIGNED_BYTE,
                                                      0,
                                                      &texture);
    if (cr != kCVReturnSuccess || !texture) {
        NSLog(@"[SCRenderCapture] CreateTextureFromImage failed: %d", (int)cr);
        CVPixelBufferRelease(pixelBuffer);
        return NO;
    }

    GLuint texName = CVOpenGLESTextureGetName(texture);
    GLenum target = CVOpenGLESTextureGetTarget(texture);
    glBindTexture(target, texName);
    glTexParameteri(target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glBindFramebuffer(GL_FRAMEBUFFER, self.captureFBO);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, target, texName, 0);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, self.depthRBO);

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"[SCRenderCapture] incomplete FBO: 0x%x", status);
        CFRelease(texture);
        CVPixelBufferRelease(pixelBuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        return NO;
    }

    glViewport(0, 0, outW, outH);

    self.pendingPixelBuffer = pixelBuffer;
    self.pendingTexture = texture;
    self.pendingPTSSeconds = now - self.startTime;
    return YES;
}

- (void)endEncodePass {
    if (!self.pendingPixelBuffer || !self.pendingTexture) {
        [self abandonPendingFrame];
        return;
    }

    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glFlush();
    if (self.textureCache) {
        CVOpenGLESTextureCacheFlush(self.textureCache, 0);
    }

    CFRelease(self.pendingTexture);
    self.pendingTexture = NULL;

    CVPixelBufferRef pixelBuffer = self.pendingPixelBuffer;
    self.pendingPixelBuffer = NULL;

    if (!self.formatDescription) {
        OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                   pixelBuffer,
                                                                   &_formatDescription);
        if (st != noErr || !self.formatDescription) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
    }

    NSInteger fps = self.maxFPS > 0 ? self.maxFPS : 30;
    CMTime pts = CMTimeMakeWithSeconds(self.pendingPTSSeconds, 1000000);
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

    self.lastCaptureTime = CACurrentMediaTime();
    [self.delegate didOutputSampleBuffer:sampleBuffer];
    static int sCap = 0;
    if ((++sCap % 30) == 1) {
        NSLog(@"[SCRenderCapture] textureCache → #%d %dx%d", sCap, self.poolWidth, self.poolHeight);
    }
    CFRelease(sampleBuffer);
}

@end
