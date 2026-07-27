//
//  VideoCapture.m
//  Media
//
//  Created by Stan on 2025/10/6.
//

#import "VideoCapture.h"


@interface VideoCapture () <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, copy) NSString *sessionPreset;
@end

@implementation VideoCapture

- (instancetype)init {
    return [self initWithSessionPreset:AVCaptureSessionPreset352x288];
}

- (instancetype)initWithSessionPreset:(NSString *)sessionPreset {
    self = [super init];
    if (self) {
        _sessionPreset = [sessionPreset copy] ?: AVCaptureSessionPreset352x288;
        [self setUP];
    }
    return self;
}

- (void)setUP {
    self.captureSeccion = [[AVCaptureSession alloc] init];
    if ([self.captureSeccion canSetSessionPreset:self.sessionPreset]) {
        self.captureSeccion.sessionPreset = self.sessionPreset;
    } else {
        self.captureSeccion.sessionPreset = AVCaptureSessionPreset352x288;
    }
    
    AVCaptureDevice *captureDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                        mediaType:AVMediaTypeVideo
                                                                         position:AVCaptureDevicePositionBack];
    if(!captureDevice){
        NSLog(@"NO back camera available");
        return;
    }
    
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:&error];
    if(!input){
        NSLog(@"Could not create onput device:%@",error.localizedDescription);
    }
    
    if([self.captureSeccion canAddInput:input]){
        [self.captureSeccion addInput:input];
    }
    
    AVCaptureVideoDataOutput *videOutput = [[AVCaptureVideoDataOutput alloc] init];
    NSDictionary *outputSettings = @{(__bridge  NSString*)
                                     kCVPixelBufferPixelFormatTypeKey:
                                         @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
    videOutput.videoSettings = outputSettings;
    dispatch_queue_t videoQueue = dispatch_queue_create("videoQueue",DISPATCH_QUEUE_SERIAL);
    [videOutput setSampleBufferDelegate:self queue:videoQueue];
    
    if([self.captureSeccion canAddOutput:videOutput]){
        [self.captureSeccion addOutput:videOutput];
        //方向
        AVCaptureConnection *connection = [videOutput connectionWithMediaType:AVMediaTypeVideo];
            if ([connection isVideoOrientationSupported]) {
                connection.videoOrientation = AVCaptureVideoOrientationPortrait;
            }
            if ([connection isVideoMirroringSupported]) {
                connection.videoMirrored = NO;
            }
    }
    
    
}

-(void)startVideoCollect{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.captureSeccion startRunning];
    });
}
-(void)stopVideoCollect{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.captureSeccion stopRunning];
    });
}
#pragma mark-AVCaptureVideoDataOutputSampleBufferDelegate
-(void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection{
    if([self.delegate respondsToSelector:@selector(didOutputSampleBuffer:)]){
        [self.delegate didOutputSampleBuffer:sampleBuffer];
    }
}
@end
