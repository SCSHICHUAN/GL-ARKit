/*
  RTMPStreamer.h
  Media

  Created by Stan on 2025/10/4.
*/

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
NS_ASSUME_NONNULL_BEGIN


@interface RTMPStreamer : NSObject
- (instancetype)initWithRTMPURL:(NSString *)rtmpURL;
- (BOOL)startStreaming;
- (void)stopStreaming;
- (void)sendSPS:(NSData *)sps PPS:(NSData *)pps andPTS:(CMTime)pts;
//视频流
- (void)sendVideoFrame:(NSData *)frameData andPTS:(CMTime)pts isKeyFrame:(BOOL)isKeyFrame;
//音频流
- (void)sendAudioFrame:(NSData *)aacData andPTS:(CMTime)pts;
/// FLV 音频头（Media 固定 0xAF / 0x12 0x10）；保留接口兼容，无实际效果
- (void)configureAudioSampleRate:(int)sampleRate channels:(int)channels;
@end
    



NS_ASSUME_NONNULL_END
