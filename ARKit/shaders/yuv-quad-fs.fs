/*
  yuv-quad-fs.fs
  NV12 biplanar → RGB
  GL_LUMINANCE_ALPHA 的 UV 平面必须用 .ra（不是 .rg），否则整屏发绿。
*/
#version 300 es
precision highp float;

in vec2 vTexCoord;
out vec4 FragColor;

uniform sampler2D yTex;
uniform sampler2D uvTex;
/// CGImagePropertyOrientation 原值 1..8
uniform int orientation;
uniform bool mirrorX;
/// CV 纹理相对 GL 常需竖翻
uniform bool flipTexY;

vec2 applyOrientation(vec2 uv) {
    // 1 Up, 2 UpMir, 3 Down, 4 DownMir, 5 LeftMir, 6 Right, 7 RightMir, 8 Left
    if (orientation == 2) {
        return vec2(1.0 - uv.x, uv.y);
    } else if (orientation == 3) {
        return vec2(1.0 - uv.x, 1.0 - uv.y);
    } else if (orientation == 4) {
        return vec2(uv.x, 1.0 - uv.y);
    } else if (orientation == 5) {
        return vec2(uv.y, uv.x);
    } else if (orientation == 6) {
        // Right：竖屏前置常见
        return vec2(uv.y, 1.0 - uv.x);
    } else if (orientation == 7) {
        return vec2(1.0 - uv.y, 1.0 - uv.x);
    } else if (orientation == 8) {
        return vec2(1.0 - uv.y, uv.x);
    }
    return uv; // Up
}

void main() {
    vec2 uv = vTexCoord;
    if (flipTexY) {
        uv.y = 1.0 - uv.y;
    }
    uv = applyOrientation(uv);
    if (mirrorX) {
        uv.x = 1.0 - uv.x;
    }

    float y = texture(yTex, uv).r;
    // LUMINANCE_ALPHA：Cb→R，Cr→A
    vec2 cbcr = texture(uvTex, uv).ra;
    float cb = cbcr.x - 0.5;
    float cr = cbcr.y - 0.5;

    float r = y + 1.402 * cr;
    float g = y - 0.344136 * cb - 0.714136 * cr;
    float b = y + 1.772 * cb;
    FragColor = vec4(clamp(vec3(r, g, b), 0.0, 1.0), 1.0);
}
