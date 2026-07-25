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

/// Scene / animation controls (UI lives in ViewController).
- (void)toggleAnimPause;
- (void)playWalk;
- (void)playRun;
- (void)playCrawl;
- (void)playIdle;
- (void)browsePrevAnim;
- (void)browseNextAnim;

@end

NS_ASSUME_NONNULL_END
