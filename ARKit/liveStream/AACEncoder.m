//
//  AACEncoder.m
//  Media
//
//  Created by Stan on 2025/10/6.
//

#import "AACEncoder.h"

@interface AACEncoder () {
    AudioConverterRef _audioConverter;
    AudioStreamBasicDescription _inputASBD;
    AudioStreamBasicDescription _outputASBD;
    uint8_t *_aacBuffer;
    UInt32 _aacBufferSize;
    BOOL _isEncoding;
    UInt32 _bitRate;
}
@end

@implementation AACEncoder

#pragma mark - 初始化
- (instancetype)initWithSampleRate:(Float64)sampleRate channels:(UInt32)channels {
    return [self initWithSampleRate:sampleRate channels:channels bitRate:0];
}

- (instancetype)initWithSampleRate:(Float64)sampleRate channels:(UInt32)channels bitRate:(UInt32)bitRate {
    self = [super init];
    if (self) {
        _isEncoding = NO;
        _bitRate = bitRate;
        [self setupAudioConverterWithSampleRate:sampleRate channels:channels];
    }
    return self;
}

#pragma mark - 初始化 AudioConverter
- (void)setupAudioConverterWithSampleRate:(Float64)sampleRate channels:(UInt32)channels {
    // 输入格式 PCM
    memset(&_inputASBD, 0, sizeof(_inputASBD));
    _inputASBD.mSampleRate = sampleRate;
    _inputASBD.mFormatID = kAudioFormatLinearPCM;
    _inputASBD.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    _inputASBD.mChannelsPerFrame = channels;
    _inputASBD.mBitsPerChannel = 16;
    _inputASBD.mBytesPerFrame = (_inputASBD.mBitsPerChannel / 8) * _inputASBD.mChannelsPerFrame;
    _inputASBD.mFramesPerPacket = 1;
    _inputASBD.mBytesPerPacket = _inputASBD.mBytesPerFrame;
    
    // 输出格式 AAC
    memset(&_outputASBD, 0, sizeof(_outputASBD));
    _outputASBD.mSampleRate = sampleRate;
    _outputASBD.mFormatID = kAudioFormatMPEG4AAC;
    _outputASBD.mChannelsPerFrame = channels;
    _outputASBD.mFramesPerPacket = 1024; // AAC 每帧固定1024采样
    
    // 查找合适的编码器
    AudioClassDescription desc;
    UInt32 size = sizeof(desc);
    AudioFormatGetProperty(kAudioFormatProperty_Encoders,
                           sizeof(_outputASBD.mFormatID),
                           &_outputASBD.mFormatID,
                           &size,
                           &desc);
    
    // 创建转换器
    OSStatus status = AudioConverterNewSpecific(&_inputASBD, &_outputASBD, 1, &desc, &_audioConverter);
    if (status != noErr) {
        NSLog(@"❌ 创建 AudioConverter 失败: %d", (int)status);
        return;
    }
    
    // 与 Media 一致：高质量
    UInt32 quality = kAudioConverterQuality_High;
    AudioConverterSetProperty(_audioConverter, kAudioConverterCodecQuality, sizeof(quality), &quality);

    if (_bitRate > 0) {
        UInt32 br = _bitRate;
        AudioConverterSetProperty(_audioConverter, kAudioConverterEncodeBitRate, sizeof(br), &br);
    }
    
    // 分配AAC输出缓冲区
    _aacBufferSize = 1024 * 4;
    _aacBuffer = malloc(_aacBufferSize);
    
    _isEncoding = YES;
    
    NSLog(@"✅ AACEncoder 初始化成功 (%.0fHz, %u通道)", sampleRate, (unsigned int)channels);
}

#pragma mark - 编码 PCM -> AAC
- (void)encodePCMData:(NSData *)pcmData pts:(CMTime)pts {
    if (!_isEncoding || !_audioConverter || pcmData.length == 0) return;
    
    // 输入缓冲区
    AudioBufferList inputBufferList;
    inputBufferList.mNumberBuffers = 1;
    inputBufferList.mBuffers[0].mNumberChannels = _inputASBD.mChannelsPerFrame;
    inputBufferList.mBuffers[0].mDataByteSize = (UInt32)pcmData.length;
    inputBufferList.mBuffers[0].mData = (void *)pcmData.bytes;
    
    // 输出缓冲区
    AudioBufferList outputBufferList;
    outputBufferList.mNumberBuffers = 1;
    outputBufferList.mBuffers[0].mNumberChannels = _outputASBD.mChannelsPerFrame;
    outputBufferList.mBuffers[0].mDataByteSize = _aacBufferSize;
    outputBufferList.mBuffers[0].mData = _aacBuffer;
    
    UInt32 ioOutputDataPacketSize = 1;
    
    OSStatus status = AudioConverterFillComplexBuffer(_audioConverter,
                                                      inputDataProc,
                                                      &inputBufferList,
                                                      &ioOutputDataPacketSize,
                                                      &outputBufferList,
                                                      NULL);
    if (status == noErr) {
        NSData *aacData = [NSData dataWithBytes:outputBufferList.mBuffers[0].mData
                                         length:outputBufferList.mBuffers[0].mDataByteSize];
        
        if ([self.delegate respondsToSelector:@selector(outAudioFrame:andPTS:)]) {
            [self.delegate outAudioFrame:aacData andPTS:pts];
        }
    } else {
        NSLog(@"❌ AAC编码失败: %d", (int)status);
    }
}

#pragma mark - AudioConverter 回调
static OSStatus inputDataProc(AudioConverterRef inAudioConverter,
                              UInt32 *ioNumberDataPackets,
                              AudioBufferList *ioData,
                              AudioStreamPacketDescription **outDataPacketDescription,
                              void *inUserData) {
    AudioBufferList *inputBufferList = (AudioBufferList *)inUserData;
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0] = inputBufferList->mBuffers[0];
    
    // 计算单个数据包的字节数（根据你的 PCM 格式）
    // 示例：16位（2字节）单声道 → 每个数据包 2 字节
    UInt32 bytesPerPacket = 2;
    
    // 总字节数
    UInt32 totalBytes = inputBufferList->mBuffers[0].mDataByteSize;
    
    // 动态计算数据包数量（确保不超过总字节数）
    *ioNumberDataPackets = totalBytes / bytesPerPacket;
    
    // 安全检查：避免数据包数量为 0
    if (*ioNumberDataPackets == 0) {
        return kAudioConverterErr_InvalidInputSize;
    }
    
    
    
    return noErr;
}

#pragma mark - 停止编码
- (void)stopEncoding {
    _isEncoding = NO;
    if (_audioConverter) {
        AudioConverterDispose(_audioConverter);
        _audioConverter = NULL;
    }
    if (_aacBuffer) {
        free(_aacBuffer);
        _aacBuffer = NULL;
    }
    NSLog(@"🛑 AACEncoder 已停止");
}

- (void)dealloc {
    [self stopEncoding];
}

@end
