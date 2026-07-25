//
//  SCRendererData.h
//  ARKit — C++ scene previously driven by GLFW main loop
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
    bool loadModelAtIndex(int index);

    /// ARKit 投射结果：头姿 + 眼/脸权重 → 模型（头旋转 + 表情骨骼覆盖）。
    /// eyePitch/Yaw：左右眼注视角（弧度，头/脸空间）。
    void applyFaceDrive(float headYawRad, float headPitchRad, float headRollRad,
                        float eyePitchL, float eyeYawL, float eyePitchR, float eyeYawR,
                        const std::map<std::string, float>& eyeWeights,
                        const std::map<std::string, float>& faceWeights);
    void clearFaceDrive();
    bool isFaceDriveActive() const;

private:
    struct Impl;
    Impl* impl_;
};

#endif /* SCRendererData_h */
