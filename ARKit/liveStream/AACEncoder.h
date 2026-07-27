//
//  AACEncoder.h
//  Media
//
//  Created by Stan on 2025/10/6.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AACEncoderDelegate <NSObject>
- (void)outAudioFrame:(NSData *)aacData andPTS:(CMTime)pts;
@end

@interface AACEncoder : NSObject

@property (nonatomic, weak) id<AACEncoderDelegate> delegate;
@property (nonatomic, assign, readonly) BOOL isEncoding;
@property (nonatomic, assign, readonly)CMSampleBufferRef sampleBuffer;


- (instancetype)initWithSampleRate:(Float64)sampleRate channels:(UInt32)channels;
/// bitRate 单位 bps；0 表示不设（系统默认）
- (instancetype)initWithSampleRate:(Float64)sampleRate channels:(UInt32)channels bitRate:(UInt32)bitRate;
- (void)encodePCMData:(NSData *)pcmData pts:(CMTime)pts;
- (void)stopEncoding;

@end

NS_ASSUME_NONNULL_END
