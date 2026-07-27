/*
  PushStream.h
  推流门面：Src=Avatar(GL) 或 Cam；经 H264/AAC → RTMP。
  Avatar 默认；开播时挂 SCRenderCapture 到 SCRenderer，帧率跟 DisplayLink。
*/

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SCRenderer;

typedef NS_ENUM(NSInteger, PushStreamVideoQuality) {
    /// 全部为 iPhone 11 同款 19.5:9（828:1792），避免竖屏被拉胖
    PushStreamVideoQualityLow320x240 = 0, // 360×780 / 1.5Mbps
    PushStreamVideoQualityStandard,       // 540×1170 / 3Mbps
    PushStreamVideoQuality480p,           // 720×1560 / 5Mbps
    PushStreamVideoQuality720p,           // 828×1792 / 6Mbps（iPhone 11 原生）
    PushStreamVideoQuality1080p,          // 1080×2340 / 8Mbps
    PushStreamVideoQuality2K,             // 1440×3120 / 12Mbps
};

typedef NS_ENUM(NSInteger, PushStreamFPS) {
    PushStreamFPS5 = 0,
    PushStreamFPS10,
    PushStreamFPS24,
    PushStreamFPS30,
    PushStreamFPS60,
};

/// Cam = 前置/后置摄像头；Avatar = SCRenderer GL 画面（虚拟主播）
typedef NS_ENUM(NSInteger, PushStreamVideoSource) {
    PushStreamVideoSourceCamera = 0,
    PushStreamVideoSourceAvatar,
};

@interface PushStream : NSObject

@property (nonatomic, readonly, getter=isStreaming) BOOL streaming;
@property (nonatomic, assign) PushStreamVideoQuality videoQuality;
@property (nonatomic, assign) PushStreamFPS fps;
@property (nonatomic, assign) PushStreamVideoSource videoSource;
/// Avatar 模式必填：挂 SCRenderCapture 的 GL 视图
@property (nonatomic, weak, nullable) SCRenderer *glRenderer;
@property (nonatomic, strong, readonly, nullable) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, readonly) CGSize encodeSize;
@property (nonatomic, copy) NSString *rtmpURL;

+ (NSString *)titleForVideoQuality:(PushStreamVideoQuality)q;
+ (NSString *)titleForFPS:(PushStreamFPS)f;
+ (NSString *)titleForVideoSource:(PushStreamVideoSource)s;
+ (int)fpsValue:(PushStreamFPS)f;
+ (PushStreamFPS)nextFPS:(PushStreamFPS)f;
+ (PushStreamVideoQuality)nextVideoQuality:(PushStreamVideoQuality)q;

/// 连 RTMP，成功后再开采集。回调在主线程。
- (void)startWithCompletion:(void (^)(BOOL ok, NSString * _Nullable message))completion;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
