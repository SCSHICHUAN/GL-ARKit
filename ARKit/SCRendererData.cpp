//
//  SCRendererData.cpp
//  ARKit — 与 main.cpp 相同逻辑；仅去掉 GLFW，路径走 bundle
//

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#include "SCRendererData.h"
#include "gl_platform.h"
#include "shader.h"
#include "Camera.h"
#include "mesh.h"
#include "model.h"
#include "animation.h"

#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>

#include <algorithm>
#include <cmath>
#include <iostream>
#include <string>
#include <vector>

using namespace std;

struct SCRendererData::Impl {
    // settings / camera — 与 main.cpp 一致
    Camera camera;
    float lastX = 0.0f;
    float lastY = 0.0f;
    bool firstMouse = true;

    float deltaTime = 0.0f;
    float elapsedTime = 0.0f;

    bool gEnableAnimation = true;
    int gSelectedAnimIndex = -1;
    float gModelYaw = glm::radians(60.0f);   // touch left/right
    float gModelPitch = 0.0f;                // touch up/down
    bool gAnimPaused = false;
    int gIdleAnimIndex = 0;
    int gActionAnimIndex = -1;
    int gStandAnimIndex = -1;
    int gSitAnimIndex = -1;
    std::vector<int> gExtraAnimKeySlots;
    int gBrowseAnimIndex = 0;

    Model* gModel = nullptr;
    Animator* gAnimator = nullptr;
    Animator* animator = nullptr;
    Model* ourModel = nullptr;
    Shader* ourShader = nullptr;
    Shader* lightCubeShader = nullptr;

    glm::vec3 lightPos = glm::vec3(1.0f, 0.0f, 0.0f);
    unsigned int cubeVAO = 0, lightCubeVAO = 0, VBO = 0;

    int screenWidth = 1000;
    int screenHeight = 750;
    std::string resourceRoot;

    bool moveForward = false, moveBackward = false, moveLeft = false;
    bool moveRight = false, moveUp = false, moveDown = false;

    Impl()
        : camera(glm::vec3(0.0f, 1.6f, 2.8f), glm::vec3(0.0f, 1.0f, 0.0f), -88.0f, -30.0f)
    {}

    ~Impl() {
        delete animator;
        delete ourModel;
        delete ourShader;
        delete lightCubeShader;
        if (cubeVAO) glDeleteVertexArrays(1, &cubeVAO);
        if (lightCubeVAO) glDeleteVertexArrays(1, &lightCubeVAO);
        if (VBO) glDeleteBuffers(1, &VBO);
    }

    void createVBOVAO() {
        float vertices[] = {
            -0.5f, -0.5f, -0.5f,  0.0f,  0.0f, -1.0f,  0.0f,  0.0f,
             0.5f, -0.5f, -0.5f,  0.0f,  0.0f, -1.0f,  1.0f,  0.0f,
             0.5f,  0.5f, -0.5f,  0.0f,  0.0f, -1.0f,  1.0f,  1.0f,
             0.5f,  0.5f, -0.5f,  0.0f,  0.0f, -1.0f,  1.0f,  1.0f,
            -0.5f,  0.5f, -0.5f,  0.0f,  0.0f, -1.0f,  0.0f,  1.0f,
            -0.5f, -0.5f, -0.5f,  0.0f,  0.0f, -1.0f,  0.0f,  0.0f,

            -0.5f, -0.5f,  0.5f,  0.0f,  0.0f,  1.0f,  0.0f,  0.0f,
             0.5f, -0.5f,  0.5f,  0.0f,  0.0f,  1.0f,  1.0f,  0.0f,
             0.5f,  0.5f,  0.5f,  0.0f,  0.0f,  1.0f,  1.0f,  1.0f,
             0.5f,  0.5f,  0.5f,  0.0f,  0.0f,  1.0f,  1.0f,  1.0f,
            -0.5f,  0.5f,  0.5f,  0.0f,  0.0f,  1.0f,  0.0f,  1.0f,
            -0.5f, -0.5f,  0.5f,  0.0f,  0.0f,  1.0f,  0.0f,  0.0f,

            -0.5f,  0.5f,  0.5f, -1.0f,  0.0f,  0.0f,  1.0f,  0.0f,
            -0.5f,  0.5f, -0.5f, -1.0f,  0.0f,  0.0f,  1.0f,  1.0f,
            -0.5f, -0.5f, -0.5f, -1.0f,  0.0f,  0.0f,  0.0f,  1.0f,
            -0.5f, -0.5f, -0.5f, -1.0f,  0.0f,  0.0f,  0.0f,  1.0f,
            -0.5f, -0.5f,  0.5f, -1.0f,  0.0f,  0.0f,  0.0f,  0.0f,
            -0.5f,  0.5f,  0.5f, -1.0f,  0.0f,  0.0f,  1.0f,  0.0f,

             0.5f,  0.5f,  0.5f,  1.0f,  0.0f,  0.0f,  1.0f,  0.0f,
             0.5f,  0.5f, -0.5f,  1.0f,  0.0f,  0.0f,  1.0f,  1.0f,
             0.5f, -0.5f, -0.5f,  1.0f,  0.0f,  0.0f,  0.0f,  1.0f,
             0.5f, -0.5f, -0.5f,  1.0f,  0.0f,  0.0f,  0.0f,  1.0f,
             0.5f, -0.5f,  0.5f,  1.0f,  0.0f,  0.0f,  0.0f,  0.0f,
             0.5f,  0.5f,  0.5f,  1.0f,  0.0f,  0.0f,  1.0f,  0.0f,

            -0.5f, -0.5f, -0.5f,  0.0f, -1.0f,  0.0f,  0.0f,  1.0f,
             0.5f, -0.5f, -0.5f,  0.0f, -1.0f,  0.0f,  1.0f,  1.0f,
             0.5f, -0.5f,  0.5f,  0.0f, -1.0f,  0.0f,  1.0f,  0.0f,
             0.5f, -0.5f,  0.5f,  0.0f, -1.0f,  0.0f,  1.0f,  0.0f,
            -0.5f, -0.5f,  0.5f,  0.0f, -1.0f,  0.0f,  0.0f,  0.0f,
            -0.5f, -0.5f, -0.5f,  0.0f, -1.0f,  0.0f,  0.0f,  1.0f,

            -0.5f,  0.5f, -0.5f,  0.0f,  1.0f,  0.0f,  0.0f,  1.0f,
             0.5f,  0.5f, -0.5f,  0.0f,  1.0f,  0.0f,  1.0f,  1.0f,
             0.5f,  0.5f,  0.5f,  0.0f,  1.0f,  0.0f,  1.0f,  0.0f,
             0.5f,  0.5f,  0.5f,  0.0f,  1.0f,  0.0f,  1.0f,  0.0f,
            -0.5f,  0.5f,  0.5f,  0.0f,  1.0f,  0.0f,  0.0f,  0.0f,
            -0.5f,  0.5f, -0.5f,  0.0f,  1.0f,  0.0f,  0.0f,  1.0f
        };
        glGenVertexArrays(1, &cubeVAO);
        glGenBuffers(1, &VBO);
        glBindBuffer(GL_ARRAY_BUFFER, VBO);
        glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
        glBindVertexArray(cubeVAO);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 8 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 8 * sizeof(float), (void*)(3 * sizeof(float)));
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, 8 * sizeof(float), (void*)(6 * sizeof(float)));
        glEnableVertexAttribArray(2);
        glGenVertexArrays(1, &lightCubeVAO);
        glBindVertexArray(lightCubeVAO);
        glBindBuffer(GL_ARRAY_BUFFER, VBO);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 8 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(0);
    }

    void buildAnimKeyMap() {
        const int animCount = ourModel->getAnimationCount();
        gBrowseAnimIndex = (gIdleAnimIndex >= 0 && gIdleAnimIndex < animCount) ? gIdleAnimIndex : 0;
        auto findIdx = [&](const std::string& k) { return ourModel->findAnimationIndexByNameContains(k); };
        const int idxWalk  = findIdx("walk");
        const int idxRun   = findIdx("run");
        const int idxSit   = findIdx("sit");
        int idxCrawl = findIdx("crawl");
        if (idxCrawl == -1) idxCrawl = findIdx("prone");
        if (idxCrawl == -1) idxCrawl = findIdx("creep");
        const int idxStand = findIdx("stand");
        const int idxIdle  = findIdx("idle");
        gStandAnimIndex = idxStand;
        gSitAnimIndex = idxSit;

        std::vector<int> reserved;
        auto addReserved = [&](int v) {
            if (v < 0) return;
            if (std::find(reserved.begin(), reserved.end(), v) == reserved.end()) reserved.push_back(v);
        };
        addReserved(idxWalk); addReserved(idxRun); addReserved(idxSit);
        addReserved(idxCrawl); addReserved(idxStand); addReserved(idxIdle); addReserved(gIdleAnimIndex);

        std::vector<int> extras;
        for (int i = 0; i < animCount; ++i) {
            if (std::find(reserved.begin(), reserved.end(), i) == reserved.end()) extras.push_back(i);
        }
        gExtraAnimKeySlots.assign(5, -1);
        for (int i = 0; i < 5 && i < (int)extras.size(); ++i) gExtraAnimKeySlots[i] = extras[i];
    }

    void switchAnim(int idx, bool loop) {
        if (!gModel || !gAnimator) return;
        Animation* a = gModel->getAnimation(idx);
        if (!a) return;
        gAnimator->setLooping(loop);
        gAnimator->playAnimation(a, true);
        gEnableAnimation = true;
        gSelectedAnimIndex = idx;
        std::cout << "[Anim] switched to index " << idx
                  << " name=" << a->getSourceName()
                  << " matchedChannels=" << a->getMatchedChannels()
                  << " loop=" << (loop ? "ON" : "OFF") << std::endl;
    }

    void switchAnimByKeywordOrIndex(const std::string& keyLower, int fallbackIndex, bool loop) {
        if (!gModel) return;
        int idx = gModel->findAnimationIndexByNameContains(keyLower);
        if (idx == -1) idx = fallbackIndex;
        switchAnim(idx, loop);
    }

    void switchAnimByKeywordsOrIndex(const std::vector<std::string>& keysLower, int fallbackIndex, bool loop) {
        if (!gModel) return;
        int idx = -1;
        for (const auto& keyLower : keysLower) {
            idx = gModel->findAnimationIndexByNameContains(keyLower);
            if (idx != -1) break;
        }
        if (idx == -1) idx = fallbackIndex;
        switchAnim(idx, loop);
    }
};

SCRendererData::SCRendererData() : impl_(new Impl) {}
SCRendererData::~SCRendererData() { delete impl_; impl_ = nullptr; }

bool SCRendererData::init(const std::string& resourceRoot, int width, int height) {
    if (!impl_) return false;
    impl_->resourceRoot = resourceRoot;
    impl_->screenWidth = width;
    impl_->screenHeight = height;
    impl_->lastX = width / 2.0f;
    impl_->lastY = height / 2.0f;

    impl_->createVBOVAO();

    // 仅路径改为 bundle；其余与 main.cpp 一致
    std::string lampVs = resourceRoot + "/shaders/lamp-vs.vs";
    std::string lampFs = resourceRoot + "/shaders/lamp-fs.fs";
    std::string colorVs = resourceRoot + "/shaders/colors-vs.vs";
    std::string colorFs = resourceRoot + "/shaders/colors-fs.fs";
    std::string modelPath = resourceRoot + "/Wolf-fbx/Wolf_One_fbx7.4_binary.fbx";

    impl_->lightCubeShader = new Shader(lampVs.c_str(), lampFs.c_str());
    impl_->ourShader = new Shader(colorVs.c_str(), colorFs.c_str());
    impl_->ourModel = new Model(modelPath);
    printf("Model loaded, number of meshes: %d\n", impl_->ourModel->getMeshCount());
    printf("Number of bones in model: %d\n", impl_->ourModel->getBoneCount());

    if (impl_->ourModel->getAnimation()) {
        impl_->animator = new Animator(impl_->ourModel->getAnimation());
        impl_->gIdleAnimIndex = impl_->ourModel->getAnimation()->getAnimationIndex();
    }
    impl_->gModel = impl_->ourModel;
    impl_->gAnimator = impl_->animator;
    impl_->buildAnimKeyMap();

    glEnable(GL_DEPTH_TEST);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glViewport(0, 0, width, height);
    return true;
}

void SCRendererData::resize(int width, int height) {
    if (!impl_ || width <= 0 || height <= 0) return;
    impl_->screenWidth = width;
    impl_->screenHeight = height;
    glViewport(0, 0, width, height);
}

void SCRendererData::update(float dt) {
    if (!impl_) return;
    impl_->deltaTime = dt;
    impl_->elapsedTime += dt;

    if (impl_->moveForward)  impl_->camera.ProcessKeyboard(FORWARD, dt);
    if (impl_->moveBackward) impl_->camera.ProcessKeyboard(BACKWARD, dt);
    if (impl_->moveLeft)     impl_->camera.ProcessKeyboard(LEFT, dt);
    if (impl_->moveRight)    impl_->camera.ProcessKeyboard(RIGHT, dt);
    if (impl_->moveUp)       impl_->camera.ProcessKeyboard(UPWARD, dt);
    if (impl_->moveDown)     impl_->camera.ProcessKeyboard(DOWN, dt);

    if (impl_->animator && impl_->gEnableAnimation && !impl_->gAnimPaused) {
        impl_->animator->updateAnimation(dt);
    }
    if (impl_->animator && impl_->gEnableAnimation && !impl_->gAnimPaused && impl_->animator->isFinished()) {
        if (impl_->gStandAnimIndex != -1 && impl_->gActionAnimIndex == impl_->gStandAnimIndex) {
            Animation* idle = impl_->ourModel->getAnimation(impl_->gIdleAnimIndex);
            if (idle) {
                impl_->animator->setLooping(true);
                impl_->animator->playAnimation(idle, true);
                impl_->gSelectedAnimIndex = impl_->gIdleAnimIndex;
                impl_->gActionAnimIndex = -1;
            }
        }
    }
}

void SCRendererData::render() {
    if (!impl_ || !impl_->ourShader || !impl_->lightCubeShader || !impl_->ourModel) return;

    glClearColor(0.1f, 0.1f, 0.1f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    glm::vec3 lempColor(1.f, 1.0f, 1.0f);
    static const glm::vec3 colors[] = {
        {1.0f, 0.0f, 0.0f}, {0.0f, 1.0f, 0.0f}, {0.0f, 0.0f, 1.0f},
        {1.0f, 1.0f, 0.0f}, {1.0f, 0.0f, 1.0f}, {0.0f, 1.0f, 1.0f},
    };
    int idx = (int)(impl_->elapsedTime * 2.0f) % 6;
    lempColor = colors[idx];

    float aspect = (float)impl_->screenWidth / (float)impl_->screenHeight;
    glm::mat4 projection = glm::perspective(glm::radians(impl_->camera.Zoom), aspect, 0.1f, 100.0f);
    glm::mat4 view = impl_->camera.GetViewMatrix();

    impl_->ourShader->use();
    impl_->ourShader->setMat4("projection", projection);
    impl_->ourShader->setMat4("view", view);

    impl_->lightCubeShader->use();
    impl_->lightCubeShader->setVec3("lampColor", lempColor);
    impl_->lightCubeShader->setMat4("projection", projection);
    impl_->lightCubeShader->setMat4("view", view);
    glBindVertexArray(impl_->lightCubeVAO);
    impl_->lightPos = glm::vec3(-0.4, 0.8, 0);
    glm::mat4 light_model = glm::mat4(1.0f);
    light_model = glm::translate(light_model, impl_->lightPos);
    light_model = glm::scale(light_model, glm::vec3(0.05f));
    impl_->lightCubeShader->setMat4("model", light_model);
    glDrawArrays(GL_TRIANGLES, 0, 36);

    // 与 main.cpp 相同的模型绘制 / 蒙皮上传
    impl_->ourShader->use();
    impl_->ourShader->setMat4("projection", projection);
    impl_->ourShader->setMat4("view", view);
    impl_->ourShader->setVec3("viewPos", impl_->camera.Position);
    impl_->ourShader->setFloat("material.shininess", 32.0f);

    if (impl_->animator && impl_->ourModel->getAnimation()) {
        const int MAX_BONES = 100;
        glm::mat4 identity(1.0f);
        for (int i = 0; i < MAX_BONES; ++i) {
            string uniformName = "finalBonesMatrices[" + to_string(i) + "]";
            impl_->ourShader->setMat4(uniformName.c_str(), identity);
        }
        auto& finalBoneMatrices = impl_->animator->getFinalBoneMatrices();
        for (auto& entry : finalBoneMatrices) {
            string uniformName = "finalBonesMatrices[" + to_string(entry.first) + "]";
            impl_->ourShader->setMat4(uniformName.c_str(), entry.second);
        }
    }

    impl_->ourShader->setVec3("dirLight.direction", -0.2f, -1.0f, -0.3f);
    impl_->ourShader->setVec3("dirLight.ambient", 1.0f, 1.0f, 1.0f);
    impl_->ourShader->setVec3("dirLight.diffuse", 0.9f, 0.9f, 0.9f);
    impl_->ourShader->setVec3("dirLight.specular", 0.5f, 0.5f, 0.5f);

    // OpenGL ES：未初始化的 pointLights[0..2] 会导致 NaN 发黑，显式清零
    for (int i = 0; i < 3; ++i) {
        std::string base = "pointLights[" + std::to_string(i) + "]";
        impl_->ourShader->setVec3((base + ".position").c_str(), 0.0f, 0.0f, 0.0f);
        impl_->ourShader->setVec3((base + ".ambient").c_str(), 0.0f, 0.0f, 0.0f);
        impl_->ourShader->setVec3((base + ".diffuse").c_str(), 0.0f, 0.0f, 0.0f);
        impl_->ourShader->setVec3((base + ".specular").c_str(), 0.0f, 0.0f, 0.0f);
        impl_->ourShader->setFloat((base + ".constant").c_str(), 1.0f);
        impl_->ourShader->setFloat((base + ".linear").c_str(), 0.0f);
        impl_->ourShader->setFloat((base + ".quadratic").c_str(), 0.0f);
    }

    glm::vec3 lightColor = lempColor;
    glm::vec3 diffuseColor = lightColor * glm::vec3(0.8f);
    glm::vec3 ambientColor = diffuseColor * glm::vec3(0.05f);
    impl_->ourShader->setVec3("pointLights[3].position", impl_->lightPos);
    impl_->ourShader->setVec3("pointLights[3].ambient", ambientColor);
    impl_->ourShader->setVec3("pointLights[3].diffuse", diffuseColor);
    impl_->ourShader->setVec3("pointLights[3].specular", 1.0f, 1.0f, 1.0f);
    impl_->ourShader->setFloat("pointLights[3].constant", 1.0f);
    impl_->ourShader->setFloat("pointLights[3].linear", 0.09f);
    impl_->ourShader->setFloat("pointLights[3].quadratic", 0.032f);

    impl_->ourShader->setVec3("spotLight.position", impl_->camera.Position);
    impl_->ourShader->setVec3("spotLight.direction", impl_->camera.Front);
    impl_->ourShader->setVec3("spotLight.ambient", 0.0f, 0.0f, 0.0f);
    impl_->ourShader->setVec3("spotLight.diffuse", 1.0f, 1.0f, 1.0f);
    impl_->ourShader->setVec3("spotLight.specular", 1.0f, 1.0f, 1.0f);
    impl_->ourShader->setFloat("spotLight.constant", 1.0f);
    impl_->ourShader->setFloat("spotLight.linear", 0.09f);
    impl_->ourShader->setFloat("spotLight.quadratic", 0.032f);
    impl_->ourShader->setFloat("spotLight.cutOff", glm::cos(glm::radians(12.5f)));
    impl_->ourShader->setFloat("spotLight.outerCutOff", glm::cos(glm::radians(15.0f)));

    glm::mat4 model = glm::mat4(1.0f);
    model = glm::translate(model, glm::vec3(0.0f, -0.7f, 0.0f));
    model = glm::rotate(model, impl_->gModelYaw, glm::vec3(0.0f, 1.0f, 0.0f));
    model = glm::rotate(model, impl_->gModelPitch, glm::vec3(1.0f, 0.0f, 0.0f));
    model = glm::scale(model, glm::vec3(0.018f));
    impl_->ourShader->setMat4("model", model);
    impl_->ourModel->Draw(*impl_->ourShader);
}

void SCRendererData::onTouchBegan(float x, float y) {
    if (!impl_) return;
    impl_->lastX = x; impl_->lastY = y; impl_->firstMouse = false;
}
void SCRendererData::onTouchMoved(float x, float y) {
    if (!impl_) return;
    if (impl_->firstMouse) { impl_->lastX = x; impl_->lastY = y; impl_->firstMouse = false; }
    float xoffset = x - impl_->lastX;
    float yoffset = y - impl_->lastY; // finger down → pitch down
    impl_->lastX = x; impl_->lastY = y;

    // Drag rotates the model only (not camera). Sensitivity in radians / pixel.
    const float sens = 0.005f;
    impl_->gModelYaw   += xoffset * sens;
    impl_->gModelPitch += yoffset * sens;
    const float pitchLimit = glm::radians(80.0f);
    impl_->gModelPitch = std::max(-pitchLimit, std::min(pitchLimit, impl_->gModelPitch));
}
void SCRendererData::onTouchEnded() { if (impl_) impl_->firstMouse = true; }
void SCRendererData::onPinch(float scaleDelta) {
    if (impl_) impl_->camera.ProcessMouseScroll(scaleDelta);
}

void SCRendererData::setMoveForward(bool on)  { if (impl_) impl_->moveForward = on; }
void SCRendererData::setMoveBackward(bool on) { if (impl_) impl_->moveBackward = on; }
void SCRendererData::setMoveLeft(bool on)     { if (impl_) impl_->moveLeft = on; }
void SCRendererData::setMoveRight(bool on)    { if (impl_) impl_->moveRight = on; }
void SCRendererData::setMoveUp(bool on)       { if (impl_) impl_->moveUp = on; }
void SCRendererData::setMoveDown(bool on)     { if (impl_) impl_->moveDown = on; }

void SCRendererData::toggleAnimPause() {
    if (!impl_) return;
    impl_->gAnimPaused = !impl_->gAnimPaused;
    std::cout << "[Toggle] Anim pause: " << (impl_->gAnimPaused ? "ON" : "OFF") << std::endl;
}
void SCRendererData::playWalk()  { if (impl_) impl_->switchAnimByKeywordOrIndex("walk", 2, true); }
void SCRendererData::playRun()   { if (impl_) impl_->switchAnimByKeywordOrIndex("run", 3, true); }
void SCRendererData::playCrawl() {
    if (!impl_) return;
    impl_->switchAnimByKeywordsOrIndex({"crawl", "prone", "creep"}, 4, true);
    impl_->gActionAnimIndex = -1;
}
void SCRendererData::playIdle() {
    if (!impl_) return;
    impl_->switchAnim(impl_->gIdleAnimIndex, true);
    impl_->gActionAnimIndex = -1;
}
void SCRendererData::browsePrevAnim() {
    if (!impl_ || !impl_->gModel) return;
    int count = impl_->gModel->getAnimationCount();
    if (count <= 0) return;
    impl_->gBrowseAnimIndex = (impl_->gBrowseAnimIndex - 1 + count) % count;
    impl_->switchAnim(impl_->gBrowseAnimIndex, true);
    impl_->gActionAnimIndex = -1;
}
void SCRendererData::browseNextAnim() {
    if (!impl_ || !impl_->gModel) return;
    int count = impl_->gModel->getAnimationCount();
    if (count <= 0) return;
    impl_->gBrowseAnimIndex = (impl_->gBrowseAnimIndex + 1) % count;
    impl_->switchAnim(impl_->gBrowseAnimIndex, true);
    impl_->gActionAnimIndex = -1;
}
