//
//  SCRendererData.h
//  C++ 场景与 Face / lean 驱动入口（applyFaceDrive / applyUpperBodyLean）。
//

#ifndef SCRendererData_h
#define SCRendererData_h

#include <string>
#include <map>

class SCRendererData {
public:
    SCRendererData();
    ~SCRendererData();

    // resourceRoot: absolute path to bundle resources (shaders/, models/, ...)
    bool init(const std::string& resourceRoot, int width, int height);
    void resize(int width, int height);
    void update(float deltaTime);
    void render();
    /// 渲到 CVPixelBuffer 时翻转 Y（GL 底原点 → 视频顶原点）
    void setRenderFlipY(bool flipY);

    /// 主播 YUV 面板（GLuint 纹理，由 ObjC TextureCache 上传）
    void setHostVideoTextures(unsigned int yTex, unsigned int uvTex, bool valid,
                              int pixelW = 0, int pixelH = 0);
    void setHostVideoOrientation(int cgImageOrientation /*1..8*/);
    void setHostVideoMirrorX(bool mirror);
    void setHostVideoVisible(bool visible);
    /// UIKit 坐标归一化到 glView：x,y 左上原点，宽高相对 view bounds（0~1）
    void setHostVideoScreenRectNorm(float x, float y, float w, float h);
    /// 视频矩形绕面对角线旋转角（度），范围 [0, 90]
    void setHostVideoRotationDegrees(float degrees);
    /// 点击小窗：铺满窗口并画在模型后；再点恢复。
    void setHostVideoExpanded(bool expanded);
    bool isHostVideoExpanded() const;
    /// 切模型前强制收起，避免展开视频拖慢加载→首帧
    void resetHostVideoExpandForModelLoad();
    /// 展开时按住调节视频板前后（世界 Z；+ 朝相机）
    void setHostVideoMoveCloser(bool on);
    void setHostVideoMoveFarther(bool on);

    // Touch / gesture input (replaces mouse + keyboard)
    void onTouchBegan(float x, float y);
    void onTouchMoved(float x, float y);
    void onTouchEnded();
    void onPinch(float scaleDelta);
    void setMoveForward(bool on);
    void setMoveBackward(bool on);
    void setMoveLeft(bool on);
    void setMoveRight(bool on);
    void setMoveUp(bool on);
    void setMoveDown(bool on);
    /// 绕人物世界 Y 轴环绕（相机始终看人）
    void setOrbitLeft(bool on);
    void setOrbitRight(bool on);

    void toggleAnimPause();

    /// Available after model load (Assimp clips).
    int animationCount() const;
    std::string animationNameAt(int index) const;
    void playAnimationAtIndex(int index);

    /// Catalog scanned from bundle models/ (synced from ARKit/models).
    int modelCount() const;
    std::string modelNameAt(int index) const;
    int currentModelIndex() const;
    /// Swap the drawn Assimp model; returns false if path missing / load failed.
    /// 须在当前 EAGLContext 下调用（可用 sharegroup 后台线程 Assimp+上传纹理）。
    bool loadModelAtIndex(int index);
    /// 目录中第一个可加载模型（启动时异步调用）
    bool loadFirstAvailableModel();
    bool hasModel() const;
    /// 主 context 上重建 VAO（后台线程 load 之后必须调）
    void rebindCurrentModelGPU();

    /// ARKit 投射结果：头姿 + 眼/脸权重 → 模型（头旋转 + 表情骨骼覆盖）。
    /// eyePitch/Yaw：左右眼注视角（弧度，头/脸空间）。
    void applyFaceDrive(float headYawRad, float headPitchRad, float headRollRad,
                        float eyePitchL, float eyeYawL, float eyePitchR, float eyeYawR,
                        const std::map<std::string, float>& eyeWeights,
                        const std::map<std::string, float>& faceWeights);
    /// Vision 上体左右倾斜（弧度），只打脊柱骨；叠在动画上，与 Face 合并。返回匹配骨数。
    int applyUpperBodyLean(float torsoLeanRad);
    void clearUpperBodyDrive();
    void clearFaceDrive();
    bool isFaceDriveActive() const;
    int lastUpperBodyBoneCount() const;

private:
    struct Impl;
    Impl* impl_;
};

#endif /* SCRendererData_h */
