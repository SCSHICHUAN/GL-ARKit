/*
  SCARKitSession.h
  ARKit Face（头+blendShapes）或 Body（骨架）；前后摄不同，同时只能一种。
  Face 模式通过 didUpdateCapturedImage 把仍有效的画面交给 Vision lean。
*/

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
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
/// 仅在本回调栈内有效（勿保存指针）。用于 Vision lean。
- (void)arSession:(SCARKitSession *)session
didUpdateCapturedImage:(CVPixelBufferRef)image
      orientation:(CGImagePropertyOrientation)orientation;
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
