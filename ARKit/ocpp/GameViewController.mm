/*
  GameViewController.mm
  UI host: embeds SCRenderer; model switch + animation clips; ARKit Face → face drive.
*/

#import "GameViewController.h"
#import "SCRenderer.h"
#import "SCARKitSession.h"
#import "SCARFaceProjector.h"
#import "SCARUpperBodyProjector.h"
#import "SCARPixelBufferCopy.h"
#import "PushStream.h"
#import "SCDropdownButton.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <math.h>

static NSString * const kModelCellId = @"ModelCell";

/// 与预览左右镜像对齐：Left↔Right 权重对调
static NSDictionary<NSString *, NSNumber *> *SCARMirrorLRWeights(NSDictionary<NSString *, NSNumber *> *src) {
    if (!src.count) return src;
    NSMutableDictionary *dst = [NSMutableDictionary dictionaryWithCapacity:src.count];
    NSMutableSet<NSString *> *done = [NSMutableSet set];
    for (NSString *k in src) {
        if ([done containsObject:k]) continue;
        NSString *other = nil;
        if ([k hasSuffix:@"Left"]) {
            other = [[k substringToIndex:k.length - 4] stringByAppendingString:@"Right"];
        } else if ([k hasSuffix:@"Right"]) {
            other = [[k substringToIndex:k.length - 5] stringByAppendingString:@"Left"];
        }
        if (other) {
            NSNumber *a = src[k];
            NSNumber *b = src[other];
            if (b) {
                dst[k] = b;
                dst[other] = a ?: @0;
                [done addObject:k];
                [done addObject:other];
                continue;
            }
            // 只有一侧有值 → 挪到对侧
            dst[other] = a;
            [done addObject:k];
            continue;
        }
        dst[k] = src[k];
        [done addObject:k];
    }
    return dst;
}

@interface AnimClipCell : UICollectionViewCell
@property (nonatomic, strong) UILabel *titleLabel;
- (void)setHighlightedSelected:(BOOL)on;
@end

@implementation AnimClipCell
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
        self.contentView.layer.cornerRadius = 8;
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
        self.titleLabel.textColor = UIColor.whiteColor;
        self.titleLabel.numberOfLines = 1;
        [self.contentView addSubview:self.titleLabel];
        [NSLayoutConstraint activateConstraints:@[
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
            [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }
    return self;
}

- (void)setHighlightedSelected:(BOOL)on {
    self.contentView.backgroundColor = on
        ? [[UIColor systemBlueColor] colorWithAlphaComponent:0.75]
        : [[UIColor blackColor] colorWithAlphaComponent:0.45];
}
@end

@interface GameViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, SCARKitSessionDelegate>
@property (nonatomic, strong) SCRenderer *glView;
@property (nonatomic, strong) UICollectionView *modelCollection;
@property (nonatomic, strong) SCDropdownButton *animDropdown;
@property (nonatomic, strong) UIButton *pauseButton;
@property (nonatomic, strong) UIButton *arModeButton;
@property (nonatomic, strong) UIButton *camPreviewButton;
@property (nonatomic, strong) UIButton *liveButton;
@property (nonatomic, strong) SCDropdownButton *liveQualityButton;
@property (nonatomic, strong) SCDropdownButton *liveFPSButton;
@property (nonatomic, strong) SCDropdownButton *liveSourceButton;
@property (nonatomic, copy) NSArray<NSNumber *> *liveQualityValues;
@property (nonatomic, copy) NSArray<NSNumber *> *liveFPSValues;
@property (nonatomic, copy) NSArray<NSNumber *> *liveSourceValues;
@property (nonatomic, strong) UILabel *arDumpLabel;
@property (nonatomic, strong) UIStackView *movePad;
@property (nonatomic, strong) UIStackView *orbitPad; // 相机按钮左侧：绕人 Y 轴左右环绕
@property (nonatomic, strong) UIStackView *videoDepthPad; // 放大视频时：前后调节
@property (nonatomic, strong) UIImageView *camPreviewView;
@property (nonatomic, strong) CIContext *camPreviewCIContext;
@property (nonatomic, strong) dispatch_queue_t camPreviewQueue;
@property (nonatomic, assign) BOOL camPreviewEnabled;
@property (nonatomic, assign) BOOL camPreviewConvertBusy;
/// AR 回调只存最新帧；后台缩小+CI，主线程只设 UIImage（避免和 GL 抢主线程）
@property (nonatomic, assign) CVPixelBufferRef camPreviewPendingBuffer;
@property (nonatomic, assign) CGImagePropertyOrientation camPreviewPendingOrientation;
@property (nonatomic, assign) BOOL camPreviewPendingDirty;
@property (nonatomic, assign) CFTimeInterval lastCamPreviewGrabTime;
@property (nonatomic, strong) NSLayoutConstraint *orbitPadLeadingToSafe;
@property (nonatomic, strong) NSLayoutConstraint *orbitPadLeadingToPreview;
@property (nonatomic, strong) NSLayoutConstraint *camPreviewWidth;
@property (nonatomic, strong) NSLayoutConstraint *camPreviewHeight;
@property (nonatomic, copy) NSArray<NSString *> *animNames;
@property (nonatomic, copy) NSArray<NSString *> *modelNames;
@property (nonatomic, assign) NSInteger selectedModelIndex;
@property (nonatomic, strong) SCARKitSession *arSession;
@property (nonatomic, strong) SCARFaceProjector *faceProjector;
@property (nonatomic, strong) SCARUpperBodyProjector *upperBodyProjector;
/// 合并 AR 回调，避免主队列堆积造成眼球一跳一跳
@property (nonatomic, assign) BOOL faceDrivePending;
@property (nonatomic, assign) float pendingHeadYaw, pendingHeadPitch, pendingHeadRoll;
@property (nonatomic, assign) float pendingEyePitchL, pendingEyeYawL, pendingEyePitchR, pendingEyeYawR;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *pendingEyeWeights;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *pendingFaceWeights;
@property (nonatomic, assign) BOOL pendingUpperBodyValid;
@property (nonatomic, assign) float pendingTorsoLean;
@property (nonatomic, copy) NSString *pendingDumpText;
@property (nonatomic, strong) UIView *loadingOverlay;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, assign) BOOL modelLoading;
/// 与屏幕刷新同拍：lean + 相机预览
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) NSInteger lastLeanBoneCount;
/// Live：PushStream = Media ViewController 完整拷贝
@property (nonatomic, strong) PushStream *pushStream;
@property (nonatomic, strong) UIView *livePreviewHost;
@property (nonatomic, assign) PushStreamVideoQuality liveVideoQuality;
@property (nonatomic, assign) PushStreamFPS liveFPS;
@property (nonatomic, assign) PushStreamVideoSource liveVideoSource;
@end

@implementation GameViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1.0];

    self.glView = [[SCRenderer alloc] initWithFrame:self.view.bounds];
    self.glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.glView];

    // 先建遮罩，再异步 Assimp，避免启动/切模卡死主线程（黑屏无反馈）
    [self setupLoadingOverlay];
    [self setModelLoadingVisible:YES];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (![self.glView startRendering]) {
            [self setModelLoadingVisible:NO];
            return;
        }
        [self.glView loadDefaultModelWithCompletion:^(BOOL ok) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.modelNames = [self.glView modelNames] ?: @[];
            self.selectedModelIndex = [self.glView currentModelIndex];
            self.animNames = [self.glView animationNames] ?: @[];
            [self setupControls];
            [self setupARKit];
            [self setModelLoadingVisible:NO];
            if (!ok) {
                self.arDumpLabel.text = @"默认模型加载失败";
            }
        }];
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self syncHostVideoRectToGL];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopLiveStreaming];
    [self.displayLink invalidate];
    self.displayLink = nil;
    [self tearDownCamPreviewPipeline];
    [self.arSession stop];
}

- (void)clearCamPreviewPending {
    if (self.camPreviewPendingBuffer) {
        CVPixelBufferRelease(self.camPreviewPendingBuffer);
        self.camPreviewPendingBuffer = NULL;
    }
    self.camPreviewPendingDirty = NO;
}

- (void)tearDownCamPreviewPipeline {
    // 停抓帧 + 清待转缓冲；在途后台任务结束时因 enabled=NO 不会贴图
    [self clearCamPreviewPending];
    self.lastCamPreviewGrabTime = 0;
    self.camPreviewView.image = nil;
    dispatch_queue_t q = self.camPreviewQueue;
    if (q) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(q, ^{
            weakSelf.camPreviewCIContext = nil;
        });
    } else {
        self.camPreviewCIContext = nil;
    }
}

#pragma mark - ARKit

- (void)setupARKit {
    self.arSession = [[SCARKitSession alloc] init];
    self.arSession.delegate = self;
    self.arSession.logInterval = 0.5;
    self.faceProjector = [[SCARFaceProjector alloc] init];
    self.upperBodyProjector = [[SCARUpperBodyProjector alloc] init];
    [self.displayLink invalidate];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tickDisplayLink:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    BOOL faceOK = [SCARKitSession isFaceTrackingSupported];
    BOOL bodyOK = [SCARKitSession isBodyTrackingSupported];
    NSLog(@"[ARKit] device support: face=%d body=%d", (int)faceOK, (int)bodyOK);

    if (!faceOK && !bodyOK) {
        self.arDumpLabel.text = @"ARKit: 此设备不支持 Face/Body 追踪";
        return;
    }

    SCARKitTrackingMode mode = faceOK ? SCARKitTrackingModeFace : SCARKitTrackingModeBody;
    self.arDumpLabel.text = @"ARKit: 请求相机权限…";
    [self.arSession startWithMode:mode];
    [self refreshARModeButton];
}

- (void)toggleARMode {
    SCARKitTrackingMode next = (self.arSession.mode == SCARKitTrackingModeFace)
        ? SCARKitTrackingModeBody
        : SCARKitTrackingModeFace;
    [self.faceProjector reset];
    [self.upperBodyProjector reset];
    [self.glView clearUpperBodyDrive];
    [self.arSession switchToMode:next];
    [self refreshARModeButton];
}

- (void)refreshARModeButton {
    BOOL face = self.arSession.mode == SCARKitTrackingModeFace;
    NSString *title = face ? @"AR:Face" : @"AR:Body";
    [self.arModeButton setTitle:title forState:UIControlStateNormal];
}

- (void)arSession:(SCARKitSession *)session didUpdateFace:(SCARFaceData *)face {
    SCARFaceProjection *proj = [self.faceProjector projectFace:face];

    // quat → 近似 yaw/pitch/roll（相对校准姿态）
    float yaw = 0, pitch = 0, roll = 0;
    if (proj.headValid) {
        simd_float4 q = proj.headOrientation.vector; // x,y,z,w
        const float x = q.x, y = q.y, z = q.z, w = q.w;
        float sinp = 2.f * (w * x + y * z);
        if (fabsf(sinp) >= 1.f) pitch = copysignf((float)M_PI / 2.f, sinp);
        else pitch = asinf(sinp);
        yaw = atan2f(2.f * (w * y - z * x), 1.f - 2.f * (x * x + y * y));
        roll = atan2f(2.f * (w * z + x * y), 1.f - 2.f * (y * y + z * z));
        // 相对旧版自拍镜像再取反：头 yaw/roll 用原始符号
        const float lim = 0.85f;
        yaw = fmaxf(-lim, fminf(lim, yaw));
        pitch = fmaxf(-lim, fminf(lim, pitch));
        roll = fmaxf(-lim * 0.5f, fminf(lim * 0.5f, roll));
    }

    // 眼：相对旧版「对调+取反」再取反 → 左眼用左、右眼用右
    float ePL = proj.eyePitchLeft, eYL = proj.eyeYawLeft;
    float ePR = proj.eyePitchRight, eYR = proj.eyeYawRight;

    float smile = [proj.faceWeights[@"mouthSmileLeft"] floatValue] + [proj.faceWeights[@"mouthSmileRight"] floatValue];
    float brow = [proj.faceWeights[@"browInnerUp"] floatValue];
    float cheek = [proj.faceWeights[@"cheekPuff"] floatValue];
    float blink = ([proj.eyeWeights[@"eyeBlinkLeft"] floatValue] +
                   [proj.eyeWeights[@"eyeBlinkRight"] floatValue]) * 0.5f;
    SCARUpperBodyDrive *ub = [self.upperBodyProjector latestDrive];
    NSString *ubLine = @"LEAN: no pose (双肩入镜)";
    if (ub.valid) {
        ubLine = [NSString stringWithFormat:@"LEAN=%.0f° (±40) Vision≈%.0fHz bones=%ld",
                  ub.torsoLean * 180.f / (float)M_PI,
                  self.upperBodyProjector.measuredHz, (long)self.lastLeanBoneCount];
    }
    NSString *text = [NSString stringWithFormat:
                      @"DRIVE HEAD ypr=(%.2f, %.2f, %.2f)\n"
                      @"EYE L py=(%.2f,%.2f) R=(%.2f,%.2f) blink=%.2f\n"
                      @"FACE smile=%.2f brow=%.2f cheek=%.2f jaw=%.2f\n%@",
                      yaw, pitch, roll, ePL, eYL, ePR, eYR, blink,
                      smile * 0.5f, brow, cheek,
                      [proj.faceWeights[@"jawOpen"] floatValue],
                      ubLine];

    self.pendingHeadYaw = yaw;
    self.pendingHeadPitch = pitch;
    self.pendingHeadRoll = roll;
    self.pendingEyePitchL = ePL;
    self.pendingEyeYawL = eYL;
    self.pendingEyePitchR = ePR;
    self.pendingEyeYawR = eYR;
    self.pendingEyeWeights = proj.eyeWeights;
    self.pendingFaceWeights = proj.faceWeights;
    self.pendingDumpText = text;

    if (self.faceDrivePending) return;
    self.faceDrivePending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.faceDrivePending = NO;
        [self.glView applyFaceProjectionHeadYaw:self.pendingHeadYaw
                                          pitch:self.pendingHeadPitch
                                           roll:self.pendingHeadRoll
                                   eyePitchLeft:self.pendingEyePitchL
                                     eyeYawLeft:self.pendingEyeYawL
                                  eyePitchRight:self.pendingEyePitchR
                                    eyeYawRight:self.pendingEyeYawR
                                     eyeWeights:self.pendingEyeWeights
                                    faceWeights:self.pendingFaceWeights];
        self.arDumpLabel.text = self.pendingDumpText;
    });
}

/// ARFrame 回调内：缓冲仍有效。预览只轻量抓帧，CI 放到 DisplayLink。
- (void)arSession:(SCARKitSession *)session
didUpdateCapturedImage:(CVPixelBufferRef)image
      orientation:(CGImagePropertyOrientation)orientation {
    (void)session;
    // Cam:On → GL 左下角小窗（与原 UIKit 预览同位同尺寸）
    if (self.camPreviewEnabled && self.glView.hostVideoVisible) {
        static CFTimeInterval sLastGLVideo = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (sLastGLVideo <= 0 || (now - sLastGLVideo) >= (1.0 / 24.0)) {
            [self.glView submitHostVideoPixelBuffer:image orientation:orientation];
            sLastGLVideo = now;
        }
    }
    // blackMan 不做 lean：跳过 Vision，把算力留给头/脸
    NSString *model = (self.selectedModelIndex >= 0 &&
                       self.selectedModelIndex < (NSInteger)self.modelNames.count)
        ? self.modelNames[self.selectedModelIndex] : @"";
    if ([model.lowercaseString containsString:@"black"]) return;
    [self.upperBodyProjector submitLivePixelBuffer:image orientation:orientation];
}

/// DisplayLink：摘走 pending，后台缩小+镜像+CI；主线程只贴图
- (void)flushCameraPreviewOnDisplayLink {
    if (!self.camPreviewEnabled || !self.camPreviewPendingDirty || self.camPreviewConvertBusy) return;
    if (!self.camPreviewView || self.camPreviewView.hidden) return;

    CVPixelBufferRef buf = self.camPreviewPendingBuffer;
    CGImagePropertyOrientation ori = self.camPreviewPendingOrientation;
    if (!buf) {
        self.camPreviewPendingDirty = NO;
        return;
    }
    self.camPreviewPendingBuffer = NULL;
    self.camPreviewPendingDirty = NO;
    self.camPreviewConvertBusy = YES;

    if (!self.camPreviewQueue) {
        self.camPreviewQueue = dispatch_queue_create("sc.cam.preview", DISPATCH_QUEUE_SERIAL);
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.camPreviewQueue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        UIImage *img = nil;
        if (self && self.camPreviewEnabled) {
            CIContext *ctx = self.camPreviewCIContext;
            if (!ctx) {
                ctx = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @YES }];
                self.camPreviewCIContext = ctx;
            }
            CIImage *ci = [CIImage imageWithCVPixelBuffer:buf];
            if (ci) {
                ci = [ci imageByApplyingOrientation:ori];
                CGFloat w = ci.extent.size.width;
                CGAffineTransform flip = CGAffineTransformMakeTranslation(w, 0);
                flip = CGAffineTransformScale(flip, -1.0, 1.0);
                ci = [ci imageByApplyingTransform:flip];
                CGRect e = ci.extent;
                if (!CGRectIsNull(e) && !CGRectIsEmpty(e)) {
                    ci = [ci imageByApplyingTransform:
                          CGAffineTransformMakeTranslation(-e.origin.x, -e.origin.y)];
                }
                // 小窗预览：先缩到 ~240 长边再软件渲染，比全分辨率便宜很多
                CGRect extent = CGRectIntegral(ci.extent);
                CGFloat longSide = MAX(extent.size.width, extent.size.height);
                const CGFloat kMaxSide = 240.0;
                if (longSide > kMaxSide && longSide > 1.0) {
                    CGFloat s = kMaxSide / longSide;
                    ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];
                    extent = CGRectIntegral(ci.extent);
                }
                if (extent.size.width >= 2 && extent.size.height >= 2) {
                    CGImageRef cg = [ctx createCGImage:ci fromRect:extent];
                    if (cg) {
                        img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
                        CGImageRelease(cg);
                    }
                }
            }
        }
        CVPixelBufferRelease(buf);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.camPreviewConvertBusy = NO;
            if (self.camPreviewEnabled && img) {
                self.camPreviewView.transform = CGAffineTransformIdentity;
                self.camPreviewView.image = img;
            }
        });
    });
}

- (void)toggleCamPreview {
    self.camPreviewEnabled = !self.camPreviewEnabled;
    [self applyCamPreviewVisible:self.camPreviewEnabled];
}

- (void)applyCamPreviewVisible:(BOOL)on {
    // UIKit 小窗只占位；真人画面改由 GL YUV 长方形绘制（同位置同大小，可进推流）
    self.camPreviewView.hidden = YES;
    self.camPreviewView.image = nil;
    self.glView.hostVideoVisible = on;
    if (!on) {
        self.glView.hostVideoExpanded = NO;
        [self tearDownCamPreviewPipeline];
    }
    [self.camPreviewButton setTitle:(on ? @"Cam:On" : @"Cam:Off") forState:UIControlStateNormal];
    self.camPreviewWidth.constant = on ? 108.0 : 0.0;
    self.camPreviewHeight.constant = on ? 144.0 : 0.0;
    self.orbitPadLeadingToSafe.active = !on;
    self.orbitPadLeadingToPreview.active = on;
    [self syncHostVideoRectToGL];
}

- (void)syncHostVideoRectToGL {
    if (!self.glView || !self.camPreviewView) return;
    // 即使 UIImageView hidden，约束仍给出与原先预览相同的 frame（收起态命中区）
    [self.view layoutIfNeeded];
    CGRect r = [self.camPreviewView convertRect:self.camPreviewView.bounds toView:self.glView];
    [self.glView setHostVideoScreenRect:r];
    // 放大才显示视频前后按钮
    BOOL showVid = self.camPreviewEnabled && self.glView.hostVideoExpanded;
    if (self.videoDepthPad.hidden == showVid)
        self.videoDepthPad.hidden = !showVid;
    if (!showVid) {
        [self.glView setHostVideoMoveCloser:NO];
        [self.glView setHostVideoMoveFarther:NO];
    }
}

#pragma mark - Live（Media ViewController → PushStream + 开关）

- (NSInteger)indexForLiveQuality:(PushStreamVideoQuality)q {
    for (NSInteger i = 0; i < (NSInteger)self.liveQualityValues.count; i++) {
        if (self.liveQualityValues[i].integerValue == q) return i;
    }
    return 0;
}

- (NSInteger)indexForLiveFPS:(PushStreamFPS)f {
    for (NSInteger i = 0; i < (NSInteger)self.liveFPSValues.count; i++) {
        if (self.liveFPSValues[i].integerValue == f) return i;
    }
    return 0;
}

- (NSInteger)indexForLiveSource:(PushStreamVideoSource)s {
    for (NSInteger i = 0; i < (NSInteger)self.liveSourceValues.count; i++) {
        if (self.liveSourceValues[i].integerValue == s) return i;
    }
    return 0;
}

- (void)refreshLiveQualityButton {
    self.liveQualityButton.selectedIndex = [self indexForLiveQuality:self.liveVideoQuality];
    self.liveFPSButton.selectedIndex = [self indexForLiveFPS:self.liveFPS];
    self.liveSourceButton.selectedIndex = [self indexForLiveSource:self.liveVideoSource];
    BOOL enable = !self.pushStream.isStreaming;
    self.liveQualityButton.enabled = enable;
    self.liveFPSButton.enabled = enable;
    self.liveSourceButton.enabled = enable;
}

- (void)refreshLiveButton {
    BOOL on = self.pushStream.isStreaming;
    [self.liveButton setTitle:(on ? @"Live:On" : @"Live:Off") forState:UIControlStateNormal];
    [self refreshLiveQualityButton];
}

- (void)toggleLive {
    if (self.pushStream.isStreaming) {
        [self stopLiveStreaming];
    } else {
        [self startLiveStreaming];
    }
}

- (void)startLiveStreaming {
    if (!self.pushStream) {
        self.pushStream = [[PushStream alloc] init];
    }
    self.pushStream.videoQuality = self.liveVideoQuality;
    self.pushStream.fps = self.liveFPS;
    self.pushStream.videoSource = self.liveVideoSource;
    self.pushStream.glRenderer = (self.liveVideoSource == PushStreamVideoSourceAvatar)
        ? self.glView : nil;
    [self.liveButton setTitle:@"Live:…" forState:UIControlStateNormal];
    self.liveButton.enabled = NO;
    self.arDumpLabel.text = @"Connecting RTMP…";

    __weak typeof(self) weakSelf = self;
    [self.pushStream startWithCompletion:^(BOOL ok, NSString *message) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.liveButton.enabled = YES;
        [self refreshLiveButton];
        if (ok) {
            NSString *src = [PushStream titleForVideoSource:self.liveVideoSource];
            NSString *vq = [PushStream titleForVideoQuality:self.liveVideoQuality];
            NSString *fq = [PushStream titleForFPS:self.liveFPS];
            self.arDumpLabel.text = [NSString stringWithFormat:
                @"Live ON %@ Vid:%@ FPS:%@\n%@", src, vq, fq, message ?: @""];
            [self showLivePreview];
        } else {
            self.arDumpLabel.text = message ?: @"Live FAIL";
            self.pushStream = nil;
            [self hideLivePreview];
            [self refreshLiveButton];
        }
    }];
}

- (void)stopLiveStreaming {
    [self.pushStream stop];
    self.pushStream = nil;
    [self hideLivePreview];
    [self refreshLiveButton];
    self.arDumpLabel.text = @"Live Off";
}

- (void)showLivePreview {
    if (!self.pushStream.previewLayer) return;
    if (!self.livePreviewHost) {
        self.livePreviewHost = [[UIView alloc] initWithFrame:CGRectMake(8, 120, 108, 144)];
        self.livePreviewHost.clipsToBounds = YES;
        self.livePreviewHost.layer.cornerRadius = 8;
        self.livePreviewHost.layer.borderWidth = 1;
        self.livePreviewHost.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
        [self.view addSubview:self.livePreviewHost];
    }
    AVCaptureVideoPreviewLayer *pl = self.pushStream.previewLayer;
    pl.frame = self.livePreviewHost.bounds;
    [self.livePreviewHost.layer addSublayer:pl];
    self.livePreviewHost.hidden = NO;
    [self.view bringSubviewToFront:self.livePreviewHost];
}

- (void)hideLivePreview {
    [self.pushStream.previewLayer removeFromSuperlayer];
    self.livePreviewHost.hidden = YES;
}

/// 与屏幕刷新同拍：上体 lean + 相机预览
- (void)tickDisplayLink:(CADisplayLink *)link {
    (void)link;
    [self syncHostVideoRectToGL];
    [self flushCameraPreviewOnDisplayLink];
    if (!self.upperBodyProjector) return;
    SCARUpperBodyDrive *ub = [self.upperBodyProjector latestDrive];
    if (ub.valid) {
        // 肩 lean 直接驱动，不再取反
        self.lastLeanBoneCount = [self.glView applyUpperBodyLean:ub.torsoLean];
    }
}

- (void)arSession:(SCARKitSession *)session didUpdateBody:(SCARBodyData *)body {
    [self.upperBodyProjector reset];
    [self.glView clearFaceDrive];
    NSInteger tracked = 0;
    for (SCARBodyJoint *j in body.joints) {
        if (j.tracked) tracked++;
    }
    NSString *headLine = @"HEAD  (n/a)";
    if (body.head) {
        simd_float3 p = body.head.position;
        headLine = [NSString stringWithFormat:@"HEAD  pos=(%.2f, %.2f, %.2f)", p.x, p.y, p.z];
    }
    NSString *text = [NSString stringWithFormat:@"BODY/%@\ntracked joints=%ld / %lu",
                      headLine, (long)tracked, (unsigned long)body.joints.count];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.arDumpLabel.text = text;
    });
}

- (void)arSession:(SCARKitSession *)session didFailWithMessage:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.arDumpLabel.text = [NSString stringWithFormat:@"ARKit: %@", message];
    });
}

- (void)arSession:(SCARKitSession *)session didChangeMode:(SCARKitTrackingMode)mode {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshARModeButton];
        self.arDumpLabel.text = mode == SCARKitTrackingModeFace
            ? @"ARKit Face: waiting for face…"
            : @"ARKit Body: stand in rear camera view…";
    });
}

#pragma mark - Controls (UI only)

- (UIButton *)makeButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    b.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.layer.cornerRadius = 8;
    b.contentEdgeInsets = UIEdgeInsetsMake(8, 10, 8, 10);
    if (action) {
        [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    }
    return b;
}

- (UIButton *)makeHoldButton:(NSString *)title began:(SEL)began ended:(SEL)ended {
    UIButton *b = [self makeButton:title action:nil];
    b.exclusiveTouch = YES;
    [b.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [b addTarget:self action:began forControlEvents:UIControlEventTouchDown];
    [b addTarget:self action:began forControlEvents:UIControlEventTouchDragEnter];
    [b addTarget:self action:ended forControlEvents:UIControlEventTouchUpInside];
    [b addTarget:self action:ended forControlEvents:UIControlEventTouchUpOutside];
    [b addTarget:self action:ended forControlEvents:UIControlEventTouchCancel];
    [b addTarget:self action:ended forControlEvents:UIControlEventTouchDragExit];
    return b;
}

- (UICollectionView *)makeChipCollection:(NSString *)reuseId {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumInteritemSpacing = 6;
    layout.minimumLineSpacing = 6;
    layout.sectionInset = UIEdgeInsetsZero;

    UICollectionView *cv = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    cv.translatesAutoresizingMaskIntoConstraints = NO;
    cv.backgroundColor = UIColor.clearColor;
    cv.showsHorizontalScrollIndicator = NO;
    cv.dataSource = self;
    cv.delegate = self;
    [cv registerClass:[AnimClipCell class] forCellWithReuseIdentifier:reuseId];
    return cv;
}

- (void)setupControls {
    self.modelCollection = [self makeChipCollection:kModelCellId];
    [self.view addSubview:self.modelCollection];

    __weak typeof(self) weakSelf = self;
    NSArray<NSString *> *anims = self.animNames.count ? self.animNames : @[@"—"];
    self.animDropdown = [[SCDropdownButton alloc] initWithPrefix:@"Anim"
                                                         options:anims
                                                   selectedIndex:0];
    self.animDropdown.panelAlignment = SCDropdownPanelAlignmentLeading;
    self.animDropdown.selectionHandler = ^(NSInteger index, __unused NSString *title) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || index < 0 || index >= (NSInteger)self.animNames.count) return;
        [self.glView playAnimationAtIndex:index];
    };
    [self.view addSubview:self.animDropdown];

    self.pauseButton = [self makeButton:@"Pause" action:@selector(togglePause)];
    self.pauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.pauseButton];

    self.arModeButton = [self makeButton:@"AR:Face" action:@selector(toggleARMode)];
    self.arModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.arModeButton];

    self.camPreviewButton = [self makeButton:@"Cam:On" action:@selector(toggleCamPreview)];
    self.camPreviewButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.camPreviewButton];

    self.liveButton = [self makeButton:@"Live:Off" action:@selector(toggleLive)];
    self.liveButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.liveButton];

    self.liveVideoQuality = PushStreamVideoQualityLow320x240; // 360×780
    self.liveFPS = PushStreamFPS60;
    self.liveVideoSource = PushStreamVideoSourceAvatar;
    self.liveQualityValues = @[
        @(PushStreamVideoQualityLow320x240),
        @(PushStreamVideoQualityStandard),
        @(PushStreamVideoQuality480p),
        @(PushStreamVideoQuality720p),
        @(PushStreamVideoQuality1080p),
        @(PushStreamVideoQuality2K),
    ];
    self.liveFPSValues = @[
        @(PushStreamFPS5),
        @(PushStreamFPS10),
        @(PushStreamFPS24),
        @(PushStreamFPS30),
        @(PushStreamFPS60),
    ];
    self.liveSourceValues = @[
        @(PushStreamVideoSourceAvatar),
        @(PushStreamVideoSourceCamera),
    ];
    NSMutableArray<NSString *> *vqTitles = [NSMutableArray array];
    for (NSNumber *n in self.liveQualityValues) {
        [vqTitles addObject:[PushStream titleForVideoQuality:(PushStreamVideoQuality)n.integerValue]];
    }
    NSMutableArray<NSString *> *fpsTitles = [NSMutableArray array];
    for (NSNumber *n in self.liveFPSValues) {
        [fpsTitles addObject:[PushStream titleForFPS:(PushStreamFPS)n.integerValue]];
    }
    NSMutableArray<NSString *> *srcTitles = [NSMutableArray array];
    for (NSNumber *n in self.liveSourceValues) {
        [srcTitles addObject:[PushStream titleForVideoSource:(PushStreamVideoSource)n.integerValue]];
    }

    __weak typeof(self) weakSelfLive = self;
    self.liveSourceButton = [[SCDropdownButton alloc] initWithPrefix:@"Src"
                                                              options:srcTitles
                                                        selectedIndex:[self indexForLiveSource:self.liveVideoSource]];
    self.liveSourceButton.selectionHandler = ^(NSInteger index, __unused NSString *title) {
        __strong typeof(weakSelfLive) self = weakSelfLive;
        if (!self || index < 0 || index >= (NSInteger)self.liveSourceValues.count) return;
        self.liveVideoSource = (PushStreamVideoSource)self.liveSourceValues[index].integerValue;
    };
    [self.view addSubview:self.liveSourceButton];

    self.liveQualityButton = [[SCDropdownButton alloc] initWithPrefix:@"Vid"
                                                              options:vqTitles
                                                        selectedIndex:[self indexForLiveQuality:self.liveVideoQuality]];
    self.liveQualityButton.selectionHandler = ^(NSInteger index, __unused NSString *title) {
        __strong typeof(weakSelfLive) self = weakSelfLive;
        if (!self || index < 0 || index >= (NSInteger)self.liveQualityValues.count) return;
        self.liveVideoQuality = (PushStreamVideoQuality)self.liveQualityValues[index].integerValue;
    };
    [self.view addSubview:self.liveQualityButton];

    self.liveFPSButton = [[SCDropdownButton alloc] initWithPrefix:@"FPS"
                                                          options:fpsTitles
                                                    selectedIndex:[self indexForLiveFPS:self.liveFPS]];
    self.liveFPSButton.selectionHandler = ^(NSInteger index, __unused NSString *title) {
        __strong typeof(weakSelfLive) self = weakSelfLive;
        if (!self || index < 0 || index >= (NSInteger)self.liveFPSValues.count) return;
        self.liveFPS = (PushStreamFPS)self.liveFPSValues[index].integerValue;
    };
    [self.view addSubview:self.liveFPSButton];

    self.camPreviewView = [[UIImageView alloc] init];
    self.camPreviewView.translatesAutoresizingMaskIntoConstraints = NO;
    self.camPreviewView.contentMode = UIViewContentModeScaleAspectFill;
    self.camPreviewView.clipsToBounds = YES;
    self.camPreviewView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.65];
    self.camPreviewView.layer.cornerRadius = 8;
    self.camPreviewView.layer.borderWidth = 1.0;
    self.camPreviewView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.45].CGColor;
    self.camPreviewView.userInteractionEnabled = NO;
    [self.view addSubview:self.camPreviewView];
    self.camPreviewEnabled = YES;

    self.arDumpLabel = [[UILabel alloc] init];
    self.arDumpLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.arDumpLabel.numberOfLines = 5;
    self.arDumpLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.arDumpLabel.textColor = UIColor.greenColor;
    self.arDumpLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    self.arDumpLabel.layer.cornerRadius = 6;
    self.arDumpLabel.clipsToBounds = YES;
    self.arDumpLabel.text = @"ARKit: starting…";
    [self.view addSubview:self.arDumpLabel];

    // 相机 WASD 左侧：绕人世界 Y（头→脚）左右环绕，始终看人
    self.orbitPad = [[UIStackView alloc] init];
    self.orbitPad.axis = UILayoutConstraintAxisVertical;
    self.orbitPad.spacing = 6;
    self.orbitPad.translatesAutoresizingMaskIntoConstraints = NO;
    [self.orbitPad addArrangedSubview:[self makeHoldButton:@"绕左" began:@selector(orbitLeftOn) ended:@selector(orbitLeftOff)]];
    [self.orbitPad addArrangedSubview:[self makeHoldButton:@"绕右" began:@selector(orbitRightOn) ended:@selector(orbitRightOff)]];
    [self.view addSubview:self.orbitPad];

    self.movePad = [[UIStackView alloc] init];
    self.movePad.axis = UILayoutConstraintAxisVertical;
    self.movePad.spacing = 6;
    self.movePad.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *rowW = [[UIStackView alloc] init];
    rowW.axis = UILayoutConstraintAxisHorizontal;
    [rowW addArrangedSubview:[self makeHoldButton:@"W" began:@selector(fwdOn) ended:@selector(fwdOff)]];

    UIStackView *rowAD = [[UIStackView alloc] init];
    rowAD.axis = UILayoutConstraintAxisHorizontal;
    rowAD.spacing = 6;
    [rowAD addArrangedSubview:[self makeHoldButton:@"A" began:@selector(leftOn) ended:@selector(leftOff)]];
    [rowAD addArrangedSubview:[self makeHoldButton:@"S" began:@selector(backOn) ended:@selector(backOff)]];
    [rowAD addArrangedSubview:[self makeHoldButton:@"D" began:@selector(rightOn) ended:@selector(rightOff)]];

    UIStackView *rowUF = [[UIStackView alloc] init];
    rowUF.axis = UILayoutConstraintAxisHorizontal;
    rowUF.spacing = 6;
    [rowUF addArrangedSubview:[self makeHoldButton:@"Up" began:@selector(upOn) ended:@selector(upOff)]];
    [rowUF addArrangedSubview:[self makeHoldButton:@"Dn" began:@selector(downOn) ended:@selector(downOff)]];

    [self.movePad addArrangedSubview:rowW];
    [self.movePad addArrangedSubview:rowAD];
    [self.movePad addArrangedSubview:rowUF];
    [self.view addSubview:self.movePad];
    [self.view bringSubviewToFront:self.movePad];

    // 视频放大时：相机按钮右侧 — 前/后移动视频板
    self.videoDepthPad = [[UIStackView alloc] init];
    self.videoDepthPad.axis = UILayoutConstraintAxisVertical;
    self.videoDepthPad.spacing = 6;
    self.videoDepthPad.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoDepthPad.hidden = YES;
    [self.videoDepthPad addArrangedSubview:[self makeHoldButton:@"Vid前" began:@selector(vidCloserOn) ended:@selector(vidCloserOff)]];
    [self.videoDepthPad addArrangedSubview:[self makeHoldButton:@"Vid后" began:@selector(vidFartherOn) ended:@selector(vidFartherOff)]];
    [self.view addSubview:self.videoDepthPad];
    [self.view bringSubviewToFront:self.videoDepthPad];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    self.orbitPadLeadingToSafe = [self.orbitPad.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12];
    self.orbitPadLeadingToPreview = [self.orbitPad.leadingAnchor constraintEqualToAnchor:self.camPreviewView.trailingAnchor constant:10];
    self.orbitPadLeadingToSafe.active = NO;
    self.orbitPadLeadingToPreview.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.pauseButton.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [self.pauseButton.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [self.pauseButton.heightAnchor constraintEqualToConstant:36],

        [self.arModeButton.trailingAnchor constraintEqualToAnchor:self.pauseButton.trailingAnchor],
        [self.arModeButton.topAnchor constraintEqualToAnchor:self.pauseButton.bottomAnchor constant:6],
        [self.arModeButton.heightAnchor constraintEqualToConstant:36],

        [self.camPreviewButton.trailingAnchor constraintEqualToAnchor:self.pauseButton.trailingAnchor],
        [self.camPreviewButton.topAnchor constraintEqualToAnchor:self.arModeButton.bottomAnchor constant:6],
        [self.camPreviewButton.heightAnchor constraintEqualToConstant:36],

        [self.liveButton.trailingAnchor constraintEqualToAnchor:self.pauseButton.trailingAnchor],
        [self.liveButton.topAnchor constraintEqualToAnchor:self.camPreviewButton.bottomAnchor constant:6],
        [self.liveButton.heightAnchor constraintEqualToConstant:36],

        [self.liveSourceButton.trailingAnchor constraintEqualToAnchor:self.pauseButton.trailingAnchor],
        [self.liveSourceButton.topAnchor constraintEqualToAnchor:self.liveButton.bottomAnchor constant:6],
        [self.liveSourceButton.heightAnchor constraintEqualToConstant:36],

        [self.liveQualityButton.trailingAnchor constraintEqualToAnchor:self.pauseButton.trailingAnchor],
        [self.liveQualityButton.topAnchor constraintEqualToAnchor:self.liveSourceButton.bottomAnchor constant:6],
        [self.liveQualityButton.heightAnchor constraintEqualToConstant:36],

        [self.liveFPSButton.trailingAnchor constraintEqualToAnchor:self.pauseButton.trailingAnchor],
        [self.liveFPSButton.topAnchor constraintEqualToAnchor:self.liveQualityButton.bottomAnchor constant:6],
        [self.liveFPSButton.heightAnchor constraintEqualToConstant:36],

        [self.modelCollection.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [self.modelCollection.trailingAnchor constraintEqualToAnchor:self.pauseButton.leadingAnchor constant:-8],
        [self.modelCollection.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [self.modelCollection.heightAnchor constraintEqualToConstant:36],

        // 左边第二排第一个：动画下拉
        [self.animDropdown.leadingAnchor constraintEqualToAnchor:self.modelCollection.leadingAnchor],
        [self.animDropdown.topAnchor constraintEqualToAnchor:self.modelCollection.bottomAnchor constant:6],
        [self.animDropdown.heightAnchor constraintEqualToConstant:36],

        // 左下角相机预览（关闭时宽高归零，不占位）
        [self.camPreviewView.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [self.camPreviewView.bottomAnchor constraintEqualToAnchor:self.arDumpLabel.topAnchor constant:-8],

        [self.arDumpLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [self.arDumpLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [self.arDumpLabel.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],

        [self.orbitPad.bottomAnchor constraintEqualToAnchor:self.arDumpLabel.topAnchor constant:-8],
        [self.movePad.leadingAnchor constraintEqualToAnchor:self.orbitPad.trailingAnchor constant:8],
        [self.movePad.bottomAnchor constraintEqualToAnchor:self.orbitPad.bottomAnchor],

        [self.videoDepthPad.leadingAnchor constraintEqualToAnchor:self.movePad.trailingAnchor constant:8],
        [self.videoDepthPad.bottomAnchor constraintEqualToAnchor:self.movePad.bottomAnchor],
    ]];
    self.camPreviewWidth = [self.camPreviewView.widthAnchor constraintEqualToConstant:108];
    self.camPreviewHeight = [self.camPreviewView.heightAnchor constraintEqualToConstant:144];
    self.camPreviewWidth.active = YES;
    self.camPreviewHeight.active = YES;

    [self applyCamPreviewVisible:YES];
    [self refreshLiveQualityButton];
    [self.view bringSubviewToFront:self.camPreviewView];
    [self.view bringSubviewToFront:self.orbitPad];
    [self.view bringSubviewToFront:self.movePad];
    [self.view bringSubviewToFront:self.videoDepthPad];
    if (self.loadingOverlay) {
        [self.view bringSubviewToFront:self.loadingOverlay];
    }
}

- (void)setupLoadingOverlay {
    if (self.loadingOverlay) return;

    self.loadingOverlay = [[UIView alloc] init];
    self.loadingOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingOverlay.backgroundColor = [[UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1.0]
                                           colorWithAlphaComponent:0.92];
    self.loadingOverlay.hidden = YES;
    self.loadingOverlay.userInteractionEnabled = YES;
    [self.view addSubview:self.loadingOverlay];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"GL-ARKit";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    [self.loadingOverlay addSubview:title];

    UILabel *sub = [[UILabel alloc] init];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.text = @"Loading model…";
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    sub.font = [UIFont systemFontOfSize:16];
    sub.textAlignment = NSTextAlignmentCenter;
    [self.loadingOverlay addSubview:sub];

    if (@available(iOS 13.0, *)) {
        self.loadingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    } else {
        self.loadingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    }
    self.loadingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingSpinner.color = UIColor.whiteColor;
    [self.loadingOverlay addSubview:self.loadingSpinner];

    [NSLayoutConstraint activateConstraints:@[
        [self.loadingOverlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.loadingOverlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.loadingOverlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.loadingOverlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [title.centerXAnchor constraintEqualToAnchor:self.loadingOverlay.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:self.loadingOverlay.centerYAnchor constant:-36],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [sub.centerXAnchor constraintEqualToAnchor:self.loadingOverlay.centerXAnchor],
        [self.loadingSpinner.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:20],
        [self.loadingSpinner.centerXAnchor constraintEqualToAnchor:self.loadingOverlay.centerXAnchor],
    ]];
}

- (void)setModelLoadingVisible:(BOOL)visible {
    if (!self.loadingOverlay) [self setupLoadingOverlay];
    self.modelLoading = visible;
    self.loadingOverlay.hidden = !visible;
    self.modelCollection.userInteractionEnabled = !visible;
    self.animDropdown.enabled = !visible;
    if (visible) {
        [self.view bringSubviewToFront:self.loadingOverlay];
        [self.loadingSpinner startAnimating];
    } else {
        [self.loadingSpinner stopAnimating];
    }
}

- (void)refreshAnimDropdown {
    NSArray<NSString *> *opts = self.animNames.count ? self.animNames : @[@"—"];
    self.animDropdown.options = opts;
    self.animDropdown.selectedIndex = 0;
}

#pragma mark - UICollectionView

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    (void)collectionView;
    return (NSInteger)self.modelNames.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    AnimClipCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kModelCellId forIndexPath:indexPath];
    cell.titleLabel.text = self.modelNames[(NSUInteger)indexPath.item];
    [cell setHighlightedSelected:(indexPath.item == self.selectedModelIndex)];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    [self switchToModelAtIndex:indexPath.item];
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    (void)collectionViewLayout;
    NSString *name = self.modelNames[(NSUInteger)indexPath.item];
    CGSize textSize = [name sizeWithAttributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold]
    }];
    return CGSizeMake(ceil(textSize.width) + 20.0, 32.0);
}

- (void)switchToModelAtIndex:(NSInteger)index {
    if (self.modelLoading) return;
    if (index == self.selectedModelIndex) return;
    if (index < 0 || index >= (NSInteger)self.modelNames.count) return;

    [self setModelLoadingVisible:YES];
    self.arDumpLabel.text = [NSString stringWithFormat:@"加载中… %@", self.modelNames[(NSUInteger)index]];

    __weak typeof(self) weakSelf = self;
    [self.glView loadModelAtIndex:index completion:^(BOOL ok) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self setModelLoadingVisible:NO];
        if (!ok) {
            self.arDumpLabel.text = [NSString stringWithFormat:@"模型加载失败: %@", self.modelNames[(NSUInteger)index]];
            [self.modelCollection reloadData];
            return;
        }
        self.selectedModelIndex = index;
        self.animNames = [self.glView animationNames] ?: @[];
        [self.modelCollection reloadData];
        [self refreshAnimDropdown];
        self.arDumpLabel.text = [NSString stringWithFormat:@"已加载 %@", self.modelNames[(NSUInteger)index]];
        NSLog(@"[Model] switched to %@", self.modelNames[(NSUInteger)index]);
    }];
}

#pragma mark - Button → SCRenderer

- (void)togglePause { [self.glView toggleAnimPause]; }

- (void)fwdOn { [self.glView setMoveForward:YES]; }
- (void)fwdOff { [self.glView setMoveForward:NO]; }
- (void)backOn { [self.glView setMoveBackward:YES]; }
- (void)backOff { [self.glView setMoveBackward:NO]; }
- (void)leftOn { [self.glView setMoveLeft:YES]; }
- (void)leftOff { [self.glView setMoveLeft:NO]; }
- (void)rightOn { [self.glView setMoveRight:YES]; }
- (void)rightOff { [self.glView setMoveRight:NO]; }
- (void)upOn { [self.glView setMoveUp:YES]; }
- (void)upOff { [self.glView setMoveUp:NO]; }
- (void)downOn { [self.glView setMoveDown:YES]; }
- (void)downOff { [self.glView setMoveDown:NO]; }

- (void)orbitLeftOn { [self.glView setOrbitLeft:YES]; }
- (void)orbitLeftOff { [self.glView setOrbitLeft:NO]; }
- (void)orbitRightOn { [self.glView setOrbitRight:YES]; }
- (void)orbitRightOff { [self.glView setOrbitRight:NO]; }

- (void)vidCloserOn { [self.glView setHostVideoMoveCloser:YES]; }
- (void)vidCloserOff { [self.glView setHostVideoMoveCloser:NO]; }
- (void)vidFartherOn { [self.glView setHostVideoMoveFarther:YES]; }
- (void)vidFartherOff { [self.glView setHostVideoMoveFarther:NO]; }

@end
