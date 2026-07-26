/*
  SCARUpperBodyProjector.h
  前置画面 → Vision → 上体左右倾斜（仅 lean，±40°）
*/

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCARUpperBodyDrive : NSObject
@property (nonatomic, assign) BOOL valid;
/// 上体左右倾斜（弧度，已钳制 ±40°）
@property (nonatomic, assign) float torsoLean;
@end

@interface SCARUpperBodyProjector : NSObject
@property (nonatomic, assign) float smoothing;    // 0..0.95
@property (nonatomic, assign) BOOL mirrorSelfie;  // 前置默认 YES
/// 近 1 秒内有效 Vision 完成次数
@property (nonatomic, assign, readonly) float measuredHz;
/// 正在处理时为 YES（此时勿再拷贝投递）
@property (nonatomic, assign, readonly, getter=isBusy) BOOL busy;

- (void)reset;

/// 仅在 ARFrame 回调内、缓冲仍有效时调用。
/// 忙则直接跳过（不拷贝），避免主线程卡顿。
- (void)submitLivePixelBuffer:(CVPixelBufferRef)pixelBuffer
                  orientation:(CGImagePropertyOrientation)orientation;

- (SCARUpperBodyDrive *)latestDrive;

@end

NS_ASSUME_NONNULL_END
