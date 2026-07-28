/*
  SCRenderer.h
  OpenGL ES view: renders the scene and exposes camera control APIs.
*/

#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@class SCRenderCapture;
@class EAGLContext;

@interface SCRenderer : UIView

/// 直播抓帧（SCRenderCapture attach 后设置）；encode 尺寸离屏再画屏
@property (nonatomic, weak, nullable) SCRenderCapture *renderCapture;
@property (nonatomic, strong, readonly, nullable) EAGLContext *eaglContext;
/// 场景中主播摄像头 YUV 长方形（默认开；进 Avatar 推流）
@property (nonatomic, assign) BOOL hostVideoVisible;
/// CADisplayLink 目标帧率（推流 60p 时设为 60；0 = 系统默认）
@property (nonatomic, assign) NSInteger preferredFramesPerSecond;

/// Start GLES context, scene, and display link. Call once after added to hierarchy (or from VC viewDidLoad).
- (BOOL)startRendering;

/// ARKit capturedImage → GL 面板（内部 retain；在渲染线程上传纹理）
- (void)submitHostVideoPixelBuffer:(CVPixelBufferRef)pixelBuffer
                       orientation:(CGImagePropertyOrientation)orientation;

/// 与 UIKit 前置预览小窗对齐（glView 坐标系，点）
- (void)setHostVideoScreenRect:(CGRect)rectInGLView;
/// 视频绕底边前后翻（度）：上滑向后(负)、下滑向前(正)，[-90, 90]
@property (nonatomic, assign) float hostVideoRotationDegrees;
/// 点击视频区：大矩形移到人物身后（仍可见矩形）；再点恢复小窗
@property (nonatomic, assign) BOOL hostVideoExpanded;
- (void)toggleHostVideoExpanded;

/// Camera move (hold buttons typically call these).
- (void)setMoveForward:(BOOL)on;
- (void)setMoveBackward:(BOOL)on;
- (void)setMoveLeft:(BOOL)on;
- (void)setMoveRight:(BOOL)on;
- (void)setMoveUp:(BOOL)on;
- (void)setMoveDown:(BOOL)on;
/// 绕人物 Y 轴环绕（始终看人）
- (void)setOrbitLeft:(BOOL)on;
- (void)setOrbitRight:(BOOL)on;
/// 展开视频时：按住前后移动视频板（世界 Z）
- (void)setHostVideoMoveCloser:(BOOL)on;
- (void)setHostVideoMoveFarther:(BOOL)on;

/// Clip names from the loaded model (ready after startRendering succeeds).
- (NSArray<NSString *> *)animationNames;
- (void)playAnimationAtIndex:(NSInteger)index;
- (void)toggleAnimPause;

/// Bundled character models (auto-scanned from models/).
- (NSArray<NSString *> *)modelNames;
- (NSInteger)currentModelIndex;
- (BOOL)loadModelAtIndex:(NSInteger)index;
/// Assimp+纹理在 sharegroup 后台线程；完成后主线程回调（不卡 UI）
- (void)loadModelAtIndex:(NSInteger)index
              completion:(void (^)(BOOL success))completion;
- (void)loadDefaultModelWithCompletion:(void (^)(BOOL success))completion;

/// ARKit 三路投射 → 驱动当前模型（头旋转 + 表情骨骼）。
- (void)applyFaceProjectionHeadYaw:(float)yaw
                             pitch:(float)pitch
                              roll:(float)roll
                       eyePitchLeft:(float)eyePitchL
                         eyeYawLeft:(float)eyeYawL
                      eyePitchRight:(float)eyePitchR
                        eyeYawRight:(float)eyeYawR
                        eyeWeights:(NSDictionary<NSString *, NSNumber *> *)eyeWeights
                       faceWeights:(NSDictionary<NSString *, NSNumber *> *)faceWeights;
/// Vision 上体左右倾斜，叠在动画上。返回匹配骨骼数。
- (NSInteger)applyUpperBodyLean:(float)lean;
- (void)clearUpperBodyDrive;
- (void)clearFaceDrive;

@end

NS_ASSUME_NONNULL_END
