//
//  model.h
//  ARKit
//
//  Created by Stan on 2024/9/22.
//

#ifndef model_h
#define model_h

#include <string>
#include <fstream>
#include <sstream>
#include <iostream>
#include <map>
#include <vector>
#include <algorithm>
#include <cctype>
#include <functional>
#include <cstdlib>
#include <cmath>

#include "gl_platform.h"
#include "stb_image.h"

#include "mesh.h"
#include "shader.h"

#include <assimp/Importer.hpp>
#include <assimp/scene.h>
#include <assimp/postprocess.h>
#include <assimp/config.h>
#include "animation.h"
using namespace std;

unsigned int TextureFromFile(const char *path, const string &directory, bool gamma = false);
unsigned int TextureFromFile(const char *path, const string &directory, const aiScene *scene, bool gamma = false);

static glm::mat4 AiToGlmMat4_Model(const aiMatrix4x4& m) {
    return glm::mat4(
        m.a1, m.b1, m.c1, m.d1,
        m.a2, m.b2, m.c2, m.d2,
        m.a3, m.b3, m.c3, m.d3,
        m.a4, m.b4, m.c4, m.d4
    );
}


class Model {
public:
    vector<Texture> textures_loaded; //缓存加载过的纹理
    vector<Mesh> meshes;  //缓存网格
    string directory;  //路径
    bool gammaCorrection;
    map<string, BoneInfo> boneInfoMap;
    int boneCount = 0;
    Animation* animation = nullptr; // default selected animation
    vector<Animation*> animations;  // all animations in file
    const aiScene* scenePtr = nullptr;
    Assimp::Importer importer; // 保存Importer对象，防止scene指针悬空

    //model 构造函数
    Model(string const &path,bool gamma = false) : gammaCorrection(gamma){
        loadModel(path);
    }
    //画网格（boneMatrices: globalBoneId → skin matrix；按 mesh 调色板上传）
    void Draw(Shader &shader, const map<int, glm::mat4>* boneMatrices = nullptr){
        for(unsigned int i = 0; i < meshes.size(); i++)
            meshes[i].Draw(shader, boneMatrices);
    }
    //获取骨骼信息映射
    map<string, BoneInfo> &getBoneInfoMap() { return boneInfoMap; }
    int getBoneCount() const { return boneCount; }
    Animation* getAnimation() { return animation; }
    Animation* getAnimation(int index) {
        if (index < 0 || index >= (int)animations.size()) return nullptr;
        return animations[index];
    }
    int findAnimationIndexByNameContains(const string& needleLower) const {
        auto lower = [](string s) {
            for (char& c : s) c = (char)std::tolower((unsigned char)c);
            return s;
        };
        for (int i = 0; i < (int)animations.size(); ++i) {
            if (!animations[i]) continue;
            string n = lower(animations[i]->getSourceName());
            if (!needleLower.empty() && n.find(needleLower) != string::npos) return i;
        }
        return -1;
    }
    int getAnimationCount() const { return (int)animations.size(); }
    int getMeshCount() const { return meshes.size(); }

    /// 后台 sharegroup 加载后，在主 EAGLContext 上重建各 mesh 的 VAO
    void rebindGPUOnCurrentContext() {
        for (Mesh& m : meshes) m.rebindVAOOnCurrentContext();
    }

    bool hasMorphTargets() const {
        for (const auto& m : meshes) if (m.hasMorphTargets()) return true;
        return false;
    }

    /// 任一 mesh 的最大 morph 数（UnionAvatars 头通常 44）
    int morphTargetCount() const {
        int n = 0;
        for (const auto& m : meshes)
            n = std::max(n, (int)m.morphDeltas.size());
        return n;
    }

    /// jaw / lips / eyelid 等细表情骨（blackMan）；无这些时优先骨驱动，避免 morph 叠两层
    bool hasDetailedFaceBones() const {
        for (const auto& kv : boneInfoMap) {
            string n = kv.first;
            for (char& c : n) c = (char)std::tolower((unsigned char)c);
            if (n.find("jawbone") != string::npos) return true;
            if (n.find("lips_smile") != string::npos) return true;
            if (n.find("eyelid") != string::npos) return true;
        }
        return false;
    }

    void setMorphWeights(const vector<float>& weights) {
        for (auto& m : meshes) {
            if (m.hasMorphTargets()) m.setMorphWeights(weights);
        }
    }

    void clearMorphWeights() {
        for (auto& m : meshes) {
            if (m.hasMorphTargets()) m.clearMorphWeights();
        }
    }

    /// 按 ARKit 规范名写权重；每个 mesh 按自身 morph 数映射（49/51/44 混用时不能用全局 max）
    void setMorphWeightsByName(const map<string, float>& named) {
        for (auto& m : meshes) {
            const int n = (int)m.morphDeltas.size();
            if (n <= 0) continue;
            vector<string> names;
            bool anyName = false;
            for (const auto& nm : m.morphNames) if (!nm.empty()) { anyName = true; break; }
            if (anyName) {
                names = m.morphNames;
                names.resize(n);
            } else {
                names = defaultArkitMorphNames(n);
            }
            if (names.empty()) continue;
            vector<float> w(n, 0.0f);
            for (int i = 0; i < n; ++i) {
                if (i < (int)names.size() && !names[i].empty()) {
                    auto it = named.find(names[i]);
                    if (it != named.end()) w[i] = it->second;
                }
            }
            m.setMorphWeights(w);
        }
    }

    /// 无名 morph 名表（按数量区分模型）
    /// - 52/51/49：Apple 文档常见顺序（blackMan 脸 mesh）
    /// - 44：Unity ARKitBlendShapeLocation 枚举序去掉 8 个 Look（whiteMan / UnionAvatars）
    static vector<string> defaultArkitMorphNames(int count) {
        // Apple-ish 顺序（眼 Look 穿插在 Blink 后）
        static const char* kApple52[] = {
            "eyeBlinkLeft","eyeLookDownLeft","eyeLookInLeft","eyeLookOutLeft","eyeLookUpLeft","eyeSquintLeft","eyeWideLeft",
            "eyeBlinkRight","eyeLookDownRight","eyeLookInRight","eyeLookOutRight","eyeLookUpRight","eyeSquintRight","eyeWideRight",
            "jawForward","jawLeft","jawRight","jawOpen",
            "mouthClose","mouthFunnel","mouthPucker","mouthRight","mouthLeft",
            "mouthSmileLeft","mouthSmileRight","mouthFrownLeft","mouthFrownRight",
            "mouthDimpleLeft","mouthDimpleRight","mouthStretchLeft","mouthStretchRight",
            "mouthRollLower","mouthRollUpper","mouthShrugLower","mouthShrugUpper",
            "mouthPressLeft","mouthPressRight","mouthLowerDownLeft","mouthLowerDownRight",
            "mouthUpperUpLeft","mouthUpperUpRight",
            "browDownLeft","browDownRight","browInnerUp","browOuterUpLeft","browOuterUpRight",
            "cheekPuff","cheekSquintLeft","cheekSquintRight",
            "noseSneerLeft","noseSneerRight","tongueOut"
        };
        // Unity ARKitBlendShapeLocation 整数序（白模 44 = 此表去掉 Look）
        static const char* kUnity52[] = {
            "browDownLeft","browDownRight","browInnerUp","browOuterUpLeft","browOuterUpRight",
            "cheekPuff","cheekSquintLeft","cheekSquintRight",
            "eyeBlinkLeft","eyeBlinkRight",
            "eyeLookDownLeft","eyeLookDownRight","eyeLookInLeft","eyeLookInRight",
            "eyeLookOutLeft","eyeLookOutRight","eyeLookUpLeft","eyeLookUpRight",
            "eyeSquintLeft","eyeSquintRight","eyeWideLeft","eyeWideRight",
            "jawForward","jawLeft","jawOpen","jawRight",
            "mouthClose","mouthDimpleLeft","mouthDimpleRight","mouthFrownLeft","mouthFrownRight",
            "mouthFunnel","mouthLeft","mouthLowerDownLeft","mouthLowerDownRight",
            "mouthPressLeft","mouthPressRight","mouthPucker","mouthRight",
            "mouthRollLower","mouthRollUpper","mouthShrugLower","mouthShrugUpper",
            "mouthSmileLeft","mouthSmileRight","mouthStretchLeft","mouthStretchRight",
            "mouthUpperUpLeft","mouthUpperUpRight",
            "noseSneerLeft","noseSneerRight","tongueOut"
        };
        vector<string> out;
        if (count == 52) {
            out.assign(kApple52, kApple52 + 52);
            return out;
        }
        if (count == 51) {
            out.assign(kApple52, kApple52 + 51); // blackMan：无 tongueOut
            return out;
        }
        if (count == 49) {
            out.assign(kApple52, kApple52 + 49);
            return out;
        }
        if (count == 44) {
            // whiteMan：Unity 序且无 Look（眼球用 LeftEye/RightEye 骨）
            out.reserve(44);
            for (int i = 0; i < 52; ++i) {
                string s = kUnity52[i];
                if (s.find("Look") != string::npos) continue;
                out.push_back(s);
            }
            return out;
        }
        return out;
    }

    vector<string> resolveMorphNames(int count) const {
        // 优先用 Assimp 里非空的名字（取第一个有 morph 的 mesh）
        for (const auto& m : meshes) {
            if ((int)m.morphDeltas.size() != count) continue;
            bool any = false;
            for (const auto& n : m.morphNames) if (!n.empty()) { any = true; break; }
            if (any) {
                vector<string> names = m.morphNames;
                names.resize(count);
                return names;
            }
        }
        return defaultArkitMorphNames(count);
    }

private:
    //加载模型资源
    void loadModel(string const &path){
        // iOS 使用的 Assimp 5：关闭 FBX pivot 拆分，行为才接近原先桌面版 Assimp
        importer.SetPropertyBool(AI_CONFIG_IMPORT_FBX_PRESERVE_PIVOTS, false);
        // blackMan 等大骨架：拆成每 mesh ≤64，才能用 100 槽调色板蒙皮
        importer.SetPropertyInteger(AI_CONFIG_PP_SBBC_MAX_BONES, 64);
        const aiScene *scene = importer.ReadFile(path, aiProcess_Triangulate |
                                                 aiProcess_GenSmoothNormals |
                                                 aiProcess_FlipUVs |
                                                 aiProcess_CalcTangentSpace |
                                                 aiProcess_SplitByBoneCount);
        if(!scene || scene->mFlags & AI_SCENE_FLAGS_INCOMPLETE || !scene->mRootNode){
            cout << "ERROR::ASSIMP::" << importer.GetErrorString() << endl;
            return;
        }
        scenePtr = scene;
        //文件夹路路径
        directory = path.substr(0,path.find_last_of('/'));

        // 调试输出：模型信息
        cout << "Model loaded successfully!" << endl;
        cout << "Number of meshes: " << scene->mNumMeshes << endl;
        cout << "Number of animations: " << scene->mNumAnimations << endl;

        processNode(scene->mRootNode, scene);

        // Assimp FBX：厂商 mOffsetMatrix 常与节点层级不一致 → 蒙皮炸开。
        // 用 bind 姿势重算 offset = inv(boneGlobal) * meshGlobal（不改蒙皮公式）。
        // 注意：glTF/GLB 的 inverseBindMatrices 一般是对的，重算会毁掉多 mesh 皮肤。
        const bool isFbx = path.size() >= 4 &&
            (path.compare(path.size() - 4, 4, ".fbx") == 0 ||
             path.compare(path.size() - 4, 4, ".FBX") == 0);
        if (isFbx && boneCount > 0) {
            glm::mat4 meshGlobal(1.0f);
            bool foundMesh = false;
            std::function<void(aiNode*, const glm::mat4&)> findMesh =
                [&](aiNode* node, const glm::mat4& parent) {
                    glm::mat4 global = parent * AiToGlmMat4_Model(node->mTransformation);
                    if (!foundMesh && node->mNumMeshes > 0) {
                        meshGlobal = global;
                        foundMesh = true;
                        return;
                    }
                    for (unsigned int i = 0; i < node->mNumChildren; i++)
                        findMesh(node->mChildren[i], global);
                };
            findMesh(scene->mRootNode, glm::mat4(1.0f));

            std::function<void(aiNode*, const glm::mat4&)> fixOffsets =
                [&](aiNode* node, const glm::mat4& parent) {
                    glm::mat4 global = parent * AiToGlmMat4_Model(node->mTransformation);
                    auto it = boneInfoMap.find(node->mName.data);
                    if (it != boneInfoMap.end()) {
                        it->second.offset = glm::inverse(global) * meshGlobal;
                    }
                    for (unsigned int i = 0; i < node->mNumChildren; i++)
                        fixOffsets(node->mChildren[i], global);
                };
            fixOffsets(scene->mRootNode, glm::mat4(1.0f));
        }

        // 加载动画数据
        // 注意：Animation 构建需要 boneInfoMap/boneCount（在 processMesh 里填充），
        // 所以必须在 processNode/processMesh 跑完之后再创建，否则 bones 列表会是空的，动画不会动。
        if (scene->mNumAnimations > 0) {
            // 打印所有动画，方便你找“run/奔跑”
            cout << "Animations in file (" << scene->mNumAnimations << "):" << endl;
            for (unsigned int i = 0; i < scene->mNumAnimations; ++i) {
                aiAnimation* a = scene->mAnimations[i];
                string n = (a && a->mName.length > 0) ? string(a->mName.C_Str()) : string("<unnamed>");
                double d = a ? a->mDuration : 0.0;
                double tps = a ? a->mTicksPerSecond : 0.0;
                cout << "  [" << i << "] name=" << n << " duration=" << d << " tps=" << tps << endl;
            }

            auto toLower = [](string s) {
                for (char& c : s) c = (char)std::tolower((unsigned char)c);
                return s;
            };

            // 默认动画：优先选择常态（idle/stand），否则再选 walk/run，最后用 duration 最长的兜底
            int bestIndex = 0;
            double bestDuration = scene->mAnimations[0] ? scene->mAnimations[0]->mDuration : 0.0;

            int idleIndex = -1;
            int standIndex = -1;
            int runIndex = -1;
            int walkIndex = -1;
            for (unsigned int i = 0; i < scene->mNumAnimations; ++i) {
                aiAnimation* a = scene->mAnimations[i];
                if (!a) continue;
                string n = (a->mName.length > 0) ? toLower(string(a->mName.C_Str())) : string();
                if (idleIndex == -1 && (n.find("idle") != string::npos || n.find("rest") != string::npos)) {
                    idleIndex = (int)i;
                }
                if (standIndex == -1 && (n.find("stand") != string::npos || n.find("default") != string::npos)) {
                    standIndex = (int)i;
                }
                if (runIndex == -1 && (n.find("run") != string::npos || n.find("running") != string::npos)) {
                    runIndex = (int)i;
                }
                if (walkIndex == -1 && (n.find("walk") != string::npos || n.find("walking") != string::npos)) {
                    walkIndex = (int)i;
                }
            }

            if (idleIndex != -1) {
                bestIndex = idleIndex;
                bestDuration = scene->mAnimations[bestIndex]->mDuration;
            } else if (standIndex != -1) {
                bestIndex = standIndex;
                bestDuration = scene->mAnimations[bestIndex]->mDuration;
            } else {
                for (unsigned int i = 1; i < scene->mNumAnimations; ++i) {
                    if (scene->mAnimations[i] && scene->mAnimations[i]->mDuration > bestDuration) {
                        bestDuration = scene->mAnimations[i]->mDuration;
                        bestIndex = (int)i;
                    }
                }
            }

            cout << "Selected animation index: " << bestIndex << " duration: " << bestDuration << endl;
            
            // Scene.mAnimations[]：多条 clip 平行；每条含 Channel(骨名+关键帧 格)
            animations.reserve(scene->mNumAnimations);
            for (unsigned int i = 0; i < scene->mNumAnimations; ++i) {
                animations.push_back(new Animation("Anim" + to_string(i), scene, (int)i, boneInfoMap, boneCount));
            }

            cout << "Animation channels matched (bone-driven):" << endl;
            for (int i = 0; i < (int)animations.size(); ++i) {
                cout << "  [" << i << "] name=" << animations[i]->getSourceName()
                     << " matchedChannels=" << animations[i]->getMatchedChannels()
                     << " duration=" << animations[i]->getDuration()
                     << " tps=" << animations[i]->getTicksPerSecond()
                     << endl;
            }
            
            animation = getAnimation(bestIndex);
            cout << "Animation loaded!" << endl;
        }
    }
    //从根node开递归加载网格
    void processNode(aiNode *node,const aiScene *scene){
        for(unsigned int i = 0; i < node->mNumMeshes; i++){
            aiMesh *mesh = scene->mMeshes[node->mMeshes[i]];
            meshes.push_back(processMesh(mesh, scene));
        }
        for(unsigned int i = 0; i < node->mNumChildren; i++){
            processNode(node->mChildren[i], scene);
        }
    }
    //把 aiMesh 转换为我自己定义的 Mesh
    Mesh processMesh(aiMesh *mesh,const aiScene *scene){
        vector<Vertex> vertices;
        vector<unsigned int> indices;
        vector<Texture> textures;

        for(unsigned int i = 0; i < mesh->mNumVertices; i++){
            Vertex vertex;
            glm::vec3 vector;
            //顶点向量
            vector.x = mesh->mVertices[i].x;
            vector.y = mesh->mVertices[i].y;
            vector.z = mesh->mVertices[i].z;
            vertex.Position = vector;
            //法向量
            if(mesh->mNormals){
                vector.x = mesh->mNormals[i].x;
                vector.y = mesh->mNormals[i].y;
                vector.z = mesh->mNormals[i].z;
                vertex.Normal = vector;
            }

            if(mesh->mTextureCoords[0]){
                glm::vec2 vec;
                //纹理坐标
                vec.x = mesh->mTextureCoords[0][i].x;
                vec.y = mesh->mTextureCoords[0][i].y;
                vertex.TexCoords = vec;

                if (mesh->mTangents) {
                    vector.x = mesh->mTangents[i].x;
                    vector.y = mesh->mTangents[i].y;
                    vector.z = mesh->mTangents[i].z;
                    vertex.Tangent = vector;
                } else {
                    vertex.Tangent = glm::vec3(1.0f, 0.0f, 0.0f);
                }
                if (mesh->mBitangents) {
                    vector.x = mesh->mBitangents[i].x;
                    vector.y = mesh->mBitangents[i].y;
                    vector.z = mesh->mBitangents[i].z;
                    vertex.Bitangent = vector;
                } else {
                    vertex.Bitangent = glm::vec3(0.0f, 1.0f, 0.0f);
                }
            }
            else
                vertex.TexCoords = glm::vec2(0.0f,0.0f);
            vertices.push_back(vertex);
        }

        // Mesh 绑骨：顶点用「本 mesh 局部骨 id」，palette[local]=globalId（着色器只有 100 槽）
        vector<int> bonePalette;
        map<string, int> localBoneIds;
        if (mesh->mNumBones > 0) {
            for (unsigned int i = 0; i < mesh->mNumBones; i++) {
                aiBone* bone = mesh->mBones[i];
                string boneName = bone->mName.data;

                if (boneInfoMap.find(boneName) == boneInfoMap.end()) {
                    BoneInfo info;
                    info.id = boneCount;
                    info.offset = AiToGlmMat4_Model(bone->mOffsetMatrix);
                    boneInfoMap[boneName] = info;
                    boneCount++;
                }
                const int globalId = boneInfoMap[boneName].id;

                int localId;
                auto lit = localBoneIds.find(boneName);
                if (lit == localBoneIds.end()) {
                    localId = (int)bonePalette.size();
                    localBoneIds[boneName] = localId;
                    bonePalette.push_back(globalId);
                } else {
                    localId = lit->second;
                }

                for (unsigned int j = 0; j < bone->mNumWeights; j++) {
                    aiVertexWeight weight = bone->mWeights[j];
                    int vertexID = weight.mVertexId;
                    float weightValue = weight.mWeight;
                    vertices[vertexID].addBoneData(localId, weightValue);
                }
            }
            if ((int)bonePalette.size() > 100) {
                cout << "WARNING: mesh bone palette " << bonePalette.size()
                     << " > 100 — skinning will clip" << endl;
            }
        }
        //顶点索引
        for(unsigned int i = 0; i < mesh->mNumFaces; i++){
            aiFace face = mesh->mFaces[i];
            for(unsigned int j = 0; j < face.mNumIndices; j++)
                indices.push_back(face.mIndices[j]);
        }
        //加载纹理（glTF 常用 BASE_COLOR；FBX 常用 DIFFUSE）
        // 部分 Sketchfab 材质：颜色只在 emissiveTexture，baseColor 为黑且无贴图
        aiMaterial *material = scene->mMaterials[mesh->mMaterialIndex];
        string matName = material && material->GetName().length ? material->GetName().C_Str() : "";
        string meshName = mesh->mName.length ? mesh->mName.C_Str() : "";
        string matLower = matName, meshLower = meshName;
        for (char& c : matLower) c = (char)tolower((unsigned char)c);
        for (char& c : meshLower) c = (char)tolower((unsigned char)c);
        const bool isHairMat = (matLower.find("hair") != string::npos || meshLower.find("hair") != string::npos);

        vector<Texture> diffuseMaps = loadMaterialTextures(scene, material, aiTextureType_BASE_COLOR, "texture_diffuse");
        if (diffuseMaps.empty()) {
            diffuseMaps = loadMaterialTextures(scene, material, aiTextureType_DIFFUSE, "texture_diffuse");
        }
        if (diffuseMaps.empty()) {
            diffuseMaps = loadMaterialTextures(scene, material, aiTextureType_EMISSIVE, "texture_diffuse");
        }
#ifdef AI_TEXTURE_TYPE_MAX
        if (diffuseMaps.empty()) {
            diffuseMaps = loadMaterialTextures(scene, material, aiTextureType_EMISSION_COLOR, "texture_diffuse");
        }
#endif
        // 头发：再试 opacity / unknown（部分资源把发卡贴图挂在这些槽）
        if (diffuseMaps.empty() && isHairMat) {
            diffuseMaps = loadMaterialTextures(scene, material, aiTextureType_OPACITY, "texture_diffuse");
        }
        if (diffuseMaps.empty() && isHairMat) {
            diffuseMaps = loadMaterialTextures(scene, material, aiTextureType_UNKNOWN, "texture_diffuse");
        }
        textures.insert(textures.end(), diffuseMaps.begin(), diffuseMaps.end());
        //镜面反射
        vector<Texture> specularMaps = loadMaterialTextures(scene, material, aiTextureType_SPECULAR, "texture_specular");
        textures.insert(textures.end(), specularMaps.begin(), specularMaps.end());
        //法线贴图（glTF NORMALS / HEIGHT 偶发混用）
        vector<Texture> normalMaps = loadMaterialTextures(scene, material, aiTextureType_NORMALS, "texture_normal");
        if (normalMaps.empty()) {
            normalMaps = loadMaterialTextures(scene, material, aiTextureType_HEIGHT, "texture_normal");
        }
        textures.insert(textures.end(), normalMaps.begin(), normalMaps.end());
        //高度图
        vector<Texture> heightMaps = loadMaterialTextures(scene, material, aiTextureType_HEIGHT, "texture_height");
        textures.insert(textures.end(), heightMaps.begin(), heightMaps.end());

        // 材质底色 / 双面 / 头发标记
        glm::vec4 matColor(1.0f, 1.0f, 1.0f, 1.0f);
        aiColor4D col;
        if (material && (AI_SUCCESS == aiGetMaterialColor(material, AI_MATKEY_BASE_COLOR, &col) ||
                         AI_SUCCESS == aiGetMaterialColor(material, AI_MATKEY_COLOR_DIFFUSE, &col))) {
            matColor = glm::vec4(col.r, col.g, col.b, col.a);
        }
        // 已有 diffuse 贴图时不要用 FBX 底色（常很暗，会把狼身/Fur 乘黑）
        if (!diffuseMaps.empty() && !isHairMat) {
            matColor = glm::vec4(1.0f, 1.0f, 1.0f, 1.0f);
        }
        // whiteMan 头发：baseColorFactor=(0,0,0) 且无 diffuse → 用默认发色
        if (isHairMat && (matColor.r + matColor.g + matColor.b) < 0.05f) {
            matColor = glm::vec4(0.20f, 0.14f, 0.10f, 1.0f);
        }
        int twosided = 0;
        if (material)
            aiGetMaterialInteger(material, AI_MATKEY_TWOSIDED, &twosided);

        // glTF morph targets → aiAnimMesh（部分资源把绝对 cm 坐标误标成 target）
        vector<vector<glm::vec3>> morphDeltas;
        vector<string> morphNames;
        if (mesh->mNumAnimMeshes > 0 && mesh->mAnimMeshes) {
            float maxBase = 0.0f;
            for (unsigned int i = 0; i < mesh->mNumVertices; ++i) {
                const aiVector3D& b = mesh->mVertices[i];
                maxBase = std::max(maxBase, std::fabs(b.x) + std::fabs(b.y) + std::fabs(b.z));
            }
            morphDeltas.resize(mesh->mNumAnimMeshes);
            morphNames.resize(mesh->mNumAnimMeshes);
            // 先估一个共享尺度（绝对 cm 目标），避免每个 morph 各自 maxAnim 不同把表情压扁
            float sharedUnit = 1.0f;
            bool haveSharedUnit = false;
            for (unsigned int mi = 0; mi < mesh->mNumAnimMeshes; ++mi) {
                aiAnimMesh* am = mesh->mAnimMeshes[mi];
                if (!am || !am->mVertices) continue;
                float maxAnim = 0.0f;
                for (unsigned int i = 0; i < mesh->mNumVertices; ++i) {
                    const aiVector3D& t = am->mVertices[i];
                    maxAnim = std::max(maxAnim, std::fabs(t.x) + std::fabs(t.y) + std::fabs(t.z));
                }
                if (maxBase > 1e-6f && maxAnim > maxBase * 2.0f) {
                    sharedUnit = maxAnim > 1e-8f ? (maxBase / maxAnim) : 1.0f;
                    haveSharedUnit = true;
                    break;
                }
            }
            for (unsigned int mi = 0; mi < mesh->mNumAnimMeshes; ++mi) {
                aiAnimMesh* am = mesh->mAnimMeshes[mi];
                morphNames[mi] = am && am->mName.length ? am->mName.C_Str() : "";
                morphDeltas[mi].assign(mesh->mNumVertices, glm::vec3(0.0f));
                if (!am || !am->mVertices) continue;

                float maxAnim = 0.0f;
                for (unsigned int i = 0; i < mesh->mNumVertices; ++i) {
                    const aiVector3D& t = am->mVertices[i];
                    maxAnim = std::max(maxAnim, std::fabs(t.x) + std::fabs(t.y) + std::fabs(t.z));
                }
                const bool absolute = (maxBase > 1e-6f && maxAnim > maxBase * 2.0f);
                const float unit = absolute ? (haveSharedUnit ? sharedUnit : (maxAnim > 1e-8f ? maxBase / maxAnim : 1.0f)) : 1.0f;

                for (unsigned int i = 0; i < mesh->mNumVertices; ++i) {
                    const aiVector3D& b = mesh->mVertices[i];
                    const aiVector3D& t = am->mVertices[i];
                    if (absolute) {
                        morphDeltas[mi][i] = glm::vec3(t.x * unit - b.x, t.y * unit - b.y, t.z * unit - b.z);
                    } else {
                        morphDeltas[mi][i] = glm::vec3(t.x, t.y, t.z);
                    }
                }
            }
            if (!morphDeltas.empty()) {
                cout << "Mesh morphs: " << morphDeltas.size()
                     << " (method=" << (int)mesh->mMethod << ")" << endl;
            }
        }

        //得到  顶点 索引 贴图 生成一个网格
        Mesh out(vertices, indices, textures, bonePalette, std::move(morphDeltas), std::move(morphNames));
        out.materialColor = matColor;
        out.doubleSided = (twosided != 0) || isHairMat;
        out.isHair = isHairMat;
        return out;
    };
    //加载模型中的图片等资源,生成纹理（支持 GLB 内嵌 *0 / GetEmbeddedTexture）
    vector<Texture> loadMaterialTextures(const aiScene *scene, aiMaterial *mat, aiTextureType type, string typeName){
        vector<Texture> textures;
        for(unsigned int i = 0; i < mat->GetTextureCount(type); i++){
            aiString str;
            mat->GetTexture(type, i, &str);
            bool skip = false;
            for(unsigned int j = 0; j < textures_loaded.size(); j++){
                if(std::strcmp(textures_loaded[j].path.data(), str.data) == 0){
                    textures.push_back(textures_loaded[j]);
                    skip = true;
                    break;
                }
            }
            if(!skip){
                Texture texture;
                texture.id = TextureFromFile(str.data, this->directory, scene);
                texture.type = typeName;
                texture.path = str.data;
                textures.push_back(texture);
                textures_loaded.push_back(texture);
            }
        }
        return textures;
    }
};


// 从 Assimp 内嵌贴图或磁盘路径创建 GL 纹理
unsigned int TextureFromFile(const char *path, const string &directory, const aiScene *scene, bool gamma){
    string filename = string(path ? path : "");
    replace(filename.begin(), filename.end(), '\\', '/');

    unsigned int textureID;
    glGenTextures(1, &textureID);

    int width = 0, height = 0, nrComponents = 0;
    unsigned char *data = nullptr;
    string loadedPath;
    bool freeWithStbi = true;

    // 1) GLB / glTF 内嵌：路径多为 "*0" / "*1" 或可被 GetEmbeddedTexture 解析
    if (scene && path && path[0] != '\0') {
        const aiTexture *emb = scene->GetEmbeddedTexture(path);
        if (emb) {
            if (emb->mHeight == 0) {
                // 压缩图（jpeg/png）存在 pcData，长度 = mWidth
                data = stbi_load_from_memory(
                    reinterpret_cast<const stbi_uc*>(emb->pcData),
                    (int)emb->mWidth,
                    &width, &height, &nrComponents, 0);
                loadedPath = string("embedded:") + path;
            } else {
                // 未压缩：Assimp 为 aiTexel(BGRA) 数组
                width = (int)emb->mWidth;
                height = (int)emb->mHeight;
                nrComponents = 4;
                data = (unsigned char*)malloc((size_t)width * (size_t)height * 4);
                freeWithStbi = false;
                for (int i = 0; i < width * height; ++i) {
                    const aiTexel &t = emb->pcData[i];
                    data[i*4+0] = t.r;
                    data[i*4+1] = t.g;
                    data[i*4+2] = t.b;
                    data[i*4+3] = t.a;
                }
                loadedPath = string("embedded_raw:") + path;
            }
        }
    }

    // 2) 磁盘候选路径
    if (!data) {
        auto tryLoad = [](const string& fullPath, int& w, int& h, int& n) -> unsigned char* {
            return stbi_load(fullPath.c_str(), &w, &h, &n, 0);
        };
        vector<string> candidates;
        candidates.push_back(directory + '/' + filename);
        {
            size_t slash = filename.find_last_of('/');
            string base = (slash == string::npos) ? filename : filename.substr(slash + 1);
            // Assimp/Blender 常带 ".001" 后缀：Image_5.001 → Image_5.png
            string stem = base;
            size_t dot = stem.find_last_of('.');
            if (dot != string::npos) {
                string ext = stem.substr(dot);
                string nameOnly = stem.substr(0, dot);
                // 去掉末尾 .数字 版本号
                size_t d2 = nameOnly.find_last_of('.');
                if (d2 != string::npos) {
                    bool allDigit = true;
                    for (size_t i = d2 + 1; i < nameOnly.size(); ++i) {
                        if (nameOnly[i] < '0' || nameOnly[i] > '9') { allDigit = false; break; }
                    }
                    if (allDigit) nameOnly = nameOnly.substr(0, d2);
                }
                stem = nameOnly;
                auto pushBase = [&](const string& b) {
                    candidates.push_back(directory + '/' + b);
                    candidates.push_back(directory + "/textures/" + b);
                    candidates.push_back(directory + "/TEXTURES/" + b);
                    candidates.push_back(directory + "/../textures/" + b);
                    candidates.push_back(directory + "/../TEXTURES/" + b);
                };
                pushBase(base);
                pushBase(stem + ext);
                pushBase(stem + ".png");
                pushBase(stem + ".PNG");
                pushBase(stem + ".jpg");
                pushBase(stem + ".jpeg");
            } else {
                candidates.push_back(directory + '/' + base);
                candidates.push_back(directory + "/textures/" + base);
                candidates.push_back(directory + "/TEXTURES/" + base);
                candidates.push_back(directory + "/../textures/" + base);
                candidates.push_back(directory + "/../TEXTURES/" + base);
                candidates.push_back(directory + "/../textures/" + base + ".png");
            }
        }
        for (const auto& cand : candidates) {
            data = tryLoad(cand, width, height, nrComponents);
            if (data) { loadedPath = cand; freeWithStbi = true; break; }
        }
    }

    if (data)
    {
        unsigned char *rgba = data;
        bool needFreeRgba = false;
        if (nrComponents != 4) {
            rgba = (unsigned char*)malloc((size_t)width * (size_t)height * 4);
            needFreeRgba = true;
            for (int i = 0; i < width * height; ++i) {
                if (nrComponents == 1) {
                    rgba[i*4+0] = data[i];
                    rgba[i*4+1] = data[i];
                    rgba[i*4+2] = data[i];
                    rgba[i*4+3] = 255;
                } else if (nrComponents == 2) {
                    rgba[i*4+0] = data[i*2+0];
                    rgba[i*4+1] = data[i*2+0];
                    rgba[i*4+2] = data[i*2+0];
                    rgba[i*4+3] = data[i*2+1];
                } else {
                    rgba[i*4+0] = data[i*nrComponents+0];
                    rgba[i*4+1] = data[i*nrComponents+1];
                    rgba[i*4+2] = data[i*nrComponents+2];
                    rgba[i*4+3] = 255;
                }
            }
        }

        glBindTexture(GL_TEXTURE_2D, textureID);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
        glGenerateMipmap(GL_TEXTURE_2D);

        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        cout << "Texture OK: " << loadedPath << " (" << width << "x" << height << ")" << endl;
        if (freeWithStbi) stbi_image_free(data);
        else free(data);
        if (needFreeRgba) free(rgba);
    }
    else
    {
        // 占位：品红 = 贴图加载失败
        unsigned char pink[] = { 255, 0, 255, 255 };
        glBindTexture(GL_TEXTURE_2D, textureID);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, pink);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        std::cout << "Texture failed to load at path: " << path << std::endl;
    }

    return textureID;
}

// 兼容旧签名（无 scene）
unsigned int TextureFromFile(const char *path, const string &directory, bool gamma){
    return TextureFromFile(path, directory, nullptr, gamma);
}


#endif /* model_h */
