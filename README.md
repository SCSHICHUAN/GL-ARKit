# GL-ARKit

基于 **OpenGL ES 3** 的 iOS 演示：Assimp 加载模型（Wolf FBX / blackMan·whiteMan GLB），用 **ARKit Face Tracking** 驱动头、眼、眉、嘴、舌等；Face 模式下用 **Vision** 估肩线做 whiteMan 躯干左右倾。

> 真机运行（Face 需 TrueDepth；Body 需 A12+）。模拟器无法完整验证。

---

## 功能一览

| 功能 | 说明 |
|------|------|
| 多模型 | `Wolf` / `BlackMan` / `WhiteMan`；切换带加载遮罩 |
| 骨骼动画 | Assimp 剪辑 + Pause；Face 时身体动画继续，表情/头眼叠加上去 |
| 相机 | WASD / Up / Dn；单指转模型；双指 FOV |
| AR Face → 模型 | 头姿、注视、眨眼、眉、嘴、舌、颊鼻等 |
| Vision 上体 | 仅 **whiteMan** 左右倾 ±40°；**blackMan / Wolf 不做** |
| AR Body | 关节摘要（不驱动当前人模） |
| RTMP 推流 | **Avatar**（GL 离屏）或 **Cam**；H.264 + AAC → librtmp |

---

## 工程结构

```
GL-ARKit/
├── README.md
├── ARKit.xcodeproj/
└── ARKit/
    ├── arkit/
    │   ├── SCARTypes.*              # Head / Body / Face DTO
    │   ├── SCARKitSession.*         # Face / Body Session；帧回调投递画面
    │   ├── SCARFaceProjector.*      # blendShapes + 眼变换 → 驱动量
    │   ├── SCARUpperBodyProjector.* # Vision → torsoLean
    │   └── SCARPixelBufferCopy.*    # AR 画面 CPU 深拷贝（给 Vision）
    ├── GL/
    │   ├── SCRenderer.* / SCRendererData.*  # 渲染 + applyFaceDrive / lean
    │   ├── model.h / mesh.h / animation.*   # Assimp、morph 名表、骨 override
    │   └── …
    ├── ocpp/GameViewController.mm   # UI + AR→GL 合并 + 推流控件
    ├── liveStream/                  # RTMP 推流（见下文「GL → 视频」）
    │   ├── PushStream.*             # 门面：Avatar / Cam、画质、FPS
    │   ├── SCRenderCapture.*        # GL 离屏 → CVPixelBuffer
    │   ├── H264Encoder.* / AACEncoder.*
    │   ├── VideoCapture.* / AudioCapture.*
    │   ├── RTMPStreamer.*           # FLV Tag → librtmp
    │   └── rtmp/                    # librtmp + openssl 静态库
    ├── models/                      # CopyModels → bundle
    ├── shaders/ / assimp/ / libs/
```

---

## 数据流

```
ARFaceAnchor (+ ARFrame.capturedImage，仅 whiteMan lean)
  → SCARKitSession
  → SCARFaceProjector          # 头 / 眼 / 眉嘴颊舌权重
  → SCARUpperBodyProjector     # 肩线 → lean（忙则丢帧）
  → GameViewController         # 主队列合并 Face；DisplayLink 写 lean
  → SCRendererData
       applyFaceDrive          # 头骨 + 眼 + jaw骨 + morph
       applyUpperBodyLean      # Spine1/Spine2（仅 whiteMan）
```

Face 与 Body 不能同时开（前后摄不同）。切 Body 时清空 Face / lean。

---

## ARKit 怎么映射到角色

### 总原则

| 环节 | 作用 |
|------|------|
| `ARFaceAnchor.blendShapes` | 52 个 `ARBlendShapeLocation` 权重 0..1 |
| `leftEyeTransform` / `rightEyeTransform` | 注视方向（优先于 Look 类 blendShape） |
| `transform`（头） | 相对「休息姿态」的四元数 → yaw / pitch / roll |
| Vision `VNDetectHumanBodyPose` | 双肩连线倾角 → 躯干 lean（非 AR Body） |

`SCARFaceProjector` 只做规范化与平滑，**不写骨骼**。真正绑骨/morph 在 `SCRendererData::applyFaceDrive`。

人模分支：

| | **blackMan** | **whiteMan** |
|--|--------------|--------------|
| 判定 | `hasDetailedFaceBones()`（有 jawbone / eyelid 等） | 否则（简骨 + 44 morph） |
| Morph 名表 | Apple 序，脸 mesh 常 **51**（无 `tongueOut`）或 49 | **Unity ARKit 序去掉 8 个 Look**，共 **44** |
| 眨眼 | **眼皮骨** | **Morph** `eyeBlink*` |
| 张嘴 | **颌骨** `jawbone` / `c_jawbone` | **Morph** `jawOpen` 等 |
| 注视 | `c_eye_ref_track` **整局部 replace** | `LeftEye` / `RightEye` **只叠旋转** |

Wolf：无 Face 驱动（无可用头骨/morph 管线），只播动画。

---

### 1. 头（Head）

**ARKit 源**

- `ARFaceAnchor.transform` → 四元数  
- Projector：相对首次/校准休息姿态做 `relOri`，再指数平滑  
- VC：四元数 → yaw / pitch / roll（并钳制）

**角色**

- 只驱动 **一根** head + **一根** neck（优先变形骨 `head.x` / `neck.x`，避免 ARP 的 `c_head`+`head` 父子双写）  
- Animator：`nodeLocal = animLocal × override`（增量叠在动画上）  
- 显示侧再对 YPR 做 SmoothDamp，减轻 blackMan 重 `applyFaceDrive` 被合并后的「头卡」

**不做**：转整模、转 hips/spine 当头。

---

### 2. 眼球注视（Gaze）

**ARKit 源（优先）**

- `leftEyeTransform` / `rightEyeTransform`  
- Apple：局部 **+Z** 指向瞳孔前方（不是 −Z）  
- 相对休息眼四元数 → 小角度 pitch / yaw（避免 ±π 跳变）

**回退**：无眼变换时用 `eyeLook*` blendShape（少用，易与变换硬切）。

**角色**

| 模型 | 骨 | 矩阵写法 |
|------|-----|----------|
| blackMan | `c_eye_ref_track.l/r` | 完整局部 `T * gaze * RS`，Animator **replace** |
| whiteMan | `LeftEye_*` / `RightEye_*` | 仅 gaze 旋转，`bind * R`；禁止写完整 orbit |

角色局部抬头方向与 ARKit pitch 符号相反 → 应用前对 pitch **取反**。

---

### 3. 眨眼 / 眯眼 / 睁大

**ARKit 源**：`eyeBlinkLeft/Right`、`eyeSquint*`、`eyeWide*`

| 模型 | 映射 |
|------|------|
| blackMan | 骨：`eyelid_top/bot`（及 skin 的 `c_eyelid_*`）；上睑 −Rx、下睑 +Rx 闭眼；**不再写 blink morph** |
| whiteMan | Morph：`eyeBlink*` 等（Unity 去 Look 表里下标约 8/9） |

---

### 4. 眉毛

**ARKit 源**：`browDownLeft/Right`、`browInnerUp`、`browOuterUpLeft/Right`

**角色**：两侧人模都走 **Morph**（名表按模型序）。不单独转 eyebrow 骨（避免与 morph 叠两层）。

---

### 5. 嘴 / 颌

**ARKit 源（节选）**

- 颌：`jawOpen`、`jawLeft`、`jawRight`、`jawForward`  
- 嘴：`mouthSmile*`、`mouthFunnel`、`mouthPucker`、`mouthClose`、`mouthUpperUp*`、`mouthLowerDown*`、`mouthRoll*`、`mouthShrug*`、`mouthPress*`、`mouthStretch*`、`mouthDimple*`、`mouthFrown*`、`mouthLeft/Right` 等

| 模型 | 张嘴 / 颌 | 其余嘴形 |
|------|-----------|----------|
| blackMan | **骨** `c_jawbone` / `jawbone.x`（`jawOpen` 扣一点 `mouthClose`） | Morph；并从 morph 里 **去掉** jaw*，避免和骨打架 |
| whiteMan | Morph（含 `jawOpen`@Unity 去 Look 序约 16） | Morph |

---

### 6. 舌头

**ARKit 源**：`tongueOut`

| 模型 | 处理 |
|------|------|
| whiteMan（44） | Morph 名表含 `tongueOut` → 有目标则驱动 |
| blackMan（51） | Apple 表截断到 51，**通常无 tongueOut 槽** → 吐舌无效果属资源限制 |
| 有舌骨的定制模 | 本工程未绑舌骨，只走 morph |

---

### 7. 颊 / 鼻（顺带）

- `cheekPuff`、`cheekSquint*` → Morph  
- `noseSneer*` → Morph  

---

### 8. 躯干（Torso lean）

**不是** ARKit Body（Face 模式开不了全身骨骼）。

**做法**

1. `ARFrame.capturedImage` 仅在 `didUpdateFrame` 回调内有效  
2. `SCARUpperBodyProjector`：空闲才 **CPU 深拷贝** + Vision `VNDetectHumanBodyPose`  
3. 双肩点 → `atan2` 得左右倾，钳制 **±40°**，轻度 EMA  
4. `applyUpperBodyLean`：只打 whiteMan 的 **Spine1 / Spine2**（不上最下段 Spine，避免胯/裆歪）  
5. 显示侧 SmoothDamp；**blackMan 在 VC 跳过 Vision**（骨轴/头链不合，且拷贝拖慢头脸）

Wolf：无 Spine1/2 → lean 自动 skip。

---

## 模型对照表

| | **Wolf** | **blackMan** | **whiteMan** |
|--|----------|--------------|--------------|
| Face | 否 | 是 | 是 |
| 头骨 | — | 单根 `head.x` 优先 | 单根 `Head_*` 等 |
| 注视 | — | `c_eye_ref_track` replace | `LeftEye`/`RightEye` 旋转增量 |
| 眨眼 | — | 眼皮骨 | Morph |
| 眉/嘴/颊/鼻 | — | Morph（Apple 序） | Morph（Unity 去 Look） |
| 舌 | — | 多无 morph 槽 | Morph `tongueOut` |
| 躯干 lean | 否 | 否 | Spine1/2，±40° |

---

## 坑（踩过的结论）

### Face / 眼 / morph

1. **转错眼骨**：`c_eye` / `c_eye_offset` 会带着眼眶/眼皮；blackMan 只打 `c_eye_ref_track`。  
2. **whiteMan 写完整 orbit**：位移叠两次 → 眼球飞出；只能 `bind * R`。  
3. **注视用 −Z**：yaw 落在 ±π，`atan2` 狂跳；必须用 +Z + 相对休息四元数。  
4. **Look 权重与眼变换硬切**：正前方跳动；注视以眼变换为准。  
5. **blackMan 眨眼再写 morph**：和眼皮骨方向打架；blink 只走骨。  
6. **眼皮符号反了**：闭眼变睁眼；上睑 −Rx、下睑 +Rx。  
7. **父级 eyelid 不在 skin 表**：也要从节点树写 override。  
8. **44 morph 当成 Apple「去 Look」**：实际是 **Unity 枚举序去 Look**（blink@8/9，jawOpen@16），序错则全脸错位。  
9. **GLB morph 是绝对坐标**：加载时若 `maxAnim ≫ maxBase` 需换成位移；whiteMan 位移偏小可对 morph 略增益。  
10. **头打 c_head + head**：父子同增量 → 头卡；只留一根变形骨 + YPR 平滑。

### 躯干 / Vision / 性能

11. **ARFrame 缓冲跨帧用**：野指针 / `EXC_BREAKPOINT`；回调内用完或立刻 CPU 拷贝。  
12. **Metal CIContext 缩放 + OpenGL**：GPU 冲突崩溃；缩放/拷贝用 CPU。  
13. **每帧全分辨率拷贝**：主线程卡顿；仅 Vision 空闲时拷一帧。  
14. **blackMan 仍跑 Vision**：拖慢头脸；lean 本就 disable，VC 直接跳过投递。  
15. **lean 打最下 Spine**：像从胯歪；只用 Spine1/Spine2。  
16. **Face 回调过密**：主队列合并；blackMan `applyFaceDrive` 重，头靠显示帧 SmoothDamp 补间。

### 工程 / 其它

17. Face / Body 不能同时开。  
18. 动画与表情：身体继续播，头脸眼用 override；眼球 blackMan 为 replace。  
19. 人模初始前倾：glb 默认 pitch≈−12°。  
20. 头发/毛皮发黑：材质与双面兜底（见历史提交）。

### 推流

21. **全屏 glReadPixels 推流**：主线程/渲染卡死；用编码尺寸离屏 + TextureCache。  
22. **Avatar 视频 PTS 从 0、音频用主机绝对时间**：播放器狂缓冲；RTMP 统一相对时钟。  
23. **用编码结束时间做 FPS 限帧**：编码耗时会把 60 打成 ~30；现跟 DisplayLink，不再软件限帧。

---

## 关键源码

| 文件 | 职责 |
|------|------|
| `arkit/SCARKitSession.mm` | Face / Body；`didUpdateCapturedImage` |
| `arkit/SCARFaceProjector.m` | 头/眼/52 名权重平滑与别名 |
| `arkit/SCARUpperBodyProjector.m` | Vision lean ±40° |
| `arkit/SCARPixelBufferCopy.m` | 画面 CPU 拷贝 |
| `ocpp/GameViewController.mm` | UI；Face 合并；blackMan 跳过 Vision |
| `GL/SCRendererData.cpp` | `applyFaceDrive` / lean / 头骨缓存与平滑 |
| `GL/model.h` | morph 名表（44 Unity / 51 Apple）、细脸骨检测 |
| `GL/animation.cpp` | 骨 override；眼 replace vs 头脸相乘 |
| `liveStream/PushStream.m` | 推流编排 Avatar/Cam |
| `liveStream/SCRenderCapture.m` | 离屏 FBO + TextureCache |
| `liveStream/H264Encoder.m` | VideoToolbox → AVCC |
| `liveStream/RTMPStreamer.m` | FLV + RTMP |

---

## GL → 视频推流（Avatar）

默认 **Src=Avatar · Vid=360×780 · 60fps**。核心：**不要**全屏 `glReadPixels`，而是按编码分辨率离屏直写 `CVPixelBuffer`，再进 VideoToolbox。

### 总览图

```
CADisplayLink (preferredFramesPerSecond = 目标 FPS，如 60)
    │
    ▼
SCRenderer.drawFrame
    │
    ├─① beginEncodePass          取池中 CVPixelBuffer(BGRA, 如 360×780)
    │     │                      CVOpenGLESTextureCache → GL 纹理
    │     │                      绑到离屏 FBO（颜色=该纹理）
    │     ├─ resize(编码宽高) + FlipY
    │     ├─ SCRendererData.render()     ← 场景画进像素缓冲（零拷贝共享）
    │     └─ endEncodePass
    │           glFlush + TextureCacheFlush
    │           CMSampleBufferCreateForImageBuffer
    │                │
    │                ▼
    │           PushStream.didOutputSampleBuffer
    │                │
    │                ▼
    │           H264Encoder (VideoToolbox)
    │                │  关键帧：SPS / PPS
    │                │  帧数据：AVCC [4B len][NALU]…
    │                ▼
    │           RTMPStreamer → FLV Video Tag → librtmp → RTMP 服务器
    │
    └─② 屏幕 FBO + presentRenderbuffer     ← 本机预览（再渲一趟全屏）

并行：麦克风 → AudioCapture → AACEncoder → RTMPStreamer（同一相对时间戳）
```

### 像素如何进 H.264

```
离屏 GL
  → CVPixelBuffer (BGRA，编码尺寸，IOSurface / OpenGLESCompatible)
  → CMSampleBuffer（带 PTS / duration）
  → VTCompressionSessionEncodeFrame(imageBuffer)
  → 回调 CMSampleBuffer（压缩后）
       ├─ 关键帧：抽出 SPS、PPS → sendSPS/PPS（AVCDecoderConfigurationRecord）
       └─ AVCC 载荷 → 按 NALU 拆 FLV Tag（0x17/0x27）→ RTMP_SendPacket
```

| 阶段 | 形态 | 说明 |
|------|------|------|
| GL 输出 | `CVPixelBuffer` BGRA | TextureCache 与 FBO 共享，无 CPU 大块拷贝 |
| 送编码 | `CMSampleBuffer` | 包一层 timing，给 VideoToolbox |
| 编码输出 | AVCC | `[长度][NALU]…`，**不是** `00 00 00 01` Annex-B |
| 上线 | FLV over RTMP | 配置包 + 视频/音频 Tag；时间戳为相对 ms |

### 为何离屏能减轻卡顿

| 旧做法 | 现做法 |
|--------|--------|
| 先按**全屏**分辨率画完 | 离屏直接画 **360×780** 等编码尺寸 |
| `glReadPixels` 整屏回读 CPU | `CVOpenGLESTextureCache`：GL 写 IOSurface，编码器直接读 |
| GPU–CPU 同步，DisplayLink 掉帧 | 无全屏 readback；多付一次「小分辨率 render」 |

仍会 **同一逻辑帧 render 两次**（离屏 + 上屏）。编码分辨率远小于屏幕时，通常比 readback 轻得多。

### 帧率

- `PushStream` 开播：`glRenderer.preferredFramesPerSecond = activeFPS`
- Avatar：**每个** DisplayLink 回调抓一帧（不再做 `maxFPS` 软件丢帧）
- Cam：相机本身约 30fps；仅当 UI 选 &lt;30 时在 `PushStream` 里节流

### 相关源码

| 文件 | 步骤 |
|------|------|
| `GL/SCRenderer.mm` `drawFrame:` | ① 离屏 ② 上屏 |
| `liveStream/SCRenderCapture.m` | Pool / TextureCache / FBO / SampleBuffer |
| `liveStream/H264Encoder.m` | VideoToolbox |
| `liveStream/RTMPStreamer.m` | FLV + 统一时钟时间戳 |
| `liveStream/PushStream.m` | 接线与默认 360×780@60 |

### UI 操作（推流）

| 控件 | 作用 |
|------|------|
| Live / Stop | 开始 / 停止 RTMP |
| Src | Avatar（GL） / Cam |
| Vid | 编码分辨率（19.5:9） |
| FPS | 5…60；Avatar 驱动 DisplayLink |

默认 URL：`rtmp://192.168.71.92:1935/live/teststream`（可在 `PushStream` / UI 改）。

---

## 运行与操作

1. Xcode 打开 `ARKit.xcodeproj`，真机，授权相机  
2. 选 **BlackMan** 或 **WhiteMan**，**AR:Face**，双肩入镜（白模 lean）  
3. 绿字：`DRIVE HEAD` / `EYE …` / `FACE …` / `LEAN=° Vision≈Hz`
4. 推流：Src=Avatar，点 Live；播放器拉同一 RTMP 地址

| 操作 | 效果 |
|------|------|
| 顶部模型芯片 | 切换模型 |
| 动画芯片 / Pause | 剪辑与暂停 |
| AR:Face / AR:Body | 追踪模式 |
| W A S D / Up / Dn | 相机 |
| 单指拖 / 双指捏 | 模型朝向 / FOV |
| Live / Src / Vid / FPS | RTMP 推流（见上节） |

---

## 依赖

OpenGL ES 3 · ARKit · Vision（iOS 14+）· VideoToolbox · AudioToolbox · librtmp · Assimp · GLM · stb_image
