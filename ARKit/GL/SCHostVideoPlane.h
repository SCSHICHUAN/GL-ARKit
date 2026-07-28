/*
  SCHostVideoPlane.h
  ARKit capturedImage (NV12) → GLES Y/UV 纹理，供场景长方形采样。
*/

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <OpenGLES/ES3/gl.h>

NS_ASSUME_NONNULL_BEGIN

@class EAGLContext;

@interface SCHostVideoPlane : NSObject

@property (nonatomic, readonly) GLuint yTextureName;
@property (nonatomic, readonly) GLuint uvTextureName;
@property (nonatomic, readonly) BOOL hasTexture;
@property (nonatomic, readonly) CGImagePropertyOrientation orientation;
@property (nonatomic, readonly) int pixelWidth;
@property (nonatomic, readonly) int pixelHeight;
/// 前置自拍默认镜像
@property (nonatomic, assign) BOOL mirrorX;

- (BOOL)ensureCacheWithContext:(EAGLContext *)context;

/// 用当前帧更新纹理（可在 AR 回调里对仍有效的 buffer 调用；或传入 clone）
- (BOOL)updateWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                  orientation:(CGImagePropertyOrientation)orientation;

- (void)destroyGLResources;

@end

NS_ASSUME_NONNULL_END
