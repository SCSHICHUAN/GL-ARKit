//
//  VideoCapture.h
//  Media
//
//  Created by Stan on 2025/10/6.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol VideoCaptureDelegate <NSObject>

-(void)didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end

@interface VideoCapture : NSObject

@property (nonatomic, weak) id<VideoCaptureDelegate> delegate;
@property (nonatomic, strong) AVCaptureSession *captureSeccion;

/// 默认 AVCaptureSessionPreset352x288（同 Media）
- (instancetype)init;
- (instancetype)initWithSessionPreset:(NSString *)sessionPreset;

- (void)startVideoCollect;
- (void)stopVideoCollect;

@end

NS_ASSUME_NONNULL_END
