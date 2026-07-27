/*
  SCRenderCapture.m
  CVPixelBufferPool + CVOpenGLESTextureCache：
  begin → 渲到 4x MSAA FBO；end → blit resolve 进 CV 纹理 → CMSampleBuffer → H264。
  无全屏 glReadPixels，避免 GPU–CPU 同步卡顿。
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
@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic, assign) CVOpenGLESTextureCacheRef textureCache;
/// 多重采样绘制目标
@property (nonatomic, assign) GLuint msaaFBO;
@property (nonatomic, assign) GLuint msaaColorRBO;
@property (nonatomic, assign) GLuint msaaDepthRBO;
@property (nonatomic, assign) int msaaSamples;
@property (nonatomic, assign) int msaaWidth;
@property (nonatomic, assign) int msaaHeight;
/// resolve：颜色 = CVOpenGLESTexture（进编码）
@property (nonatomic, assign) GLuint resolveFBO;
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
        _msaaSamples = 4;
    }
    return self;
}

- (void)dealloc {
    [self stopCapture];
    [self detachFromRenderer];
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

- (void)destroyMSAABuffers {
    if (self.msaaFBO) {
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDeleteFramebuffers(1, &_msaaFBO);
        self.msaaFBO = 0;
    }
    if (self.msaaColorRBO) {
        glDeleteRenderbuffers(1, &_msaaColorRBO);
        self.msaaColorRBO = 0;
    }
    if (self.msaaDepthRBO) {
        glDeleteRenderbuffers(1, &_msaaDepthRBO);
        self.msaaDepthRBO = 0;
    }
    self.msaaWidth = 0;
    self.msaaHeight = 0;
}

- (void)destroyGLResources {
    [self abandonPendingFrame];
    if (self.resolveFBO) {
        glBindFramebuffer(GL_FRAMEBUFFER, self.resolveFBO);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDeleteFramebuffers(1, &_resolveFBO);
        self.resolveFBO = 0;
    }
    [self destroyMSAABuffers];
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

- (BOOL)ensureMSAAWidth:(int)w height:(int)h {
    if (self.msaaFBO && self.msaaWidth == w && self.msaaHeight == h &&
        self.msaaColorRBO && self.msaaDepthRBO) {
        return YES;
    }
    [self destroyMSAABuffers];

    GLint maxSamples = 0;
    glGetIntegerv(GL_MAX_SAMPLES, &maxSamples);
    int samples = 4;
    if (maxSamples > 0 && samples > maxSamples) samples = (int)maxSamples;
    if (samples < 1) samples = 1;
    self.msaaSamples = samples;

    glGenFramebuffers(1, &_msaaFBO);
    glGenRenderbuffers(1, &_msaaColorRBO);
    glGenRenderbuffers(1, &_msaaDepthRBO);

    glBindRenderbuffer(GL_RENDERBUFFER, self.msaaColorRBO);
    glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_RGBA8, w, h);

    glBindRenderbuffer(GL_RENDERBUFFER, self.msaaDepthRBO);
    glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_DEPTH_COMPONENT24, w, h);

    glBindFramebuffer(GL_FRAMEBUFFER, self.msaaFBO);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, self.msaaColorRBO);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, self.msaaDepthRBO);

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"[SCRenderCapture] MSAA FBO incomplete: 0x%x samples=%d", status, samples);
        [self destroyMSAABuffers];
        return NO;
    }

    self.msaaWidth = w;
    self.msaaHeight = h;
    NSLog(@"[SCRenderCapture] MSAA %dx%d x%d", w, h, samples);
    return YES;
}

- (BOOL)ensureResolveFBO {
    if (!self.resolveFBO) {
        glGenFramebuffers(1, &_resolveFBO);
    }
    return self.resolveFBO != 0;
}

- (BOOL)beginEncodePassWithContext:(EAGLContext *)context {
    if (!self.capturing) return NO;
    if (![self.delegate respondsToSelector:@selector(didOutputSampleBuffer:)]) return NO;

    CFTimeInterval now = CACurrentMediaTime();

    int outW = 0, outH = 0;
    if (self.outputSize.width >= 2 && self.outputSize.height >= 2) {
        outW = ((int)self.outputSize.width) & ~1;
        outH = ((int)self.outputSize.height) & ~1;
    }
    if (outW < 2 || outH < 2) return NO;

    if (![self ensurePoolWidth:outW height:outH]) return NO;
    if (![self ensureTextureCache:context]) return NO;
    if (![self ensureMSAAWidth:outW height:outH]) return NO;
    if (![self ensureResolveFBO]) return NO;

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

    // resolve 目标：CV 纹理（本帧只 blit，不直接画）
    glBindFramebuffer(GL_FRAMEBUFFER, self.resolveFBO);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, target, texName, 0);

    // 绘制到 MSAA
    glBindFramebuffer(GL_FRAMEBUFFER, self.msaaFBO);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"[SCRenderCapture] MSAA bind incomplete: 0x%x", status);
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

    const int w = self.poolWidth;
    const int h = self.poolHeight;

    // MSAA → 单采样 CV 纹理（ES3：multisample blit 须 NEAREST）
    glBindFramebuffer(GL_READ_FRAMEBUFFER, self.msaaFBO);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, self.resolveFBO);
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);

    glBindFramebuffer(GL_FRAMEBUFFER, self.resolveFBO);
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

    [self.delegate didOutputSampleBuffer:sampleBuffer];
#ifdef DEBUG
    static int sCap = 0;
    if ((++sCap % 120) == 1) {
        NSLog(@"[SCRenderCapture] → #%d %dx%d MSAAx%d (maxFPS=%ld)",
              sCap, self.poolWidth, self.poolHeight, self.msaaSamples, (long)self.maxFPS);
    }
#endif
    CFRelease(sampleBuffer);
}

@end
