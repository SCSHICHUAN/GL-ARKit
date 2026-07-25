/*
  SCARTypes.h
  Shared ARKit tracking payloads (head / body / face).
  Face dump → SCARFaceProjector 投射后再接模型。
*/

#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

/// Head pose from face anchor (front camera) or body skeleton head joint.
@interface SCARHeadData : NSObject
@property (nonatomic, assign) simd_float3 position;
@property (nonatomic, assign) simd_quatf orientation;
@property (nonatomic, assign) simd_float4x4 transform;
@property (nonatomic, copy) NSString *source; // @"face" | @"body"
@end

/// One body joint sample.
@interface SCARBodyJoint : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) simd_float3 position;
@property (nonatomic, assign) simd_quatf orientation;
@property (nonatomic, assign) BOOL tracked;
@end

@interface SCARBodyData : NSObject
@property (nonatomic, copy) NSArray<SCARBodyJoint *> *joints;
@property (nonatomic, strong, nullable) SCARHeadData *head;
@end

/// Face blend shapes + optional mesh stats (TrueDepth).
@interface SCARFaceData : NSObject
@property (nonatomic, strong) SCARHeadData *head;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *blendShapes; // ARBlendShapeLocation → 0..1
@property (nonatomic, assign) NSInteger geometryVertexCount;
/// 相对 face anchor 的眼球变换（ARFaceAnchor left/rightEyeTransform）
@property (nonatomic, assign) simd_float4x4 leftEyeTransform;
@property (nonatomic, assign) simd_float4x4 rightEyeTransform;
@property (nonatomic, assign) BOOL hasEyeTransforms;
@end

NS_ASSUME_NONNULL_END
