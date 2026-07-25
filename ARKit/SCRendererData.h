//
//  SCRendererData.h
//  ARKit — C++ scene previously driven by GLFW main loop
//

#ifndef SCRendererData_h
#define SCRendererData_h

#include <string>

class SCRendererData {
public:
    SCRendererData();
    ~SCRendererData();

    // resourceRoot: absolute path to bundle resources (shaders/, Wolf-fbx/, ...)
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
    void playWalk();
    void playRun();
    void playCrawl();
    void playIdle();
    void browsePrevAnim();
    void browseNextAnim();

private:
    struct Impl;
    Impl* impl_;
};

#endif /* SCRendererData_h */
