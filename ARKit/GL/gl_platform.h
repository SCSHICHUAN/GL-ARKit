//
//  gl_platform.h
//  ARKit — OpenGL ES 3 on iOS, Glad on other platforms
//

#ifndef gl_platform_h
#define gl_platform_h

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if TARGET_OS_IPHONE
#ifndef GLES_SILENCE_DEPRECATION
#define GLES_SILENCE_DEPRECATION
#endif
#include <OpenGLES/ES3/gl.h>
#include <OpenGLES/ES3/glext.h>
#else
#include <glad/glad.h>
#endif

#endif /* gl_platform_h */
