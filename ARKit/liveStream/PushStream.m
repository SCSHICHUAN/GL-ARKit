/*
  PushStream.m
  推流：Cam（VideoCapture）或 Avatar（SCRenderCapture ← SCRenderer）。
*/

#import "PushStream.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import "VideoCapture.h"
#import "SCRenderCapture.h"
#import "SCRenderer.h"
#import "H264Encoder.h"
#import "AudioCapture.h"
#import "AACEncoder.h"
#import "RTMPStreamer.h"

static NSString * const kDefaultRTMPURL = @"rtmp://192.168.71.92:1935/live/teststream";

@interface PushStream () <
    VideoCaptureDelegate,
    SCRenderCaptureDelegate,
    H264EncoderDelegate,
    AudioCaptureDelegate,
    AACEncoderDelegate
>

@property (strong, nonatomic) VideoCapture *videoCapture;
@property (strong, nonatomic) SCRenderCapture *renderCapture;
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
        _videoSource = PushStreamVideoSourceAvatar;
        _rtmpURL = [kDefaultRTMPURL copy];
    }
    return self;
}

+ (NSString *)titleForVideoQuality:(PushStreamVideoQuality)q {
    switch (q) {
        case PushStreamVideoQualityLow320x240: return @"360×780";
        case PushStreamVideoQuality480p:       return @"720×1560";
        case PushStreamVideoQuality720p:       return @"828×1792";
        case PushStreamVideoQuality1080p:      return @"1080×2340";
        case PushStreamVideoQuality2K:         return @"1440×3120";
        case PushStreamVideoQualityStandard:
        default: return @"540×1170";
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

+ (NSString *)titleForVideoSource:(PushStreamVideoSource)s {
    switch (s) {
        case PushStreamVideoSourceAvatar: return @"Avatar";
        case PushStreamVideoSourceCamera:
        default: return @"Cam";
    }
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
    // iPhone 11 = 828×1792 → 19.5:9；宽高均偶数，便于 H.264
    switch (self.videoQuality) {
        case PushStreamVideoQualityLow320x240:
            return CGSizeMake(360, 780);
        case PushStreamVideoQuality480p:
            return CGSizeMake(720, 1560);
        case PushStreamVideoQuality720p:
            return CGSizeMake(828, 1792);
        case PushStreamVideoQuality1080p:
            return CGSizeMake(1080, 2340);
        case PushStreamVideoQuality2K:
            return CGSizeMake(1440, 3120);
        case PushStreamVideoQualityStandard:
        default:
            return CGSizeMake(540, 1170);
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
            return 1500000;
        case PushStreamVideoQuality480p:
            return 5000000;
        case PushStreamVideoQuality720p:
            return 6000000;
        case PushStreamVideoQuality1080p:
            return 8000000;
        case PushStreamVideoQuality2K:
            return 12000000;
        case PushStreamVideoQualityStandard:
        default:
            return 3000000;
    }
}

- (void)startWithCompletion:(void (^)(BOOL, NSString * _Nullable))completion {
    if (self.streaming || self.starting) {
        if (completion) completion(self.streaming, self.streaming ? @"already" : @"busy");
        return;
    }
    if (self.videoSource == PushStreamVideoSourceAvatar && !self.glRenderer) {
        if (completion) completion(NO, @"Avatar 模式需要 glRenderer");
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
            NSString *src = [PushStream titleForVideoSource:self.videoSource];
            if (completion) {
                completion(YES, [NSString stringWithFormat:@"%@ · %@", src, self.rtmpURL]);
            }
        });
    });
}

- (BOOL)connectRTMPAndStartCapture {
    CGSize enc = [self encodeSize];
    int br = [self bitRateForQuality:self.videoQuality];
    self.activeFPS = [PushStream fpsValue:self.fps];
    self.lastEncodeTime = 0;

    __block BOOL videoOK = YES;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (self.videoSource == PushStreamVideoSourceAvatar) {
            if (!self.glRenderer) {
                videoOK = NO;
                return;
            }
            self.renderCapture = [[SCRenderCapture alloc] init];
            self.renderCapture.delegate = self;
            self.renderCapture.maxFPS = self.activeFPS;
            self.renderCapture.outputSize = enc;
            [self.renderCapture attachToRenderer:self.glRenderer];
            [self.renderCapture startCapture];
            self.previewLayer = nil;
            self.videoCapture = nil;
        } else {
            NSString *preset = [self capturePresetForQuality:self.videoQuality];
            self.videoCapture = [[VideoCapture alloc] initWithSessionPreset:preset];
            self.videoCapture.delegate = self;
            [self.videoCapture startVideoCollect];
            AVCaptureVideoPreviewLayer *previewlayer =
                [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.videoCapture.captureSeccion];
            previewlayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            self.previewLayer = previewlayer;
            self.renderCapture = nil;
        }
    });
    if (!videoOK) return NO;

    self.h264encoder = [[H264Encoder alloc] initWithVideSize:enc bitRate:br fps:self.activeFPS];
    self.h264encoder.delegate = self;
    NSLog(@"[PushStream] src=%@ vid=%@ encode=%.0fx%.0f %dkbps fps=%d",
          [PushStream titleForVideoSource:self.videoSource],
          [PushStream titleForVideoQuality:self.videoQuality],
          enc.width, enc.height, br / 1000, self.activeFPS);

    self.audioCapture = [[AudioCapture alloc] init];
    self.audioCapture.delegate = self;
    [self.audioCapture startCapture];

    self.aacEncoder = [[AACEncoder alloc] initWithSampleRate:44100 channels:1];
    self.aacEncoder.delegate = self;

    NSString *url = self.rtmpURL.length ? self.rtmpURL : kDefaultRTMPURL;
    NSLog(@"[PushStream] RTMP connect %@", url);
    self.rtpStreamer = [[RTMPStreamer alloc] initWithRTMPURL:url];
    if (![self.rtpStreamer startStreaming]) {
        NSLog(@"推流开始失败");
        [self tearDownCaptureEncoders];
        return NO;
    }
    NSLog(@"推流开始成功");

    self.streaming = YES;
    return YES;
}

- (void)tearDownCaptureEncoders {
    dispatch_block_t ui = ^{
        [self.renderCapture stopCapture];
        [self.renderCapture detachFromRenderer];
        [self.videoCapture stopVideoCollect];
        self.renderCapture = nil;
        self.videoCapture = nil;
        self.previewLayer = nil;
    };
    if ([NSThread isMainThread]) {
        ui();
    } else {
        dispatch_sync(dispatch_get_main_queue(), ui);
    }
    [self.h264encoder stopEncoding];
    [self.audioCapture stopCapture];
    [self.aacEncoder stopEncoding];
    self.h264encoder = nil;
    self.audioCapture = nil;
    self.aacEncoder = nil;
    self.rtpStreamer = nil;
}

- (void)stop {
    self.starting = NO;
    self.streaming = NO;

    dispatch_block_t cleanup = ^{
        [self.renderCapture stopCapture];
        [self.renderCapture detachFromRenderer];
        [self.videoCapture stopVideoCollect];
        [self.h264encoder stopEncoding];
        [self.audioCapture stopCapture];
        [self.aacEncoder stopEncoding];
        [self.rtpStreamer stopStreaming];

        self.renderCapture = nil;
        self.videoCapture = nil;
        self.h264encoder = nil;
        self.audioCapture = nil;
        self.aacEncoder = nil;
        self.rtpStreamer = nil;
        self.previewLayer = nil;
    };

    if ([NSThread isMainThread]) {
        cleanup();
    } else {
        dispatch_sync(dispatch_get_main_queue(), cleanup);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].idleTimerDisabled = NO;
    });
}

#pragma mark - Video / GL → H264

- (void)didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // Avatar：SCRenderCapture 已按 maxFPS 限帧；Cam：仅低于 30 时节流
    if (self.videoSource == PushStreamVideoSourceCamera &&
        self.activeFPS > 0 && self.activeFPS < 30) {
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
