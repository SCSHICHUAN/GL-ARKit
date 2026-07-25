/* 
  vertex.strings
  ARKit

  Created by Stan on 2024/8/12.
  
*/
#version 300 es
precision highp float;
precision highp int;
layout (location = 0) in vec3 aPos;   //顶点向量
layout (location = 1) in vec3 aNormal; //法线向量
layout (location = 2) in vec2 aTexCoords; //纹理坐标
layout (location = 5) in vec4 aBoneIDs;  // 骨骼索引（float 传入，与 OpenGL ES 兼容）
layout (location = 6) in vec4 aWeights;   // 每根骨的权重，最多 4 根骨叠加

//输出
out vec3 FragPos;
out vec3 Normal;
out vec2 TexCoords;

uniform mat4 model;
uniform mat4 view;
uniform mat4 projection;

const int MAX_BONES = 100;
uniform mat4 finalBonesMatrices[MAX_BONES]; // CPU 按 currentTime 算好的蒙皮矩阵

void main()
{
    vec4 totalPosition = vec4(0.0f);
    vec3 totalNormal = vec3(0.0f);
    bool hasBoneInfluence = false;

    // 加权蒙皮：total += weight * finalBonesMatrices[boneID] * vec4(aPos,1)
    for(int i = 0 ; i < 4 ; i++)
    {
        int boneId = int(aBoneIDs[i]);
        if(boneId < 0)
            continue;
        if(boneId >= MAX_BONES)
        {
            totalPosition = vec4(aPos, 1.0f);
            totalNormal = aNormal;
            break;
        }

        vec4 localPosition = finalBonesMatrices[boneId] * vec4(aPos, 1.0f);
        totalPosition += localPosition * aWeights[i];

        vec3 localNormal = mat3(finalBonesMatrices[boneId]) * aNormal;
        totalNormal += localNormal * aWeights[i];
        hasBoneInfluence = true;
    }

    // 如果模型没有骨骼/权重数据（如普通 obj），走常规顶点变换，避免所有顶点塌缩到原点
    if(!hasBoneInfluence) {
        totalPosition = vec4(aPos, 1.0f);
        totalNormal = aNormal;
    }

    FragPos = vec3(model * totalPosition);
    Normal = mat3(transpose(inverse(model))) * totalNormal;//法向量防止物体拉升而丢失
    TexCoords = aTexCoords;

    // 蒙皮后再做整模型 model、相机 view、投影 projection
    gl_Position = projection * view * model * totalPosition;
}
