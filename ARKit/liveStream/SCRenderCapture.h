/*
  SCRenderCapture.h
  Avatar 推流抓帧：编码尺寸离屏 FBO + CVOpenGLESTextureCache，
  场景直接渲进 CVPixelBuffer（零拷贝进 VideoToolbox），避免全屏 glReadPixels 卡顿。
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
/// 仅用于 CMSampleBuffer.duration / 日志；帧率由 CADisplayLink.preferredFramesPerSecond 决定，此处不再软件限帧
@property (nonatomic, assign) NSInteger maxFPS;
/// 编码输出尺寸（须与 H264Encoder 一致）；偶数宽高
@property (nonatomic, assign) CGSize outputSize;
@property (nonatomic, readonly) CGSize captureSize;
@property (nonatomic, readonly, getter=isCapturing) BOOL capturing;
@property (nonatomic, readonly) int captureWidth;
@property (nonatomic, readonly) int captureHeight;

- (void)attachToRenderer:(SCRenderer *)renderer;
- (void)detachFromRenderer;

- (void)startCapture;
- (void)stopCapture;

/// 当前 EAGLContext 下：从池取 CVPixelBuffer → TextureCache 纹理 → 绑离屏 FBO；NO=本帧不抓
- (BOOL)beginEncodePassWithContext:(EAGLContext *)context;
/// 离屏渲完：flush → 包 CMSampleBuffer → delegate（再走 H264）
- (void)endEncodePass;

/// 释放 FBO / TextureCache（须在 EAGLContext 当前时）
- (void)destroyGLResources;

@end

NS_ASSUME_NONNULL_END
