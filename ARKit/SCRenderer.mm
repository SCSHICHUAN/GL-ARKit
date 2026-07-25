/*
  SCRenderer.mm
  CAEAGLLayer OpenGL ES 3 view — render loop + camera gestures/APIs.
*/

#import "SCRenderer.h"
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#include "SCRendererData.h"

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
        [self destroyFramebuffer];
    }
    delete self.data;
    self.data = nullptr;
    if ([EAGLContext currentContext] == self.context) {
        [EAGLContext setCurrentContext:nil];
    }
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
    CGPoint p = [gr locationInView:self];
    CGFloat scale = self.contentScaleFactor;
    float x = (float)(p.x * scale);
    float y = (float)(p.y * scale);
    if (gr.state == UIGestureRecognizerStateBegan) {
        self.data->onTouchBegan(x, y);
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        self.data->onTouchMoved(x, y);
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

- (void)toggleAnimPause     { if (self.data) self.data->toggleAnimPause(); }
- (void)playWalk            { if (self.data) self.data->playWalk(); }
- (void)playRun             { if (self.data) self.data->playRun(); }
- (void)playCrawl           { if (self.data) self.data->playCrawl(); }
- (void)playIdle            { if (self.data) self.data->playIdle(); }
- (void)browsePrevAnim      { if (self.data) self.data->browsePrevAnim(); }
- (void)browseNextAnim      { if (self.data) self.data->browseNextAnim(); }

@end
