/*
  SCARPixelBufferCopy.m
*/

#import "SCARPixelBufferCopy.h"
#import <Foundation/Foundation.h>

CVPixelBufferRef SCARClonePixelBuffer(CVPixelBufferRef src) {
    if (!src) return NULL;
    // 野指针时 GetTypeID 也可能崩；调用方须保证 src 仍归属有效 ARFrame/自有缓冲
    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    if (w == 0 || h == 0) return NULL;

    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    size_t planes = CVPixelBufferGetPlaneCount(src);
    if (planes == 0) {
        const void *s = CVPixelBufferGetBaseAddress(src);
        void *d = CVPixelBufferGetBaseAddress(dst);
        size_t srcBPR = CVPixelBufferGetBytesPerRow(src);
        size_t dstBPR = CVPixelBufferGetBytesPerRow(dst);
        size_t row = srcBPR < dstBPR ? srcBPR : dstBPR;
        if (s && d) {
            for (size_t y = 0; y < h; ++y) {
                memcpy((char *)d + y * dstBPR, (const char *)s + y * srcBPR, row);
            }
        }
    } else {
        for (size_t p = 0; p < planes; ++p) {
            const void *s = CVPixelBufferGetBaseAddressOfPlane(src, p);
            void *d = CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t ph = CVPixelBufferGetHeightOfPlane(src, p);
            size_t sbpr = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t dbpr = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            size_t row = sbpr < dbpr ? sbpr : dbpr;
            if (!s || !d) continue;
            for (size_t y = 0; y < ph; ++y) {
                memcpy((char *)d + y * dbpr, (const char *)s + y * sbpr, row);
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return dst;
}
