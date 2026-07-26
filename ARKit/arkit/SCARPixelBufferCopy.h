/*
  SCARPixelBufferCopy.h
  CPU 深拷贝 CVPixelBuffer。
  ARFrame.capturedImage 下一帧即失效；Vision 异步用必须先拷贝（勿 Metal CI，会与 GL 冲突）。
*/

#import <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 返回新建缓冲（调用方 CVPixelBufferRelease）；失败返回 NULL
CVPixelBufferRef SCARClonePixelBuffer(CVPixelBufferRef src);

#ifdef __cplusplus
}
#endif
