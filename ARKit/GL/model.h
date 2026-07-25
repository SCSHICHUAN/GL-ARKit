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

unsigned int TextureFromFile(const char *path, const string &directory,bool gamma = false);

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
    //画网格
    void Draw(Shader &shader){
        for(unsigned int i = 0; i < meshes.size(); i++)
            meshes[i].Draw(shader);
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
private:
    //加载模型资源
    void loadModel(string const &path){
        // iOS 使用的 Assimp 5：关闭 FBX pivot 拆分，行为才接近原先桌面版 Assimp
        importer.SetPropertyBool(AI_CONFIG_IMPORT_FBX_PRESERVE_PIVOTS, false);
        const aiScene *scene = importer.ReadFile(path, aiProcess_Triangulate |
                                                 aiProcess_GenSmoothNormals |
                                                 aiProcess_FlipUVs |
                                                 aiProcess_CalcTangentSpace);
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
        if (boneCount > 0) {
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

                vector.x = mesh->mTangents[i].x;
                vector.y = mesh->mTangents[i].y;
                vector.z = mesh->mTangents[i].z;
                vertex.Tangent = vector;

                vector.x = mesh->mBitangents[i].x;
                vector.y = mesh->mBitangents[i].y;
                vector.z = mesh->mBitangents[i].z;
                vertex.Bitangent = vector;
            }
            else
                vertex.TexCoords = glm::vec2(0.0f,0.0f);
            vertices.push_back(vertex);
        }

        // Mesh 绑骨：顶点写入 m_BoneIDs + m_Weights（最多4根），登记 boneInfoMap(名→id, offset)
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

                for (unsigned int j = 0; j < bone->mNumWeights; j++) {
                    aiVertexWeight weight = bone->mWeights[j];
                    int vertexID = weight.mVertexId;
                    float weightValue = weight.mWeight;

                    vertices[vertexID].addBoneData(boneInfoMap[bone->mName.data].id, weightValue);
                }
            }
        }
        //顶点索引
        for(unsigned int i = 0; i < mesh->mNumFaces; i++){
            aiFace face = mesh->mFaces[i];
            for(unsigned int j = 0; j < face.mNumIndices; j++)
                indices.push_back(face.mIndices[j]);
        }
        //加载纹理
        aiMaterial *material = scene->mMaterials[mesh->mMaterialIndex];
        //漫反射
        vector<Texture> diffuseMaps = loadMaterialTextures(material, aiTextureType_DIFFUSE, "texture_diffuse");
        textures.insert(textures.end(), diffuseMaps.begin(),diffuseMaps.end());
        //镜面反射
        vector<Texture> specularMaps = loadMaterialTextures(material, aiTextureType_SPECULAR, "texture_specular");
        textures.insert(textures.end(), specularMaps.begin(),specularMaps.end());
        //法线贴图
        vector<Texture> normalMaps = loadMaterialTextures(material, aiTextureType_NORMALS, "texture_normal");
        textures.insert(textures.end(), normalMaps.begin(),normalMaps.end());
        //高度图
        vector<Texture> heightMaps = loadMaterialTextures(material,aiTextureType_HEIGHT , "texture_height");
        textures.insert(textures.end(), heightMaps.begin(),heightMaps.end());

        //得到  顶点 索引 贴图 生成一个网格
        return Mesh(vertices,indices,textures);
    };
    //加载模型中的图片等资源,生成纹理
    vector<Texture> loadMaterialTextures(aiMaterial *mat,aiTextureType type,string typeName){
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
                texture.id = TextureFromFile(str.data, this->directory);//文件名字 + 路径
//                printf("%s \n",str.C_Str());
                texture.type = typeName;
                texture.path = str.data;
                textures.push_back(texture);
                textures_loaded.push_back(texture);
            }
        }
        return textures;
    }
};


//加载纹理
unsigned int TextureFromFile(const char *path, const string &directory, bool gamma){
    string filename = string(path);
    replace(filename.begin(), filename.end(), '\\', '/');

    auto tryLoad = [](const string& fullPath, int& width, int& height, int& nrComponents) -> unsigned char* {
        return stbi_load(fullPath.c_str(), &width, &height, &nrComponents, 0);
    };

    // 候选路径：原相对路径 / 仅文件名 / textures/文件名（兼容 FBX 里的 Windows 绝对路径）
    vector<string> candidates;
    candidates.push_back(directory + '/' + filename);
    {
        size_t slash = filename.find_last_of('/');
        string base = (slash == string::npos) ? filename : filename.substr(slash + 1);
        candidates.push_back(directory + '/' + base);
        candidates.push_back(directory + "/textures/" + base);
    }

    unsigned int textureID;
    glGenTextures(1, &textureID);

    int width = 0, height = 0, nrComponents = 0;
    unsigned char *data = nullptr;
    string loadedPath;
    for (const auto& cand : candidates) {
        data = tryLoad(cand, width, height, nrComponents);
        if (data) { loadedPath = cand; break; }
    }

    if (data)
    {
        // OpenGL ES：统一按 RGBA 上传
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
        stbi_image_free(data);
        if (needFreeRgba) free(rgba);
    }
    else
    {
        // 占位：品红，方便辨认加载失败（不是资源没进 bundle 就会看到这个）
        unsigned char pink[] = { 255, 0, 255, 255 };
        glBindTexture(GL_TEXTURE_2D, textureID);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, pink);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        std::cout << "Texture failed to load at path: " << path << std::endl;
    }

    return textureID;
}


#endif /* model_h */
