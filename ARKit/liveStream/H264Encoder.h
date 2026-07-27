//
//  H264Encoder.h
//  Media
//
//  Created by Stan on 2025/10/2.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN



@protocol H264EncoderDelegate <NSObject>
@optional
- (void)h264EncoderOutputFrameData:(NSData *)frameData andPTS:(CMTime)pts isKeyFrame:(BOOL)isKeyFrame;
- (void)h264EncoderOutputSPS:(NSData *)sps PPS:(NSData *)pps andPTS:(CMTime)pts;
@end

@interface H264Encoder : NSObject
@property (nonatomic, weak) id<H264EncoderDelegate> delegate;
- (instancetype)initWithVideSize:(CGSize)videoSize;
/// bitRate 单位 bps；默认 4Mbps（同 Media）
- (instancetype)initWithVideSize:(CGSize)videoSize bitRate:(int)bitRate;
- (instancetype)initWithVideSize:(CGSize)videoSize bitRate:(int)bitRate fps:(int)fps;
- (void)encodeSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)stopEncoding;

@end

NS_ASSUME_NONNULL_END
