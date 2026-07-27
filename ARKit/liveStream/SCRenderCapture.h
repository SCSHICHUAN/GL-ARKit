/*
  SCRenderCapture.h
  从 SCRenderer 的 GLES 帧缓冲取像素，打成 CMSampleBuffer。
  委托接口与 Media/VideoCapture 一致，可直接喂给 H264Encoder。
*/

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class SCRenderer;

/// 与 Media `VideoCaptureDelegate` 同签名，便于替换摄像头采集做直播
@protocol SCRenderCaptureDelegate <NSObject>
- (void)didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

@interface SCRenderCapture : NSObject

@property (nonatomic, weak, nullable) id<SCRenderCaptureDelegate> delegate;

/// 限帧，默认 30；编码器尺寸应对齐 `captureSize`
@property (nonatomic, assign) NSInteger maxFPS;

/// 最近一次成功抓到的像素尺寸（偶数对齐，供 H264Encoder initWithVideSize:）
@property (nonatomic, readonly) CGSize captureSize;

@property (nonatomic, readonly, getter=isCapturing) BOOL capturing;

/// 挂到渲染器：之后每帧 render 完会自动抓缓冲
- (void)attachToRenderer:(SCRenderer *)renderer;
- (void)detachFromRenderer;

- (void)startCapture;
- (void)stopCapture;

/// 仅供 SCRenderer 在「当前 EAGLContext + FBO 已画完」时调用
- (void)onFramebufferReadyWidth:(int)width height:(int)height;

@end

NS_ASSUME_NONNULL_END
