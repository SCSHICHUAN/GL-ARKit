//
//  SCRendererData.cpp
//  OpenGL 场景：模型目录、渲染、ARKit Face 驱动、Vision lean（whiteMan）。
//  Face 映射详见仓库 README「ARKit 映射」。
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
#include <cctype>
#include <cmath>
#include <cstring>
#include <dirent.h>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <utility>
#include <vector>

using namespace std;

struct CatalogEntry {
    std::string name;
    std::string relativePath; // under resourceRoot / bundle
    float scale = 1.0f;
    float yOffset = -0.5f;
    float xOffset = 0.0f;
    float defaultYawDeg = 0.0f;   // initial left-right facing
    float defaultPitchDeg = 0.0f; // initial nod（负=后仰，纠正人模前倾）
    float cameraY = 0.35f;        // 切换模型时重置相机
    float cameraZ = 2.8f;         // 越大越远（yaw=-90 时沿 +Z 后退）
};

static std::string toLowerCopy(std::string s) {
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

static bool hasLoadableModelExt(const std::string& nameLower) {
    // .blend intentionally excluded — iOS Assimp almost never loads it (was causing black screen).
    static const char* kExts[] = {
        ".glb", ".gltf", ".fbx", ".obj", ".dae", nullptr
    };
    for (int i = 0; kExts[i]; ++i) {
        const char* e = kExts[i];
        const size_t n = strlen(e);
        if (nameLower.size() >= n &&
            nameLower.compare(nameLower.size() - n, n, e) == 0)
            return true;
    }
    return false;
}

/// Lower is better.
static int modelExtPriority(const std::string& nameLower) {
    if (nameLower.size() >= 4 && nameLower.compare(nameLower.size() - 4, 4, ".glb") == 0) return 0;
    if (nameLower.size() >= 5 && nameLower.compare(nameLower.size() - 5, 5, ".gltf") == 0) return 1;
    if (nameLower.size() >= 4 && nameLower.compare(nameLower.size() - 4, 4, ".fbx") == 0) return 2;
    if (nameLower.size() >= 4 && nameLower.compare(nameLower.size() - 4, 4, ".obj") == 0) return 3;
    if (nameLower.size() >= 4 && nameLower.compare(nameLower.size() - 4, 4, ".dae") == 0) return 4;
    return 100;
}

static std::string prettyModelName(const std::string& folderOrStem) {
    std::string s = folderOrStem;
    // "Wolf-fbx" → "Wolf"
    auto dash = s.find('-');
    if (dash != std::string::npos) s = s.substr(0, dash);
    if (!s.empty()) s[0] = (char)std::toupper((unsigned char)s[0]);
    return s;
}

static bool pathEndsWithExt(const std::string& pathLower, const char* ext) {
    const size_t n = strlen(ext);
    return pathLower.size() >= n && pathLower.compare(pathLower.size() - n, n, ext) == 0;
}

/// 按文件格式设默认摆放（不再按模型名特判；已删模型的名字分支一并去掉）
static void applyFormatLayout(CatalogEntry& e) {
    const std::string path = toLowerCopy(e.relativePath);
    if (pathEndsWithExt(path, ".fbx")) {
        // FBX：常见游戏单位（如 Wolf）— 体型大，相机往后一点才看得全
        e.scale = 0.018f;
        e.yOffset = -0.7f;
        e.xOffset = -0.2f;
        e.defaultYawDeg = 60.0f;
        e.cameraY = 0.0f;
        e.cameraZ = 4.8f;
    } else if (pathEndsWithExt(path, ".glb") || pathEndsWithExt(path, ".gltf")) {
        // glTF：米制人模；扶正后默认正面，略下移/右移进画面中心
        e.scale = 1.0f;
        e.yOffset = -1.0f;
        e.xOffset = 0.041f;
        e.defaultYawDeg = 0.0f;
        // whiteMan / blackMan 扶正后仍略前倾，初始化后仰一点（Wolf 等 FBX 不走这里）
        e.defaultPitchDeg = 10.0f;
        e.cameraY = 0.3f;
        e.cameraZ = 2.5f;
    } else {
        // obj/dae 等
        e.scale = 1.0f;
        e.yOffset = -0.5f;
        e.xOffset = 0.5f;
        e.defaultYawDeg = 180.0f;
        e.cameraY = 0.4f;
        e.cameraZ = 3.2f;
    }
}

static void collectModelFiles(const std::string& absDir,
                              const std::string& relDir,
                              std::vector<std::pair<int, std::string>>& out) {
    DIR* d = opendir(absDir.c_str());
    if (!d) return;
    while (dirent* ent = readdir(d)) {
        const char* n = ent->d_name;
        if (!n || n[0] == '.') continue;
        std::string abs = absDir + "/" + n;
        std::string rel = relDir.empty() ? n : (relDir + "/" + n);
        struct stat st {};
        if (stat(abs.c_str(), &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            collectModelFiles(abs, rel, out);
        } else if (S_ISREG(st.st_mode)) {
            std::string lower = toLowerCopy(n);
            if (hasLoadableModelExt(lower))
                out.push_back({ modelExtPriority(lower), rel });
        }
    }
    closedir(d);
}

/// FBX 优先（当前仅 Wolf），其余按名字
static int catalogSortKey(const CatalogEntry& e) {
    const std::string path = toLowerCopy(e.relativePath);
    if (pathEndsWithExt(path, ".fbx")) return 0;
    if (pathEndsWithExt(path, ".glb") || pathEndsWithExt(path, ".gltf")) return 1;
    return 10;
}

/// Prefer bundle models/ (synced from ARKit/models). Fallback to legacy flat copy paths.
static std::vector<CatalogEntry> scanBundledModels(const std::string& resourceRoot) {
    std::vector<CatalogEntry> catalog;
    const std::string modelsAbs = resourceRoot + "/models";
    struct stat st {};
    if (stat(modelsAbs.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
        DIR* d = opendir(modelsAbs.c_str());
        if (d) {
            std::vector<std::string> entries;
            while (dirent* ent = readdir(d)) {
                const char* n = ent->d_name;
                if (!n || n[0] == '.') continue;
                entries.push_back(n);
            }
            closedir(d);
            std::sort(entries.begin(), entries.end());

            for (const std::string& name : entries) {
                std::string abs = modelsAbs + "/" + name;
                std::string relBase = "models/" + name;
                struct stat est {};
                if (stat(abs.c_str(), &est) != 0) continue;

                CatalogEntry e;
                if (S_ISDIR(est.st_mode)) {
                    std::vector<std::pair<int, std::string>> files;
                    collectModelFiles(abs, relBase, files);
                    if (files.empty()) {
                        printf("[Model] skip folder (no loadable mesh, need .glb/.fbx/…): %s\n",
                               name.c_str());
                        continue;
                    }
                    std::sort(files.begin(), files.end());
                    e.name = prettyModelName(name);
                    e.relativePath = files.front().second;
                } else if (S_ISREG(est.st_mode) && hasLoadableModelExt(toLowerCopy(name))) {
                    e.name = prettyModelName(name.substr(0, name.find_last_of('.')));
                    e.relativePath = relBase;
                } else {
                    continue;
                }
                applyFormatLayout(e);
                printf("[Model] catalog: %s → %s (scale=%.4f y=%.2f x=%.2f yaw=%.0f pitch=%.0f)\n",
                       e.name.c_str(), e.relativePath.c_str(),
                       e.scale, e.yOffset, e.xOffset, e.defaultYawDeg, e.defaultPitchDeg);
                catalog.push_back(std::move(e));
            }
        }
    }

    if (catalog.empty()) {
        printf("[Model] models/ missing or empty — no catalog entries\n");
    }

    std::stable_sort(catalog.begin(), catalog.end(),
                     [](const CatalogEntry& a, const CatalogEntry& b) {
                         const int ka = catalogSortKey(a), kb = catalogSortKey(b);
                         if (ka != kb) return ka < kb;
                         return a.name < b.name;
                     });
    return catalog;
}

struct SCRendererData::Impl {
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
    Shader* yuvQuadShader = nullptr;

    glm::vec3 lightPos = glm::vec3(1.0f, 0.0f, 0.0f);
    unsigned int cubeVAO = 0, lightCubeVAO = 0, VBO = 0;
    unsigned int videoQuadVAO = 0, videoQuadVBO = 0;

    unsigned int hostVideoYTex = 0;
    unsigned int hostVideoUVTex = 0;
    bool hostVideoValid = false;
    bool hostVideoVisible = true;
    int hostVideoOrientation = 6; // CGImagePropertyOrientationRight
    bool hostVideoMirrorX = true;
    // 相对屏幕：左上原点归一化 rect（与 camPreviewView 对齐）
    float hostVideoRectX = 0.02f;
    float hostVideoRectY = 0.75f;
    float hostVideoRectW = 0.15f;
    float hostVideoRectH = 0.18f;
    bool hostVideoRectValid = false;
    float hostVideoRotDeg = 0.0f; // 绕对角线，限制 0~90°

    int screenWidth = 1000;
    int screenHeight = 750;
    bool renderFlipY = false;
    std::string resourceRoot;
    std::vector<CatalogEntry> catalog;

    int currentModelIndex = 0;
    float modelScale = 0.018f;
    float modelYOffset = -0.7f;
    float modelXOffset = 0.0f;
    /// 把文件里的「头→脚」对齐到世界 +Y，并绕该中轴线左右转
    glm::mat4 modelBasis{1.0f};
    glm::vec3 modelAxisPivot{0.0f};
    bool modelHasAxisPivot = false;
    bool faceDriveWarnedNoHead = false;

    bool faceDriveActive = false;
    bool upperBodyDriveActive = false;
    int lastUpperBodyBoneCount = 0;
    /// Vision lean 目标；显示侧 SmoothDamp（仅 whiteMan）
    float leanTarget = 0.0f;
    float leanDisplay = 0.0f;
    float leanVel = 0.0f;
    float leanPublished = 1e9f;
    bool leanBoneCacheValid = false;
    struct SpineLeanBone { std::string name; int tier; }; // 1/2/3
    std::vector<SpineLeanBone> leanSpineBones;
    float arHeadYaw = 0.0f;
    float arHeadPitch = 0.0f;
    float arHeadRoll = 0.0f;
    /// 头姿：目标来自 AR；显示侧 SmoothDamp（blackMan 父子双写头骨时尤易「头卡」）
    float headYawT = 0.0f, headPitchT = 0.0f, headRollT = 0.0f;
    float headYawD = 0.0f, headPitchD = 0.0f, headRollD = 0.0f;
    float headYawV = 0.0f, headPitchV = 0.0f, headRollV = 0.0f;
    std::string cachedHeadBone;
    std::string cachedNeckBone;
    bool headBoneCacheValid = false;
    /// Face / 上体各自维护，publish 时合并进 Animator（头脸不与躯干抢骨）
    std::map<std::string, glm::mat4> faceBoneOverrides;
    std::map<std::string, glm::mat4> upperBodyBoneOverrides;
    /// 节点 bind 局部矩阵缓存（眼球 orbit 用），避免每帧整树遍历
    std::map<std::string, glm::mat4> cachedNodeBind;
    bool cachedNodeBindValid = false;

    void publishBoneOverrides() {
        if (!animator) return;
        std::map<std::string, glm::mat4> merged = faceBoneOverrides;
        for (const auto& kv : upperBodyBoneOverrides) {
            auto it = merged.find(kv.first);
            if (it == merged.end()) merged[kv.first] = kv.second;
            else it->second = it->second * kv.second;
        }
        if (merged.empty()) animator->clearBoneLocalOverrides();
        else animator->setBoneLocalOverrides(merged);
    }

    void ensureLeanBoneCache() {
        if (leanBoneCacheValid || !ourModel) return;
        leanSpineBones.clear();
        // blackMan：不做躯干 lean
        if (ourModel->hasDetailedFaceBones()) {
            leanBoneCacheValid = true;
            lastUpperBodyBoneCount = 0;
            printf("[Lean] skip (blackMan)\n");
            return;
        }
        auto isJunk = [](const std::string& bn) {
            return bn.find("_end") != std::string::npos ||
                   bn.find("twist") != std::string::npos ||
                   bn.find("_ref") != std::string::npos;
        };
        for (const auto& kv : ourModel->getBoneInfoMap()) {
            const std::string bn = toLowerCopy(kv.first);
            if (isJunk(bn)) continue;
            if (bn.size() >= 2 && bn[0] == 'c' && bn[1] == '_') continue;
            if (bn.find("spine") == std::string::npos) continue;
            if (bn.find("shoulder") != std::string::npos) continue;
            // 只打 Spine1 / Spine2（胸腰以上）；不要最下段 Spine（贴髋/裆）
            int tier = 0;
            if (bn.find("spine2") != std::string::npos) tier = 3;
            else if (bn.find("spine1") != std::string::npos) tier = 2;
            else continue;
            leanSpineBones.push_back({kv.first, tier});
        }
        leanBoneCacheValid = true;
        lastUpperBodyBoneCount = (int)leanSpineBones.size();
        // Wolf 等无 Spine1/2：不算 whiteMan，直接禁用
        if (leanSpineBones.empty()) {
            printf("[Lean] skip (no Spine1/Spine2)\n");
            return;
        }
        printf("[Lean] cache bones=%d\n", lastUpperBodyBoneCount);
        for (const auto& b : leanSpineBones)
            printf("[Lean]   tier=%d %s\n", b.tier, b.name.c_str());
    }

    void rebuildUpperBodyFromDisplayLean() {
        upperBodyBoneOverrides.clear();
        if (!upperBodyDriveActive || leanSpineBones.empty()) {
            lastUpperBodyBoneCount = 0;
            return;
        }
        // Spine1 中段 + Spine2 上胸；白模侧倾用局部 Z（此前已验证）
        const float w2 = 0.75f, w3 = 1.20f;
        auto leanMat = [](float lean) {
            return glm::rotate(glm::mat4(1.0f), lean, glm::vec3(0, 0, 1));
        };
        glm::mat4 s2 = leanMat(leanDisplay * w2);
        glm::mat4 s3 = leanMat(leanDisplay * w3);
        for (const auto& b : leanSpineBones) {
            if (b.tier == 3) upperBodyBoneOverrides[b.name] = s3;
            else if (b.tier == 2) upperBodyBoneOverrides[b.name] = s2;
        }
        lastUpperBodyBoneCount = (int)upperBodyBoneOverrides.size();
        leanPublished = leanDisplay;
        publishBoneOverrides();
    }

    void ensureHeadBoneCache() {
        if (headBoneCacheValid || !ourModel) return;
        cachedHeadBone.clear();
        cachedNeckBone.clear();
        std::string headDef, headCtrl, headAny;
        std::string neckDef, neckCtrl, neckAny;
        for (const auto& kv : ourModel->getBoneInfoMap()) {
            const std::string bn = toLowerCopy(kv.first);
            if (bn.find("wolf3d") != std::string::npos) continue;
            if (bn.find("_end") != std::string::npos) continue;
            if (bn.find("head") != std::string::npos && bn.find("neck") == std::string::npos) {
                if (bn.find("head_ref") != std::string::npos || bn.find("head_scale") != std::string::npos)
                    continue;
                if (bn.find("c_head.x") != std::string::npos) headCtrl = kv.first;
                else if (bn.find("head.x") != std::string::npos) headDef = kv.first;
                else if (bn.find("ref") == std::string::npos && bn.find("scale") == std::string::npos) {
                    if (headAny.empty()) headAny = kv.first;
                }
            }
            if (bn.find("neck") != std::string::npos) {
                if (bn.find("neck_ref") != std::string::npos || bn.find("neck_twist") != std::string::npos)
                    continue;
                if (bn.find("c_p_neck") != std::string::npos) continue;
                if (bn.find("c_neck.x") != std::string::npos) neckCtrl = kv.first;
                else if (bn.find("neck.x") != std::string::npos) neckDef = kv.first;
                else if (bn.rfind("neck_", 0) == 0 || bn.find("neck") != std::string::npos) {
                    if (neckAny.empty()) neckAny = kv.first;
                }
            }
        }
        // ARP：只打一根变形骨，避免 c_head + head 父子同增量叠两层 → 头一卡一卡
        cachedHeadBone = !headDef.empty() ? headDef : (!headCtrl.empty() ? headCtrl : headAny);
        cachedNeckBone = !neckDef.empty() ? neckDef : (!neckCtrl.empty() ? neckCtrl : neckAny);
        headBoneCacheValid = true;
        printf("[FaceDrive] headBone=%s neckBone=%s\n",
               cachedHeadBone.empty() ? "(none)" : cachedHeadBone.c_str(),
               cachedNeckBone.empty() ? "(none)" : cachedNeckBone.c_str());
    }

    static float smoothDamp1(float current, float target, float& vel, float smoothTime, float dt) {
        smoothTime = fmaxf(smoothTime, 1e-4f);
        float omega = 2.0f / smoothTime;
        float x = omega * fmaxf(dt, 0.0f);
        float exp = 1.0f / (1.0f + x + 0.48f * x * x + 0.235f * x * x * x);
        float change = current - target;
        float temp = (vel + omega * change) * fmaxf(dt, 0.0f);
        vel = (vel - omega * temp) * exp;
        return target + (change + temp) * exp;
    }

    void writeHeadOverrides(std::map<std::string, glm::mat4>& out, float yaw, float pitch, float roll) {
        ensureHeadBoneCache();
        glm::mat4 headM(1.0f);
        headM = glm::rotate(headM, pitch, glm::vec3(1, 0, 0));
        headM = glm::rotate(headM, yaw, glm::vec3(0, 1, 0));
        headM = glm::rotate(headM, roll, glm::vec3(0, 0, 1));
        glm::mat4 neckM(1.0f);
        neckM = glm::rotate(neckM, pitch * 0.28f, glm::vec3(1, 0, 0));
        neckM = glm::rotate(neckM, yaw * 0.28f, glm::vec3(0, 1, 0));
        neckM = glm::rotate(neckM, roll * 0.20f, glm::vec3(0, 0, 1));
        if (!cachedHeadBone.empty()) out[cachedHeadBone] = headM;
        if (!cachedNeckBone.empty()) out[cachedNeckBone] = neckM;
    }

    void clearDriveOverrides() {
        faceDriveActive = false;
        upperBodyDriveActive = false;
        leanTarget = leanDisplay = 0.0f;
        leanVel = 0.0f;
        leanPublished = 1e9f;
        faceBoneOverrides.clear();
        upperBodyBoneOverrides.clear();
        arHeadYaw = arHeadPitch = arHeadRoll = 0.0f;
        headYawT = headPitchT = headRollT = 0.0f;
        headYawD = headPitchD = headRollD = 0.0f;
        headYawV = headPitchV = headRollV = 0.0f;
        if (ourModel) ourModel->clearMorphWeights();
        if (animator) animator->clearBoneLocalOverrides();
    }

    bool moveForward = false, moveBackward = false, moveLeft = false;
    bool moveRight = false, moveUp = false, moveDown = false;

    Impl()
        : camera(glm::vec3(0.0f, 1.6f, 2.8f), glm::vec3(0.0f, 1.0f, 0.0f), -88.0f, -30.0f)
    {}

    void destroyCurrentModel() {
        delete animator;
        animator = nullptr;
        gAnimator = nullptr;
        if (ourModel) {
            for (Animation* a : ourModel->animations) delete a;
            ourModel->animations.clear();
            ourModel->animation = nullptr;
            delete ourModel;
            ourModel = nullptr;
        }
        gModel = nullptr;
        gSelectedAnimIndex = -1;
        gIdleAnimIndex = 0;
        gActionAnimIndex = -1;
        gStandAnimIndex = -1;
        gSitAnimIndex = -1;
        gExtraAnimKeySlots.clear();
        gBrowseAnimIndex = 0;
        faceDriveWarnedNoHead = false;
        faceDriveActive = false;
        upperBodyDriveActive = false;
        leanTarget = leanDisplay = 0.0f;
        leanVel = 0.0f;
        leanPublished = 1e9f;
        leanBoneCacheValid = false;
        leanSpineBones.clear();
        headBoneCacheValid = false;
        cachedHeadBone.clear();
        cachedNeckBone.clear();
        headYawT = headPitchT = headRollT = 0.0f;
        headYawD = headPitchD = headRollD = 0.0f;
        headYawV = headPitchV = headRollV = 0.0f;
        faceBoneOverrides.clear();
        upperBodyBoneOverrides.clear();
        cachedNodeBind.clear();
        cachedNodeBindValid = false;
        modelHasAxisPivot = false;
        modelAxisPivot = glm::vec3(0.0f);
        modelBasis = glm::mat4(1.0f);
    }

    ~Impl() {
        destroyCurrentModel();
        delete ourShader;
        delete lightCubeShader;
        delete yuvQuadShader;
        if (cubeVAO) glDeleteVertexArrays(1, &cubeVAO);
        if (lightCubeVAO) glDeleteVertexArrays(1, &lightCubeVAO);
        if (VBO) glDeleteBuffers(1, &VBO);
        if (videoQuadVAO) glDeleteVertexArrays(1, &videoQuadVAO);
        if (videoQuadVBO) glDeleteBuffers(1, &videoQuadVBO);
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

        // 单位矩形：中心原点，朝 +Z，UV 左下→右上
        float quad[] = {
            // pos              uv
            -0.5f, -0.5f, 0.0f,  0.0f, 0.0f,
             0.5f, -0.5f, 0.0f,  1.0f, 0.0f,
             0.5f,  0.5f, 0.0f,  1.0f, 1.0f,
            -0.5f, -0.5f, 0.0f,  0.0f, 0.0f,
             0.5f,  0.5f, 0.0f,  1.0f, 1.0f,
            -0.5f,  0.5f, 0.0f,  0.0f, 1.0f,
        };
        glGenVertexArrays(1, &videoQuadVAO);
        glGenBuffers(1, &videoQuadVBO);
        glBindVertexArray(videoQuadVAO);
        glBindBuffer(GL_ARRAY_BUFFER, videoQuadVBO);
        glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 5 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 5 * sizeof(float), (void*)(3 * sizeof(float)));
        glEnableVertexAttribArray(1);
        glBindVertexArray(0);
    }

    void drawHostVideoQuad(const glm::mat4& /*projection*/, const glm::mat4& /*view*/) {
        if (!hostVideoVisible || !hostVideoValid || !yuvQuadShader || !videoQuadVAO) return;
        if (!hostVideoYTex || !hostVideoUVTex || !hostVideoRectValid) return;

        // 屏幕空间 NDC（与前置预览小窗同位置同大小）；不受场景相机影响
        float L = hostVideoRectX;
        float T = hostVideoRectY;
        float W = hostVideoRectW;
        float H = hostVideoRectH;
        if (W <= 1e-4f || H <= 1e-4f) return;

        float ndcL = L * 2.0f - 1.0f;
        float ndcR = (L + W) * 2.0f - 1.0f;
        float ndcT = 1.0f - T * 2.0f;
        float ndcB = 1.0f - (T + H) * 2.0f;
        // 编码 FBO：3D 已 FlipY，屏幕空间小窗要镜像 Y，才能仍在观看端下方
        if (renderFlipY) {
            float nt = -ndcB;
            float nb = -ndcT;
            ndcT = nt;
            ndcB = nb;
        }
        float cx = 0.5f * (ndcL + ndcR);
        float cy = 0.5f * (ndcB + ndcT);
        float sx = (ndcR - ndcL);
        float sy = (ndcT - ndcB);

        // 绕视频面可视对角线（左下→右上）旋转，限制 0~90°
        float ang = glm::radians(hostVideoRotDeg);
        glm::vec3 diag = glm::normalize(glm::vec3(sx, sy, 0.0f));
        glm::mat4 ident(1.0f);
        glm::mat4 model(1.0f);
        model = glm::translate(model, glm::vec3(cx, cy, 0.0f));
        model = glm::rotate(model, ang, diag);
        model = glm::scale(model, glm::vec3(sx, sy, 1.0f));

        GLboolean depthWas = glIsEnabled(GL_DEPTH_TEST);
        glDisable(GL_DEPTH_TEST);

        yuvQuadShader->use();
        yuvQuadShader->setMat4("projection", ident);
        yuvQuadShader->setMat4("view", ident);
        yuvQuadShader->setMat4("model", model);
        yuvQuadShader->setInt("yTex", 0);
        yuvQuadShader->setInt("uvTex", 1);
        yuvQuadShader->setInt("orientation", hostVideoOrientation);
        yuvQuadShader->setBool("mirrorX", hostVideoMirrorX);
        // 显示端 upright；编码 FlipY 后小窗内容要再竖翻一次，观看端才正
        yuvQuadShader->setBool("flipTexY", renderFlipY);

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, hostVideoYTex);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, hostVideoUVTex);

        glBindVertexArray(videoQuadVAO);
        glDrawArrays(GL_TRIANGLES, 0, 6);
        glBindVertexArray(0);
        glActiveTexture(GL_TEXTURE0);

        if (depthWas) glEnable(GL_DEPTH_TEST);
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
        // 手动切动画时退出 Face / 上体驱动，恢复播放
        faceDriveActive = false;
        upperBodyDriveActive = false;
        leanTarget = leanDisplay = 0.0f;
        leanVel = 0.0f;
        leanPublished = 1e9f;
        faceBoneOverrides.clear();
        upperBodyBoneOverrides.clear();
        gAnimPaused = false;
        gAnimator->clearBoneLocalOverrides();
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
    impl_->catalog = scanBundledModels(resourceRoot);

    impl_->createVBOVAO();

    std::string lampVs = resourceRoot + "/shaders/lamp-vs.vs";
    std::string lampFs = resourceRoot + "/shaders/lamp-fs.fs";
    std::string colorVs = resourceRoot + "/shaders/colors-vs.vs";
    std::string colorFs = resourceRoot + "/shaders/colors-fs.fs";

    impl_->lightCubeShader = new Shader(lampVs.c_str(), lampFs.c_str());
    impl_->ourShader = new Shader(colorVs.c_str(), colorFs.c_str());
    {
        std::string yuvVs = resourceRoot + "/shaders/yuv-quad-vs.vs";
        std::string yuvFs = resourceRoot + "/shaders/yuv-quad-fs.fs";
        impl_->yuvQuadShader = new Shader(yuvVs.c_str(), yuvFs.c_str());
    }

    bool loaded = false;
    for (int i = 0; i < (int)impl_->catalog.size(); ++i) {
        if (loadModelAtIndex(i)) {
            loaded = true;
            break;
        }
        printf("[Model] skip unloadable #%d %s\n", i, impl_->catalog[(size_t)i].name.c_str());
    }
    if (!loaded) {
        printf("SCRendererData: no model could be loaded\n");
        return false;
    }

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

void SCRendererData::setRenderFlipY(bool flipY) {
    if (impl_) impl_->renderFlipY = flipY;
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

    // 头姿 SmoothDamp（blackMan 重 apply 被合并时，靠显示帧补中间值）
    if (impl_->faceDriveActive && impl_->animator) {
        const float st = 0.09f;
        float ny = SCRendererData::Impl::smoothDamp1(impl_->headYawD, impl_->headYawT, impl_->headYawV, st, dt);
        float np = SCRendererData::Impl::smoothDamp1(impl_->headPitchD, impl_->headPitchT, impl_->headPitchV, st, dt);
        float nr = SCRendererData::Impl::smoothDamp1(impl_->headRollD, impl_->headRollT, impl_->headRollV, st, dt);
        if (fabsf(ny - impl_->headYawD) > 1e-5f || fabsf(np - impl_->headPitchD) > 1e-5f ||
            fabsf(nr - impl_->headRollD) > 1e-5f) {
            impl_->headYawD = ny;
            impl_->headPitchD = np;
            impl_->headRollD = nr;
            impl_->writeHeadOverrides(impl_->faceBoneOverrides, ny, np, nr);
            impl_->publishBoneOverrides();
        }
    }

    // 上体 lean：仅 SmoothDamp 追目标（不做速度外推，避免一卡一冲）
    if (impl_->upperBodyDriveActive && impl_->animator) {
        const float smoothTime = 0.14f;
        float omega = 2.0f / fmaxf(smoothTime, 1e-4f);
        float x = omega * fmaxf(dt, 0.0f);
        float exp = 1.0f / (1.0f + x + 0.48f * x * x + 0.235f * x * x * x);
        float change = impl_->leanDisplay - impl_->leanTarget;
        float temp = (impl_->leanVel + omega * change) * fmaxf(dt, 0.0f);
        impl_->leanVel = (impl_->leanVel - omega * temp) * exp;
        impl_->leanDisplay = impl_->leanTarget + (change + temp) * exp;

        const float kMax = 40.0f * 0.01745329252f; // ±40°
        if (impl_->leanDisplay > kMax) impl_->leanDisplay = kMax;
        if (impl_->leanDisplay < -kMax) impl_->leanDisplay = -kMax;

        if (fabsf(impl_->leanDisplay - impl_->leanPublished) > 0.00015f)
            impl_->rebuildUpperBodyFromDisplayLean();
    }

    if (impl_->animator) {
        const float step = (impl_->gEnableAnimation && !impl_->gAnimPaused) ? dt : 0.0f;
        impl_->animator->updateAnimation(step);
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
    if (impl_->renderFlipY) {
        // FBO/CVPixelBuffer 顶原点；翻转后正面需改绕序
        projection = glm::scale(glm::mat4(1.0f), glm::vec3(1.0f, -1.0f, 1.0f)) * projection;
        glFrontFace(GL_CW);
    } else {
        glFrontFace(GL_CCW);
    }
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

    impl_->ourShader->use();
    impl_->ourShader->setMat4("projection", projection);
    impl_->ourShader->setMat4("view", view);
    impl_->ourShader->setVec3("viewPos", impl_->camera.Position);
    impl_->ourShader->setFloat("material.shininess", 32.0f);

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
    // T * R(user) * S * Basis(扶正) * T(-pivot)：左右滑绕头→脚中轴线（世界 Y）
    model = glm::translate(model, glm::vec3(impl_->modelXOffset, impl_->modelYOffset, 0.0f));
    model = glm::rotate(model, impl_->gModelPitch, glm::vec3(1.0f, 0.0f, 0.0f));
    model = glm::rotate(model, impl_->gModelYaw, glm::vec3(0.0f, 1.0f, 0.0f));
    model = glm::scale(model, glm::vec3(impl_->modelScale));
    model = model * impl_->modelBasis;
    if (impl_->modelHasAxisPivot) {
        model = glm::translate(model, -impl_->modelAxisPivot);
    }
    impl_->ourShader->setMat4("model", model);
    // 每 mesh 按骨骼调色板上传（blackMan 等大骨架：每 mesh ≤64，全局 100 槽）
    if (impl_->animator && impl_->ourModel->getAnimation()) {
        auto& finalBoneMatrices = impl_->animator->getFinalBoneMatrices();
        impl_->ourModel->Draw(*impl_->ourShader, &finalBoneMatrices);
    } else {
        impl_->ourModel->Draw(*impl_->ourShader, nullptr);
    }

    // 主播摄像头 YUV 长方形（世界空间，进 Avatar 推流）
    impl_->drawHostVideoQuad(projection, view);
}

void SCRendererData::setHostVideoTextures(unsigned int yTex, unsigned int uvTex, bool valid) {
    if (!impl_) return;
    impl_->hostVideoYTex = yTex;
    impl_->hostVideoUVTex = uvTex;
    impl_->hostVideoValid = valid;
}

void SCRendererData::setHostVideoOrientation(int cgImageOrientation) {
    if (!impl_) return;
    impl_->hostVideoOrientation = cgImageOrientation;
}

void SCRendererData::setHostVideoMirrorX(bool mirror) {
    if (!impl_) return;
    impl_->hostVideoMirrorX = mirror;
}

void SCRendererData::setHostVideoVisible(bool visible) {
    if (!impl_) return;
    impl_->hostVideoVisible = visible;
}

void SCRendererData::setHostVideoScreenRectNorm(float x, float y, float w, float h) {
    if (!impl_) return;
    impl_->hostVideoRectX = x;
    impl_->hostVideoRectY = y;
    impl_->hostVideoRectW = w;
    impl_->hostVideoRectH = h;
    impl_->hostVideoRectValid = (w > 1e-4f && h > 1e-4f);
}

void SCRendererData::setHostVideoRotationDegrees(float degrees) {
    if (!impl_) return;
    if (degrees < 0.f) degrees = 0.f;
    if (degrees > 90.f) degrees = 90.f;
    impl_->hostVideoRotDeg = degrees;
}

void SCRendererData::onTouchBegan(float x, float y) {
    if (!impl_) return;
    impl_->lastX = x; impl_->lastY = y; impl_->firstMouse = false;
}
void SCRendererData::onTouchMoved(float x, float y) {
    if (!impl_) return;
    if (impl_->firstMouse) { impl_->lastX = x; impl_->lastY = y; impl_->firstMouse = false; }
    float xoffset = x - impl_->lastX;
    // Screen Y grows downward; finger-up should pitch the head forward/down visually.
    float yoffset = y - impl_->lastY;
    impl_->lastX = x; impl_->lastY = y;

    const float sens = 0.008f;
    impl_->gModelYaw   += xoffset * sens;
    impl_->gModelPitch += yoffset * sens;
    const float pitchLimit = glm::radians(89.0f);
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

int SCRendererData::animationCount() const {
    if (!impl_ || !impl_->gModel) return 0;
    return impl_->gModel->getAnimationCount();
}

std::string SCRendererData::animationNameAt(int index) const {
    if (!impl_ || !impl_->gModel) return {};
    Animation* a = impl_->gModel->getAnimation(index);
    return a ? a->getSourceName() : std::string();
}

void SCRendererData::playAnimationAtIndex(int index) {
    if (!impl_) return;
    impl_->switchAnim(index, true);
    impl_->gBrowseAnimIndex = index;
    impl_->gActionAnimIndex = -1;
}

int SCRendererData::modelCount() const {
    return impl_ ? (int)impl_->catalog.size() : 0;
}

std::string SCRendererData::modelNameAt(int index) const {
    if (!impl_ || index < 0 || index >= (int)impl_->catalog.size()) return {};
    return impl_->catalog[(size_t)index].name;
}

int SCRendererData::currentModelIndex() const {
    return impl_ ? impl_->currentModelIndex : 0;
}

bool SCRendererData::loadModelAtIndex(int index) {
    if (!impl_ || index < 0 || index >= (int)impl_->catalog.size()) return false;

    const CatalogEntry& entry = impl_->catalog[(size_t)index];
    std::string path = impl_->resourceRoot + "/" + entry.relativePath;
    printf("[Model] loading %s → %s\n", entry.name.c_str(), path.c_str());

    Model* next = new Model(path);
    if (next->getMeshCount() <= 0) {
        printf("[Model] load failed (0 meshes): %s\n", path.c_str());
        delete next;
        return false;
    }

    impl_->destroyCurrentModel();
    impl_->ourModel = next;
    impl_->gModel = next;
    impl_->currentModelIndex = index;
    impl_->modelScale = entry.scale;
    impl_->modelYOffset = entry.yOffset;
    impl_->modelXOffset = entry.xOffset;
    impl_->modelHasAxisPivot = false;
    impl_->modelAxisPivot = glm::vec3(0.0f);
    impl_->modelBasis = glm::mat4(1.0f);
    impl_->gModelYaw = glm::radians(entry.defaultYawDeg);
    impl_->gModelPitch = glm::radians(entry.defaultPitchDeg);
    // 按模型重置机位（狼更远，避免看不全）
    impl_->camera.Position = glm::vec3(0.0f, entry.cameraY, entry.cameraZ);
    impl_->camera.Yaw = -90.0f;
    impl_->camera.Pitch = 0.0f;
    impl_->camera.ProcessMouseMovement(0.0f, 0.0f);
    impl_->gAnimPaused = false;
    impl_->faceDriveWarnedNoHead = false;
    impl_->cachedNodeBind.clear();
    impl_->cachedNodeBindValid = false;
    clearFaceDrive();

    printf("Model loaded: %s meshes=%d bones=%d anims=%d morphMax=%d faceBones=%d scale=%.4f yOff=%.3f\n",
           entry.name.c_str(), next->getMeshCount(), next->getBoneCount(), next->getAnimationCount(),
           next->morphTargetCount(), (int)next->hasDetailedFaceBones(),
           impl_->modelScale, impl_->modelYOffset);
    if (next->morphTargetCount() == 44) {
        printf("[Model] whiteMan-style morphs: Unity ARKit order (no Look); blink@8/9 jawOpen@16\n");
    } else if (next->hasDetailedFaceBones()) {
        printf("[Model] blackMan-style: eyelid/jaw bones + Apple-order morphs\n");
    }

    if (next->getAnimation()) {
        impl_->animator = new Animator(next->getAnimation());
        impl_->gIdleAnimIndex = next->getAnimation()->getAnimationIndex();
        impl_->gSelectedAnimIndex = impl_->gIdleAnimIndex;
        impl_->animator->updateAnimation(0.0f);
    }
    impl_->gAnimator = impl_->animator;
    impl_->buildAnimKeyMap();

    // 扶正：最长边视为头→脚，转到世界 +Y；再把中轴线移到 Y 轴，左右滑才是原地转
    {
        const std::map<int, glm::mat4>* bones = nullptr;
        if (impl_->animator) bones = &impl_->animator->getFinalBoneMatrices();

        auto accumulate = [&](const std::map<int, glm::mat4>* boneMats,
                              glm::vec3& outMin, glm::vec3& outMax) -> bool {
            bool any = false;
            for (const Mesh& mesh : next->meshes) {
                const bool doSkin = boneMats && !mesh.bonePalette.empty();
                for (const Vertex& v : mesh.vertices) {
                    glm::vec3 p = v.Position;
                    if (doSkin) {
                        glm::vec4 acc(0.0f);
                        bool has = false;
                        for (int i = 0; i < MAX_BONE_INFLUENCE; ++i) {
                            const int local = (int)v.m_BoneIDs[i];
                            if (local < 0 || local >= (int)mesh.bonePalette.size()) continue;
                            const int gid = mesh.bonePalette[local];
                            auto it = boneMats->find(gid);
                            const glm::mat4& m = (it != boneMats->end()) ? it->second : glm::mat4(1.0f);
                            acc += (m * glm::vec4(v.Position, 1.0f)) * v.m_Weights[i];
                            has = true;
                        }
                        if (has) p = glm::vec3(acc);
                    }
                    if (!any) { outMin = outMax = p; any = true; }
                    else {
                        outMin = glm::min(outMin, p);
                        outMax = glm::max(outMax, p);
                    }
                }
            }
            return any;
        };

        glm::vec3 bmin, bmax;
        bool ok = accumulate(bones, bmin, bmax);
        if (bones) {
            glm::vec3 bindMin, bindMax;
            if (accumulate(nullptr, bindMin, bindMax)) {
                const float hBind = std::max(bindMax.y - bindMin.y, 1e-4f);
                const float hSkin = ok ? (bmax.y - bmin.y) : 0.0f;
                if (!ok || !std::isfinite(hSkin) || hSkin < hBind * 0.01f || hSkin > hBind * 100.0f) {
                    bmin = bindMin;
                    bmax = bindMax;
                    ok = true;
                }
            }
        }
        if (ok) {
            const glm::vec3 c = 0.5f * (bmin + bmax);
            const glm::vec3 ext = bmax - bmin;
            int up = 1; // 0=X 1=Y 2=Z
            if (ext.z >= ext.x && ext.z >= ext.y) up = 2;
            else if (ext.x >= ext.y && ext.x >= ext.z) up = 0;

            glm::mat4 basis(1.0f);
            glm::vec3 pivot(0.0f);
            if (up == 1) {
                // 已是 Y 朝上：只消 XZ，绕头脚中线转
                pivot = glm::vec3(c.x, 0.0f, c.z);
            } else if (up == 2) {
                // Z 为身高（WhiteMan 常见）：转到 +Y，脚靠近 0 的一端朝下
                const bool feetAtMaxZ = std::fabs(bmax.z) <= std::fabs(bmin.z);
                if (feetAtMaxZ) {
                    // Rx(+90): (x,y,z)->(x,-z,y)，z≈0 → y≈0
                    basis = glm::rotate(glm::mat4(1.0f), glm::radians(90.0f), glm::vec3(1, 0, 0));
                } else {
                    // Rx(-90): (x,y,z)->(x,z,-y)
                    basis = glm::rotate(glm::mat4(1.0f), glm::radians(-90.0f), glm::vec3(1, 0, 0));
                }
                pivot = glm::vec3(c.x, c.y, 0.0f);
            } else {
                // X 为身高：转到 +Y
                const bool feetAtMaxX = std::fabs(bmax.x) <= std::fabs(bmin.x);
                if (feetAtMaxX) {
                    // Rz(-90): (x,y,z)->(y,-x,z)，x≈0 → 需另一端…
                    // Rz(+90): (x,y,z)->(-y,x,z) 使 x→y
                    basis = glm::rotate(glm::mat4(1.0f), glm::radians(90.0f), glm::vec3(0, 0, 1));
                } else {
                    basis = glm::rotate(glm::mat4(1.0f), glm::radians(-90.0f), glm::vec3(0, 0, 1));
                }
                pivot = glm::vec3(0.0f, c.y, c.z);
            }

            impl_->modelBasis = basis;
            impl_->modelAxisPivot = pivot;
            impl_->modelHasAxisPivot = true;
            printf("[Model] upright upAxis=%c pivot=(%.3f,%.3f,%.3f) ext=(%.3f,%.3f,%.3f)\n",
                   up == 0 ? 'X' : (up == 1 ? 'Y' : 'Z'),
                   pivot.x, pivot.y, pivot.z, ext.x, ext.y, ext.z);
        }
    }

    return true;
}

static std::string lowerCopy(std::string s) {
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

static float weightOr(const std::map<std::string, float>& m, const char* key) {
    auto it = m.find(key);
    return it == m.end() ? 0.0f : it->second;
}

static void addBoneOverrideContaining(std::map<std::string, glm::mat4>& out,
                                      const std::map<std::string, BoneInfo>& bones,
                                      const std::string& needle,
                                      const glm::mat4& xform,
                                      const char* exclude = nullptr) {
    const std::string n = lowerCopy(needle);
    std::string ex = exclude ? lowerCopy(exclude) : "";
    for (const auto& kv : bones) {
        std::string bn = lowerCopy(kv.first);
        if (bn.find(n) == std::string::npos) continue;
        if (!ex.empty() && bn.find(ex) != std::string::npos) continue;
        auto it = out.find(kv.first);
        if (it == out.end()) out[kv.first] = xform;
        else it->second = it->second * xform;
    }
}

/// 只写脸部变形骨：跳过 eye/lid，以及 ref/retain/offset/end，避免叠两层或碰到现有眼驱动
static void addFaceBoneOverride(std::map<std::string, glm::mat4>& out,
                                const std::map<std::string, BoneInfo>& bones,
                                const std::string& needle,
                                const glm::mat4& xform) {
    const std::string n = lowerCopy(needle);
    for (const auto& kv : bones) {
        std::string bn = lowerCopy(kv.first);
        if (bn.find(n) == std::string::npos) continue;
        if (bn.find("eyelid") != std::string::npos) continue;
        // 跳过眼球相关，但保留 eyebrow
        if (bn.find("eye") != std::string::npos && bn.find("brow") == std::string::npos) continue;
        if (bn.find("_end") != std::string::npos) continue;
        if (bn.find("_ref") != std::string::npos) continue;
        if (bn.find("retain") != std::string::npos) continue;
        if (bn.find("offset") != std::string::npos) continue;
        auto it = out.find(kv.first);
        if (it == out.end()) out[kv.first] = xform;
        else it->second = it->second * xform;
    }
}

/// ARKit → 角色：头(单骨) + 眼(注视/眨眼) + 颌骨 + morph(眉嘴颊舌等)。分支见 hasDetailedFaceBones()。
void SCRendererData::applyFaceDrive(float headYawRad, float headPitchRad, float headRollRad,
                                    float eyePitchL, float eyeYawL, float eyePitchR, float eyeYawR,
                                    const std::map<std::string, float>& eyeWeights,
                                    const std::map<std::string, float>& faceWeights) {
    if (!impl_ || !impl_->ourModel) return;
    impl_->arHeadYaw = headYawRad;
    impl_->arHeadPitch = headPitchRad;
    impl_->arHeadRoll = headRollRad;

    if (!impl_->animator) return;

    const auto& bones = impl_->ourModel->getBoneInfoMap();
    std::map<std::string, glm::mat4> overrides;

    // 头：目标更新；override 用平滑显示值（只写一根 head / neck）
    impl_->headYawT = headYawRad;
    impl_->headPitchT = headPitchRad;
    impl_->headRollT = headRollRad;
    impl_->writeHeadOverrides(overrides, impl_->headYawD, impl_->headPitchD, impl_->headRollD);
    if (impl_->cachedHeadBone.empty() && !impl_->faceDriveWarnedNoHead) {
        impl_->faceDriveWarnedNoHead = true;
        printf("[FaceDrive] warning: no head bone found; head pose ignored (not applied to whole body)\n");
    }

    // —— 脸部：张嘴仍用骨；笑/眉/颊等走 morph（避免几十次全骨表扫描卡顿）——
    const bool useFaceBones = impl_->ourModel->hasDetailedFaceBones();
    if (useFaceBones) {
        const float jaw = weightOr(faceWeights, "jawOpen");
        const float jawL = weightOr(faceWeights, "jawLeft");
        const float jawR = weightOr(faceWeights, "jawRight");
        const float mouthClose = weightOr(faceWeights, "mouthClose");
        float jawAmt = fmaxf(0.f, jaw - mouthClose * 0.35f);
        if (jawAmt > 0.001f) {
            glm::mat4 m = glm::rotate(glm::mat4(1.0f), jawAmt * 0.55f, glm::vec3(1, 0, 0));
            addFaceBoneOverride(overrides, bones, "c_jawbone", m);
            addFaceBoneOverride(overrides, bones, "jawbone.x", m);
        }
        if (jawL > 0.001f || jawR > 0.001f) {
            glm::mat4 m = glm::rotate(glm::mat4(1.0f), (jawL - jawR) * 0.25f, glm::vec3(0, 1, 0));
            addFaceBoneOverride(overrides, bones, "c_jawbone", m);
            addFaceBoneOverride(overrides, bones, "jawbone.x", m);
        }
    }

    // —— 眼球：只转 c_eye_ref_track（不碰眼眶）；注视角来自 projector（眼变换优先）——
    const float blinkL = weightOr(eyeWeights, "eyeBlinkLeft");
    const float blinkR = weightOr(eyeWeights, "eyeBlinkRight");
    const float wideL = weightOr(eyeWeights, "eyeWideLeft");
    const float wideR = weightOr(eyeWeights, "eyeWideRight");
    const float squintL = weightOr(eyeWeights, "eyeSquintLeft");
    const float squintR = weightOr(eyeWeights, "eyeSquintRight");

    // 只用 projector 给出的 pitch/yaw（眼变换连续源）；不再用 Look 权重回退，避免正前方硬切跳动
    float pitchL = fmaxf(-0.85f, fminf(0.85f, eyePitchL));
    float yawL   = fmaxf(-0.95f, fminf(0.95f, eyeYawL));
    float pitchR = fmaxf(-0.85f, fminf(0.85f, eyePitchR));
    float yawR   = fmaxf(-0.95f, fminf(0.95f, eyeYawR));
    // ARKit 抬头 → pitch>0；角色局部 Rx+ 是低头，故上下取反（whiteMan / blackMan 共用）
    pitchL = -pitchL;
    pitchR = -pitchR;

    auto eyeLookMat = [](float p, float y) {
        glm::mat4 m(1.0f);
        m = glm::rotate(m, p, glm::vec3(1, 0, 0));
        m = glm::rotate(m, y, glm::vec3(0, 1, 0));
        return m;
    };
    glm::mat4 gazeL = eyeLookMat(pitchL, yawL);
    glm::mat4 gazeR = eyeLookMat(pitchR, yawR);

    auto aiMat = [](const aiMatrix4x4& m) {
        return glm::mat4(
            m.a1, m.b1, m.c1, m.d1,
            m.a2, m.b2, m.c2, m.d2,
            m.a3, m.b3, m.c3, m.d3,
            m.a4, m.b4, m.c4, m.d4);
    };
    if (!impl_->cachedNodeBindValid &&
        impl_->ourModel->getAnimation() && impl_->ourModel->getAnimation()->getScene()) {
        impl_->cachedNodeBind.clear();
        const aiNode* root = impl_->ourModel->getAnimation()->getScene()->mRootNode;
        std::vector<const aiNode*> stack;
        if (root) stack.push_back(root);
        while (!stack.empty()) {
            const aiNode* n = stack.back();
            stack.pop_back();
            impl_->cachedNodeBind[n->mName.C_Str()] = aiMat(n->mTransformation);
            for (unsigned i = 0; i < n->mNumChildren; ++i) stack.push_back(n->mChildren[i]);
        }
        impl_->cachedNodeBindValid = true;
    }
    const auto& nodeBind = impl_->cachedNodeBind;

    // 绕眼窝：T * gaze * RS（完整局部，Animator 里 replace）
    auto orbitGaze = [&](const glm::mat4& bind, const glm::mat4& gaze) {
        glm::mat4 rs = bind;
        rs[3] = glm::vec4(0, 0, 0, 1);
        return glm::translate(glm::mat4(1.0f), glm::vec3(bind[3])) * gaze * rs;
    };

    for (const auto& kv : bones) {
        const std::string bn = lowerCopy(kv.first);
        if (bn.find("_end") != std::string::npos) continue;
        if (bn.find("c_eye_ref_track") == std::string::npos) continue;
        auto bit = nodeBind.find(kv.first);
        if (bit == nodeBind.end()) continue;
        const bool isRight = (bn.find(".r") != std::string::npos || bn.find("_r") != std::string::npos);
        overrides[kv.first] = orbitGaze(bit->second, isRight ? gazeR : gazeL);
    }

    // whiteMan 等简骨：LeftEye_00 / RightEye_07
    // Animator 对非 c_eye_ref_track 是 bind*ov；只能写旋转增量，不能写完整 orbit（否则 T 叠两次，眼球飞出）
    if (!useFaceBones) {
        for (const auto& kv : bones) {
            const std::string bn = lowerCopy(kv.first);
            if (bn.find("lid") != std::string::npos) continue;
            if (bn.find("brow") != std::string::npos) continue;
            if (bn.find("_end") != std::string::npos) continue;
            // 只匹配 LeftEye / RightEye，避开空父节点 Left_Eye
            const bool left = (bn.find("lefteye") != std::string::npos);
            const bool right = (bn.find("righteye") != std::string::npos);
            if (!left && !right) continue;
            overrides[kv.first] = right ? gazeR : gazeL;
        }
    }

    // —— 眨眼（细眼皮骨，仅 blackMan；whiteMan 走 morph，勿改那边）——
    // 蒙皮在 c_eyelid_top/bot_0N；关睑主轴在父骨 eyelid_top/bot（不在 skin 表，要从 node 树写）。
    if (useFaceBones) {
        auto applyEyelid = [&](bool left, float blink, float squint, float wide) {
            float close = fminf(1.0f, blink + squint * 0.55f);
            float open = wide * 0.25f;
            // blackMan 局部轴：闭眼需上睑 −Rx、下睑 +Rx（与 +/− 相反会变成越闭越睁）
            float topAmt = -(close * 0.85f) + open;
            float botAmt = (close * 0.55f) - open * 0.35f;
            if (fabsf(topAmt) < 0.0005f && fabsf(botAmt) < 0.0005f) return;
            glm::mat4 top = glm::rotate(glm::mat4(1.0f), topAmt, glm::vec3(1, 0, 0));
            glm::mat4 bot = glm::rotate(glm::mat4(1.0f), botAmt, glm::vec3(1, 0, 0));
            const char* side = left ? ".l" : ".r";

            auto driveLid = [&](const std::string& name) {
                const std::string bn = lowerCopy(name);
                if (bn.find(side) == std::string::npos) return;
                if (bn.find("end") != std::string::npos) return;
                if (bn.find("ref") != std::string::npos) return;
                if (bn.find("corner") != std::string::npos) return;
                const bool isTop = (bn.find("eyelid_top") != std::string::npos);
                const bool isBot = (bn.find("eyelid_bot") != std::string::npos);
                if (!isTop && !isBot) return;
                overrides[name] = isTop ? top : bot;
            };
            for (const auto& kv : bones) driveLid(kv.first);
            // 父级 eyelid_top/bot 无蒙皮权重，不在 boneInfoMap，必须从节点缓存补写
            for (const auto& kv : nodeBind) driveLid(kv.first);
        };
        applyEyelid(true, blinkL, squintL, wideL);
        applyEyelid(false, blinkR, squintR, wideR);
    }

    // —— Morph ——
    // whiteMan（无细脸骨，44 / Unity 序）：眨眼+表情全走 morph。
    // blackMan（细脸骨，51 / Apple 序）：眨眼/jaw 只走骨；morph 只补嘴眉颊，避免和眼皮骨方向打架。
    bool appliedMorphs = false;
    if (impl_->ourModel->hasMorphTargets()) {
        std::map<std::string, float> faceMorph;
        const float kGain = useFaceBones ? 1.0f : 1.85f; // 仅 whiteMan 放大
        auto put = [&](const std::string& k, float w) {
            if (k.find("Look") != std::string::npos) return; // 注视走眼骨
            // blackMan：眨眼/眯眼/睁大已由 eyelid 骨驱动，勿再写 morph
            if (useFaceBones &&
                (k.find("Blink") != std::string::npos ||
                 k.find("Squint") != std::string::npos ||
                 k.find("Wide") != std::string::npos)) {
                return;
            }
            faceMorph[k] = fminf(1.0f, fmaxf(0.0f, w) * kGain);
        };
        for (const auto& kv : faceWeights) put(kv.first, kv.second);
        for (const auto& kv : eyeWeights) put(kv.first, kv.second);
        if (useFaceBones) {
            faceMorph.erase("jawOpen");
            faceMorph.erase("jawLeft");
            faceMorph.erase("jawRight");
            faceMorph.erase("jawForward");
        }
        impl_->ourModel->setMorphWeightsByName(faceMorph);
        appliedMorphs = true;
    }

    // Face 覆盖与上体分开存，再合并发布（避免互相冲掉）
    impl_->faceBoneOverrides = std::move(overrides);
    if (impl_->faceBoneOverrides.empty() && !appliedMorphs) {
        impl_->faceDriveActive = false;
        impl_->arHeadYaw = impl_->arHeadPitch = impl_->arHeadRoll = 0.0f;
        if (impl_->ourModel) impl_->ourModel->clearMorphWeights();
    } else {
        impl_->faceDriveActive = true;
    }
    // 不暂停骨骼动画：身体继续播；头/眼/脸 + 上体 override 叠在动画上
    impl_->publishBoneOverrides();
}

int SCRendererData::applyUpperBodyLean(float torsoLeanRad) {
    if (!impl_ || !impl_->ourModel || !impl_->animator) {
        if (impl_) impl_->lastUpperBodyBoneCount = 0;
        return 0;
    }
    impl_->ensureLeanBoneCache();
    if (impl_->leanSpineBones.empty()) {
        impl_->upperBodyDriveActive = false;
        impl_->lastUpperBodyBoneCount = 0;
        return 0;
    }
    const float kMax = 40.0f * 0.01745329252f; // ±40°
    float next = torsoLeanRad;
    if (next > kMax) next = kMax;
    if (next < -kMax) next = -kMax;
    // 同值不重置，避免 60Hz 重复 apply 干扰平滑
    if (fabsf(next - impl_->leanTarget) > 1e-4f)
        impl_->leanTarget = next;
    impl_->upperBodyDriveActive = true;
    impl_->lastUpperBodyBoneCount = (int)impl_->leanSpineBones.size();
    return impl_->lastUpperBodyBoneCount;
}

void SCRendererData::clearUpperBodyDrive() {
    if (!impl_) return;
    impl_->upperBodyDriveActive = false;
    impl_->leanTarget = impl_->leanDisplay = 0.0f;
    impl_->leanVel = 0.0f;
    impl_->leanPublished = 1e9f;
    impl_->lastUpperBodyBoneCount = 0;
    impl_->upperBodyBoneOverrides.clear();
    impl_->publishBoneOverrides();
}

void SCRendererData::clearFaceDrive() {
    if (!impl_) return;
    impl_->clearDriveOverrides();
    impl_->lastUpperBodyBoneCount = 0;
}

bool SCRendererData::isFaceDriveActive() const {
    return impl_ && impl_->faceDriveActive;
}

int SCRendererData::lastUpperBodyBoneCount() const {
    return impl_ ? impl_->lastUpperBodyBoneCount : 0;
}
