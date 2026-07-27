/*
  SCRenderCapture.h
  编码尺寸离屏 FBO + CVOpenGLESTextureCache：直接渲进 CVPixelBuffer，避免全屏 glReadPixels。
*/

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class SCRenderer;
@class EAGLContext;

@protocol SCRenderCaptureDelegate <NSObject>
- (void)didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

@interface SCRenderCapture : NSObject

@property (nonatomic, weak, nullable) id<SCRenderCaptureDelegate> delegate;
@property (nonatomic, assign) NSInteger maxFPS;
/// 编码输出尺寸（应对齐 H264Encoder）；必填有效偶数尺寸
@property (nonatomic, assign) CGSize outputSize;
@property (nonatomic, readonly) CGSize captureSize;
@property (nonatomic, readonly, getter=isCapturing) BOOL capturing;
@property (nonatomic, readonly) int captureWidth;
@property (nonatomic, readonly) int captureHeight;

- (void)attachToRenderer:(SCRenderer *)renderer;
- (void)detachFromRenderer;

- (void)startCapture;
- (void)stopCapture;

/// 须在当前 EAGLContext 下调用。绑定离屏 FBO；返回 NO 则本帧跳过抓帧。
- (BOOL)beginEncodePassWithContext:(EAGLContext *)context;
/// 渲完离屏后调用：冲刷纹理缓存 → CMSampleBuffer → delegate
- (void)endEncodePass;

/// 释放 FBO / TextureCache（须在 EAGLContext 当前时）
- (void)destroyGLResources;

@end

NS_ASSUME_NONNULL_END
