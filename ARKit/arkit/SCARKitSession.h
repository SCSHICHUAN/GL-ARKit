/*
  SCARKitSession.h
  Apple ARKit session: face (head + blend shapes) or body (skeleton).
  Face and body use different cameras — only one mode runs at a time.
*/

#import <Foundation/Foundation.h>
#import "SCARTypes.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCARKitTrackingMode) {
    /// Front camera + TrueDepth: head pose + face blend shapes.
    SCARKitTrackingModeFace = 0,
    /// Rear camera: body skeleton (includes head joint).
    SCARKitTrackingModeBody = 1,
};

@class SCARKitSession;

@protocol SCARKitSessionDelegate <NSObject>
@optional
- (void)arSession:(SCARKitSession *)session didUpdateFace:(SCARFaceData *)face;
- (void)arSession:(SCARKitSession *)session didUpdateBody:(SCARBodyData *)body;
- (void)arSession:(SCARKitSession *)session didChangeMode:(SCARKitTrackingMode)mode;
- (void)arSession:(SCARKitSession *)session didFailWithMessage:(NSString *)message;
@end

@interface SCARKitSession : NSObject

@property (nonatomic, weak, nullable) id<SCARKitSessionDelegate> delegate;
@property (nonatomic, assign, readonly) SCARKitTrackingMode mode;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;

/// Throttle console dumps (seconds). 0 = every frame (very noisy).
@property (nonatomic, assign) NSTimeInterval logInterval;

+ (BOOL)isFaceTrackingSupported;
+ (BOOL)isBodyTrackingSupported;

- (BOOL)startWithMode:(SCARKitTrackingMode)mode;
- (void)switchToMode:(SCARKitTrackingMode)mode;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
