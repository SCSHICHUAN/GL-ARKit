
#ifndef animation_h
#define animation_h

#include "gl_platform.h"
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>
#include <glm/gtc/quaternion.hpp>

#include <assimp/Importer.hpp>
#include <assimp/scene.h>
#include <assimp/postprocess.h>

#include <string>
#include <vector>
#include <map>
#include <iostream>

using namespace std;

// 蒙皮绑定：骨名 → 着色器用的索引 id、逆绑定矩阵 offset(invBind)
struct BoneInfo {
    int id;
    glm::mat4 offset;
};

// 关键帧：位置 vec3 + 时间戳(格 tick)，如关键帧0、关键帧20
struct KeyPosition {
    glm::vec3 position;
    float timeStamp;
};

struct KeyRotation {
    glm::quat orientation;
    float timeStamp;
};

struct KeyScale {
    glm::vec3 scale;
    float timeStamp;
};

class Bone {
private:
    vector<KeyPosition> positions;
    vector<KeyRotation> rotations;
    vector<KeyScale> scales;
    int numPositions;
    int numRotations;
    int numScalings;
    int boneID;
    string boneName;
    glm::mat4 localTransform;

public:
    Bone(const string& name, int ID, const aiNodeAnim* channel);
    void update(float animationTime);
    glm::mat4 getLocalTransform() { return localTransform; }
    string getBoneName() const { return boneName; }
    int getBoneID() { return boneID; }

private:
    int getPositionIndex(float animationTime);
    int getRotationIndex(float animationTime);
    int getScaleIndex(float animationTime);
    float getScaleFactor(float lastTimeStamp, float nextTimeStamp, float animationTime);
    glm::mat4 interpolatePosition(float animationTime);
    glm::mat4 interpolateRotation(float animationTime);
    glm::mat4 interpolateScaling(float animationTime);
};

// 一条动画 clip：Channel 列表(按骨名) + 时长(格) + 时间基(tick/s)
class Animation {
private:
    float duration;       // 动画总长，单位：格(tick)
    int ticksPerSecond;   // 时间基 tick/s，如 25 表示 1 秒走 25 格
    vector<Bone> bones;
    map<string, BoneInfo> boneInfoMap;
    int boneCount;
    string animationName;
    string sourceName;
    const aiScene* scene;
    glm::mat4 globalInverseTransform;
    int animationIndex;

public:
    Animation(const string& name, const aiScene* scene, int animationIndex, const map<string, BoneInfo>& boneInfoMap, int boneCount);
    void update(float animationTime);
    Bone* findBone(const string& name);
    map<string, BoneInfo>& getBoneInfoMap();
    int getBoneCount();
    float getDuration();        // 动画总长(格)
    int getTicksPerSecond();    // 时间基 tick/s
    const aiScene* getScene() { return scene; }
    const glm::mat4& getGlobalInverseTransform() const { return globalInverseTransform; }
    int getAnimationIndex() const { return animationIndex; }
    const string& getSourceName() const { return sourceName; }
    int getMatchedChannels() const { return (int)bones.size(); }
};

// 运行时驱动：推进播放头、沿 Node 树算矩阵，供着色器使用
class Animator {
private:
    Animation* currentAnimation;
    float currentTime;              // 播放头位置，单位：格(tick)
    float deltaTime;
    map<int, glm::mat4> finalBoneMatrices; // 下标=骨骼id，CPU 算好的蒙皮矩阵
    bool looping;

public:
    Animator(Animation* animation);
    void updateAnimation(float dt);
    void playAnimation(Animation* pAnimation, bool resetTime = true);
    void setLooping(bool enabled) { looping = enabled; }
    bool isLooping() const { return looping; }
    bool isFinished() const;
    void calculateBoneTransform(const aiNode* node, glm::mat4 parentTransform);
    map<int, glm::mat4>& getFinalBoneMatrices();
};

#endif /* animation_h */
