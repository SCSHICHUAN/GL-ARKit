# GL-ARKit

基于 **OpenGL ES 3** 的 iOS 演示工程：加载带骨骼动画的 FBX 模型（狼），并在屏幕上实时渲染与交互。

> 工程名含 “ARKit”，实际**未使用** Apple ARKit 框架，而是桌面端 OpenGL（GLFW）场景逻辑移植到 iOS（EAGL / `CAEAGLLayer`）。

## 功能

- **FBX 模型加载**：通过 Assimp 加载 `Wolf-fbx` 下的狼模型与贴图
- **骨骼蒙皮动画**：解析 Assimp 动画剪辑，GPU 蒙皮绘制
- **动画切换 / 暂停**：顶部横向列表选择剪辑，Pause 按钮暂停/继续
- **相机控制**
  - 左下角 WASD / Up / Dn：前后左右上下移动
  - 单指拖动：旋转模型朝向
  - 双指捏合：缩放视野（FOV）
- **光照**：点光源 + 灯立方体示意，Blinn-Phong 风格着色
- **横竖屏自适应**：framebuffer 随视图尺寸重建

## 工程结构

```
GL-ARKit/
├── ARKit.xcodeproj/          # Xcode 工程
├── README.md
└── ARKit/                    # 源码与资源
    ├── other/                # App 入口与配置
    │   ├── main.m
    │   ├── AppDelegate.*
    │   ├── Info.plist
    │   └── Assets.xcassets
    ├── GameViewController.*  # UI：嵌入 GL 视图 + 控制按钮/动画列表
    ├── SCRenderer.*          # ObjC++：EAGL 上下文、CADisplayLink、手势转发
    ├── SCRendererData.*      # C++：场景 init / update / render（原 GLFW main 逻辑）
    ├── model.h               # Assimp 模型、网格、骨骼、动画列表
    ├── mesh.h                # VBO/VAO、顶点属性（含骨索引与权重）
    ├── animation.h/.cpp      # Bone / Animation / Animator
    ├── shader.h              # 着色器编译与 uniform
    ├── Camera.h              # 自由相机
    ├── gl_platform.h         # iOS → GLES3，其它平台 → Glad
    ├── shaders/              # GLSL ES 着色器
    │   ├── colors-vs.vs / colors-fs.fs   # 模型 + 光照
    │   └── lamp-vs.vs / lamp-fs.fs       # 灯立方体
    ├── Wolf-fbx/             # 示例模型与纹理
    ├── assimp/               # Assimp 头文件与 iOS 库
    └── libs/
        ├── glm/              # 数学库
        └── stb_image.h       # 贴图解码
```

## 分层说明

| 层 | 职责 |
|----|------|
| `GameViewController` | 纯 UI：动画 CollectionView、Pause、移动摇杆；调用 `SCRenderer` API |
| `SCRenderer` | OpenGL ES 视图：创建缓冲区、`CADisplayLink` 渲染循环、触摸/捏合 → `SCRendererData` |
| `SCRendererData` | C++ 场景核心：加载资源、相机、动画状态机、每帧 update/render |
| `Model` / `Mesh` / `Animation` | 资源与骨骼动画管线 |

## 运行

1. 用 Xcode 打开 `ARKit.xcodeproj`
2. 选择真机或模拟器（需支持 **OpenGL ES 3**）
3. Build & Run

## 依赖

| 库 | 用途 |
|----|------|
| OpenGL ES 3 | 渲染 |
| Assimp | FBX / 骨骼 / 动画导入 |
| GLM | 矩阵与向量 |
| stb_image | 纹理加载 |

## 操作一览

| 操作 | 效果 |
|------|------|
| 顶部动画条目 | 播放对应剪辑 |
| Pause | 暂停 / 继续动画 |
| W A S D / Up / Dn | 相机移动 |
| 单指拖动 | 旋转模型 |
| 双指捏合 | 缩放视野 |
