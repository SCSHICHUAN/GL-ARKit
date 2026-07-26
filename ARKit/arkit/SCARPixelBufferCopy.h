/*
  SCARPixelBufferCopy.h
  CPU 深拷贝 CVPixelBuffer（ARKit capturedImage 不可跨帧裸存指针）。
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
