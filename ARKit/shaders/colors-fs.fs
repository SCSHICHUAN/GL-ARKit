/* 
 fragment.strings
 ARKit
 
 Created by Stan on 2024/8/30.
 
 */
#version 300 es
precision highp float;
precision highp int;
out vec4 FragColor;
//物体材料
struct Material {
    sampler2D diffuse; //纹理慢反射
    sampler2D specular; //纹理镜面反射
    float shininess;//反射强度
};
//平行光
struct DirLight {
    vec3 direction; //平行光方向
    
    vec3 ambient; //环境强度
    vec3 diffuse; //漫反射强度
    vec3 specular; //镜面反射强度
};
//点光源
struct PointLight {
    vec3 position;//灯位置向量
    //衰减
    float constant;//常量
    float linear; //一次项
    float quadratic;//二次项
    
    vec3 ambient;//环境强度
    vec3 diffuse;//漫反射强度
    vec3 specular;//镜面反射强度
};
//手电筒
struct SpotLight {
    vec3 position;
    vec3 direction;
    float cutOff;
    float outerCutOff;
    //衰减
    float constant;//常量
    float linear; //一次项
    float quadratic;//二次项
  
    vec3 ambient;//环境强度
    vec3 diffuse;//漫反射强度
    vec3 specular;//镜面反射强度
};

#define NR_POINT_LIGHTS 4 //灯的个数
//输入
in vec3 FragPos;//片段向量
in vec3 Normal;//片段法向量
in vec2 TexCoords;//纹理坐标

uniform vec3 viewPos; //眼睛向量
uniform DirLight dirLight;//平行光结构体
uniform PointLight pointLights[NR_POINT_LIGHTS];//点光源数组
uniform SpotLight spotLight;//手电筒
uniform Material material;//物体材质结构体
uniform bool useAlphaCutout;
uniform bool hairSolidColor;
uniform vec4 materialColor;

// function prototypes 函数原型
vec3 CalcDirLight(DirLight light, vec3 normal, vec3 viewDir, vec3 albedo, vec3 specColor);//计算平行光
vec3 CalcPointLight(PointLight light, vec3 normal, vec3 fragPos, vec3 viewDir, vec3 albedo, vec3 specColor);//计算点光源
vec3 CalcSpotLight(SpotLight light, vec3 normal, vec3 fragPos, vec3 viewDir, vec3 albedo, vec3 specColor);//计算手电筒

void main()
{
    vec4 albedoSample = texture(material.diffuse, TexCoords);
    float outAlpha = 1.0;
    vec3 albedo = albedoSample.rgb;
    vec3 specColor = vec3(texture(material.specular, TexCoords));
    if (hairSolidColor) {
        // whiteMan 头发：无 diffuse，用发色常量
        albedo = materialColor.rgb;
        if (dot(albedo, vec3(1.0)) < 0.05) albedo = vec3(0.20, 0.14, 0.10);
        specColor = vec3(0.08);
        outAlpha = materialColor.a;
    } else if (useAlphaCutout) {
        // Wolf_Fur.jpg：黑毛+白底，亮度反推 cutout；毛色固定，不乘材质底色
        float luma = dot(albedoSample.rgb, vec3(0.299, 0.587, 0.114));
        outAlpha = 1.0 - luma;
        outAlpha = smoothstep(0.15, 0.85, outAlpha);
        if (outAlpha < 0.1) discard;
        albedo = vec3(0.22, 0.18, 0.14);
        specColor = vec3(0.05);
    } else if (albedoSample.a < 0.99) {
        outAlpha = albedoSample.a;
        if (outAlpha < 0.08) discard;
    }

    // properties
    vec3 norm = normalize(Normal);
    vec3 viewDir = normalize(viewPos - FragPos);//观看方向向量
    
    // == =====================================================
    // Our lighting is set up in 3 phases: directional, point lights and an optional flashlight
    // For each phase, a calculate function is defined that calculates the corresponding color
    // per lamp. In the main() function we take all the calculated colors and sum them up for
    // this fragment's final color.
    // == =====================================================
    // phase 1: directional lighting
    vec3 result = CalcDirLight(dirLight, norm, viewDir, albedo, specColor);
    // phase 2: point lights
    for(int i = 0; i < NR_POINT_LIGHTS; i++)
        result += CalcPointLight(pointLights[i], norm, FragPos, viewDir, albedo, specColor);
    // phase 3: spot light
    result += CalcSpotLight(spotLight, norm, FragPos, viewDir, albedo, specColor);
    
    FragColor = vec4(result, outAlpha);
}

// calculates the color when using a directional light.计算平行光
vec3 CalcDirLight(DirLight light, vec3 normal, vec3 viewDir, vec3 albedo, vec3 specColor)
{
    vec3 lightDir = normalize(-light.direction);//平行光方向 不考虑灯的位置
    // diffuse shading 慢反射
    float diff = max(dot(normal, lightDir), 0.0);//平行光向量和法向量点积
    // specular shading
    vec3 reflectDir = reflect(-lightDir, normal);//镜面反射向量
    float spec = pow(max(dot(viewDir, reflectDir), 0.0), material.shininess);//镜面反射向量和眼睛向量点积
    // combine results
    vec3 ambient = light.ambient * albedo;
    vec3 diffuse = light.diffuse * diff * albedo;
    vec3 specular = light.specular * spec * specColor;
    return (ambient + diffuse + specular);
}

// calculates the color when using a point light.计算点光源
vec3 CalcPointLight(PointLight light, vec3 normal, vec3 fragPos, vec3 viewDir, vec3 albedo, vec3 specColor)
{
    vec3 lightDir = normalize(light.position - fragPos);//灯相对片段的方向向量
    // diffuse shading 漫反射
    float diff = max(dot(normal, lightDir), 0.0);//灯相对片段的方向向量和法向量点积
    // specular shading 镜面反射
    vec3 reflectDir = reflect(-lightDir, normal);//镜面反射向量
    float spec = pow(max(dot(viewDir, reflectDir), 0.0), material.shininess);//镜面反射向量和眼睛向量点积
    // attenuation 衰减
    float distance = length(light.position - fragPos);
    float attenuation = 1.0 / (light.constant + light.linear * distance + light.quadratic * (distance * distance));
    // combine results
    vec3 ambient = light.ambient * albedo;
    vec3 diffuse = light.diffuse * diff * albedo;
    vec3 specular = light.specular * spec * specColor;
    ambient *= attenuation;
    diffuse *= attenuation;
    specular *= attenuation;
    return (ambient + diffuse + specular);
}

// calculates the color when using a spot light.解释聚光
vec3 CalcSpotLight(SpotLight light, vec3 normal, vec3 fragPos, vec3 viewDir, vec3 albedo, vec3 specColor)
{
    vec3 lightDir = normalize(light.position - fragPos);//灯相对片段的方向向量
    // diffuse shading 漫反射
    float diff = max(dot(normal, lightDir), 0.0);//灯相对片段的方向向量和法向量点积
    // specular shading 镜面反射
    vec3 reflectDir = reflect(-lightDir, normal);//镜面反射向量
    float spec = pow(max(dot(viewDir, reflectDir), 0.0), material.shininess);//镜面反射向量和眼睛向量点积
    // attenuation 衰减
    float distance = length(light.position - fragPos);//灯和片段的距离
    float attenuation = 1.0 / (light.constant + light.linear * distance + light.quadratic * (distance * distance));
    // spotlight intensity 聚光灯下的强度
    float theta = dot(lightDir, normalize(-light.direction));//灯相对片段的方向向量和灯光方向向量点积
    float epsilon = light.cutOff - light.outerCutOff;//内外锥余弦值差
    float intensity = clamp((theta - light.outerCutOff) / epsilon, 0.0, 1.0);//强度规划到0~1
    // combine results 合并结果
    vec3 ambient = light.ambient * albedo;
    vec3 diffuse = light.diffuse * diff * albedo;
    vec3 specular = light.specular * spec * specColor;
    ambient *= attenuation * intensity; //环境 = 衰减 x 聚光强度
    diffuse *= attenuation * intensity;
    specular *= attenuation * intensity;
    return (ambient + diffuse + specular);
}
