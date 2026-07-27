/*
  PushStream.m
  Media 推流：连 RTMP → 开采集/编码。
*/

#import "PushStream.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import "VideoCapture.h"
#import "H264Encoder.h"
#import "AudioCapture.h"
#import "AACEncoder.h"
#import "RTMPStreamer.h"

static NSString * const kDefaultRTMPURL = @"rtmp://192.168.71.92:1935/live/teststream";

@interface PushStream () <
    VideoCaptureDelegate,
    H264EncoderDelegate,
    AudioCaptureDelegate,
    AACEncoderDelegate
>

@property (strong, nonatomic) VideoCapture *videoCapture;
@property (strong, nonatomic) H264Encoder *h264encoder;
@property (nonatomic, strong) AudioCapture *audioCapture;
@property (nonatomic, strong) AACEncoder *aacEncoder;
@property (strong, nonatomic) RTMPStreamer *rtpStreamer;
@property (nonatomic, assign, readwrite, getter=isStreaming) BOOL streaming;
@property (nonatomic, strong, readwrite) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, assign) CFTimeInterval lastEncodeTime;
@property (nonatomic, assign) int activeFPS;
@property (nonatomic, assign) BOOL starting;
@end

@implementation PushStream

- (instancetype)init {
    self = [super init];
    if (self) {
        _videoQuality = PushStreamVideoQualityStandard;
        _fps = PushStreamFPS30;
        _rtmpURL = [kDefaultRTMPURL copy];
    }
    return self;
}

+ (NSString *)titleForVideoQuality:(PushStreamVideoQuality)q {
    switch (q) {
        case PushStreamVideoQualityLow320x240: return @"240×320";
        case PushStreamVideoQuality480p:       return @"480×640";
        case PushStreamVideoQuality720p:       return @"720×1280";
        case PushStreamVideoQuality1080p:      return @"1080×1920";
        case PushStreamVideoQuality2K:         return @"1440×2560";
        case PushStreamVideoQualityStandard:
        default: return @"288×352";
    }
}

+ (int)fpsValue:(PushStreamFPS)f {
    switch (f) {
        case PushStreamFPS5:  return 5;
        case PushStreamFPS10: return 10;
        case PushStreamFPS24: return 24;
        case PushStreamFPS60: return 60;
        case PushStreamFPS30:
        default: return 30;
    }
}

+ (NSString *)titleForFPS:(PushStreamFPS)f {
    return [NSString stringWithFormat:@"%d", [self fpsValue:f]];
}

+ (PushStreamFPS)nextFPS:(PushStreamFPS)f {
    switch (f) {
        case PushStreamFPS5:  return PushStreamFPS10;
        case PushStreamFPS10: return PushStreamFPS24;
        case PushStreamFPS24: return PushStreamFPS30;
        case PushStreamFPS30: return PushStreamFPS60;
        case PushStreamFPS60:
        default: return PushStreamFPS5;
    }
}

+ (PushStreamVideoQuality)nextVideoQuality:(PushStreamVideoQuality)q {
    switch (q) {
        case PushStreamVideoQualityLow320x240: return PushStreamVideoQualityStandard;
        case PushStreamVideoQualityStandard:   return PushStreamVideoQuality480p;
        case PushStreamVideoQuality480p:       return PushStreamVideoQuality720p;
        case PushStreamVideoQuality720p:       return PushStreamVideoQuality1080p;
        case PushStreamVideoQuality1080p:      return PushStreamVideoQuality2K;
        case PushStreamVideoQuality2K:
        default: return PushStreamVideoQualityLow320x240;
    }
}

- (CGSize)encodeSize {
    switch (self.videoQuality) {
        case PushStreamVideoQualityLow320x240:
            return CGSizeMake(240, 320);
        case PushStreamVideoQuality480p:
            return CGSizeMake(480, 640);
        case PushStreamVideoQuality720p:
            return CGSizeMake(720, 1280);
        case PushStreamVideoQuality1080p:
            return CGSizeMake(1080, 1920);
        case PushStreamVideoQuality2K:
            return CGSizeMake(1440, 2560);
        case PushStreamVideoQualityStandard:
        default:
            return CGSizeMake(288, 352);
    }
}

- (NSString *)capturePresetForQuality:(PushStreamVideoQuality)q {
    switch (q) {
        case PushStreamVideoQualityLow320x240:
            return AVCaptureSessionPreset640x480;
        case PushStreamVideoQuality480p:
            return AVCaptureSessionPreset640x480;
        case PushStreamVideoQuality720p:
            return AVCaptureSessionPreset1280x720;
        case PushStreamVideoQuality1080p:
            return AVCaptureSessionPreset1920x1080;
        case PushStreamVideoQuality2K:
            return AVCaptureSessionPreset3840x2160;
        case PushStreamVideoQualityStandard:
        default:
            return AVCaptureSessionPreset352x288;
    }
}

- (int)bitRateForQuality:(PushStreamVideoQuality)q {
    switch (q) {
        case PushStreamVideoQualityLow320x240:
            return 1000000;
        case PushStreamVideoQuality480p:
            return 3000000;
        case PushStreamVideoQuality720p:
            return 5000000;
        case PushStreamVideoQuality1080p:
            return 8000000;
        case PushStreamVideoQuality2K:
            return 12000000;
        case PushStreamVideoQualityStandard:
        default:
            return 4000000;
    }
}

- (void)startWithCompletion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (self.streaming || self.starting) {
        if (completion) completion(self.streaming, self.streaming ? @"already" : @"busy");
        return;
    }
    self.starting = YES;
    [UIApplication sharedApplication].idleTimerDisabled = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = [self connectRTMPAndStartCapture];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.starting = NO;
            if (!ok) {
                [self stop];
                if (completion) completion(NO, @"RTMP 连接失败");
                return;
            }
            if (completion) completion(YES, self.rtmpURL);
        });
    });
}

- (BOOL)connectRTMPAndStartCapture {
    // 启动顺序与 Media ViewController 一致：采集/编码先起，最后连 RTMP
    NSString *preset = [self capturePresetForQuality:self.videoQuality];
    CGSize enc = [self encodeSize];
    int br = [self bitRateForQuality:self.videoQuality];
    self.activeFPS = [PushStream fpsValue:self.fps];
    self.lastEncodeTime = 0;

    dispatch_sync(dispatch_get_main_queue(), ^{
        self.videoCapture = [[VideoCapture alloc] initWithSessionPreset:preset];
        self.videoCapture.delegate = self;
        [self.videoCapture startVideoCollect];
        AVCaptureVideoPreviewLayer *previewlayer =
            [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.videoCapture.captureSeccion];
        previewlayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.previewLayer = previewlayer;
    });

    self.h264encoder = [[H264Encoder alloc] initWithVideSize:enc bitRate:br fps:self.activeFPS];
    self.h264encoder.delegate = self;
    NSLog(@"[PushStream] vid=%@ encode=%.0fx%.0f %dkbps fps=%d",
          [PushStream titleForVideoQuality:self.videoQuality],
          enc.width, enc.height, br / 1000, self.activeFPS);

    self.audioCapture = [[AudioCapture alloc] init];
    self.audioCapture.delegate = self;
    [self.audioCapture startCapture];

    // 与 Media 一致：44100Hz mono，不强制码率
    self.aacEncoder = [[AACEncoder alloc] initWithSampleRate:44100 channels:1];
    self.aacEncoder.delegate = self;

    NSString *url = self.rtmpURL.length ? self.rtmpURL : kDefaultRTMPURL;
    NSLog(@"[PushStream] RTMP connect %@", url);
    self.rtpStreamer = [[RTMPStreamer alloc] initWithRTMPURL:url];
    if (![self.rtpStreamer startStreaming]) {
        NSLog(@"推流开始失败");
        [self.videoCapture stopVideoCollect];
        [self.h264encoder stopEncoding];
        [self.audioCapture stopCapture];
        [self.aacEncoder stopEncoding];
        self.videoCapture = nil;
        self.h264encoder = nil;
        self.audioCapture = nil;
        self.aacEncoder = nil;
        self.rtpStreamer = nil;
        self.previewLayer = nil;
        return NO;
    }
    NSLog(@"推流开始成功");

    self.streaming = YES;
    return YES;
}

- (void)stop {
    self.starting = NO;
    self.streaming = NO;

    [self.videoCapture stopVideoCollect];
    [self.h264encoder stopEncoding];
    [self.audioCapture stopCapture];
    [self.aacEncoder stopEncoding];
    [self.rtpStreamer stopStreaming];

    self.videoCapture = nil;
    self.h264encoder = nil;
    self.audioCapture = nil;
    self.aacEncoder = nil;
    self.rtpStreamer = nil;
    self.previewLayer = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].idleTimerDisabled = NO;
    });
}

#pragma mark - VideoCollectDelegate
- (void)didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // Media 默认不限帧；仅当用户选了更低 FPS 时才节流
    if (self.activeFPS > 0 && self.activeFPS < 30) {
        CFTimeInterval now = CACurrentMediaTime();
        CFTimeInterval minInterval = 1.0 / MAX(self.activeFPS, 1);
        if (self.lastEncodeTime > 0 && (now - self.lastEncodeTime) < minInterval) {
            return;
        }
        self.lastEncodeTime = now;
    }
    [self.h264encoder encodeSampleBuffer:sampleBuffer];
}

#pragma mark - H264EncoderDelegate
- (void)h264EncoderOutputFrameData:(NSData *)frameData andPTS:(CMTime)pts isKeyFrame:(BOOL)isKeyFrame {
    [self.rtpStreamer sendVideoFrame:frameData andPTS:pts isKeyFrame:isKeyFrame];
}
- (void)h264EncoderOutputSPS:(NSData *)sps PPS:(NSData *)pps andPTS:(CMTime)pts {
    [self.rtpStreamer sendSPS:sps PPS:pps andPTS:pts];
}

#pragma mark - AudioCaptureDelegate
- (void)audioCaptureDidOutputPCMData:(NSData *)pcmData andPTS:(CMTime)pts {
    [self.aacEncoder encodePCMData:pcmData pts:pts];
}

#pragma mark - AACEncoderDelegate
- (void)outAudioFrame:(NSData *)aacData andPTS:(CMTime)pts {
    [self.rtpStreamer sendAudioFrame:aacData andPTS:pts];
}

@end
