# GL-ARKit

基于 **OpenGL ES 3** 的 iOS 演示工程：加载带骨骼动画的 FBX 模型（狼），并叠加 **Apple ARKit** 追踪（当前仅输出头/身/脸数据，尚未驱动模型）。

## 功能

- **FBX 模型加载**：通过 Assimp 加载 `Wolf-fbx` 下的狼模型与贴图
- **骨骼蒙皮动画**：解析 Assimp 动画剪辑，GPU 蒙皮绘制
- **动画切换 / 暂停**：顶部横向列表选择剪辑，Pause 按钮暂停/继续
- **相机控制**
  - 左下角 WASD / Up / Dn：前后左右上下移动
  - 单指拖动：旋转模型朝向
  - 双指捏合：缩放视野（FOV）
- **光照**：点光源 + 灯立方体示意，Blinn-Phong 风格着色
- **ARKit 追踪（dump）**
  - **Face 模式**（前置 TrueDepth）：头部位姿 + 面部 blendShapes + 脸部网格顶点数
  - **Body 模式**（后置摄像头）：身体骨骼关节 + 头部关节
  - Face / Body 不能同时跑（前后摄像头冲突）；用 `AR:Face` / `AR:Body` 按钮切换
  - 控制台约 0.5s 打一次完整日志；屏幕底部绿色标签显示摘要
  - **尚未与狼模型联动**

## 工程结构

```
GL-ARKit/
├── ARKit.xcodeproj/          # Xcode 工程
├── README.md
└── ARKit/                    # 源码与资源
    ├── arkit/                # Apple ARKit 模块（与 GL 模型解耦）
    │   ├── SCARTypes.*       # Head / Body / Face 数据结构
    │   └── SCARKitSession.*  # ARSession：Face / Body 配置与日志输出
    ├── other/                # App 入口与配置
    │   ├── main.m
    │   ├── AppDelegate.*
    │   ├── Info.plist        # 含 NSCameraUsageDescription
    │   └── Assets.xcassets
    ├── GameViewController.*  # UI：GL 视图 + 控制 + AR dump
    ├── SCRenderer.*          # ObjC++：EAGL 上下文、CADisplayLink、手势转发
    ├── SCRendererData.*      # C++：场景 init / update / render
    ├── model.h / mesh.h / animation.* / shader.h / Camera.h
    ├── gl_platform.h
    ├── shaders/
    ├── Wolf-fbx/
    ├── assimp/
    └── libs/                 # glm、stb_image
```

## 分层说明

| 层 | 职责 |
|----|------|
| `GameViewController` | UI + 启动 `SCARKitSession`；显示 AR 摘要，不改模型 |
| `arkit/SCARKitSession` | Apple ARKit Face / Body；回调与 NSLog 输出 |
| `SCRenderer` | OpenGL ES 视图与渲染循环 |
| `SCRendererData` | C++ 场景核心 |
| `Model` / `Mesh` / `Animation` | 资源与骨骼动画管线 |

## 运行

1. 用 Xcode 打开 `ARKit.xcodeproj`
2. **真机**运行（ARKit Face / Body 模拟器基本不可用）
   - Face：带 TrueDepth 的 iPhone（如 X 及以后多数机型）
   - Body：A12 及以上芯片
3. 授权相机后，看 Xcode 控制台 `[ARKit …]` 日志与屏幕底部摘要

## 依赖

| 库 | 用途 |
|----|------|
| OpenGL ES 3 | 渲染 |
| ARKit | 面部 / 身体追踪 |
| Assimp | FBX / 骨骼 / 动画导入 |
| GLM | 矩阵与向量 |
| stb_image | 纹理加载 |

## 操作一览

| 操作 | 效果 |
|------|------|
| 顶部动画条目 | 播放对应剪辑 |
| Pause | 暂停 / 继续动画 |
| AR:Face / AR:Body | 切换追踪模式并输出对应数据 |
| W A S D / Up / Dn | 相机移动 |
| 单指拖动 | 旋转模型 |
| 双指捏合 | 缩放视野 |
