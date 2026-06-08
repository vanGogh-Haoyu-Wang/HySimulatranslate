# HySimulatranslate (HySimulatranslate)

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014.0%2B-blue" alt="platform">
  <img src="https://img.shields.io/badge/swift-5.9-orange" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
</p>

<p align="center"><strong>🎙️ 端到端实时同声传译桌面应用 — 本地引擎 + 云端 LLM 精校</strong></p>

---

## 功能

- **实时语音转写** — sherpa-onnx 流式识别 + WhisperKit large-v3 本地精校，双引擎兜底
- **LLM 文本格式化** — Groq API（llama-3.3-70b-versatile）智能修复标点、ASR 错误、句子拼接
- **中英同传** — 从英文语音到中文译文的完整流水线
- **强化专项** — 自定义学科关键词与会议 focus，提升专业术语识别准确率
- **实时总结** — NVIDIA API（nemotron-super-49b-v1）逐段生成中文会议总结
- **会话笔记** — 自动将转写+翻译+总结写入桌面 Markdown 笔记文件
- **毛玻璃 UI** — 原生 SwiftUI 毛玻璃（glass-morphism）界面，支持深色/浅色/跟随系统

---

## 处理流水线

```
麦克风 (AVAudioEngine)
  │  16kHz int16 PCM
  ▼
sherpa-onnx 实时流式识别 ──→ draft text（蹦字区实时预览）
  │  segment + PCM 缓存
  ▼
WhisperKit large-v3 本地精校
  │  (可选: Groq Whisper API 云端兜底)
  ▼
Groq LLM 格式化 / 合并 ──→ 纠错、去重、分句
  │
  ▼
Groq LLM 翻译（英→中）
  │
  ▼
NVIDIA 实时总结 ──→ 中文摘要
  │
  ▼
写入桌面笔记文件 + Markdown 落盘
```

---

## 系统要求

| 项目 | 要求 |
|------|------|
| **操作系统** | macOS 14.0 (Sonoma) 或更高 |
| **架构** | Apple Silicon (M1/M2/M3/M4) 或 Intel (需测试) |
| **麦克风** | 系统麦克风权限 |
| **网络** | 使用云端 LLM (Groq/NVIDIA) 需要网络连接；纯本地模式可选 |
| **存储** | ~3 GB（sherpa-onnx 模型 + WhisperKit large-v3 模型） |

---

## 依赖的模型

应用运行时需要以下模型文件（自动检测，需预先放置）：

### sherpa-onnx 流式模型
将 `sherpa-onnx-streaming-zipformer-en-2023-06-26` 解压到：
```
~/Library/Application Support/SherpaOnnxModel/sherpa-onnx-streaming-zipformer-en-2023-06-26/
```

### WhisperKit large-v3 模型
首次运行 WhisperKit 会自动下载（需要网络），或可预先放置于 WhisperKit 缓存目录。

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

确保 `Libraries/sherpa-onnx/lib/` 包含以下文件：
- `libsherpa-onnx-c-api.dylib`
- `libonnxruntime.dylib`

> 这些文件未包含在仓库中（体积较大），请从 [sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases) 下载对应 macOS 版本并放入该目录。

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

### 环境变量

应用依赖系统的麦克风权限。首次启动 macOS 会弹出权限请求。

---

## 使用指南

### 启动配置

1. **API Key** — 可选配置 Groq 核心 Key（格式 `gsk_…`）和 NVIDIA 总结 Key（格式 `nvapi-…`）。不配置则无法使用 LLM 格式化和翻译。
2. **强化专项** — 选择一个学科专项（如"默认"或自定义），用于指导 LLM 识别专业术语。
3. 点击 **启动引擎** 开始。

### 同传界面

| 区域 | 功能 |
|------|------|
| **顶部状态栏** | 课程名、引擎状态、麦克风设备、队列大小（W=Whisper, L=LLM）、控制按钮 |
| **左侧历史面板** | 已确认的转写+翻译结果，自动滚动 |
| **右侧上部蹦字区** | 实时 ASR 识别文字 + 处理状态标签 |
| **右侧下部总结区** | NVIDIA 实时会议总结 |

### 设置项

- **停顿时间** (0.2s–1.5s) — 控制 sherpa-onnx 的语音分段灵敏度
- **外观** — 跟随系统 / 深色 / 浅色

### 笔记文件

每场会话自动在桌面生成：
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
│   └── build_and_run.sh           # 构建 .app 并启动
├── Sources/
│   ├── CSherpaOnnx/               # sherpa-onnx C 库模块映射
│   │   ├── dummy.c
│   │   └── module.modulemap
│   └── HySimulatranslate/
│       ├── HySimulatranslateApp.swift           # App 入口 + AppDelegate
│       ├── Views/
│       │   ├── ContentView.swift   # 根视图（启动→同传切换）
│       │   ├── StartupView.swift   # 启动配置弹窗
│       │   ├── TranscriptionView.swift  # 同传主界面
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
│           ├── LLMService.swift         # Groq LLM 格式化
│           ├── TranslationService.swift # 翻译服务
│           ├── NvidiaSummaryService.swift  # NVIDIA 总结
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
| [NVIDIA API](https://build.nvidia.com/) | 中文会议总结 |
| SwiftUI + AppKit | macOS 原生 UI |
| AVFoundation / CoreAudio | 麦克风音频采集 |

---

## 下载与安装

> 🚧 **即将发布** — 目前尚未打包为 `.dmg` 安装包。后续版本将提供：
> - 可直接拖拽安装的 `.dmg` 文件
> - 自动处理动态库依赖与模型下载

在此之前，请通过源码编译运行（见上方「编译与运行」）。

---

## 致谢

Powered by **Haoyu Wang**

本项目建立在以下开源项目的基石之上：
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — 下一代 Kaldi 实时语音识别
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — 苹果生态本地 Whisper 推理
- [swift-transformers](https://github.com/huggingface/swift-transformers) — Hugging Face 模型 Swift 运行时
- Groq Cloud & NVIDIA NIM — 云端推理

---

## 许可证

MIT License
