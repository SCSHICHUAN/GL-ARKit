/*
  SCARFaceProjector.m
  ARFaceAnchor → 头姿 / 注视角 / blendShape 权重（规范名）。
  骨与 morph 绑定在 SCRendererData::applyFaceDrive（见 README）。
*/

#import "SCARFaceProjector.h"

@implementation SCARFaceProjection

- (NSDictionary<NSString *, NSNumber *> *)morphWeights {
    NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:self.eyeWeights ?: @{}];
    [all addEntriesFromDictionary:self.faceWeights ?: @{}];
    return [all copy];
}

- (NSInteger)activeMorphCount {
    return self.activeEyeCount + self.activeFaceCount;
}

@end

@interface SCARFaceProjector ()
@property (nonatomic, assign) BOOL hasRest;
@property (nonatomic, assign) simd_float3 restPosition;
@property (nonatomic, assign) simd_quatf restOrientation;
@property (nonatomic, assign) BOOL hasSmoothedHead;
@property (nonatomic, assign) simd_float3 smoothPosition;
@property (nonatomic, assign) simd_quatf smoothOrientation;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *smoothWeights;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *aliasToCanonical;
@property (nonatomic, assign) BOOL hasSmoothedGaze;
@property (nonatomic, assign) BOOL hasRestGaze;
@property (nonatomic, assign) simd_quatf restEyeQuatL;
@property (nonatomic, assign) simd_quatf restEyeQuatR;
@property (nonatomic, assign) simd_quatf smoothEyeQuatL;
@property (nonatomic, assign) simd_quatf smoothEyeQuatR;
/// Look blendShape 回退时的欧拉平滑状态
@property (nonatomic, assign) float smoothEyePitchL;
@property (nonatomic, assign) float smoothEyeYawL;
@property (nonatomic, assign) float smoothEyePitchR;
@property (nonatomic, assign) float smoothEyeYawR;
@end

/// Apple：left/rightEyeTransform 的 +Z 指向瞳孔方向（不是 -Z）。
/// 用相对休息姿态的四元数再解 pitch/yaw，避免绝对值落在 ±π 附近导致 atan2 跳变。
static void SCARPitchYawFromRelQuat(simd_quatf rel, float *outPitch, float *outYaw) {
    simd_float3 forward = simd_act(rel, simd_make_float3(0.f, 0.f, 1.f));
    float len2 = simd_dot(forward, forward);
    if (len2 < 1e-12f) {
        *outPitch = 0.f;
        *outYaw = 0.f;
        return;
    }
    forward *= 1.f / sqrtf(len2);
    *outPitch = asinf(fmaxf(-1.f, fminf(1.f, forward.y)));
    *outYaw = atan2f(forward.x, forward.z);
}

@implementation SCARFaceProjector

- (instancetype)init {
    self = [super init];
    if (self) {
        _smoothing = 0.35f;
        _activeThreshold = 0.05f;
        _smoothWeights = [NSMutableDictionary dictionary];
        _aliasToCanonical = [[self class] defaultAliasMap];
        _restOrientation = simd_quaternion(0.f, 0.f, 0.f, 1.f);
        _smoothOrientation = _restOrientation;
        _restEyeQuatL = _restOrientation;
        _restEyeQuatR = _restOrientation;
        _smoothEyeQuatL = _restOrientation;
        _smoothEyeQuatR = _restOrientation;
    }
    return self;
}

- (void)reset {
    self.hasRest = NO;
    self.hasSmoothedHead = NO;
    self.hasSmoothedGaze = NO;
    self.hasRestGaze = NO;
    [self.smoothWeights removeAllObjects];
}

- (void)calibrateRestFromFace:(SCARFaceData *)face {
    if (!face.head) return;
    self.restPosition = face.head.position;
    self.restOrientation = face.head.orientation;
    self.hasRest = YES;
}

- (SCARFaceProjection *)projectFace:(SCARFaceData *)face {
    SCARFaceProjection *out = [[SCARFaceProjection alloc] init];
    out.eyeWeights = @{};
    out.faceWeights = @{};
    out.headOrientation = simd_quaternion(0.f, 0.f, 0.f, 1.f);

    if (!face) return out;

    // —— 头 ——
    if (face.head) {
        if (!self.hasRest) {
            [self calibrateRestFromFace:face];
        }
        simd_float3 relPos = face.head.position - self.restPosition;
        simd_quatf relOri = simd_mul(simd_inverse(self.restOrientation), face.head.orientation);

        const float a = fminf(fmaxf(self.smoothing, 0.f), 0.95f);
        if (!self.hasSmoothedHead || a <= 1e-6f) {
            self.smoothPosition = relPos;
            self.smoothOrientation = relOri;
            self.hasSmoothedHead = YES;
        } else {
            self.smoothPosition = self.smoothPosition * a + relPos * (1.f - a);
            self.smoothOrientation = simd_slerp(self.smoothOrientation, relOri, 1.f - a);
        }
        out.headPosition = self.smoothPosition;
        out.headOrientation = self.smoothOrientation;
        out.headValid = YES;
    }

    // —— 眼睛 / 脸部 morph ——
    NSMutableDictionary<NSString *, NSNumber *> *eyes = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *faces = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSNumber *> *src = face.blendShapes ?: @{};
    const float a = fminf(fmaxf(self.smoothing, 0.f), 0.95f);

    [src enumerateKeysAndObjectsUsingBlock:^(NSString *rawKey, NSNumber *val, BOOL *stop) {
        NSString *name = [self canonicalMorphNameForKey:rawKey];
        if (self.targetMorphNames.count > 0 && ![self.targetMorphNames containsObject:name]) {
            return;
        }
        float v = fminf(fmaxf(val.floatValue, 0.f), 1.f);
        NSNumber *prev = self.smoothWeights[name];
        if (prev && a > 1e-6f) {
            v = prev.floatValue * a + v * (1.f - a);
        }
        self.smoothWeights[name] = @(v);

        if ([[self class] channelForMorphName:name] == SCARFaceMorphChannelEye) {
            eyes[name] = @(v);
        } else {
            faces[name] = @(v);
        }
    }];

    if (self.targetMorphNames.count > 0) {
        for (NSString *name in self.targetMorphNames) {
            NSNumber *v = self.smoothWeights[name] ?: @(0.f);
            if ([[self class] channelForMorphName:name] == SCARFaceMorphChannelEye) {
                if (!eyes[name]) eyes[name] = v;
            } else {
                if (!faces[name]) faces[name] = v;
            }
        }
    }

    NSInteger activeEye = 0, activeFace = 0;
    for (NSNumber *n in eyes.allValues) {
        if (n.floatValue > self.activeThreshold) activeEye++;
    }
    for (NSNumber *n in faces.allValues) {
        if (n.floatValue > self.activeThreshold) activeFace++;
    }

    out.eyeWeights = [eyes copy];
    out.faceWeights = [faces copy];
    out.activeEyeCount = activeEye;
    out.activeFaceCount = activeFace;

    // —— 眼球注视 ——
    // 核心：ARKit 瞳孔朝 +Z。旧代码用 -Z → yaw≈±π，atan2 跨缝就一跳一跳。
    // 做法：相对休息姿态的四元数 slerp，再解小角度 pitch/yaw。
    float pitchL = 0.f, yawL = 0.f, pitchR = 0.f, yawR = 0.f;
    if (face.hasEyeTransforms) {
        simd_quatf qL = simd_quaternion(face.leftEyeTransform);
        simd_quatf qR = simd_quaternion(face.rightEyeTransform);
        if (!self.hasRestGaze) {
            self.restEyeQuatL = qL;
            self.restEyeQuatR = qR;
            self.hasRestGaze = YES;
        }
        simd_quatf relL = simd_mul(simd_inverse(self.restEyeQuatL), qL);
        simd_quatf relR = simd_mul(simd_inverse(self.restEyeQuatR), qR);

        const float ga = fminf(fmaxf(self.smoothing, 0.f), 0.95f);
        if (!self.hasSmoothedGaze || ga <= 1e-6f) {
            self.smoothEyeQuatL = relL;
            self.smoothEyeQuatR = relR;
            self.hasSmoothedGaze = YES;
        } else {
            float t = 1.f - ga;
            self.smoothEyeQuatL = simd_slerp(self.smoothEyeQuatL, relL, t);
            self.smoothEyeQuatR = simd_slerp(self.smoothEyeQuatR, relR, t);
        }

        SCARPitchYawFromRelQuat(self.smoothEyeQuatL, &pitchL, &yawL);
        SCARPitchYawFromRelQuat(self.smoothEyeQuatR, &pitchR, &yawR);
        // 左右幅度偏小：yaw 放大（pitch 略增）
        const float kPitch = 1.15f;
        const float kYaw = 2.0f;
        pitchL *= kPitch; pitchR *= kPitch;
        yawL *= kYaw; yawR *= kYaw;
    } else {
        const float kBS = 0.95f;
        float pL = (eyes[@"eyeLookUpLeft"].floatValue - eyes[@"eyeLookDownLeft"].floatValue) * kBS;
        float pR = (eyes[@"eyeLookUpRight"].floatValue - eyes[@"eyeLookDownRight"].floatValue) * kBS;
        float yL = (eyes[@"eyeLookInLeft"].floatValue - eyes[@"eyeLookOutLeft"].floatValue) * kBS;
        float yR = (eyes[@"eyeLookOutRight"].floatValue - eyes[@"eyeLookInRight"].floatValue) * kBS;
        pitchL = pitchR = 0.5f * (pL + pR);
        yawL = yawR = 0.5f * (yL + yR);

        const float ga = fminf(fmaxf(self.smoothing, 0.f), 0.95f);
        if (!self.hasSmoothedGaze || ga <= 1e-6f) {
            self.smoothEyePitchL = pitchL;
            self.smoothEyeYawL = yawL;
            self.smoothEyePitchR = pitchR;
            self.smoothEyeYawR = yawR;
            self.hasSmoothedGaze = YES;
        } else {
            float t = 1.f - ga;
            self.smoothEyePitchL += (pitchL - self.smoothEyePitchL) * t;
            self.smoothEyeYawL   += (yawL   - self.smoothEyeYawL)   * t;
            self.smoothEyePitchR += (pitchR - self.smoothEyePitchR) * t;
            self.smoothEyeYawR   += (yawR   - self.smoothEyeYawR)   * t;
        }
        pitchL = self.smoothEyePitchL;
        yawL = self.smoothEyeYawL;
        pitchR = self.smoothEyePitchR;
        yawR = self.smoothEyeYawR;
    }
    out.eyePitchLeft = pitchL;
    out.eyeYawLeft = yawL;
    out.eyePitchRight = pitchR;
    out.eyeYawRight = yawR;
    out.eyeGazeValid = YES;

    return out;
}

- (NSString *)canonicalMorphNameForKey:(NSString *)rawKey {
    if (rawKey.length == 0) return rawKey;
    NSString *key = rawKey;
    NSString *lower = rawKey.lowercaseString;
    if ([lower hasPrefix:@"arbendshapelocation"]) {
        key = [rawKey substringFromIndex:@"ARBlendShapeLocation".length];
        if (key.length > 0) {
            key = [[[key substringToIndex:1] lowercaseString] stringByAppendingString:[key substringFromIndex:1]];
        }
    }
    NSString *mapped = self.aliasToCanonical[key];
    if (mapped) return mapped;
    mapped = self.aliasToCanonical[key.lowercaseString];
    if (mapped) return mapped;
    return key;
}

+ (SCARFaceMorphChannel)channelForMorphName:(NSString *)name {
    if (name.length == 0) return SCARFaceMorphChannelFace;
    // ARKit 眼部一律以 eye 开头（Blink/Look/Squint/Wide）
    if ([name.lowercaseString hasPrefix:@"eye"]) {
        return SCARFaceMorphChannelEye;
    }
    static NSSet<NSString *> *eyeSet;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        eyeSet = [NSSet setWithArray:[self arkitEyeBlendShapeNames]];
    });
    if ([eyeSet containsObject:name]) return SCARFaceMorphChannelEye;
    return SCARFaceMorphChannelFace;
}

+ (NSDictionary<NSString *, NSString *> *)defaultAliasMap {
    return @{
        @"eyeblink_l": @"eyeBlinkLeft",
        @"eyeblink_r": @"eyeBlinkRight",
        @"eyeblinkleft": @"eyeBlinkLeft",
        @"eyeblinkright": @"eyeBlinkRight",
        @"jaw_open": @"jawOpen",
        @"jawopen": @"jawOpen",
        @"mouthsmile_l": @"mouthSmileLeft",
        @"mouthsmile_r": @"mouthSmileRight",
        @"mouthsmileleft": @"mouthSmileLeft",
        @"mouthsmileright": @"mouthSmileRight",
        @"browinnerup": @"browInnerUp",
        @"brow_inner_up": @"browInnerUp",
        @"mouthpucker": @"mouthPucker",
        @"tongueout": @"tongueOut",
        @"mouthfunnel": @"mouthFunnel",
        @"mouthshrugupper": @"mouthShrugUpper",
        @"mouthshruglower": @"mouthShrugLower",
        @"mouthclose": @"mouthClose",
        @"mouthfrownleft": @"mouthFrownLeft",
        @"mouthfrownright": @"mouthFrownRight",
        @"mouthdimpleleft": @"mouthDimpleLeft",
        @"mouthdimpleright": @"mouthDimpleRight",
        @"mouthupperupleft": @"mouthUpperUpLeft",
        @"mouthupperupright": @"mouthUpperUpRight",
        @"mouthlowerdownleft": @"mouthLowerDownLeft",
        @"mouthlowerdownright": @"mouthLowerDownRight",
        @"mouthpressleft": @"mouthPressLeft",
        @"mouthpressright": @"mouthPressRight",
        @"mouthstretchleft": @"mouthStretchLeft",
        @"mouthstretchright": @"mouthStretchRight",
        @"mouthleft": @"mouthLeft",
        @"mouthright": @"mouthRight",
        @"mouthrollupper": @"mouthRollUpper",
        @"mouthrolllower": @"mouthRollLower",
        @"browdownleft": @"browDownLeft",
        @"browdownright": @"browDownRight",
        @"browouterupleft": @"browOuterUpLeft",
        @"browouterupright": @"browOuterUpRight",
        @"cheekpuff": @"cheekPuff",
        @"cheeksquintleft": @"cheekSquintLeft",
        @"cheeksquintright": @"cheekSquintRight",
        @"eyesquintleft": @"eyeSquintLeft",
        @"eyesquintright": @"eyeSquintRight",
        @"eyewideleft": @"eyeWideLeft",
        @"eyewideright": @"eyeWideRight",
        @"eyelookupleft": @"eyeLookUpLeft",
        @"eyelookupright": @"eyeLookUpRight",
        @"eyelookdownleft": @"eyeLookDownLeft",
        @"eyelookdownright": @"eyeLookDownRight",
        @"eyelookinleft": @"eyeLookInLeft",
        @"eyelookinright": @"eyeLookInRight",
        @"eyelookoutleft": @"eyeLookOutLeft",
        @"eyelookoutright": @"eyeLookOutRight",
        @"nosesneerleft": @"noseSneerLeft",
        @"nosesneerright": @"noseSneerRight",
    };
}

+ (NSArray<NSString *> *)arkitEyeBlendShapeNames {
    return @[
        @"eyeBlinkLeft", @"eyeBlinkRight",
        @"eyeLookDownLeft", @"eyeLookDownRight",
        @"eyeLookInLeft", @"eyeLookInRight",
        @"eyeLookOutLeft", @"eyeLookOutRight",
        @"eyeLookUpLeft", @"eyeLookUpRight",
        @"eyeSquintLeft", @"eyeSquintRight",
        @"eyeWideLeft", @"eyeWideRight",
    ];
}

+ (NSArray<NSString *> *)arkitFaceBlendShapeNames {
    return @[
        @"browDownLeft", @"browDownRight",
        @"browInnerUp",
        @"browOuterUpLeft", @"browOuterUpRight",
        @"cheekPuff", @"cheekSquintLeft", @"cheekSquintRight",
        @"noseSneerLeft", @"noseSneerRight",
        @"jawOpen", @"jawForward", @"jawLeft", @"jawRight",
        @"mouthFunnel", @"mouthPucker", @"mouthClose",
        @"mouthSmileLeft", @"mouthSmileRight",
        @"mouthFrownLeft", @"mouthFrownRight",
        @"mouthDimpleLeft", @"mouthDimpleRight",
        @"mouthUpperUpLeft", @"mouthUpperUpRight",
        @"mouthLowerDownLeft", @"mouthLowerDownRight",
        @"mouthPressLeft", @"mouthPressRight",
        @"mouthStretchLeft", @"mouthStretchRight",
        @"mouthLeft", @"mouthRight",
        @"mouthRollUpper", @"mouthRollLower",
        @"mouthShrugUpper", @"mouthShrugLower",
        @"tongueOut",
    ];
}

+ (NSArray<NSString *> *)arkitBlendShapeNames {
    NSMutableArray *all = [NSMutableArray arrayWithArray:[self arkitEyeBlendShapeNames]];
    [all addObjectsFromArray:[self arkitFaceBlendShapeNames]];
    return [all copy];
}

@end
