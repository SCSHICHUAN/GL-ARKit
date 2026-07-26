/*
  SCARFaceProjector.h
  ARFaceAnchor → 角色驱动量（不碰 GL）：
  - 头：相对休息姿态的位置 / 四元数（再由 VC 解 yaw/pitch/roll）
  - 眼：blink / look / squint / wide + left/rightEyeTransform → pitch/yaw
  - 脸：眉 / 颊 / 鼻 / 颌 / 嘴 / tongueOut
  权重名与 Apple ARBlendShapeLocation 对齐；具体骨/morph 见 README。
*/

#import <Foundation/Foundation.h>
#import <simd/simd.h>
#import "SCARTypes.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCARFaceMorphChannel) {
    SCARFaceMorphChannelEye = 0,
    SCARFaceMorphChannelFace = 1,
};

/// 一次投射结果（头 / 眼睛 / 脸部分开）。
@interface SCARFaceProjection : NSObject
@property (nonatomic, assign) simd_float3 headPosition;       // 相对校准原点
@property (nonatomic, assign) simd_quatf headOrientation;     // 相对校准朝向
@property (nonatomic, assign) BOOL headValid;

/// 眼睛 morph 名 → 权重（0..1）
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *eyeWeights;
/// 脸部 morph 名 → 权重（0..1）
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *faceWeights;
/// 眼睛 + 脸部合并（兼容旧调用）
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *morphWeights;

@property (nonatomic, assign) NSInteger activeEyeCount;
@property (nonatomic, assign) NSInteger activeFaceCount;
@property (nonatomic, assign, readonly) NSInteger activeMorphCount;

/// 由 left/rightEyeTransform 解出的注视角（弧度，相对休息姿态）；无眼变换时用 Look blendShape 回退
@property (nonatomic, assign) float eyePitchLeft;
@property (nonatomic, assign) float eyeYawLeft;
@property (nonatomic, assign) float eyePitchRight;
@property (nonatomic, assign) float eyeYawRight;
@property (nonatomic, assign) BOOL eyeGazeValid;
@end

@interface SCARFaceProjector : NSObject

/// 指数平滑 0..1（0=不平滑，越大越钝）。默认 0.35。
@property (nonatomic, assign) float smoothing;
/// 计为「激活」的权重阈值。默认 0.05。
@property (nonatomic, assign) float activeThreshold;

/// 可选：模型实际拥有的 morph 名。设置后只输出能对上（含别名）的项。
@property (nonatomic, copy, nullable) NSSet<NSString *> *targetMorphNames;

/// 用当前帧作为「休息」头姿（相对量从此刻起算）。未校准时第一次 project 会自动校准。
- (void)calibrateRestFromFace:(SCARFaceData *)face;

/// ARKit Face → 投射结果（头 / 眼 / 脸）。
- (SCARFaceProjection *)projectFace:(SCARFaceData *)face;

/// 重置平滑状态与校准。
- (void)reset;

/// 规范 morph 名属于哪一路（眼 / 脸）。未知名默认归脸部。
+ (SCARFaceMorphChannel)channelForMorphName:(NSString *)name;

+ (NSArray<NSString *> *)arkitEyeBlendShapeNames;
+ (NSArray<NSString *> *)arkitFaceBlendShapeNames;
/// 全部 52 名（眼 + 脸）。
+ (NSArray<NSString *> *)arkitBlendShapeNames;

@end

NS_ASSUME_NONNULL_END
