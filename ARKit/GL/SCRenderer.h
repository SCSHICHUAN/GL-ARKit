/*
  SCRenderer.h
  OpenGL ES view: renders the scene and exposes camera control APIs.
*/

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCRenderer : UIView

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
- (void)clearFaceDrive;

@end

NS_ASSUME_NONNULL_END
