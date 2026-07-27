# HySimulatranslate (HySimulatranslate)

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014.0%2B-blue" alt="platform">
  <img src="https://img.shields.io/badge/swift-5.9-orange" alt="swift">
</p>

<p align="center"><strong>🎙️ 端到端实时同声传译桌面应用 — 本地引擎 + 云端 LLM 精校</strong></p>

---

## 功能

- **实时语音转写** — sherpa-onnx 原始音频实时蹦字 + 本地 VAD 切段 + 云端 Whisper 精校，本地 WhisperKit large-v3 仅作故障灾备
- **Apple 实时预览** — macOS 26+ 使用系统 Translation framework 为 Sherpa 蹦字提供低延迟中文预览，不写入历史墙或笔记
- **LLM 文本格式化** — Groq API（llama-3.3-70b-versatile）智能修复标点、ASR 错误、句子拼接
- **中英同传** — 在线时保留分学科强化翻译；完全断网时由 Apple 翻译 Whisper 精校后的正式句子
- **强化专项** — 自定义学科关键词与会议 focus，提升专业术语识别准确率
- **实时总结** — OmniRoute 使用 `auto` 模型逐段生成中文会议总结
- **会话笔记** — 自动将转写+翻译+总结写入桌面 Markdown 笔记文件
- **毛玻璃 UI** — 原生 SwiftUI 毛玻璃（glass-morphism）界面，支持深色/浅色/跟随系统

---

## 处理流水线

```
麦克风 (AVAudioEngine) / 电脑音频 (ScreenCaptureKit)
  │  16kHz int16 PCM
  ▼
sherpa-onnx 实时流式识别 ──→ 英文 draft + Apple 临时译文（仅蹦字区）
  │
  ├─→ VAD（只用于切段）
  │      │ 300-500ms pre-roll + 500-700ms hangover
  │      ▼
  │    Groq Whisper（最多两个并发 worker）
  │      │ 网络/HTTP/超时/无效结果时才延迟加载本地 WhisperKit large-v3
  ▼
动态候选区 ──→ Sherpa 草稿 + Whisper 候选 + 处理状态
  ▼
Groq LLM 格式化 / 合并 ──→ 纠错、去重、分句
  │
  ▼
在线：分学科强化 + 云端翻译（英→中）
断网：Apple 翻译 Whisper 精校句（英→简中）
  │
  ▼
OmniRoute 实时总结 ──→ 中文摘要
  │
  ▼
写入桌面笔记文件 + Markdown 落盘
```

---

## 系统要求

| 项目 | 要求 |
|------|------|
| **操作系统** | macOS 14.0 (Sonoma) 或更高 |
| **架构** | Apple Silicon (arm64)；当前 Sherpa 运行库不支持 Intel |
| **麦克风** | 系统麦克风权限 |
| **网络** | Groq 翻译、OmniRoute 总结和 Agnes 整理需要网络；断网时可使用本地转录与 Apple 翻译 |
| **Apple 翻译** | 蹦字区实时译文与断网正式翻译需 macOS 26.0+，并通过自检确认系统语言模型可用 |
| **存储** | ~3 GB（sherpa-onnx 模型 + WhisperKit large-v3 模型 + VAD 模型） |

---

## 依赖的模型

源码运行时可以继续使用本机缓存；DMG 打包会把以下模型复制进 `.app`，首次启动再自动安装到：
```
~/Library/Application Support/HySimulatranslate/
```

### sherpa-onnx 流式模型
默认打包源路径：
```
~/Library/Application Support/HySimulatranslate/Models/Sherpa/sherpa-onnx-streaming-zipformer-en-2023-06-26/
```

### WhisperKit large-v3 模型
默认打包源路径：
```
~/Library/Application Support/HySimulatranslate/Models/WhisperKit/openai_whisper-large-v3/
```

WhisperKit 默认下载优化的 large-v3 变体 `large-v3-v20240930_626MB`，并继续兼容既有 `openai_whisper-large-v3` 目录。

### VAD 模型
默认打包源路径：
```
~/Library/Application Support/HySimulatranslate/Models/VAD/silero_vad.onnx
```

### sherpa-onnx C 库
编译时需要 `Libraries/sherpa-onnx/lib/` 下的 `libsherpa-onnx-c-api.dylib` 和 `libonnxruntime.dylib`。

---

## 编译与运行

### 1. 克隆仓库

```bash
git clone https://github.com/your-org/HySimulatranslate.git
cd HySimulatranslate
```

### 2. 放置 sherpa-onnx 动态库

可以直接运行：

```bash
bash script/download_dependencies.sh --all
```

脚本会自动下载 sherpa-onnx 动态库、Sherpa 流式模型、Silero VAD 和 WhisperKit large-v3 模型。

### 3. 编译

```bash
swift build
```

### 4. 构建 .app 并运行

```bash
bash script/build_and_run.sh
```

脚本会：
- 编译项目
- 创建 `dist/HySimulatranslate.app` 应用程序包
- 复制动态库到 `Frameworks/`
- ad-hoc 签名
- 启动应用

### 5. 打包 DMG

```bash
bash script/package_dmg.sh --verify
```

脚本会生成：
- `dist/HySimulatranslate.app`
- `dist/HySimulatranslate.dmg`

DMG 打开后，将 `HySimulatranslate.app` 拖到 `Applications`。这是第三方分发包，默认使用 ad-hoc 签名，不做 Apple notarization。

可用环境变量覆盖模型源：

```bash
SHERPA_MODEL_SOURCE="/path/to/sherpa-model" \
WHISPER_MODEL_SOURCE="/path/to/openai_whisper-large-v3" \
VAD_MODEL_SOURCE="/path/to/silero_vad.onnx" \
bash script/package_dmg.sh --verify
```

### 环境变量

应用依赖系统的麦克风权限。首次启动 macOS 会弹出权限请求。

---

## 使用指南

### 工作台

应用启动后直接进入三栏工作台。API Key 位于左下角 **设置**，强化专项从左侧 **强化专项** 进入，**新记录** 会清空当前会话并保留已有自检状态。

### 同传界面

| 区域 | 功能 |
|------|------|
| **左侧记录区** | 扫描笔记目录 `.txt` 文件，可新建记录、进入强化专项、打开设置 |
| **中右主框** | 共享状态标题栏、当前会话历史墙、强化专项编辑、右侧笔记总结区 |
| **底部蹦字区** | 横贯中右主框，显示实时 Sherpa 英文与 Apple 临时译文、VAD/Whisper 候选文本、开始/停止按钮 |
| **右侧总结区** | 默认显示 OmniRoute 实时会议总结；打开左侧历史笔记时由笔记预览覆盖，关闭后恢复总结 |

### 设置项

- **停顿时间** (0.2s–1.5s) — 控制 sherpa-onnx 的语音分段灵敏度
- **Whisper 精校** — 固定智能混合策略：云端优先，本地 large-v3 只在云端明确失败时单路灾备
- **模型** — 在同传页设置中填写 OmniRoute Base URL 与 API Key；总结固定使用 `auto` 路由，避免客户端绑定单一上游模型
- **笔记位置** — 默认桌面，可改为任意本地文件夹
- **外观** — 跟随系统 / 深色 / 浅色

### 笔记文件

每场会话默认在桌面生成，也可在同传页设置中修改保存文件夹：
```
{课程缩写}_Session_{日期时间}.txt
```

---

## 项目结构

```
HySimulatranslate/
├── Package.swift                  # Swift Package Manager 配置
├── Package.resolved               # 依赖版本锁定
├── script/
│   ├── build_and_run.sh           # 构建 .app 并启动
│   ├── package_dmg.sh             # 构建可拖拽安装的 DMG
│   └── create_app_icon.swift      # 生成 macOS .icns 图标资源
├── Resources/
│   ├── AppIcon.png
│   └── AppIcon.icns
├── Sources/
│   ├── CSherpaOnnx/               # sherpa-onnx C 库模块映射
│   │   ├── dummy.c
│   │   └── module.modulemap
│   └── HySimulatranslate/
│       ├── HySimulatranslateApp.swift           # App 入口 + AppDelegate
│       ├── Views/
│       │   ├── ContentView.swift   # 根工作台入口
│       │   ├── TranscriptionView.swift  # 三栏同传工作台
│       │   ├── AddSubjectView.swift     # 添加强化专项
│       │   └── GlassStyle.swift         # 毛玻璃组件
│       ├── ViewModels/
│       │   └── TranscriptionViewModel.swift  # 核心引擎 ViewModel
│       ├── Models/
│       │   ├── Types.swift              # 数据类型定义
│       │   ├── CourseDatabase.swift     # 强化专项知识库
│       │   ├── LLMProvider.swift        # LLM 提供商配置
│       │   ├── LiveSummary.swift        # 实时总结逻辑
│       │   ├── TranscriptDisplayBlock.swift  # 转录显示块
│       │   ├── TranscriptOrganizer.swift     # 转录组织器
│       │   └── SessionNoteRenderer.swift     # 笔记渲染器
│       └── Services/
│           ├── SpeechEngine.swift       # AVAudioEngine 音频采集
│           ├── SherpaService.swift      # sherpa-onnx 流式识别
│           ├── WhisperKitService.swift  # WhisperKit 本地精校
│           ├── VoiceActivityService.swift  # 本地 VAD 封装
│           ├── ChatRateLimiter.swift    # Groq 聊天请求限流
│           ├── ResourceDownloadService.swift # 模型自动下载
│           ├── LLMService.swift         # Groq LLM 格式化
│           ├── TranslationService.swift # 翻译服务
│           ├── AppleSystemTranslationService.swift # Apple 系统翻译会话
│           ├── OmniRouteSummaryService.swift # OmniRoute 总结
│           └── KeychainManager.swift    # API Key 钥匙串管理
├── Tests/
│   └── HySimulatranslateTests/
│       └── HySimulatranslateTests.swift
├── Libraries/
│   └── sherpa-onnx/
│       └── lib/                    # sherpa-onnx C 动态库（需自行下载）
└── dist/
    └── HySimulatranslate.app/                   # 构建产物（build_and_run.sh 生成）
```

---

## 技术栈

| 技术 | 用途 |
|------|------|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 实时流式语音识别 |
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | 本地 Whisper large-v3 精校 |
| [Groq API](https://groq.com/) | LLM 文本格式化 + 翻译 |
| OmniRoute（本地或自托管） | 中文会议总结与上游故障切换 |
| Apple Translation framework | Sherpa 临时译文与断网正式翻译 |
| SwiftUI + AppKit | macOS 原生 UI |
| AVFoundation / ScreenCaptureKit | 麦克风与电脑音频采集 |

---

## 下载与安装

从 `dist/HySimulatranslate.dmg` 安装：打开 DMG，将 `HySimulatranslate.app` 拖到 `Applications`。首次启动引擎时，App 会把随附模型与脚本安装到用户 Library 支持目录。

如果 macOS 提示来源限制，请右键点击 App 后选择打开，或按你的系统安全策略允许第三方应用。

---

## 致谢

Powered by **Haoyu Wang**

本项目建立在以下开源项目的基石之上：
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — 下一代 Kaldi 实时语音识别
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — 苹果生态本地 Whisper 推理
- [swift-transformers](https://github.com/huggingface/swift-transformers) — Hugging Face 模型 Swift 运行时
- Groq Cloud & OmniRoute — 云端翻译与自托管路由

---

## 许可证

本仓库暂未附带开源许可证。
