
#include "animation.h"

static glm::mat4 AiToGlmMat4(const aiMatrix4x4& m) {
    // glm::mat4(...) 的 16 个参数按“列”填充：
    // 第 1 列是 (m00,m10,m20,m30)，第 2 列是 (m01,m11,m21,m31) ...
    // Assimp 的 aiMatrix4x4 字段对应（按行）：
    // [a1 a2 a3 a4
    //  b1 b2 b3 b4
    //  c1 c2 c3 c4
    //  d1 d2 d3 d4]
    return glm::mat4(
        m.a1, m.b1, m.c1, m.d1,
        m.a2, m.b2, m.c2, m.d2,
        m.a3, m.b3, m.c3, m.d3,
        m.a4, m.b4, m.c4, m.d4
    );
}

// 从 Animation 的一条 Channel 加载关键帧序列(pos/rot/scale + timeStamp 格)
Bone::Bone(const string& name, int ID, const aiNodeAnim* channel) {
    boneName = name;
    boneID = ID;
    numPositions = channel->mNumPositionKeys;
    numRotations = channel->mNumRotationKeys;
    numScalings = channel->mNumScalingKeys;

    localTransform = glm::mat4(1.0f);

    for (int i = 0; i < numPositions; i++) {
        aiVector3D pos = channel->mPositionKeys[i].mValue;
        float time = channel->mPositionKeys[i].mTime;
        KeyPosition data;
        data.position = glm::vec3(pos.x, pos.y, pos.z);
        data.timeStamp = time;
        positions.push_back(data);
    }

    for (int i = 0; i < numRotations; i++) {
        aiQuaternion rot = channel->mRotationKeys[i].mValue;
        float time = channel->mRotationKeys[i].mTime;
        KeyRotation data;
        data.orientation = glm::quat(rot.w, rot.x, rot.y, rot.z);
        data.timeStamp = time;
        rotations.push_back(data);
    }

    for (int i = 0; i < numScalings; i++) {
        aiVector3D s = channel->mScalingKeys[i].mValue;
        float time = channel->mScalingKeys[i].mTime;
        KeyScale data;
        data.scale = glm::vec3(s.x, s.y, s.z);
        data.timeStamp = time;
        scales.push_back(data);
    }
}

// 按当前播放头(格)插值：localMat = T(pos) * R(rot) * S(scale)
void Bone::update(float animationTime) {
    localTransform = interpolatePosition(animationTime) * interpolateRotation(animationTime) * interpolateScaling(animationTime);
}

int Bone::getPositionIndex(float animationTime) {
    for (int i = 0; i < numPositions - 1; i++) {
        if (animationTime < positions[i + 1].timeStamp)
            return i;
    }
    cout << "Error: No position key found for time " << animationTime << endl;
    return 0;
}

int Bone::getRotationIndex(float animationTime) {
    for (int i = 0; i < numRotations - 1; i++) {
        if (animationTime < rotations[i + 1].timeStamp)
            return i;
    }
    cout << "Error: No rotation key found for time " << animationTime << endl;
    return 0;
}

int Bone::getScaleIndex(float animationTime) {
    for (int i = 0; i < numScalings - 1; i++) {
        if (animationTime < scales[i + 1].timeStamp)
            return i;
    }
    cout << "Error: No scale key found for time " << animationTime << endl;
    return 0;
}

// 两关键帧之间的插值系数 t，例：current=15 格，关键帧0~20 → t=15/20=0.75
float Bone::getScaleFactor(float lastTimeStamp, float nextTimeStamp, float animationTime) {
    float scaleFactor = 0.0f;
    float midWayLength = animationTime - lastTimeStamp;
    float framesDiff = nextTimeStamp - lastTimeStamp;
    scaleFactor = midWayLength / framesDiff;
    return scaleFactor;
}

glm::mat4 Bone::interpolatePosition(float animationTime) {
    if (numPositions == 1)
        return glm::translate(glm::mat4(1.0f), positions[0].position);
    
    // 非循环动画在末尾会 clamp 到 duration；此时可能刚好落在最后一个 key 上，
    // 直接返回最后 key，避免索引查找失败导致回到第 0 帧。
    if (animationTime >= positions[numPositions - 1].timeStamp) {
        return glm::translate(glm::mat4(1.0f), positions[numPositions - 1].position);
    }

    int p0Index = getPositionIndex(animationTime);
    int p1Index = p0Index + 1;
    float scaleFactor = getScaleFactor(positions[p0Index].timeStamp, positions[p1Index].timeStamp, animationTime);
    glm::vec3 finalPosition = glm::mix(positions[p0Index].position, positions[p1Index].position, scaleFactor);
    return glm::translate(glm::mat4(1.0f), finalPosition);
}

glm::mat4 Bone::interpolateRotation(float animationTime) {
    if (numRotations == 1) {
        auto rotation = glm::normalize(rotations[0].orientation);
        return glm::mat4_cast(rotation);
    }
    
    if (animationTime >= rotations[numRotations - 1].timeStamp) {
        auto rotation = glm::normalize(rotations[numRotations - 1].orientation);
        return glm::mat4_cast(rotation);
    }

    int p0Index = getRotationIndex(animationTime);
    int p1Index = p0Index + 1;
    float scaleFactor = getScaleFactor(rotations[p0Index].timeStamp, rotations[p1Index].timeStamp, animationTime);
    glm::quat finalRotation = glm::slerp(rotations[p0Index].orientation, rotations[p1Index].orientation, scaleFactor);
    finalRotation = glm::normalize(finalRotation);
    return glm::mat4_cast(finalRotation);
}

glm::mat4 Bone::interpolateScaling(float animationTime) {
    if (numScalings == 1)
        return glm::scale(glm::mat4(1.0f), scales[0].scale);
    
    if (animationTime >= scales[numScalings - 1].timeStamp) {
        return glm::scale(glm::mat4(1.0f), scales[numScalings - 1].scale);
    }

    int p0Index = getScaleIndex(animationTime);
    int p1Index = p0Index + 1;
    float scaleFactor = getScaleFactor(scales[p0Index].timeStamp, scales[p1Index].timeStamp, animationTime);
    glm::vec3 finalScale = glm::mix(scales[p0Index].scale, scales[p1Index].scale, scaleFactor);
    return glm::scale(glm::mat4(1.0f), finalScale);
}

Animation::Animation(const string& name, const aiScene* scene, int animationIndex, const map<string, BoneInfo>& boneInfoMap, int boneCount) {
    animationName = name;
    this->scene = scene;
    this->animationIndex = animationIndex;
    if (!scene || scene->mNumAnimations == 0) {
        duration = 0.0f;
        ticksPerSecond = 25;
        globalInverseTransform = glm::mat4(1.0f);
        this->boneCount = boneCount;
        this->boneInfoMap = boneInfoMap;
        sourceName = "<no-scene>";
        return;
    }
    if (this->animationIndex < 0 || this->animationIndex >= (int)scene->mNumAnimations) {
        this->animationIndex = 0;
    }

    aiAnimation* animation = scene->mAnimations[this->animationIndex];
    sourceName = (animation && animation->mName.length > 0) ? string(animation->mName.C_Str()) : string("<unnamed>");
    duration = animation->mDuration;           // 格(tick)，如 30 表示时间轴 30 格
    ticksPerSecond = animation->mTicksPerSecond; // tick/s，如 25 → 真实 1 秒 = 25 格
    if (ticksPerSecond == 0) {
        // 一些 FBX 可能不给 ticksPerSecond，给个常用默认值避免时间不前进
        ticksPerSecond = 25;
    }
    this->boneCount = boneCount;
    this->boneInfoMap = boneInfoMap;
    // 标准做法：取 root 的 inverse 作为全局逆变换，把骨骼 global 带回模型空间
    if (scene && scene->mRootNode) {
        globalInverseTransform = glm::inverse(AiToGlmMat4(scene->mRootNode->mTransformation));
    } else {
        globalInverseTransform = glm::mat4(1.0f);
    }

    // Channel：骨名 + 关键帧；仅当骨名在 boneInfoMap(Mesh 绑定) 中存在才创建
    for (int i = 0; i < animation->mNumChannels; i++) {
        aiNodeAnim* channel = animation->mChannels[i];
        string boneName = channel->mNodeName.data;

        if (this->boneInfoMap.find(boneName) != this->boneInfoMap.end()) {
            bones.emplace_back(boneName, this->boneInfoMap[boneName].id, channel);
        }
    }
    // 保留 Model 里重算好的 offset，不用 Assimp FBX 的 mOffsetMatrix 覆盖
}

void Animation::update(float animationTime) {
    for (auto& bone : bones) {
        bone.update(animationTime);
    }
}

Bone* Animation::findBone(const string& name) {
    for (auto& bone : bones) {
        if (bone.getBoneName() == name) {
            return &bone;
        }
    }
    return nullptr;
}

map<string, BoneInfo>& Animation::getBoneInfoMap() { return boneInfoMap; }
int Animation::getBoneCount() { return boneCount; }
float Animation::getDuration() { return duration; }
int Animation::getTicksPerSecond() { return ticksPerSecond; }

Animator::Animator(Animation* animation) {
    currentAnimation = animation;
    currentTime = 0.0f;
    deltaTime = 0.0f;
    looping = true;
}

void Animator::updateAnimation(float dt) {
    deltaTime = dt;
    if (currentAnimation) {
        // 播放头步进：格 += (tick/s) * 秒
        currentTime += currentAnimation->getTicksPerSecond() * dt;
        if (looping) {
            currentTime = fmod(currentTime, currentAnimation->getDuration());
        } else {
            float d = currentAnimation->getDuration();
            if (currentTime > d) currentTime = d;
        }

        finalBoneMatrices.clear();
        // 从 Node 树根递归：插值 → 父子连乘 → 写入 finalBonesMatrices[id]
        calculateBoneTransform(currentAnimation->getScene()->mRootNode, glm::mat4(1.0f));

        // 每隔一段打印一次：确认动画链路确实在产生 bone 矩阵（避免“没看到输出”）
        static int frames = 0;
        frames++;
        if (frames == 1 || frames % 120 == 0) {
            cout << "[AnimDebug] ticksPerSecond=" << currentAnimation->getTicksPerSecond()
                 << " duration=" << currentAnimation->getDuration()
                 << " animIndex=" << currentAnimation->getAnimationIndex()
                 << " boneInfoMap=" << currentAnimation->getBoneInfoMap().size()
                 << " finalBoneMatrices=" << finalBoneMatrices.size()
                 << endl;
        }
    }
}

void Animator::playAnimation(Animation* pAnimation, bool resetTime) {
    currentAnimation = pAnimation;
    if (resetTime) currentTime = 0.0f; // 切换 clip 时播放头回到 0 格
}

void Animator::calculateBoneTransform(const aiNode* node, glm::mat4 parentTransform) {
    if (!node || !currentAnimation) {
        return;
    }

    std::string nodeName = node->mName.data;
    glm::mat4 nodeTransform = AiToGlmMat4(node->mTransformation);

    // 按骨名匹配 Channel；无 Channel 则用节点静态变换(绑定姿势)
    Bone* bone = currentAnimation->findBone(nodeName);
    if (bone) {
        bone->update(currentTime);
        nodeTransform = bone->getLocalTransform();
    }

    // 父骨骼全局 × 本骨局部
    glm::mat4 globalTransformation = parentTransform * nodeTransform;

    if (currentAnimation->getBoneInfoMap().find(nodeName) != currentAnimation->getBoneInfoMap().end()) {
        int boneIndex = currentAnimation->getBoneInfoMap()[nodeName].id;
        glm::mat4 offset = currentAnimation->getBoneInfoMap()[nodeName].offset;
        // finalBonesMatrices[id] = globalInverse * globalMat * invBind(offset)
        finalBoneMatrices[boneIndex] = currentAnimation->getGlobalInverseTransform() * globalTransformation * offset;
    }

    for (int i = 0; i < node->mNumChildren; ++i) {
        if (node->mChildren[i]) {
            calculateBoneTransform(node->mChildren[i], globalTransformation);
        }
    }
}

map<int, glm::mat4>& Animator::getFinalBoneMatrices() {
    return finalBoneMatrices;
}

bool Animator::isFinished() const {
    if (!currentAnimation) return true;
    if (looping) return false;
    return currentTime >= currentAnimation->getDuration();
}
