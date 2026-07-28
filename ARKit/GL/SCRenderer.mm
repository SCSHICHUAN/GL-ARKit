/*
  SCRenderer.mm
  CAEAGLLayer OpenGL ES 3 view — render loop + camera gestures/APIs.
*/

#import "SCRenderer.h"
#import "SCRenderCapture.h"
#import "SCHostVideoPlane.h"
#import "SCARPixelBufferCopy.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#include "SCRendererData.h"
#include <map>
#include <string>

// OpenGLES / EAGL still used intentionally; silence iOS 12+ deprecation.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface SCRenderer () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) EAGLContext *context;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) SCRendererData *data;
@property (nonatomic, assign) GLuint colorRenderbuffer;
@property (nonatomic, assign) GLuint depthRenderbuffer;
@property (nonatomic, assign) GLuint defaultFramebuffer;
@property (nonatomic, assign) int backingWidth;
@property (nonatomic, assign) int backingHeight;
@property (nonatomic, assign) CFTimeInterval lastTimestamp;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL modelLoadBusy;
@property (nonatomic, strong) SCHostVideoPlane *hostVideoPlane;
@property (nonatomic, assign) CVPixelBufferRef pendingHostVideoBuffer;
@property (nonatomic, assign) CGImagePropertyOrientation pendingHostVideoOrientation;
@property (nonatomic, assign) CGRect hostVideoHitRect;
@property (nonatomic, assign) CGRect hostVideoCollapsedHitRect;
@property (nonatomic, assign) BOOL hostVideoDragging;
@property (nonatomic, assign) CGFloat hostVideoDragStartX;
@property (nonatomic, assign) float hostVideoDragStartRot;
@end

@implementation SCRenderer

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = YES;
        self.backgroundColor = UIColor.blackColor;
        self.contentScaleFactor = UIScreen.mainScreen.scale;

        CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
        layer.opaque = YES;
        layer.drawableProperties = @{
            kEAGLDrawablePropertyRetainedBacking: @NO,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        };
        _hostVideoVisible = YES;
        _hostVideoPlane = [[SCHostVideoPlane alloc] init];
        _pendingHostVideoOrientation = kCGImagePropertyOrientationRight;
    }
    return self;
}

- (BOOL)startRendering {
    if (self.started) return YES;

    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!self.context || ![EAGLContext setCurrentContext:self.context]) {
        NSLog(@"SCRenderer: failed to create OpenGL ES 3 context");
        return NO;
    }

    [self createFramebuffer];

    NSString *resourceRoot = [[NSBundle mainBundle] resourcePath];
    self.data = new SCRendererData();
    if (!self.data->init(resourceRoot.UTF8String, self.backingWidth, self.backingHeight)) {
        NSLog(@"SCRenderer: SCRendererData init failed");
        return NO;
    }

    [self setupCameraGestures];

    self.lastTimestamp = 0;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(drawFrame:)];
    if (self.preferredFramesPerSecond > 0) {
        self.displayLink.preferredFramesPerSecond = (int)self.preferredFramesPerSecond;
    }
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.started = YES;
    return YES;
}

- (void)setPreferredFramesPerSecond:(NSInteger)preferredFramesPerSecond {
    _preferredFramesPerSecond = preferredFramesPerSecond;
    if (self.displayLink) {
        self.displayLink.preferredFramesPerSecond = (int)MAX(preferredFramesPerSecond, 0);
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.started || !self.context) return;

    [EAGLContext setCurrentContext:self.context];
    [self destroyFramebuffer];
    [self createFramebuffer];
    if (self.data) {
        self.data->resize(self.backingWidth, self.backingHeight);
    }
}

- (void)dealloc {
    [self.displayLink invalidate];
    self.displayLink = nil;
    if (self.context) {
        [EAGLContext setCurrentContext:self.context];
        [self.renderCapture destroyGLResources];
        [self.hostVideoPlane destroyGLResources];
        [self destroyFramebuffer];
    }
    if (self.pendingHostVideoBuffer) {
        CVPixelBufferRelease(self.pendingHostVideoBuffer);
        self.pendingHostVideoBuffer = NULL;
    }
    delete self.data;
    self.data = nullptr;
    if ([EAGLContext currentContext] == self.context) {
        [EAGLContext setCurrentContext:nil];
    }
}

- (EAGLContext *)eaglContext {
    return self.context;
}

#pragma mark - Framebuffer / render

- (void)createFramebuffer {
    glGenFramebuffers(1, &_defaultFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _defaultFramebuffer);

    glGenRenderbuffers(1, &_colorRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderbuffer);
    [self.context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorRenderbuffer);

    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_backingWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_backingHeight);

    glGenRenderbuffers(1, &_depthRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _depthRenderbuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, _backingWidth, _backingHeight);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthRenderbuffer);

    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"SCRenderer: incomplete framebuffer %x", glCheckFramebufferStatus(GL_FRAMEBUFFER));
    }
}

- (void)destroyFramebuffer {
    if (_defaultFramebuffer) {
        glDeleteFramebuffers(1, &_defaultFramebuffer);
        _defaultFramebuffer = 0;
    }
    if (_colorRenderbuffer) {
        glDeleteRenderbuffers(1, &_colorRenderbuffer);
        _colorRenderbuffer = 0;
    }
    if (_depthRenderbuffer) {
        glDeleteRenderbuffers(1, &_depthRenderbuffer);
        _depthRenderbuffer = 0;
    }
}

- (void)drawFrame:(CADisplayLink *)link {
    if (!self.data || !self.context || self.modelLoadBusy) return;
    [EAGLContext setCurrentContext:self.context];

    float dt = 1.0f / 60.0f;
    if (self.lastTimestamp > 0) {
        dt = (float)(link.timestamp - self.lastTimestamp);
    }
    self.lastTimestamp = link.timestamp;
    if (dt > 0.1f) dt = 0.1f;

    self.data->update(dt);
    [self flushHostVideoToGL];

    // ① Avatar 推流离屏：渲到「编码分辨率」FBO（颜色附件=CVPixelBuffer 共享纹理）
    //    FlipY：编码缓冲顶原点，与屏幕底原点相反；结束后恢复 viewport 给上屏
    SCRenderCapture *cap = self.renderCapture;
    if (cap.isCapturing && [cap beginEncodePassWithContext:self.context]) {
        const int cw = cap.captureWidth;
        const int ch = cap.captureHeight;
        self.data->resize(cw, ch);
        self.data->setRenderFlipY(true);
        self.data->render();
        self.data->setRenderFlipY(false);
        glFrontFace(GL_CCW);
        [cap endEncodePass];
        self.data->resize(self.backingWidth, self.backingHeight);
    }

    // ② 本机预览：再渲一趟到 default FBO + present
    glBindFramebuffer(GL_FRAMEBUFFER, self.defaultFramebuffer);
    glViewport(0, 0, self.backingWidth, self.backingHeight);
    self.data->render();

    glBindRenderbuffer(GL_RENDERBUFFER, self.colorRenderbuffer);
    [self.context presentRenderbuffer:GL_RENDERBUFFER];
}

- (void)flushHostVideoToGL {
    if (!self.data || !self.hostVideoPlane) return;
    self.data->setHostVideoVisible(self.hostVideoVisible);

    CVPixelBufferRef buf = self.pendingHostVideoBuffer;
    if (buf) {
        self.pendingHostVideoBuffer = NULL;
        CGImagePropertyOrientation ori = self.pendingHostVideoOrientation;
        if ([self.hostVideoPlane ensureCacheWithContext:self.context]) {
            [self.hostVideoPlane updateWithPixelBuffer:buf orientation:ori];
        }
        CVPixelBufferRelease(buf);
    }

    if (self.hostVideoPlane.hasTexture) {
        self.data->setHostVideoTextures(self.hostVideoPlane.yTextureName,
                                        self.hostVideoPlane.uvTextureName,
                                        true,
                                        self.hostVideoPlane.pixelWidth,
                                        self.hostVideoPlane.pixelHeight);
        self.data->setHostVideoOrientation((int)self.hostVideoPlane.orientation);
        self.data->setHostVideoMirrorX(self.hostVideoPlane.mirrorX);
    } else {
        self.data->setHostVideoTextures(0, 0, false);
    }
}

- (void)submitHostVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer
                       orientation:(CGImagePropertyOrientation)orientation {
    if (!pixelBuffer) return;
    // ARFrame 缓冲离开回调可能失效：CPU 深拷贝后再排队给渲染线程
    CVPixelBufferRef copy = SCARClonePixelBuffer(pixelBuffer);
    if (!copy) return;
    if (self.pendingHostVideoBuffer) {
        CVPixelBufferRelease(self.pendingHostVideoBuffer);
    }
    self.pendingHostVideoBuffer = copy;
    self.pendingHostVideoOrientation = orientation;
}

- (void)setHostVideoVisible:(BOOL)visible {
    _hostVideoVisible = visible;
    if (self.data) self.data->setHostVideoVisible(visible);
}

- (BOOL)isHostVideoVisible {
    return _hostVideoVisible;
}

- (void)setHostVideoScreenRect:(CGRect)rectInGLView {
    // 收起/展开共用：点击恢复、上下滑旋转都打在这个小窗区域
    self.hostVideoCollapsedHitRect = rectInGLView;
    self.hostVideoHitRect = rectInGLView;
    if (!self.data) return;
    CGFloat bw = CGRectGetWidth(self.bounds);
    CGFloat bh = CGRectGetHeight(self.bounds);
    if (bw < 1.0 || bh < 1.0) return;
    float x = (float)(rectInGLView.origin.x / bw);
    float y = (float)(rectInGLView.origin.y / bh);
    float w = (float)(rectInGLView.size.width / bw);
    float h = (float)(rectInGLView.size.height / bh);
    self.data->setHostVideoScreenRectNorm(x, y, w, h);
}

- (void)setHostVideoRotationDegrees:(float)degrees {
    if (degrees < -90.f) degrees = -90.f;
    if (degrees > 90.f) degrees = 90.f;
    _hostVideoRotationDegrees = degrees;
    if (self.data) self.data->setHostVideoRotationDegrees(degrees);
}

- (void)setHostVideoExpanded:(BOOL)expanded {
    if (_hostVideoExpanded == expanded) return;
    _hostVideoExpanded = expanded;
    if (self.data) self.data->setHostVideoExpanded(expanded);
    // 命中区始终是小窗；不因展开改成全屏，也不清零旋转角
    self.hostVideoHitRect = self.hostVideoCollapsedHitRect;
}

- (void)toggleHostVideoExpanded {
    self.hostVideoExpanded = !self.hostVideoExpanded;
}

- (BOOL)pointInsideHostVideo:(CGPoint)p {
    if (!self.hostVideoVisible) return NO;
    CGRect r = self.hostVideoCollapsedHitRect;
    if (CGRectIsEmpty(r) || CGRectGetWidth(r) < 1) return NO;
    return CGRectContainsPoint(r, p);
}

#pragma mark - Camera gestures

- (void)setupCameraGestures {
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    pan.maximumNumberOfTouches = 1;
    pan.delegate = self;
    [self addGestureRecognizer:pan];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(onPinch:)];
    pinch.delegate = self;
    [self addGestureRecognizer:pinch];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onHostVideoTap:)];
    tap.numberOfTapsRequired = 1;
    tap.delegate = self;
    [self addGestureRecognizer:tap];
    // 轻点优先：拖动才转相机/扭小窗
    [pan requireGestureRecognizerToFail:tap];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    return ![touch.view isKindOfClass:[UIControl class]];
}

- (void)onHostVideoTap:(UITapGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateEnded) return;
    CGPoint p = [gr locationInView:self];
    if (![self pointInsideHostVideo:p]) return;
    [self toggleHostVideoExpanded];
}

- (void)onPan:(UIPanGestureRecognizer *)gr {
    if (!self.data) return;
    CGFloat scale = self.contentScaleFactor;
    if (gr.state == UIGestureRecognizerStateBegan) {
        CGPoint p = [gr locationInView:self];
        // 收起/展开：小窗区域内上下滑都旋转视频面
        if ([self pointInsideHostVideo:p]) {
            self.hostVideoDragging = YES;
            self.hostVideoDragStartX = p.y;
            self.hostVideoDragStartRot = self.hostVideoRotationDegrees;
            [gr setTranslation:CGPointZero inView:self];
            return;
        }
        self.hostVideoDragging = NO;
        self.data->onTouchBegan((float)(p.x * scale), (float)(p.y * scale));
        [gr setTranslation:CGPointZero inView:self];
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        if (self.hostVideoDragging) {
            CGFloat h = MAX(CGRectGetHeight(self.hostVideoCollapsedHitRect), 1.0);
            // 上滑 → 负角向后；下滑 → 正角向前（绕底边，-90~90）
            CGFloat dy = self.hostVideoDragStartX - [gr locationInView:self].y;
            float deg = self.hostVideoDragStartRot - (float)(dy / h * 90.0);
            self.hostVideoRotationDegrees = deg;
            return;
        }
        CGPoint t = [gr translationInView:self];
        CGPoint p = [gr locationInView:self];
        float x = (float)(p.x * scale);
        float y = (float)(p.y * scale);
        float prevX = x - (float)(t.x * scale);
        float prevY = y - (float)(t.y * scale);
        self.data->onTouchBegan(prevX, prevY);
        self.data->onTouchMoved(x, y);
        [gr setTranslation:CGPointZero inView:self];
    } else {
        if (self.hostVideoDragging) {
            self.hostVideoDragging = NO;
            return;
        }
        self.data->onTouchEnded();
    }
}

- (void)onPinch:(UIPinchGestureRecognizer *)gr {
    if (!self.data) return;
    if (gr.state == UIGestureRecognizerStateChanged) {
        float delta = (float)((gr.scale - 1.0) * 2.0);
        self.data->onPinch(delta);
        gr.scale = 1.0;
    }
}

#pragma mark - Camera control APIs

- (void)setMoveForward:(BOOL)on  { if (self.data) self.data->setMoveForward(on); }
- (void)setMoveBackward:(BOOL)on { if (self.data) self.data->setMoveBackward(on); }
- (void)setMoveLeft:(BOOL)on     { if (self.data) self.data->setMoveLeft(on); }
- (void)setMoveRight:(BOOL)on    { if (self.data) self.data->setMoveRight(on); }
- (void)setMoveUp:(BOOL)on       { if (self.data) self.data->setMoveUp(on); }
- (void)setMoveDown:(BOOL)on     { if (self.data) self.data->setMoveDown(on); }
- (void)setOrbitLeft:(BOOL)on    { if (self.data) self.data->setOrbitLeft(on); }
- (void)setOrbitRight:(BOOL)on   { if (self.data) self.data->setOrbitRight(on); }

- (void)setHostVideoMoveCloser:(BOOL)on {
    if (self.data) self.data->setHostVideoMoveCloser(on);
}
- (void)setHostVideoMoveFarther:(BOOL)on {
    if (self.data) self.data->setHostVideoMoveFarther(on);
}

#pragma mark - Scene / animation (for VC buttons)

- (NSArray<NSString *> *)animationNames {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (!self.data) return names;
    const int n = self.data->animationCount();
    for (int i = 0; i < n; ++i) {
        std::string raw = self.data->animationNameAt(i);
        NSString *label = raw.empty()
            ? [NSString stringWithFormat:@"Anim %d", i]
            : [NSString stringWithUTF8String:raw.c_str()];
        // FBX often uses "Armature|Walk" — show the last segment.
        NSRange pipe = [label rangeOfString:@"|" options:NSBackwardsSearch];
        if (pipe.location != NSNotFound) {
            label = [label substringFromIndex:pipe.location + 1];
        }
        [names addObject:label];
    }
    return names;
}

- (void)playAnimationAtIndex:(NSInteger)index {
    if (self.data) self.data->playAnimationAtIndex((int)index);
}

- (void)toggleAnimPause {
    if (self.data) self.data->toggleAnimPause();
}

- (NSArray<NSString *> *)modelNames {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (!self.data) return names;
    const int n = self.data->modelCount();
    for (int i = 0; i < n; ++i) {
        std::string raw = self.data->modelNameAt(i);
        [names addObject:raw.empty() ? [NSString stringWithFormat:@"Model %d", i]
                                     : [NSString stringWithUTF8String:raw.c_str()]];
    }
    return names;
}

- (NSInteger)currentModelIndex {
    return self.data ? (NSInteger)self.data->currentModelIndex() : 0;
}

- (BOOL)loadModelAtIndex:(NSInteger)index {
    if (!self.data || !self.context) return NO;
    [EAGLContext setCurrentContext:self.context];
    return self.data->loadModelAtIndex((int)index) ? YES : NO;
}

/// Assimp / 贴图上传很重：放到与主 context 共享的 sharegroup 后台线程，避免卡死 UI。
- (void)loadModelAtIndex:(NSInteger)index
              completion:(void (^)(BOOL success))completion {
    [self runModelLoadOnBackground:^BOOL{
        if (!self.data) return NO;
        return self.data->loadModelAtIndex((int)index);
    } completion:completion];
}

- (void)loadDefaultModelWithCompletion:(void (^)(BOOL success))completion {
    [self runModelLoadOnBackground:^BOOL{
        if (!self.data) return NO;
        return self.data->loadFirstAvailableModel();
    } completion:completion];
}

- (void)runModelLoadOnBackground:(BOOL (^)(void))work
                      completion:(void (^)(BOOL success))completion {
    if (!self.context || !self.data || !work) {
        if (completion) completion(NO);
        return;
    }

    // 切模型前强制收起「身后大视频」（expandT 立刻归零）。
    // 若只设 expanded=NO，DisplayLink 暂停时 expandT 停在 1，首帧仍走世界平面→加载后出现极慢。
    self.hostVideoExpanded = NO;
    if (self.data) self.data->resetHostVideoExpandForModelLoad();

    self.displayLink.paused = YES;
    self.modelLoadBusy = YES;
    CFTimeInterval tGate = CACurrentMediaTime();
    EAGLContext *shareCtx =
        [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3
                               sharegroup:self.context.sharegroup];
    if (!shareCtx) {
        self.modelLoadBusy = NO;
        self.displayLink.paused = NO;
        if (completion) completion(NO);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [EAGLContext setCurrentContext:shareCtx];
        CFTimeInterval t0 = CACurrentMediaTime();
        BOOL ok = work();
        CFTimeInterval tAfterWork = CACurrentMediaTime();
        // 勿 Finish：会空等 sharegroup 上全部 GPU 命令，拖长「加载→回主线程上屏」
        glFlush();
        CFTimeInterval tAfterFlush = CACurrentMediaTime();
        NSLog(@"[ModelTiming] A bg work %.0fms | B glFlush %.0fms",
              (tAfterWork - t0) * 1000.0,
              (tAfterFlush - tAfterWork) * 1000.0);
        [EAGLContext setCurrentContext:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            CFTimeInterval tMain = CACurrentMediaTime();
            [EAGLContext setCurrentContext:self.context];
            if (ok && self.data) {
                self.data->rebindCurrentModelGPU();
            }
            CFTimeInterval tRebind = CACurrentMediaTime();
            self.modelLoadBusy = NO;
            self.displayLink.paused = NO;
            // 立刻画一帧，模型马上出现（不等下一个 DisplayLink）
            if (ok) {
                [self drawFrame:self.displayLink];
            }
            CFTimeInterval tPresent = CACurrentMediaTime();
            NSLog(@"[ModelTiming] C main rebind %.0fms | D firstPresent %.0fms | gate→screen %.0fms",
                  (tRebind - tMain) * 1000.0,
                  (tPresent - tRebind) * 1000.0,
                  (tPresent - tGate) * 1000.0);
            if (completion) completion(ok);
        });
    });
}

static std::map<std::string, float> SCMapFromWeightDict(NSDictionary<NSString *, NSNumber *> *dict) {
    std::map<std::string, float> out;
    if (!dict) return out;
    for (NSString *key in dict) {
        NSNumber *val = dict[key];
        if (!key || !val) continue;
        out[std::string(key.UTF8String)] = val.floatValue;
    }
    return out;
}

- (void)applyFaceProjectionHeadYaw:(float)yaw
                             pitch:(float)pitch
                              roll:(float)roll
                       eyePitchLeft:(float)eyePitchL
                         eyeYawLeft:(float)eyeYawL
                      eyePitchRight:(float)eyePitchR
                        eyeYawRight:(float)eyeYawR
                        eyeWeights:(NSDictionary<NSString *, NSNumber *> *)eyeWeights
                       faceWeights:(NSDictionary<NSString *, NSNumber *> *)faceWeights {
    if (!self.data || self.modelLoadBusy) return;
    self.data->applyFaceDrive(yaw, pitch, roll,
                              eyePitchL, eyeYawL, eyePitchR, eyeYawR,
                              SCMapFromWeightDict(eyeWeights),
                              SCMapFromWeightDict(faceWeights));
}

- (NSInteger)applyUpperBodyLean:(float)lean {
    if (!self.data || self.modelLoadBusy) return 0;
    return (NSInteger)self.data->applyUpperBodyLean(lean);
}

- (void)clearUpperBodyDrive {
    if (self.data && !self.modelLoadBusy) self.data->clearUpperBodyDrive();
}

- (void)clearFaceDrive {
    if (self.data && !self.modelLoadBusy) self.data->clearFaceDrive();
}

@end
