//
//  RTMPStreamer.m
//  Media
//
//  Created by Stan on 2025/10/6.
//
/*
 1️⃣FLV裸流封装（你现在做的）

 视频：[FLV Video Tag Header] + [NALU Length + NALU Data]
 音频：[SoundFormat+Rate+Size+Type] + [AACPacketType] + [AAC Data]
 目的：生成 逻辑上的可播放单元（兼容播放器解码）。
 这一层可以视作 RTP Payload 的内容，但还不是 RTP 包本身。

 2️⃣ RTP封装

 在这个阶段才加上 RTP Header：
 序列号、时间戳、SSRC、Payload Type
 可能还会做 NALU 分片（FU-A）。
 然后通过 UDP/TCP 网络发送出去。
 这是完整的 RTP 协议包。
 
 在 RTP 协议里，每个 RTP 包由两部分组成：
 1️⃣ RTP Header（序列号、时间戳、SSRC 等，用于传输控制）
 2️⃣ RTP Payload（你现在封装的 FLV裸流就是这个部分）
 也就是说，你的封装 为 RTP 提供内容，但还需要在前面加上 RTP Header，可能还要做 NALU 分片、打包，才能真正成为可发送的 RTP 网络包。
 
 */
#import "RTMPStreamer.h"
#import <TargetConditionals.h>

#if TARGET_OS_SIMULATOR

@interface RTMPStreamer ()
@property (nonatomic, copy) NSString *rtmpURL;
@property (nonatomic, assign) BOOL isStreaming;
@end

@implementation RTMPStreamer
- (instancetype)initWithRTMPURL:(NSString *)rtmpURL {
    if ((self = [super init])) { _rtmpURL = [rtmpURL copy]; }
    return self;
}
- (BOOL)startStreaming {
    NSLog(@"[RTMP] Simulator stub — use device");
    self.isStreaming = YES;
    return YES;
}
- (void)stopStreaming { self.isStreaming = NO; }
- (void)sendSPS:(NSData *)sps PPS:(NSData *)pps andPTS:(CMTime)pts { (void)sps;(void)pps;(void)pts; }
- (void)sendVideoFrame:(NSData *)frameData andPTS:(CMTime)pts isKeyFrame:(BOOL)isKeyFrame { (void)frameData;(void)pts;(void)isKeyFrame; }
- (void)sendAudioFrame:(NSData *)aacData andPTS:(CMTime)pts { (void)aacData;(void)pts; }
- (void)configureAudioSampleRate:(int)sampleRate channels:(int)channels { (void)sampleRate;(void)channels; }
@end

#else

#import "RTMPStreamer.h"
#import "rtmp.h"
#import <QuartzCore/QuartzCore.h>

@interface RTMPStreamer ()
{
    RTMP *_rtmp;
    dispatch_queue_t _rtmpQueue;
    BOOL _hasSentAudioHeader;
    BOOL _hasTimestampBase;
    CFTimeInterval _timestampBaseHost;
}
@property (nonatomic, strong) NSString *rtmpURL;
@property (nonatomic, assign) BOOL isStreaming;
@end

@implementation RTMPStreamer

- (instancetype)initWithRTMPURL:(NSString *)rtmpURL {
    if (self = [super init]) {
        _rtmpURL = [rtmpURL copy];
        _rtmpQueue = dispatch_queue_create("com.example.RTMPStreamer", DISPATCH_QUEUE_SERIAL);
        _hasSentAudioHeader = NO;
        _hasTimestampBase = NO;
        _timestampBaseHost = 0;
    }
    return self;
}

/// 音视频统一用主机时钟相对时间戳，避免 Avatar 视频(从0)与麦克风音频(主机绝对 PTS)错位导致播放器狂缓冲。
- (uint32_t)rtmpTimestampMs {
    CFTimeInterval now = CACurrentMediaTime();
    if (!_hasTimestampBase) {
        _timestampBaseHost = now;
        _hasTimestampBase = YES;
    }
    double ms = (now - _timestampBaseHost) * 1000.0;
    if (ms < 0) ms = 0;
    return (uint32_t)ms;
}

- (void)configureAudioSampleRate:(int)sampleRate channels:(int)channels {
    // 与 Media 一致：FLV 固定 0xAF / ASC 0x12 0x10，此处保留空实现以兼容调用方
    (void)sampleRate;
    (void)channels;
}

- (BOOL)startStreaming {
    if (_isStreaming) return YES;
    
    _rtmp = RTMP_Alloc();
    RTMP_Init(_rtmp);
    
    if (!RTMP_SetupURL(_rtmp, (char *)[_rtmpURL UTF8String])) {
        NSLog(@"[RTMP] Failed to setup URL");
        RTMP_Free(_rtmp); _rtmp = NULL;
        return NO;
    }
    
    RTMP_EnableWrite(_rtmp);

    if (!RTMP_Connect(_rtmp, NULL)) {
        NSLog(@"[RTMP] Connect failed");
        RTMP_Free(_rtmp); _rtmp = NULL;
        return NO;
    }
    
    if (!RTMP_ConnectStream(_rtmp, 0)) {
        NSLog(@"[RTMP] Connect stream failed");
        RTMP_Close(_rtmp);
        RTMP_Free(_rtmp); _rtmp = NULL;
        return NO;
    }
    
    _hasTimestampBase = NO;
    _isStreaming = YES;
    NSLog(@"[RTMP] Streaming started");
    return YES;
}

- (void)stopStreaming {
    if (!_isStreaming && !_rtmp) return;
    
    dispatch_sync(_rtmpQueue, ^{
        if (self->_rtmp) {
            RTMP_Close(self->_rtmp);
            RTMP_Free(self->_rtmp);
            self->_rtmp = NULL;
        }
        self->_isStreaming = NO;
        self->_hasSentAudioHeader = NO;
        self->_hasTimestampBase = NO;
    });
    
    NSLog(@"[RTMP] Streaming stopped");
}

/*
 RTMP/FLV 要求视频流第一个包必须是 AVCDecoderConfigurationRecord。
 它告诉解码器：
 你的视频是哪个 Profile、Level；
 你的解码参数（SPS/PPS）。
 否则播放器不知道怎么解析后续 NALU。
 SPS/PPS 是 H.264 编码的解码配置信息，必须在发送视频帧之前先发给 RTMP 服务器。
 */
- (void)sendSPS:(NSData *)sps PPS:(NSData *)pps andPTS:(CMTime)pts {
    if (!_isStreaming || !_rtmp) return;
    //发送ACC的format消息
    [self sendAudioHeaderIfNeeded];
    
    dispatch_async(_rtmpQueue, ^{
        uint8_t *buffer = malloc(sps.length + pps.length + 1024);
        uint8_t *p = buffer;//因为uint8_t是8位 p++ 一次移动8位
        
        // ---------- [FLV VideoTag Header] ----------
        *p++ = 0x17; // 0x10 = keyframe, 0x07 = AVC (H.264) → 0x17 表示关键帧 + H.264 编码
        *p++ = 0x00; // AVCPacketType=0 → 表示是 AVCDecoderConfigurationRecord
        *p++ = 0x00; *p++ = 0x00; *p++ = 0x00; // composition time = 0
        
        // ---------- [AVCDecoderConfigurationRecord] ----------
        *p++ = 0x01; // configurationVersion 固定为1
        *p++ = ((uint8_t *)sps.bytes)[1]; // AVCProfileIndication
        *p++ = ((uint8_t *)sps.bytes)[2]; // profile_compatibility
        *p++ = ((uint8_t *)sps.bytes)[3]; // AVCLevelIndication
        *p++ = 0xff; // lengthSizeMinusOne = 4 bytes length NALU
        
        // SPS
        *p++ = 0xe1; // numOfSequenceParameterSets = 1 (只有一个 SPS)
        uint16_t spsLen = htons(sps.length);
        memcpy(p, &spsLen, 2); p += 2;
        memcpy(p, sps.bytes, sps.length); p += sps.length;
        
        // PPS
        *p++ = 0x01; // numOfPictureParameterSets = 1 (一个 PPS)
        uint16_t ppsLen = htons(pps.length);
        memcpy(p, &ppsLen, 2); p += 2;
        memcpy(p, pps.bytes, pps.length); p += pps.length;
        
        int bodySize = (int)(p - buffer);
        
        // ---------- [RTMPPacket 封装发送] ----------
        RTMPPacket packet;
        RTMPPacket_Alloc(&packet, bodySize);
        RTMPPacket_Reset(&packet);
        memcpy(packet.m_body, buffer, bodySize);
        
        packet.m_packetType = RTMP_PACKET_TYPE_VIDEO;   // 视频类型
        packet.m_nBodySize = bodySize;
        packet.m_nTimeStamp = 0;                        // 解码配置不需要时间戳
        packet.m_nChannel = 0x04;                       // 视频通道固定是 4
        packet.m_headerType = RTMP_PACKET_SIZE_LARGE;
        packet.m_hasAbsTimestamp = 0;
        packet.m_nInfoField2 = self->_rtmp->m_stream_id;
        
        RTMP_SendPacket(self->_rtmp, &packet, TRUE);
        RTMPPacket_Free(&packet);
        free(buffer);
    });
}

/*
 1.flv的裸数据  [FLV Video Tag Header] + [NALU Length + NALU Data] +  [NALU Length + NALU Data]....
 2.sendVideoFrame 是把每个NALU单独那出来封装为一个flv,[FLV Video Tag Header] + [NALU Length + NALU Data],只包含一个NALU
 3.是为了兼容性,让每个NALU都可以被各种场景解析
 
 =========================== 一种flv裸流封装==========================
 | 字段                 | 大小   | 描述
 | ------------------- | ----   | ----------------------------------
 | FrameType + CodecID | 1 字节 | 关键帧 0x17 / 非关键帧 0x27
 | AVCPacketType       | 1 字节 | 0 = SPS/PPS header, 1 = NALU frame
 | CompositionTime     | 3 字节 | PTS 偏移
 | NALU Length         | 4 字节 | 单个 NALU 的长度（大端）
 | NALU Data           | N 字节 | 真实 H.264 NALU 数据
*/
//VideoFrame -> NALU -> RTP消息(逻辑单元,flv都裸数据) -> RTMPPacket -> 网络发送真实的rtp包
- (void)sendVideoFrame:(NSData *)frameData andPTS:(CMTime)pts isKeyFrame:(BOOL)isKeyFrame {
    if (!_isStreaming || !_rtmp) return;
    
    dispatch_async(_rtmpQueue, ^{
        const uint8_t *data = frameData.bytes;
        int totalLen = (int)frameData.length;
        if (totalLen < 4) return;
        uint32_t ts = [self rtmpTimestampMs];
        
        // VideoToolbox 输出是 AVCC 格式: [length][NALU][length][NALU]...
        int offset = 0;
        /*
         offset + 4 < totalLen 的意义
         offset：当前解析的位置
         +4：因为每个 NALU 前面有 4 字节的长度字段
         这样就可以读取所有的nalu
         */
        while (offset + 4 < totalLen) {
            uint32_t nalLen = 0;
            memcpy(&nalLen, data + offset, 4);
            nalLen = CFSwapInt32BigToHost(nalLen);
            offset += 4;
            if (offset + nalLen > totalLen) break;
            
            const uint8_t *nalUnit = data + offset;
            uint8_t nalType = nalUnit[0] & 0x1F;
            if (nalType == 6) { // SEI 数据跳过
                offset += nalLen;
                continue;
            }
            
            // ---------- [FLV VideoTag Header] ----------
            uint8_t *body = malloc(nalLen + 9);
            uint8_t *p = body;
            *p++ = (nalType == 5) ? 0x17 : 0x27; // 关键帧:0x17, 普通帧:0x27
            *p++ = 0x01; // AVCPacketType=1 表示视频帧
            *p++ = 0x00; *p++ = 0x00; *p++ = 0x00; // composition time = 0
            
            // ---------- [H.264 NALU 数据] ----------
            uint32_t len = htonl(nalLen);   // NALU 长度 (大端)
            memcpy(p, &len, 4);
            memcpy(p + 4, nalUnit, nalLen);
            p += 4 + nalLen;
            
            int bodySize = (int)(p - body);
            
            // ---------- [RTMPPacket 封装发送] ----------
            RTMPPacket packet;
            RTMPPacket_Alloc(&packet, bodySize);
            RTMPPacket_Reset(&packet);
            memcpy(packet.m_body, body, bodySize);
            
            packet.m_packetType = RTMP_PACKET_TYPE_VIDEO;
            packet.m_nBodySize = bodySize;
            packet.m_nTimeStamp = ts;
            packet.m_nChannel = 0x04;
            packet.m_headerType = RTMP_PACKET_SIZE_MEDIUM;
            packet.m_nInfoField2 = self->_rtmp->m_stream_id;
            
            RTMP_SendPacket(self->_rtmp, &packet, TRUE);
            RTMPPacket_Free(&packet);
            free(body);
            
            offset += nalLen;
        }
        (void)pts;
        (void)isKeyFrame;
    });
}

#pragma mark - 音频发送部分

/*
 sendAudioHeaderIfNeeded封装head flv音频裸流1
 | 字段                        | 大小    | 描述                                     |
 |----------------------------|---------|-----------------------------------------|
 | SoundFormat+Rate+Size+Type | 1 字节   | AAC=10, 44kHz=3, 16bit=1, Stereo=1 → 0xAF |
 | AACPacketType              | 1 字节   | 0 = AAC Sequence Header (音频头)           |
 | AudioSpecificConfig        | 2 字节   | 0x12 0x10 → AAC LC, 44.1kHz, 2声道         |

 演示
 | 0xAF | 0x00 | 0x12 | 0x10 |
 
 说明
 0xAF      →  AAC + 44kHz + 16bit + Stereo
 0x00      →  AACPacketType = 0（音频头）
 0x12 0x10 →  AudioSpecificConfig（AAC LC, 44.1kHz, 2声道）
*/

//AAC format header, 一般只发送一次（与 Media 一致）
- (void)sendAudioHeaderIfNeeded {
    if (!_isStreaming || !_rtmp || _hasSentAudioHeader) return;
    
    // 0x12,0x10 对应 AAC-LC, 44100Hz, 双声道（同 Media）
    uint8_t audioConfig[] = { 0x12, 0x10 };
    uint8_t body[4];
    body[0] = 0xAF; // SoundFormat=10(AAC) + SoundRate=3(44kHz) + SoundSize=1(16bit) + SoundType=1(stereo)
    body[1] = 0x00; // AACPacketType=0 sequence header
    body[2] = audioConfig[0];
    body[3] = audioConfig[1];
    
    RTMPPacket packet;
    RTMPPacket_Alloc(&packet, sizeof(body));
    RTMPPacket_Reset(&packet);
    memcpy(packet.m_body, body, sizeof(body));
    
    packet.m_packetType = RTMP_PACKET_TYPE_AUDIO;
    packet.m_nBodySize = sizeof(body);
    packet.m_nTimeStamp = 0;
    packet.m_nChannel = 0x05;
    packet.m_headerType = RTMP_PACKET_SIZE_LARGE;
    packet.m_nInfoField2 = _rtmp->m_stream_id;
    
    RTMP_SendPacket(_rtmp, &packet, TRUE);
    RTMPPacket_Free(&packet);
    
    _hasSentAudioHeader = YES;
}

/*
 发送 AAC  数据帧
 AudioToolbox 输出的 AAC 通常不包含 ADTS Header，这是裸 AAC 数据
 
 sendAudioFrame封装aac数据flv音频裸流2
 | 字段                         | 大小   | 描述                                    |
 | -------------------------- | ---- | ----------------------------------------- |
 | SoundFormat+Rate+Size+Type | 1 字节 | AAC=10, 44kHz=3, 16bit=1, Stereo=1 → 0xAF |
 | AACPacketType              | 1 字节 | 1 = AAC Raw Frame (音频帧)                 |
 | AAC Data                   | N 字节 | AAC 编码后的音频帧数据（无 ADTS 头）           |

 
 演示
 | 0xAF | 0x01 | [AAC Raw Data...] |
 
 说明
 0xAF              → AAC + 44kHz + 16bit + Stereo
 0x01              → AACPacketType = 1（音频帧）
 [AAC Raw Data...] → AudioToolbox 输出的 AAC 数据（裸流）
 
*/
- (void)sendAudioFrame:(NSData *)aacData andPTS:(CMTime)pts {
    if (!_isStreaming || !_rtmp || !aacData) return;
    
    // 确保音频头已经发送
    [self sendAudioHeaderIfNeeded];
    
    dispatch_async(_rtmpQueue, ^{
        int bodySize = 2 + (int)aacData.length;
        uint8_t *body = malloc(bodySize);
        
        body[0] = 0xAF; // SoundFormat=10(AAC) + SoundRate=3(44kHz) + SoundSize=1(16bit) + SoundType=1(stereo)
        body[1] = 0x01; // AACPacketType=1 表示 raw 音频帧
        memcpy(&body[2], aacData.bytes, aacData.length);
        
        // 封装 RTMPPacket
        RTMPPacket packet;
        RTMPPacket_Alloc(&packet, bodySize);
        RTMPPacket_Reset(&packet);
        memcpy(packet.m_body, body, bodySize);
        
        packet.m_packetType = RTMP_PACKET_TYPE_AUDIO;   // 音频类型
        packet.m_nBodySize = bodySize;                  // body 长度
        packet.m_nTimeStamp = [self rtmpTimestampMs];
        packet.m_nChannel = 0x05;                       // 音频通道固定为 5
        packet.m_headerType = RTMP_PACKET_SIZE_MEDIUM;  // 视频帧用 medium 头，音频同样可用
        packet.m_nInfoField2 = self->_rtmp->m_stream_id;
        
        RTMP_SendPacket(self->_rtmp, &packet, TRUE);
        RTMPPacket_Free(&packet);
        free(body);
        (void)pts;
    });
}
/*
 ============================== ADTS ===========================
 | 字段                        | 大小      | 描述                         |
 | ------------------------- | ------- | -------------------------- |
 | syncword                  | 12 bits | 0xFFF 同步字                  |
 | ID                        | 1 bit   | MPEG 版本标识                  |
 | layer                     | 2 bits  | 固定 0                       |
 | protection_absent         | 1 bit   | 是否有 CRC                    |
 | profile                   | 2 bits  | AAC Profile (0=Main, 1=LC) |
 | sampling_frequency_index  | 4 bits  | 采样率索引                      |
 | private_bit               | 1 bit   | 私有                         |
 | channel_configuration     | 3 bits  | 声道数                        |
 | original/copy             | 1 bit   | 原始或复制标识                    |
 | home                      | 1 bit   | 家庭标识                       |
 | frame_length              | 13 bits | 当前帧 AAC 数据长度 + header 长度   |
 | buffer_fullness           | 11 bits | VBV 相关                     |
 | number_of_raw_data_blocks | 2 bits  | 0 表示只有一帧 AAC 数据            |
                            
                       [AAC Raw Data]

 */
@end

#endif
