#import "H264Encoder.h"
#import <VideoToolbox/VideoToolbox.h>

@interface H264Encoder()
@property(nonatomic,assign)VTCompressionSessionRef compressionSession;
@property(nonatomic,assign)CGSize videoSize;
@property(nonatomic,assign)int bitRate;
@property(nonatomic,assign)int fps;
@end

@implementation H264Encoder

-(instancetype)initWithVideSize:(CGSize)videoSize{
    return [self initWithVideSize:videoSize bitRate:4000000 fps:30];
}

-(instancetype)initWithVideSize:(CGSize)videoSize bitRate:(int)bitRate{
    return [self initWithVideSize:videoSize bitRate:bitRate fps:30];
}

-(instancetype)initWithVideSize:(CGSize)videoSize bitRate:(int)bitRate fps:(int)fps{
    self = [super init];
    if(self){
        _videoSize = videoSize;
        _bitRate = bitRate > 0 ? bitRate : 4000000;
        _fps = fps > 0 ? fps : 30;
        [self setupCompressionSession];
    }
    return self;
}

-(void)setupCompressionSession{
    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault,
                                                 (int)self.videoSize.width,
                                                 (int)self.videoSize.height,
                                                 kCMVideoCodecType_H264,
                                                 NULL,
                                                 NULL,
                                                 NULL,
                                                 encodingCompleteCallBack,
                                                 (__bridge void * _Nullable)self,
                                                 &_compressionSession);
    if(status != noErr){
        NSLog(@"创建压缩会话失败：%d",(int)status);
        return;
    }
    
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    
    int br = self.bitRate;
    CFNumberRef bitRate = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &br);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AverageBitRate, bitRate);
    CFRelease(bitRate);

    // GOP ≈ 1s，降低开播/追帧等待（原先固定 60 帧，在 30fps 下等于 2s）
    int fps = self.fps > 0 ? self.fps : 30;
    int keyInterval = fps;
    CFNumberRef keyFrameInterval = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &keyInterval);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, keyFrameInterval);
    CFRelease(keyFrameInterval);
    CFNumberRef keyDuration = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &(double){1.0});
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyDuration);
    CFRelease(keyDuration);

    CFNumberRef expectedFPS = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &fps);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ExpectedFrameRate, expectedFPS);
    CFRelease(expectedFPS);

    // 尽量不攒帧再出，降低编码端延迟
    int maxDelay = 0;
    CFNumberRef maxFrameDelay = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &maxDelay);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_MaxFrameDelayCount, maxFrameDelay);
    CFRelease(maxFrameDelay);

    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    
    status = VTCompressionSessionPrepareToEncodeFrames(_compressionSession);
    if(status != noErr){
        NSLog(@"准备编码会话失败:%d",(int)status);
    } else {
        NSLog(@"[H264] ready %.0fx%.0f %dkbps %dfps",
              self.videoSize.width, self.videoSize.height, self.bitRate / 1000, self.fps);
    }
}


-(void)encodeSampleBuffer:(CMSampleBufferRef)sampleBuffer{
    if(!_compressionSession){
        NSLog(@"压缩会话未初始化");
        return;
    }
    CMTime presentationTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
    
    VTEncodeInfoFlags flags;
    OSStatus status = VTCompressionSessionEncodeFrame(
                                                      _compressionSession,
                                                      CMSampleBufferGetImageBuffer(sampleBuffer),
                                                      presentationTime,
                                                      kCMTimeInvalid,
                                                      NULL,
                                                      NULL,
                                                      &flags);
    if(status != noErr){
        NSLog(@"编码帧失败:%d",(int)status);
    }
}

-(void)stopEncoding{
    if(_compressionSession){
        VTCompressionSessionCompleteFrames(_compressionSession, kCMTimeInvalid);
        VTCompressionSessionInvalidate(_compressionSession);
        CFRelease(_compressionSession);
        _compressionSession = NULL;
    }
}

// 编码完成回调一帧的数据
static void encodingCompleteCallBack(void *outputCallbackRefCon,
                                     void *sourcfFrameRefCon,
                                     OSStatus status,
                                     VTEncodeInfoFlags infoFlags,
                                     CMSampleBufferRef sampleBuffer){
    if (status != noErr || !sampleBuffer) {
        return;
    }
    
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    
    H264Encoder *encoder = (__bridge H264Encoder*)outputCallbackRefCon;
    // 判断是否为关键帧
    BOOL isKeyFrame = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    if(attachments){
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
        isKeyFrame = !CFDictionaryContainsKey(dict, kCMSampleAttachmentKey_NotSync);
    }
    // 获取SPS和PPS (仅关键帧包含)
    if(isKeyFrame){
        CMFormatDescriptionRef formatDes = CMSampleBufferGetFormatDescription(sampleBuffer);
        [encoder extractSPSAndPPSFromFormatDescription:formatDes andPTS:pts];
    }
    
    // 获取编码后的H.264数据
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t totalLength;
    char *dataPointer;
    OSStatus error = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPointer);
    if (error == noErr && totalLength > 0) {
        // 直接传递原始数据
        NSData *data = [NSData dataWithBytes:dataPointer length:totalLength];
        if ([encoder.delegate respondsToSelector:@selector(h264EncoderOutputFrameData:andPTS:isKeyFrame:)]) {
            [encoder.delegate h264EncoderOutputFrameData:data andPTS:pts isKeyFrame:isKeyFrame];
        }
//        [encoder validateH264Format:data frameDescription:@""];
    }
}

// 提取SPS和PPS（修正拼写错误）
-(void)extractSPSAndPPSFromFormatDescription:(CMFormatDescriptionRef)formatDes andPTS:(CMTime)pts{
    size_t spsCount;
    const uint8_t *spsData;
    size_t spsSize;
    
    size_t ppsCount; // 修正拼写错误
    const uint8_t *ppsData;
    size_t ppsSize;
    
    OSStatus status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDes,
                                                                         0,
                                                                         &spsData,
                                                                         &spsSize,
                                                                         &spsCount,
                                                                         NULL);
    OSStatus status2 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDes,
                                                                          1,
                                                                          &ppsData,
                                                                          &ppsSize,
                                                                          &ppsCount,
                                                                          NULL);
    if(status == noErr && status2 == noErr){
        NSData *sps = [NSData dataWithBytes:spsData length:spsSize];
        NSData *pps = [NSData dataWithBytes:ppsData length:ppsSize];
        if([self.delegate respondsToSelector:@selector(h264EncoderOutputSPS:PPS:andPTS:)]){
            [self.delegate h264EncoderOutputSPS:sps PPS:pps andPTS:pts];
        }
    }
    
}

-(void)dealloc{
    [self stopEncoding];
}


#pragma mark - 新增：H264格式验证（起始码/4字节分隔）
/**
 * 验证是否存在 H264 起始码（Annex B 格式：0x000001 / 0x00000001）
 * @param data 编码后的 H264 原始数据
 * @return 字典：@"hasStartCode": BOOL, @"count": NSNumber(起始码数量), @"positions": NSArray(起始码位置)
 */
- (NSDictionary *)validateH264StartCode:(NSData *)data {
    if (!data || data.length < 3) {
        return @{@"hasStartCode": @NO, @"count": @0, @"positions": @[]};
    }
    
    const uint8_t *bytes = data.bytes;
    NSUInteger dataLen = data.length;
    NSMutableArray *positions = [NSMutableArray array];
    NSUInteger offset = 0;
    NSInteger count = 0;
    
    // 遍历查找 3字节/4字节起始码
    while (offset <= dataLen - 3) {
        // 4字节起始码：0x00000001
        if (offset + 3 < dataLen && bytes[offset] == 0x00 && bytes[offset+1] == 0x00 && bytes[offset+2] == 0x00 && bytes[offset+3] == 0x01) {
            [positions addObject:@(offset)];
            count++;
            offset += 4; // 跳过已找到的起始码
        }
        // 3字节起始码：0x000001
        else if (bytes[offset] == 0x00 && bytes[offset+1] == 0x00 && bytes[offset+2] == 0x01) {
            [positions addObject:@(offset)];
            count++;
            offset += 3; // 跳过已找到的起始码
        } else {
            offset++;
        }
    }
    
    return @{
        @"hasStartCode": @(count > 0),
        @"count": @(count),
        @"positions": [positions copy]
    };
}

/**
 * 验证是否为 4字节长度分隔格式（AVCC 格式）
 * @param data 编码后的 H264 原始数据
 * @return 字典：@"is4ByteLength": BOOL, @"count": NSNumber(NALU数量), @"positions": NSArray(长度前缀位置)
 */
- (NSDictionary *)validateH2644ByteLength:(NSData *)data {
    if (!data || data.length < 4) {
        return @{@"is4ByteLength": @NO, @"count": @0, @"positions": @[]};
    }
    
    const uint8_t *bytes = data.bytes;
    NSUInteger dataLen = data.length;
    NSMutableArray *positions = [NSMutableArray array];
    NSUInteger offset = 0;
    NSInteger count = 0;
    
    // 按 4字节长度前缀解析
    while (offset < dataLen) {
        // 剩余数据不足 4字节（长度前缀），退出
        if (offset + 4 > dataLen) break;
        
        // 读取 4字节长度（大端模式）
        UInt32 naluSize = (UInt32)(bytes[offset] << 24 | bytes[offset+1] << 16 | bytes[offset+2] << 8 | bytes[offset+3]);
        // 长度无效（0 或 超过剩余数据），退出
        if (naluSize == 0 || (offset + 4 + naluSize) > dataLen) break;
        
        // 验证 NALU 头合法性（H264 规范：第1位为0，类型在 0-31 之间）
        UInt8 naluHeader = bytes[offset + 4];
        if ((naluHeader & 0x80) != 0 || (naluHeader & 0x1F) > 0x1F) break;
        
        [positions addObject:@(offset)];
        count++;
        offset += 4 + naluSize; // 跳到下一个长度前缀
    }
    
    // 有效条件：解析完所有数据 + 至少1个 NALU
    BOOL isValid = (offset == dataLen) && (count > 0);
    return @{
        @"is4ByteLength": @(isValid),
        @"count": @(count),
        @"positions": [positions copy]
    };
}

/**
 * 统一验证入口（打印结果，方便调用）
 * @param data 编码后的 H264 原始数据
 * @param frameDesc 帧描述（如“关键帧”“非关键帧”）
 */
- (void)validateH264Format:(NSData *)data frameDescription:(NSString *)frameDesc {
    if (!data) return;
    
    NSLog(@"===== H264格式验证：%@（数据长度：%lu字节）=====", frameDesc, (unsigned long)data.length);
    
    // 验证起始码
    NSDictionary *startCodeRes = [self validateH264StartCode:data];
    NSLog(@"[起始码验证] 是否存在：%@，数量：%@个，位置：%@",
          [startCodeRes[@"hasStartCode"] boolValue] ? @"是" : @"否",
          startCodeRes[@"count"],
          startCodeRes[@"positions"]);
    
    // 验证4字节长度分隔
    NSDictionary *fourByteRes = [self validateH2644ByteLength:data];
    NSLog(@"[4字节长度验证] 是否为该格式：%@，NALU数量：%@个，长度前缀位置：%@",
          [fourByteRes[@"is4ByteLength"] boolValue] ? @"是" : @"否",
          fourByteRes[@"count"],
          fourByteRes[@"positions"]);
    
    NSLog(@"=========================================\n");
}

@end

