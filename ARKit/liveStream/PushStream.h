/*
  PushStream.h
  Media/ViewController → PushStream；视频/帧率可选。
*/

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PushStreamVideoQuality) {
    PushStreamVideoQualityLow320x240 = 0, // 240×320 / 1Mbps
    PushStreamVideoQualityStandard,       // 288×352 / 4Mbps（Media 默认）
    PushStreamVideoQuality480p,           // 480×640 / 3Mbps
    PushStreamVideoQuality720p,           // 720×1280 / 5Mbps
    PushStreamVideoQuality1080p,          // 1080×1920 / 8Mbps
    PushStreamVideoQuality2K,             // 1440×2560 / 12Mbps
};

typedef NS_ENUM(NSInteger, PushStreamFPS) {
    PushStreamFPS5 = 0,
    PushStreamFPS10,
    PushStreamFPS24,
    PushStreamFPS30,
    PushStreamFPS60,
};

@interface PushStream : NSObject

@property (nonatomic, readonly, getter=isStreaming) BOOL streaming;
@property (nonatomic, assign) PushStreamVideoQuality videoQuality;
@property (nonatomic, assign) PushStreamFPS fps;
@property (nonatomic, strong, readonly, nullable) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, readonly) CGSize encodeSize;
@property (nonatomic, copy) NSString *rtmpURL;

+ (NSString *)titleForVideoQuality:(PushStreamVideoQuality)q;
+ (NSString *)titleForFPS:(PushStreamFPS)f;
+ (int)fpsValue:(PushStreamFPS)f;
+ (PushStreamFPS)nextFPS:(PushStreamFPS)f;
+ (PushStreamVideoQuality)nextVideoQuality:(PushStreamVideoQuality)q;

/// 连 RTMP，成功后再开采集。回调在主线程。
- (void)startWithCompletion:(void (^)(BOOL ok, NSString * _Nullable message))completion;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
