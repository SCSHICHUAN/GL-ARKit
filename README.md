# GL-ARKit

基于 **OpenGL ES 3** 的 iOS 演示工程：加载 Assimp 模型（狼 FBX / 人模 GLB），用 **Apple ARKit Face Tracking** 驱动头部、眼球与表情；可选 Body Tracking 查看全身骨骼数据。

> 真机运行（Face 需 TrueDepth；Body 需 A12+）。模拟器无法完整验证 AR 驱动。

---

## 功能一览

| 功能 | 说明 |
|------|------|
| 多模型切换 | 顶部列表：`Wolf` / `Blackman` / `Whiteman`；切换时菊花遮罩 |
| 骨骼动画 | Assimp 剪辑列表 + Pause；Face 驱动时身体动画继续，表情叠加上去 |
| 相机 | WASD / Up / Dn；单指转模型；双指 FOV；按模型重置机位（狼更远） |
| AR Face → 模型 | 头姿、注视、眨眼、张嘴、眉嘴颊等表情 |
| AR Body | 关节 / 头数据摘要（不驱动当前人模） |
| 光照 | 点光 + Blinn-Phong；头发/毛皮双面与材质兜底 |

---

## 工程结构

```
GL-ARKit/
├── README.md
├── ARKit.xcodeproj/
└── ARKit/
    ├── arkit/                 # Apple ARKit 封装
    │   ├── SCARTypes.*        # Head / Body / Face 数据
    │   ├── SCARKitSession.*   # Face / Body Session
    │   └── SCARFaceProjector.*# blendShapes / 眼变换 → 驱动量
    ├── GL/                    # OpenGL ES 场景与 Assimp
    │   ├── SCRenderer.*       # EAGL + DisplayLink + 手势
    │   ├── SCRendererData.*   # 目录扫描、渲染、applyFaceDrive
    │   ├── model.h / mesh.h / animation.* / Camera.h / shader.h
    │   └── gl_platform.h
    ├── ocpp/                  # UI（GameViewController）
    ├── other/                 # App 入口、Info.plist、Assets
    ├── models/                # 运行时资源（CopyModels → bundle）
    │   ├── Wolf-fbx/
    │   ├── blackMan.glb
    │   └── whiteMan.glb
    ├── shaders/
    ├── assimp/                # 预编译 Assimp + 头文件
    └── libs/                  # glm、stb_image
```

构建只复制：`CopyShaders` + `CopyModels`（`ARKit/models` → bundle `models/`）。

---

## 数据流（Face 驱动）

```
ARFaceAnchor
  → SCARKitSession          # 头姿 / blendShapes / left·rightEyeTransform
  → SCARFaceProjector       # 平滑、校准、注视 pitch/yaw、眼/脸权重拆分
  → GameViewController      # 主队列合并回调
  → SCRenderer / SCRendererData::applyFaceDrive
       ├─ 头 / 颈骨
       ├─ 眼球骨（注视）
       ├─ 眼皮骨（blackMan 眨眼）
       └─ Morph（whiteMan 表情+眨眼；blackMan 嘴眉颊）
```

---

## 三个模型怎么驱动（必须区分）

| | **Wolf** | **blackMan** | **whiteMan** |
|---|----------|--------------|--------------|
| 格式 | FBX | GLB | GLB |
| Face 驱动 | 否（只播动画） | 是 | 是 |
| 骨架 | 游戏角色骨 | 细脸骨（jaw / eyelid / lips…） | 简骨（`Head` / `LeftEye` / `RightEye`） |
| 注视 | — | 只转 `c_eye_ref_track`（完整局部 replace） | 只给 `LeftEye`/`RightEye` **旋转增量**（勿写完整 orbit） |
| 眨眼 | — | **眼皮骨** `eyelid_top/bot` + `c_eyelid_*` | **Morph** `eyeBlink*` |
| 表情 | — | Morph（Apple 序 51）+ jaw 骨 | Morph（**Unity 序去 Look**，共 44） |
| 机位 | `z≈4.8` | `z≈2.8`，pitch≈−12° | 同左 |

`hasDetailedFaceBones()` 为 true → 走 blackMan 分支；否则走人模 morph 分支。

---

## 眼睛相关：踩过的坑与结论

### 1. 驱动错骨 / 叠错矩阵
- 曾转 `c_eye` / `c_eye_offset`：未蒙皮或带着整棵眼眶/眼皮子树 → 眼眶跟着跑。
- **结论（blackMan）**：注视只打 `c_eye_ref_track`；Animator 里对该骨 **replace** 完整局部矩阵（`T * gaze * RS`）。
- **结论（whiteMan）**：只能写 gaze 旋转叠在绑定上；写完整 orbit 会位移叠两次 → 眼球飞出眼眶。

### 2. 注视轴向与跳动
- ARKit 瞳孔朝 **+Z**；误用 −Z 时 yaw≈±π，`atan2` 跨缝狂跳。
- Look blendShape 与眼变换硬切也会跳。
- **结论**：用相对休息姿态的眼四元数 slerp，再解小角度 pitch/yaw；注视优先眼变换，Look 仅作无变换时的回退；上下 pitch 对角色局部取反。

### 3. 眨眼映射
- blackMan：控制器 `c_eyelid_top/bot` 几乎无蒙皮，父骨 `eyelid_top/bot` 不在 skin 表也要写 override；闭眼符号曾反（闭眼变睁眼）→ 仅在骨分支取反；眨眼 **不要再写 morph**，避免和骨打架。
- whiteMan：曾按 Apple「去 Look」表映射 44 morph，实际是 **Unity `ARKitBlendShapeLocation` 序去 Look**（眨眼在下标 8/9，`jawOpen` 在 16）→ 表情/眨眼全错位。

### 4. Morph 数据
- 多人模 GLB 把绝对 cm 坐标误标成 morph target；加载时检测 `maxAnim ≫ maxBase` 后按尺度转成真正位移。
- whiteMan 位移偏小，Face 驱动时对 morph 略放大（不影响 blackMan）。

---

## 其他碰到的问题（摘要）

| 问题 | 处理 |
|------|------|
| Face / Body 不能同时开 | UI 切换 `AR:Face` / `AR:Body` |
| AR 回调过密卡顿 | 主队列合并一帧一次；morph 权重变化阈值跳过 |
| 动画与表情互抢 | 身体动画继续播；头/脸/眼皮用 override 叠在动画上；眼球仍单独替换 |
| 头姿转整模 | 改为只转 head / neck |
| whiteMan 头发发黑 | 无 diffuse + 黑 baseColor → 白贴图/固色 + 双面 |
| 狼毛皮发黑环 | 有贴图时不再乘过暗 FBX 材质色；Fur cutout 固定棕色 |
| 人模初始化前倾 | glb 默认 `pitch = -12°` |
| 狼看不全 | FBX 初始相机 `z = 4.8` |
| 切换模型卡死无反馈 | 遮罩 + `UIActivityIndicator` |
| 工程里重复拷贝 Wolf | 已去掉 `CopyWolf` / `CopyWolfTex`，只保留 `CopyModels` |

---

## 本次整理改动

- 删除本地垃圾：`.DS_Store`、`xcuserdata`；`.gitignore` 补充忽略项
- 去掉重复的 Wolf 拷贝阶段（资源统一走 `models/`）
- 清理过时注释（`facial_animation` / Megumin /「dump only」等）
- README 与当前 Face 驱动、双人模差异对齐

---

## 关键源码

| 文件 | 职责 |
|------|------|
| `arkit/SCARKitSession.mm` | ARSession Face / Body |
| `arkit/SCARFaceProjector.m` | 注视与表情投射 |
| `ocpp/GameViewController.mm` | UI + AR→GL |
| `GL/SCRendererData.cpp` | `applyFaceDrive`、目录与机位 |
| `GL/model.h` | morph 名表（44 Unity / 51 Apple）、细脸骨检测 |
| `GL/animation.cpp` | 骨 override；`c_eye_ref_track` replace |
| `GL/mesh.h` | CPU morph 混合 + VBO 更新 |

---

## 运行

1. Xcode 打开 `ARKit.xcodeproj`
2. 真机运行，授权相机
3. 切到 **Blackman** 或 **Whiteman**，点 **AR:Face**，对着前置摄像头做表情
4. 绿字摘要：`DRIVE HEAD` / `EYE … blink=` / `FACE …`

---

## 操作

| 操作 | 效果 |
|------|------|
| 顶部模型芯片 | 切换 Wolf / 人模（带加载菊花） |
| 动画芯片 | 播放 Assimp 剪辑 |
| Pause | 暂停 / 继续（Face 驱动时动画本就会停） |
| AR:Face / AR:Body | 切换追踪 |
| W A S D / Up / Dn | 相机移动（前后较快，平移较慢） |
| 单指拖 | 模型 yaw / pitch |
| 双指捏合 | FOV |

---

## 依赖

| 库 | 用途 |
|----|------|
| OpenGL ES 3 | 渲染 |
| ARKit | Face / Body |
| Assimp | FBX / GLB / 骨骼 / morph |
| GLM | 矩阵 |
| stb_image | 纹理 |
