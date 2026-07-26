/*
  SCARUpperBodyProjector.m
  忙则丢帧；空闲才 CPU 拷贝 + Vision。lean 钳制 ±40°。
*/

#import "SCARUpperBodyProjector.h"
#import "SCARPixelBufferCopy.h"
#import <Vision/Vision.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>
#import <math.h>

@implementation SCARUpperBodyDrive
@end

@interface SCARUpperBodyProjector ()
@property (nonatomic, strong) VNDetectHumanBodyPoseRequest *poseRequest;
@property (nonatomic, strong) dispatch_queue_t visionQueue;
@property (nonatomic, strong) SCARUpperBodyDrive *cachedDrive;
@property (nonatomic, assign) float smoothLean;
@property (nonatomic, assign) BOOL hasSmooth;
@property (nonatomic, assign) BOOL hasLockedOrientation;
@property (nonatomic, assign) CGImagePropertyOrientation lockedOrientation;
@property (nonatomic, assign) float measuredHz;
@property (nonatomic, assign) NSInteger hzWindowCount;
@property (nonatomic, assign) CFTimeInterval hzWindowStart;
@end

@implementation SCARUpperBodyProjector {
    atomic_int _busy;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _smoothing = 0.50f;
        _mirrorSelfie = YES;
        _cachedDrive = [[SCARUpperBodyDrive alloc] init];
        atomic_init(&_busy, 0);
        _visionQueue = dispatch_queue_create("com.stan.arkit.upperbody.vision", DISPATCH_QUEUE_SERIAL);
        if (@available(iOS 14.0, *)) {
            _poseRequest = [[VNDetectHumanBodyPoseRequest alloc] init];
        }
    }
    return self;
}

- (BOOL)isBusy {
    return atomic_load(&_busy) != 0;
}

- (void)reset {
    dispatch_async(self.visionQueue, ^{
        self.hasSmooth = NO;
        self.hasLockedOrientation = NO;
        self.hzWindowCount = 0;
        self.hzWindowStart = 0;
        self.measuredHz = 0;
        atomic_store(&self->_busy, 0);
        SCARUpperBodyDrive *empty = [[SCARUpperBodyDrive alloc] init];
        @synchronized (self) {
            self.cachedDrive = empty;
        }
    });
}

- (SCARUpperBodyDrive *)latestDrive {
    @synchronized (self) {
        return self.cachedDrive;
    }
}

static float SCARClamp(float v, float lo, float hi) {
    return fminf(hi, fmaxf(lo, v));
}

static BOOL SCARPoint(VNHumanBodyPoseObservation *obs,
                      VNHumanBodyPoseObservationJointName name,
                      float *ox, float *oy) API_AVAILABLE(ios(14.0)) {
    if (!obs || !ox || !oy) return NO;
    NSError *err = nil;
    VNRecognizedPoint *p = [obs recognizedPointForJointName:name error:&err];
    if (!p || p.confidence < 0.12f) return NO;
    *ox = (float)p.location.x;
    *oy = (float)p.location.y;
    return YES;
}

- (VNHumanBodyPoseObservation *)runPoseOnBuffer:(CVPixelBufferRef)pixelBuffer
                                    orientation:(CGImagePropertyOrientation)orientation
    API_AVAILABLE(ios(14.0)) {
    if (!self.poseRequest || !pixelBuffer) return nil;
    @try {
        VNImageRequestHandler *handler =
            [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer
                                                     orientation:orientation
                                                         options:@{}];
        NSError *err = nil;
        if (![handler performRequests:@[self.poseRequest] error:&err]) return nil;
        id first = self.poseRequest.results.firstObject;
        if (![first isKindOfClass:[VNHumanBodyPoseObservation class]]) return nil;
        return (VNHumanBodyPoseObservation *)first;
    } @catch (__unused NSException *ex) {
        return nil;
    }
}

- (SCARUpperBodyDrive *)projectSync:(CVPixelBufferRef)pixelBuffer
                        orientation:(CGImagePropertyOrientation)orientation {
    SCARUpperBodyDrive *out = [[SCARUpperBodyDrive alloc] init];
    if (!pixelBuffer) return out;
    if (@available(iOS 14.0, *)) {
    } else {
        return out;
    }

    CGImagePropertyOrientation try0 = self.hasLockedOrientation ? self.lockedOrientation : orientation;
    CGImagePropertyOrientation try1 = kCGImagePropertyOrientationRight;
    const int tryCount = self.hasLockedOrientation ? 1 : 2;

    float lsx = 0, lsy = 0, rsx = 0, rsy = 0;
    BOOL found = NO;
    CGImagePropertyOrientation usedOri = try0;

    for (int i = 0; i < tryCount; ++i) {
        CGImagePropertyOrientation ori = (i == 0) ? try0 : try1;
        if (i == 1 && ori == try0) continue;
        VNHumanBodyPoseObservation *obs = [self runPoseOnBuffer:pixelBuffer orientation:ori];
        if (!obs) continue;
        float ax = 0, ay = 0, bx = 0, by = 0;
        if (!SCARPoint(obs, VNHumanBodyPoseObservationJointNameLeftShoulder, &ax, &ay)) continue;
        if (!SCARPoint(obs, VNHumanBodyPoseObservationJointNameRightShoulder, &bx, &by)) continue;
        lsx = ax; lsy = ay; rsx = bx; rsy = by;
        usedOri = ori;
        found = YES;
        break;
    }
    if (!found) return out;

    self.hasLockedOrientation = YES;
    self.lockedOrientation = usedOri;

    if (self.mirrorSelfie) {
        float tx = lsx, ty = lsy;
        lsx = rsx; lsy = rsy;
        rsx = tx; rsy = ty;
    }

    // 肩线倾角；限制 ±40°
    const float kMaxRad = 40.f * (float)M_PI / 180.f;
    float lean = atan2f(rsy - lsy, rsx - lsx);
    lean = SCARClamp(lean, -kMaxRad, kMaxRad);

    const float a = SCARClamp(self.smoothing, 0.f, 0.95f);
    if (!self.hasSmooth || a < 1e-6f) {
        self.smoothLean = lean;
        self.hasSmooth = YES;
    } else {
        self.smoothLean = self.smoothLean + (lean - self.smoothLean) * (1.f - a);
    }
    self.smoothLean = SCARClamp(self.smoothLean, -kMaxRad, kMaxRad);

    out.valid = YES;
    out.torsoLean = self.smoothLean;
    return out;
}

- (void)noteVisionSample {
    CFTimeInterval now = CACurrentMediaTime();
    if (self.hzWindowStart <= 0) self.hzWindowStart = now;
    self.hzWindowCount += 1;
    CFTimeInterval elapsed = now - self.hzWindowStart;
    if (elapsed >= 1.0) {
        self.measuredHz = (float)self.hzWindowCount / (float)elapsed;
        self.hzWindowCount = 0;
        self.hzWindowStart = now;
    }
}

- (void)submitLivePixelBuffer:(CVPixelBufferRef)pixelBuffer
                  orientation:(CGImagePropertyOrientation)orientation {
    if (!pixelBuffer) return;
    if (@available(iOS 14.0, *)) {
    } else {
        return;
    }
    // 忙则丢帧：避免主线程每帧全分辨率 memcpy 卡顿
    int expected = 0;
    if (!atomic_compare_exchange_strong(&_busy, &expected, 1)) return;

    CVPixelBufferRef copy = SCARClonePixelBuffer(pixelBuffer);
    if (!copy) {
        atomic_store(&_busy, 0);
        return;
    }
    CGImagePropertyOrientation ori = orientation;
    dispatch_async(self.visionQueue, ^{
        SCARUpperBodyDrive *drive = [self projectSync:copy orientation:ori];
        CVPixelBufferRelease(copy);
        @synchronized (self) {
            if (drive.valid) {
                self.cachedDrive = drive;
                [self noteVisionSample];
            }
        }
        atomic_store(&self->_busy, 0);
    });
}

@end
