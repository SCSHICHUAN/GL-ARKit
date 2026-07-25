/*
  SCARKitSession.mm
  ARSession wrapper — dumps head / body / face data; no model binding yet.
*/

#import "SCARKitSession.h"
#import <ARKit/ARKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

static simd_quatf SCARQuatFromTransform(simd_float4x4 m) {
    simd_float3x3 r = {
        .columns[0] = simd_make_float3(m.columns[0].x, m.columns[0].y, m.columns[0].z),
        .columns[1] = simd_make_float3(m.columns[1].x, m.columns[1].y, m.columns[1].z),
        .columns[2] = simd_make_float3(m.columns[2].x, m.columns[2].y, m.columns[2].z),
    };
    return simd_quaternion(r);
}

@interface SCARKitSession () <ARSessionDelegate>
@property (nonatomic, strong) ARSession *session;
@property (nonatomic, assign, readwrite) SCARKitTrackingMode mode;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, assign) CFTimeInterval lastLogTime;
@end

@implementation SCARKitSession

+ (BOOL)isFaceTrackingSupported {
    return [ARFaceTrackingConfiguration isSupported];
}

+ (BOOL)isBodyTrackingSupported {
    if (@available(iOS 13.0, *)) {
        return [ARBodyTrackingConfiguration isSupported];
    }
    return NO;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _session = [[ARSession alloc] init];
        _session.delegate = self;
        // Deliver anchors on main so UI / logging stay simple.
        _session.delegateQueue = dispatch_get_main_queue();
        _logInterval = 0.5;
        _mode = SCARKitTrackingModeFace;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)startWithMode:(SCARKitTrackingMode)mode {
    // Camera permission first — otherwise ARSession fails silently / errors on device.
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusNotDetermined) {
        __weak typeof(self) weakSelf = self;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!granted) {
                    NSString *msg = @"相机权限被拒绝，请到 设置 → 隐私 → 相机 打开";
                    NSLog(@"[ARKit] %@", msg);
                    if ([weakSelf.delegate respondsToSelector:@selector(arSession:didFailWithMessage:)]) {
                        [weakSelf.delegate arSession:weakSelf didFailWithMessage:msg];
                    }
                    return;
                }
                [weakSelf startWithMode:mode];
            });
        }];
        NSLog(@"[ARKit] requesting camera permission…");
        return NO;
    }
    if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
        NSString *msg = @"相机权限不可用，请到 设置 → 隐私 → 相机 打开";
        NSLog(@"[ARKit] %@", msg);
        if ([self.delegate respondsToSelector:@selector(arSession:didFailWithMessage:)]) {
            [self.delegate arSession:self didFailWithMessage:msg];
        }
        return NO;
    }

    NSString *err = nil;
    ARConfiguration *config = [self configurationForMode:mode errorMessage:&err];
    if (!config) {
        NSString *msg = err ?: @"ARKit configuration unavailable";
        NSLog(@"[ARKit] start failed: %@", msg);
        if ([self.delegate respondsToSelector:@selector(arSession:didFailWithMessage:)]) {
            [self.delegate arSession:self didFailWithMessage:msg];
        }
        return NO;
    }

    self.mode = mode;
    self.lastLogTime = 0;
    [self.session runWithConfiguration:config
                               options:ARSessionRunOptionResetTracking | ARSessionRunOptionRemoveExistingAnchors];
    self.running = YES;
    NSLog(@"[ARKit] started mode=%@ faceSupported=%d bodySupported=%d",
          mode == SCARKitTrackingModeFace ? @"Face(head+blendShapes)" : @"Body(skeleton)",
          (int)[SCARKitSession isFaceTrackingSupported],
          (int)[SCARKitSession isBodyTrackingSupported]);
    if ([self.delegate respondsToSelector:@selector(arSession:didChangeMode:)]) {
        [self.delegate arSession:self didChangeMode:mode];
    }
    return YES;
}

- (void)switchToMode:(SCARKitTrackingMode)mode {
    if (self.running && self.mode == mode) return;
    [self startWithMode:mode];
}

- (void)stop {
    if (!self.running) return;
    [self.session pause];
    self.running = NO;
    NSLog(@"[ARKit] stopped");
}

#pragma mark - Config

- (ARConfiguration *)configurationForMode:(SCARKitTrackingMode)mode errorMessage:(NSString **)outMsg {
    if (mode == SCARKitTrackingModeFace) {
        if (![ARFaceTrackingConfiguration isSupported]) {
            if (outMsg) *outMsg = @"Face tracking unsupported (needs TrueDepth / real device)";
            return nil;
        }
        ARFaceTrackingConfiguration *cfg = [[ARFaceTrackingConfiguration alloc] init];
        if (@available(iOS 13.0, *)) {
            cfg.maximumNumberOfTrackedFaces = 1;
        }
        return cfg;
    }

    if (@available(iOS 13.0, *)) {
        if (![ARBodyTrackingConfiguration isSupported]) {
            if (outMsg) *outMsg = @"Body tracking unsupported (needs A12+ / rear camera)";
            return nil;
        }
        return [[ARBodyTrackingConfiguration alloc] init];
    }
    if (outMsg) *outMsg = @"Body tracking requires iOS 13+";
    return nil;
}

#pragma mark - ARSessionDelegate

- (void)session:(ARSession *)session didUpdateAnchors:(NSArray<__kindof ARAnchor *> *)anchors {
    for (ARAnchor *anchor in anchors) {
        if ([anchor isKindOfClass:[ARFaceAnchor class]]) {
            [self handleFaceAnchor:(ARFaceAnchor *)anchor];
        } else if (@available(iOS 13.0, *)) {
            if ([anchor isKindOfClass:[ARBodyAnchor class]]) {
                [self handleBodyAnchor:(ARBodyAnchor *)anchor];
            }
        }
    }
}

- (void)session:(ARSession *)session didFailWithError:(NSError *)error {
    NSString *msg = error.localizedDescription ?: @"ARSession failed";
    NSLog(@"[ARKit] session error: %@", msg);
    if ([self.delegate respondsToSelector:@selector(arSession:didFailWithMessage:)]) {
        [self.delegate arSession:self didFailWithMessage:msg];
    }
}

- (void)sessionWasInterrupted:(ARSession *)session {
    NSLog(@"[ARKit] session interrupted");
}

- (void)sessionInterruptionEnded:(ARSession *)session {
    NSLog(@"[ARKit] session interruption ended — restarting");
    [self startWithMode:self.mode];
}

#pragma mark - Face → head + blend shapes

- (void)handleFaceAnchor:(ARFaceAnchor *)faceAnchor {
    SCARHeadData *head = [[SCARHeadData alloc] init];
    head.transform = faceAnchor.transform;
    head.position = simd_make_float3(faceAnchor.transform.columns[3].x,
                                     faceAnchor.transform.columns[3].y,
                                     faceAnchor.transform.columns[3].z);
    head.orientation = SCARQuatFromTransform(faceAnchor.transform);
    head.source = @"face";

    NSMutableDictionary<NSString *, NSNumber *> *shapes = [NSMutableDictionary dictionary];
    [faceAnchor.blendShapes enumerateKeysAndObjectsUsingBlock:^(ARBlendShapeLocation key, NSNumber *value, BOOL *stop) {
        shapes[key] = value;
    }];

    SCARFaceData *face = [[SCARFaceData alloc] init];
    face.head = head;
    face.blendShapes = shapes;
    face.geometryVertexCount = faceAnchor.geometry ? (NSInteger)faceAnchor.geometry.vertexCount : 0;
    face.leftEyeTransform = faceAnchor.leftEyeTransform;
    face.rightEyeTransform = faceAnchor.rightEyeTransform;
    face.hasEyeTransforms = YES;

    if ([self.delegate respondsToSelector:@selector(arSession:didUpdateFace:)]) {
        [self.delegate arSession:self didUpdateFace:face];
    }

    if ([self shouldLog]) {
        [self logFace:face];
    }
}

#pragma mark - Body → joints + head

- (void)handleBodyAnchor:(ARBodyAnchor *)bodyAnchor API_AVAILABLE(ios(13.0)) {
    SCARBodyData *body = [[SCARBodyData alloc] init];
    NSMutableArray<SCARBodyJoint *> *joints = [NSMutableArray array];

    ARSkeleton3D *skeleton = bodyAnchor.skeleton;
    ARSkeletonDefinition *def = skeleton.definition;
    NSInteger jointCount = (NSInteger)def.jointCount;
    const simd_float4x4 *modelTransforms = skeleton.jointModelTransforms;
    NSArray<NSString *> *jointNames = def.jointNames;

    for (NSInteger i = 0; i < jointCount; i++) {
        simd_float4x4 world = simd_mul(bodyAnchor.transform, modelTransforms[i]);

        SCARBodyJoint *j = [[SCARBodyJoint alloc] init];
        j.name = (i < (NSInteger)jointNames.count) ? jointNames[i] : [NSString stringWithFormat:@"joint_%ld", (long)i];
        j.position = simd_make_float3(world.columns[3].x, world.columns[3].y, world.columns[3].z);
        j.orientation = SCARQuatFromTransform(world);
        j.tracked = [skeleton isJointTracked:i];
        [joints addObject:j];
    }
    body.joints = joints;

    NSInteger headIndex = [def indexForJointName:ARSkeletonJointNameHead];
    if (headIndex != NSNotFound && headIndex < joints.count) {
        SCARBodyJoint *hj = joints[headIndex];
        SCARHeadData *head = [[SCARHeadData alloc] init];
        head.transform = simd_mul(bodyAnchor.transform, modelTransforms[headIndex]);
        head.position = hj.position;
        head.orientation = hj.orientation;
        head.source = @"body";
        body.head = head;
    }

    if ([self.delegate respondsToSelector:@selector(arSession:didUpdateBody:)]) {
        [self.delegate arSession:self didUpdateBody:body];
    }

    if ([self shouldLog]) {
        [self logBody:body];
    }
}

#pragma mark - Logging

- (BOOL)shouldLog {
    if (self.logInterval <= 0) return YES;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastLogTime < self.logInterval) return NO;
    self.lastLogTime = now;
    return YES;
}

- (void)logFace:(SCARFaceData *)face {
    simd_float3 p = face.head.position;
    NSLog(@"[ARKit Face/Head] pos=(%.3f, %.3f, %.3f) verts=%ld shapes=%lu",
          p.x, p.y, p.z, (long)face.geometryVertexCount, (unsigned long)face.blendShapes.count);

    NSMutableArray<NSString *> *active = [NSMutableArray array];
    [face.blendShapes enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *val, BOOL *stop) {
        if (val.floatValue > 0.05f) {
            [active addObject:[NSString stringWithFormat:@"%@=%.2f", key, val.floatValue]];
        }
    }];
    [active sortUsingSelector:@selector(compare:)];
    if (active.count > 0) {
        NSLog(@"[ARKit Face] active blendShapes: %@", [active componentsJoinedByString:@", "]);
    } else {
        NSLog(@"[ARKit Face] blendShapes: (none > 0.05)");
    }
}

- (void)logBody:(SCARBodyData *)body {
    if (body.head) {
        simd_float3 p = body.head.position;
        NSLog(@"[ARKit Body/Head] pos=(%.3f, %.3f, %.3f)", p.x, p.y, p.z);
    } else {
        NSLog(@"[ARKit Body/Head] (not tracked)");
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (SCARBodyJoint *j in body.joints) {
        if (!j.tracked) continue;
        [lines addObject:[NSString stringWithFormat:@"%@=(%.2f,%.2f,%.2f)",
                          j.name, j.position.x, j.position.y, j.position.z]];
    }
    NSLog(@"[ARKit Body] tracked joints (%lu): %@",
          (unsigned long)lines.count, [lines componentsJoinedByString:@" | "]);
}

@end
