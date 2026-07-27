/*
  SCRenderer.mm
  CAEAGLLayer OpenGL ES 3 view — render loop + camera gestures/APIs.
*/

#import "SCRenderer.h"
#import "SCRenderCapture.h"
#import <QuartzCore/QuartzCore.h>
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
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.started = YES;
    return YES;
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
        [self destroyFramebuffer];
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
    if (!self.data || !self.context) return;
    [EAGLContext setCurrentContext:self.context];

    float dt = 1.0f / 60.0f;
    if (self.lastTimestamp > 0) {
        dt = (float)(link.timestamp - self.lastTimestamp);
    }
    self.lastTimestamp = link.timestamp;
    if (dt > 0.1f) dt = 0.1f;

    self.data->update(dt);

    // ① 直播：直接渲到编码尺寸的 CVPixelBuffer（TextureCache，无全屏 readPixels）
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

    // ② 屏幕
    glBindFramebuffer(GL_FRAMEBUFFER, self.defaultFramebuffer);
    glViewport(0, 0, self.backingWidth, self.backingHeight);
    self.data->render();

    glBindRenderbuffer(GL_RENDERBUFFER, self.colorRenderbuffer);
    [self.context presentRenderbuffer:GL_RENDERBUFFER];
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
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    return ![touch.view isKindOfClass:[UIControl class]];
}

- (void)onPan:(UIPanGestureRecognizer *)gr {
    if (!self.data) return;
    // Use translation deltas — more stable than absolute location for pitch/yaw.
    CGFloat scale = self.contentScaleFactor;
    if (gr.state == UIGestureRecognizerStateBegan) {
        CGPoint p = [gr locationInView:self];
        self.data->onTouchBegan((float)(p.x * scale), (float)(p.y * scale));
        [gr setTranslation:CGPointZero inView:self];
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [gr translationInView:self];
        CGPoint p = [gr locationInView:self];
        // Feed previous point + delta via began/moved convention:
        float x = (float)(p.x * scale);
        float y = (float)(p.y * scale);
        float prevX = x - (float)(t.x * scale);
        float prevY = y - (float)(t.y * scale);
        self.data->onTouchBegan(prevX, prevY);
        self.data->onTouchMoved(x, y);
        [gr setTranslation:CGPointZero inView:self];
    } else {
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
    if (!self.data) return NO;
    return self.data->loadModelAtIndex((int)index) ? YES : NO;
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
    if (!self.data) return;
    self.data->applyFaceDrive(yaw, pitch, roll,
                              eyePitchL, eyeYawL, eyePitchR, eyeYawR,
                              SCMapFromWeightDict(eyeWeights),
                              SCMapFromWeightDict(faceWeights));
}

- (NSInteger)applyUpperBodyLean:(float)lean {
    if (!self.data) return 0;
    return (NSInteger)self.data->applyUpperBodyLean(lean);
}

- (void)clearUpperBodyDrive {
    if (self.data) self.data->clearUpperBodyDrive();
}

- (void)clearFaceDrive {
    if (self.data) self.data->clearFaceDrive();
}

@end
