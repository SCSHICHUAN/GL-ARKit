/*
  SCHostVideoPlane.m
  CVOpenGLESTextureCache：NV12 双平面 → GL_TEXTURE_2D。
*/

#import "SCHostVideoPlane.h"
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/glext.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface SCHostVideoPlane ()
@property (nonatomic, assign) CVOpenGLESTextureCacheRef textureCache;
@property (nonatomic, assign) CVOpenGLESTextureRef yTexture;
@property (nonatomic, assign) CVOpenGLESTextureRef uvTexture;
@property (nonatomic, assign) CVPixelBufferRef retainedBuffer;
@property (nonatomic, assign) GLuint yTextureName;
@property (nonatomic, assign) GLuint uvTextureName;
@property (nonatomic, assign) BOOL hasTexture;
@property (nonatomic, assign) CGImagePropertyOrientation orientation;
@end

@implementation SCHostVideoPlane

- (instancetype)init {
    self = [super init];
    if (self) {
        _mirrorX = YES;
        _orientation = kCGImagePropertyOrientationUp;
    }
    return self;
}

- (void)dealloc {
    [self destroyGLResources];
}

- (void)releaseTextures {
    if (self.yTexture) {
        CFRelease(self.yTexture);
        self.yTexture = NULL;
    }
    if (self.uvTexture) {
        CFRelease(self.uvTexture);
        self.uvTexture = NULL;
    }
    if (self.retainedBuffer) {
        CVPixelBufferRelease(self.retainedBuffer);
        self.retainedBuffer = NULL;
    }
    self.yTextureName = 0;
    self.uvTextureName = 0;
    self.hasTexture = NO;
}

- (void)destroyGLResources {
    [self releaseTextures];
    if (self.textureCache) {
        CFRelease(self.textureCache);
        self.textureCache = NULL;
    }
}

- (BOOL)ensureCacheWithContext:(EAGLContext *)context {
    if (self.textureCache) return YES;
    if (!context) return NO;
    CVReturn cr = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL,
                                               context, NULL, &_textureCache);
    if (cr != kCVReturnSuccess || !self.textureCache) {
        NSLog(@"[SCHostVideoPlane] texture cache fail %d", (int)cr);
        return NO;
    }
    return YES;
}

- (void)configureTexture:(CVOpenGLESTextureRef)tex {
    GLenum target = CVOpenGLESTextureGetTarget(tex);
    GLuint name = CVOpenGLESTextureGetName(tex);
    glBindTexture(target, name);
    glTexParameteri(target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

- (BOOL)updateWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                  orientation:(CGImagePropertyOrientation)orientation {
    if (!pixelBuffer || !self.textureCache) return NO;

    OSType fmt = CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSLog(@"[SCHostVideoPlane] unexpected format %u (want NV12)", (unsigned)fmt);
        });
        return NO;
    }

    size_t w = CVPixelBufferGetWidth(pixelBuffer);
    size_t h = CVPixelBufferGetHeight(pixelBuffer);
    if (w < 2 || h < 2) return NO;

    [self releaseTextures];

    CVOpenGLESTextureRef yTex = NULL;
    CVReturn cr = CVOpenGLESTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, self.textureCache, pixelBuffer, NULL,
        GL_TEXTURE_2D, GL_LUMINANCE, (GLsizei)w, (GLsizei)h,
        GL_LUMINANCE, GL_UNSIGNED_BYTE, 0, &yTex);
    if (cr != kCVReturnSuccess || !yTex) {
        NSLog(@"[SCHostVideoPlane] Y tex fail %d", (int)cr);
        return NO;
    }

    CVOpenGLESTextureRef uvTex = NULL;
    cr = CVOpenGLESTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, self.textureCache, pixelBuffer, NULL,
        GL_TEXTURE_2D, GL_LUMINANCE_ALPHA, (GLsizei)(w / 2), (GLsizei)(h / 2),
        GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 1, &uvTex);
    if (cr != kCVReturnSuccess || !uvTex) {
        NSLog(@"[SCHostVideoPlane] UV tex fail %d", (int)cr);
        CFRelease(yTex);
        return NO;
    }

    [self configureTexture:yTex];
    [self configureTexture:uvTex];
    CVOpenGLESTextureCacheFlush(self.textureCache, 0);

    // 纹理引用该 buffer，必须 retain 到下一帧
    CVPixelBufferRetain(pixelBuffer);
    self.retainedBuffer = pixelBuffer;

    self.yTexture = yTex;
    self.uvTexture = uvTex;
    self.yTextureName = CVOpenGLESTextureGetName(yTex);
    self.uvTextureName = CVOpenGLESTextureGetName(uvTex);
    self.orientation = orientation;
    self.hasTexture = YES;
    return YES;
}

@end
