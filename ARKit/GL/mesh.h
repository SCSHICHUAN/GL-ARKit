//
//  mesh.h
//  ARKit
//
//  Created by Stan on 2024/9/21.
//

#ifndef mesh_h
#define mesh_h

#include "gl_platform.h"
#include <iostream>
#include <cmath>
#include "shader.h"

#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>

#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <utility>
#include <cctype>

using namespace std;
#define MAX_BONE_INFLUENCE 4

struct Vertex {
    glm::vec3 Position; //顶点向量
    glm::vec3 Normal;   //顶点法向量
    glm::vec2 TexCoords;//纹理坐标

    glm::vec3 Tangent;
    glm::vec3 Bitangent;
    // OpenGL ES：用 float 传骨骼 id（避免 ivec4 / glVertexAttribIPointer 在模拟器上读错）
    float m_BoneIDs[MAX_BONE_INFLUENCE];
    float m_Weights[MAX_BONE_INFLUENCE];

    Vertex() {
        for (int i = 0; i < MAX_BONE_INFLUENCE; i++) {
            m_BoneIDs[i] = -1.0f;
            m_Weights[i] = 0.0f;
        }
    }

    void addBoneData(int boneID, float weight) {
        for (int i = 0; i < MAX_BONE_INFLUENCE; i++) {
            if ((int)m_BoneIDs[i] == boneID) {
                m_Weights[i] += weight;
                return;
            }
        }

        for (int i = 0; i < MAX_BONE_INFLUENCE; i++) {
            if (m_BoneIDs[i] < 0.0f) {
                m_BoneIDs[i] = (float)boneID;
                m_Weights[i] = weight;
                return;
            }
        }

        int minWeightIndex = 0;
        float minWeight = m_Weights[0];
        for (int i = 1; i < MAX_BONE_INFLUENCE; i++) {
            if (m_Weights[i] < minWeight) {
                minWeight = m_Weights[i];
                minWeightIndex = i;
            }
        }
        if (weight > minWeight) {
            m_BoneIDs[minWeightIndex] = (float)boneID;
            m_Weights[minWeightIndex] = weight;
        }
    }
};

struct Texture {
    unsigned int id; //纹理id
    string type;     //纹理类型
    string path;
};

class Mesh {
public:
    vector<Vertex>      vertices;  //顶点向量数组
    vector<unsigned int> indices;  //纹理ID数组
    vector<Texture>     textures;  //纹理数组
    /// local bone slot → global bone id（供蒙皮调色板上传；空=无蒙皮）
    vector<int>         bonePalette;
    /// bind 姿势顶点（有 morph 时用于每帧混合）
    vector<glm::vec3>   bindPositions;
    /// morph 位移（米）：[morphIndex][vertIndex]
    vector<vector<glm::vec3>> morphDeltas;
    vector<string>      morphNames;
    /// 上次写入的 morph 权重（用于跳过无变化帧）
    vector<float>       lastMorphWeights;
    /// 材质底色（glTF baseColorFactor）；无贴图时仍相乘
    glm::vec4           materialColor{1.0f, 1.0f, 1.0f, 1.0f};
    bool                doubleSided = false;
    bool                isHair = false;
    
    unsigned int VAO;
    // constructor
    Mesh(vector<Vertex> vertices, vector<unsigned int> indices, vector<Texture> textures,
         vector<int> bonePalette = {},
         vector<vector<glm::vec3>> morphDeltas = {},
         vector<string> morphNames = {}){
        this->vertices = std::move(vertices);
        this->indices  = std::move(indices);
        this->textures = std::move(textures);
        this->bonePalette = std::move(bonePalette);
        this->morphDeltas = std::move(morphDeltas);
        this->morphNames = std::move(morphNames);
        if (!this->morphDeltas.empty()) {
            this->bindPositions.resize(this->vertices.size());
            for (size_t i = 0; i < this->vertices.size(); ++i)
                this->bindPositions[i] = this->vertices[i].Position;
        }
        setupMesh();
    }

    bool hasMorphTargets() const { return !morphDeltas.empty(); }

    void setMorphWeights(const vector<float>& weights) {
        if (morphDeltas.empty() || bindPositions.empty()) return;
        const size_t nMorph = morphDeltas.size();
        const size_t nVert = bindPositions.size();

        // 权重几乎没变就跳过（AR 回调很密，这是卡顿主因之一）
        if (lastMorphWeights.size() == nMorph) {
            bool same = true;
            const size_t nCmp = std::min(nMorph, weights.size());
            for (size_t mi = 0; mi < nCmp; ++mi) {
                if (fabsf(weights[mi] - lastMorphWeights[mi]) > 0.012f) { same = false; break; }
            }
            if (same) return;
        }

        // 只混合激活的 morph，避免 verts × 51 的空转
        struct Active { size_t mi; float w; };
        std::vector<Active> active;
        active.reserve(16);
        for (size_t mi = 0; mi < nMorph; ++mi) {
            const float w = (mi < weights.size()) ? weights[mi] : 0.0f;
            if (fabsf(w) < 0.012f) continue;
            active.push_back({mi, w});
        }

        lastMorphWeights.assign(nMorph, 0.0f);
        for (size_t mi = 0; mi < std::min(nMorph, weights.size()); ++mi)
            lastMorphWeights[mi] = weights[mi];

        if (active.empty()) {
            for (size_t vi = 0; vi < nVert; ++vi)
                vertices[vi].Position = bindPositions[vi];
            uploadPositions();
            return;
        }

        for (size_t vi = 0; vi < nVert; ++vi) {
            glm::vec3 p = bindPositions[vi];
            for (const Active& a : active)
                p += a.w * morphDeltas[a.mi][vi];
            vertices[vi].Position = p;
        }
        uploadPositions();
    }

    void clearMorphWeights() {
        if (bindPositions.empty()) return;
        for (size_t i = 0; i < bindPositions.size(); ++i)
            vertices[i].Position = bindPositions[i];
        lastMorphWeights.clear();
        uploadPositions();
    }
    
    //tender the mesh
    void Draw(Shader &shader, const map<int, glm::mat4>* globalBoneMatrices = nullptr){
        // 按本 mesh 调色板上传 finalBonesMatrices[local] = global[palette[local]]
        {
            const int kMaxBones = 100;
            glm::mat4 identity(1.0f);
            const int n = std::min((int)bonePalette.size(), kMaxBones);
            for (int local = 0; local < kMaxBones; ++local) {
                glm::mat4 m = identity;
                if (local < n && globalBoneMatrices) {
                    auto it = globalBoneMatrices->find(bonePalette[local]);
                    if (it != globalBoneMatrices->end())
                        m = it->second;
                }
                string uniformName = "finalBonesMatrices[" + to_string(local) + "]";
                shader.setMat4(uniformName.c_str(), m);
            }
        }

        unsigned int diffuseNr  = 1;
        unsigned int specularNr = 1;
        unsigned int normalNr   = 1;
        unsigned int heightNr   = 1;

        bool useAlphaCutout = isHair;
        bool hasDiffuse = false;

        static GLuint whiteTex = 0;
        if (!whiteTex) {
            unsigned char white[] = { 255, 255, 255, 255 };
            glGenTextures(1, &whiteTex);
            glBindTexture(GL_TEXTURE_2D, whiteTex);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, white);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        }

        for(unsigned int i = 0; i < textures.size(); i++){
            glActiveTexture(GL_TEXTURE0 + i);
            glBindTexture(GL_TEXTURE_2D,textures[i].id);

            string name = textures[i].type;
            if(name == "texture_diffuse"){
                name = "material.diffuse";
                hasDiffuse = true;
                diffuseNr++;
            }else if (name == "texture_specular"){
                name = "material.specular";
                specularNr++;
            }else if (name == "texture_normal"){
                name = "texture_normal";
                normalNr++;
            }else if (name == "texture_height"){
                name = "texture_height";
                heightNr++;
            }
            shader.setInt(name.c_str(), (int)i);

            if (textures[i].type == "texture_diffuse") {
                string pl = textures[i].path;
                for (char& c : pl) c = (char)tolower((unsigned char)c);
                // 路径或文件名含 fur（Wolf_Fur.jpg）都启用 cutout
                if (pl.find("fur") != string::npos || pl.find("hair") != string::npos)
                    useAlphaCutout = true;
            }
        }

        // 只有法线/无 diffuse（whiteMan 头发常见）：必须绑白贴图，否则 ES 上 sampler 未定义
        if (!hasDiffuse) {
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, whiteTex);
            shader.setInt("material.diffuse", 0);
            if (specularNr == 1)
                shader.setInt("material.specular", 0);
        } else if (specularNr == 1) {
            shader.setInt("material.specular", 0);
        }

        shader.setBool("useAlphaCutout", useAlphaCutout);
        shader.setBool("hairSolidColor", isHair && !hasDiffuse);
        shader.setVec4("materialColor", materialColor);

        GLboolean wasCull = glIsEnabled(GL_CULL_FACE);
        if (doubleSided || isHair) glDisable(GL_CULL_FACE);

        glBindVertexArray(VAO);
        glDrawElements(GL_TRIANGLES,static_cast<unsigned>(indices.size()),GL_UNSIGNED_INT,0);
        glBindVertexArray(0);

        if (wasCull) glEnable(GL_CULL_FACE);
        glActiveTexture(GL_TEXTURE0);
    }

    /// OpenGL ES：VAO 不跨 context 共享；后台 sharegroup 加载后须在主 context 重建 VAO（VBO/EBO/纹理可共享）
    void rebindVAOOnCurrentContext() {
        if (!VBO || !EBO) return;
        glGenVertexArrays(1, &VAO);
        glBindVertexArray(VAO);
        glBindBuffer(GL_ARRAY_BUFFER, VBO);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, EBO);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)offsetof(Vertex, Normal));
        glEnableVertexAttribArray(2);
        glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)offsetof(Vertex, TexCoords));
        glEnableVertexAttribArray(3);
        glVertexAttribPointer(3, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)offsetof(Vertex, Tangent));
        glEnableVertexAttribArray(4);
        glVertexAttribPointer(4, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)offsetof(Vertex, Bitangent));
        glEnableVertexAttribArray(5);
        glVertexAttribPointer(5, 4, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)offsetof(Vertex, m_BoneIDs));
        glEnableVertexAttribArray(6);
        glVertexAttribPointer(6, 4, GL_FLOAT, GL_FALSE, sizeof(Vertex), (void *)offsetof(Vertex, m_Weights));
        glBindVertexArray(0);
    }

private:
    unsigned int VBO,EBO;
    
    void uploadPositions() {
        if (!VBO || vertices.empty()) return;
        glBindBuffer(GL_ARRAY_BUFFER, VBO);
        // Position 在 Vertex 开头；整包更新更简单稳妥
        glBufferSubData(GL_ARRAY_BUFFER, 0, vertices.size() * sizeof(Vertex), vertices.data());
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }

    void setupMesh(){
        //创建
        glGenVertexArrays(1,&VAO);
        glGenBuffers(1,&VBO);
        glGenBuffers(1,&EBO);
        
        glBindVertexArray(VAO);//绑定VAO
        
        //绑定VBO 和 导入数据（有 morph 时 DYNAMIC，便于每帧改顶点）
        glBindBuffer(GL_ARRAY_BUFFER,VBO);
        const GLenum usage = morphDeltas.empty() ? GL_STATIC_DRAW : GL_DYNAMIC_DRAW;
        glBufferData(GL_ARRAY_BUFFER,vertices.size() * sizeof(Vertex),&vertices[0],usage);
        //绑定VBO 和 导入数据
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,EBO);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER,indices.size() * sizeof(unsigned int),&indices[0],GL_STATIC_DRAW);
        
        //VAO 说明顶点属性 利用struct vector 中储存的特点,连续的数据
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,sizeof(Vertex),(void*)0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,sizeof(Vertex),(void*)offsetof(Vertex, Normal));
        glEnableVertexAttribArray(2);
        glVertexAttribPointer(2,2,GL_FLOAT,GL_FALSE,sizeof(Vertex),(void*)offsetof(Vertex, TexCoords));
        glEnableVertexAttribArray(3);
        glVertexAttribPointer(3,3,GL_FLOAT,GL_FALSE,sizeof(Vertex),(void*)offsetof(Vertex, Tangent));
        glEnableVertexAttribArray(4);
        glVertexAttribPointer(4,3,GL_FLOAT,GL_FALSE,sizeof(Vertex),(void*)offsetof(Vertex, Bitangent));
        glEnableVertexAttribArray(5);
        glVertexAttribPointer(5,4,GL_FLOAT,GL_FALSE,sizeof(Vertex),(void*)offsetof(Vertex, m_BoneIDs));
        glEnableVertexAttribArray(6);
        glVertexAttribPointer(6,4,GL_FLOAT,GL_FALSE,sizeof(Vertex),(void*)offsetof(Vertex, m_Weights));
        
        //解绑VAO
        glBindVertexArray(0);
    }
};





#endif /* mesh_h */
