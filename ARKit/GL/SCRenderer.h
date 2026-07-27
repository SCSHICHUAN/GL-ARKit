/*
  SCRenderer.h
  OpenGL ES view: renders the scene and exposes camera control APIs.
*/

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class SCRenderCapture;
@class EAGLContext;

@interface SCRenderer : UIView

/// 直播抓帧（SCRenderCapture attach 后设置）；encode 尺寸离屏再画屏
@property (nonatomic, weak, nullable) SCRenderCapture *renderCapture;
@property (nonatomic, strong, readonly, nullable) EAGLContext *eaglContext;

/// Start GLES context, scene, and display link. Call once after added to hierarchy (or from VC viewDidLoad).
- (BOOL)startRendering;

/// Camera move (hold buttons typically call these).
- (void)setMoveForward:(BOOL)on;
- (void)setMoveBackward:(BOOL)on;
- (void)setMoveLeft:(BOOL)on;
- (void)setMoveRight:(BOOL)on;
- (void)setMoveUp:(BOOL)on;
- (void)setMoveDown:(BOOL)on;

/// Clip names from the loaded model (ready after startRendering succeeds).
- (NSArray<NSString *> *)animationNames;
- (void)playAnimationAtIndex:(NSInteger)index;
- (void)toggleAnimPause;

/// Bundled character models (auto-scanned from models/).
- (NSArray<NSString *> *)modelNames;
- (NSInteger)currentModelIndex;
- (BOOL)loadModelAtIndex:(NSInteger)index;

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
