//
//  AudioCapture.m
//  Media
//
//  Created by Stan on 2025/10/6.
//

#import "AudioCapture.h"
#import <AVFoundation/AVFoundation.h>

@interface AudioCapture () <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, assign) BOOL isCapturing;
@end

@implementation AudioCapture

#pragma mark - 启动采集
- (void)startCapture {
    if (_isCapturing) return;
    
    NSError *error = nil;
    
    // 1️⃣ 配置 AVAudioSession
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
             mode:AVAudioSessionModeVideoRecording
          options:AVAudioSessionCategoryOptionDefaultToSpeaker
            error:&error];
    [session setPreferredSampleRate:44100 error:&error];       // 固定 44.1kHz
//    [session setPreferredInputNumberOfChannels:1 error:&error]; // Stereo
    [session setPreferredIOBufferDuration:0.005 error:&error]; // 5ms 低延迟
    [session setActive:YES error:&error];
    
    if (error) {
        NSLog(@"⚠️ AVAudioSession 配置失败: %@", error.localizedDescription);
    }
    
    // 2️⃣ 创建采集会话
    _captureSession = [[AVCaptureSession alloc] init];
    _captureSession.sessionPreset = AVCaptureSessionPresetMedium;
    
    // 3️⃣ 添加音频输入
    AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
    
    if (audioInput && [_captureSession canAddInput:audioInput]) {
        [_captureSession addInput:audioInput];
    } else {
        NSLog(@"⚠️ 添加音频输入失败: %@", error.localizedDescription);
        return;
    }
    
    // 4️⃣ 添加音频输出
    AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    dispatch_queue_t audioQueue = dispatch_queue_create("com.live.audioQueue", DISPATCH_QUEUE_SERIAL);
    [audioOutput setSampleBufferDelegate:self queue:audioQueue];
    
    if ([_captureSession canAddOutput:audioOutput]) {
        [_captureSession addOutput:audioOutput];
    } else {
        NSLog(@"⚠️ 添加音频输出失败");
        return;
    }
    
    // 5️⃣ 启动采集
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self->_captureSession startRunning];
    });
    
    _isCapturing = YES;
    NSLog(@"✅ AudioCapture 已启动");
}

#pragma mark - 停止采集
- (void)stopCapture {
    if (!_isCapturing) return;
    
    [_captureSession stopRunning];
    _captureSession = nil;
    _isCapturing = NO;
    
    NSLog(@"🛑 AudioCapture 已停止");
}

#pragma mark - AVCaptureAudioDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    
    // 1️⃣ 获取 PCM 数据
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t lengthAtOffset = 0;
    size_t totalLength = 0;
    char *data = NULL;
    
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, &lengthAtOffset, &totalLength, &data);
    if (status != kCMBlockBufferNoErr) {
        NSLog(@"⚠️ 获取音频数据失败: %d", (int)status);
        return;
    }
    
    // 2️⃣ 获取 PTS（时间戳）
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    // 3️⃣ 输出 PCM 数据给代理
    NSData *pcmData = [NSData dataWithBytes:data length:totalLength];
    if ([self.delegate respondsToSelector:@selector(audioCaptureDidOutputPCMData:andPTS:)]) {
        [self.delegate audioCaptureDidOutputPCMData:pcmData andPTS:pts];
    }
}

@end
