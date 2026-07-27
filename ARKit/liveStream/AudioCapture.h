//
//  AudioCapture.h
//  Media
//
//  Created by Stan on 2025/10/6.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN



@protocol AudioCaptureDelegate <NSObject>
- (void)audioCaptureDidOutputPCMData:(NSData *)pcmData andPTS:(CMTime)pts;
@end

@interface AudioCapture : NSObject

@property (nonatomic, weak) id<AudioCaptureDelegate> delegate;
@property (nonatomic, assign, readonly) BOOL isCapturing;

- (void)startCapture;
- (void)stopCapture;

@end

    

NS_ASSUME_NONNULL_END
