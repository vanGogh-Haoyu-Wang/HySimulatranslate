# 音频转写语言与模型选择器设计

## 目标

将音频转写工作区中的原语言、目标语言和 Whisper 模型自由输入框替换为受控选项，避免无效代码或模型名称，同时为未来增加 Groq Whisper 转写选项保留清晰扩展点。

## 界面与默认值

- 原语言 Picker 提供“英语”和“中文”，默认“英语”。
- 目标语言 Picker 提供“中文”和“英语”，默认“中文”；关闭“生成翻译”时保持禁用。
- 转写模型 Picker 当前只提供“WhisperKit Large V3（本地）”。
- 移除表单下方重复的 `en → cn` 说明；Picker 文案本身表达用户可读名称。

## 数据设计

- `AudioImportLanguageOption` 负责显示名和规范代码：英语写入 `en`，中文写入 `zh`。
- `AudioTranscriptionModelOption` 负责显示名、Provider 类型和实际模型 ID。
- 当前模型选项映射到 `WhisperKitService.defaultModel`，Provider 为本地 WhisperKit。
- `AudioImportFormState.makeOptions()` 继续生成现有 `ImportOptions`，不修改 SQLite schema、revision 数据结构或导入服务接口。
- 后续接入 Groq Whisper 时，在模型目录增加远程选项并扩展执行路由；本次不发送 Groq 音频请求。

## 行为与错误边界

- 用户无法提交任意语言或模型字符串。
- 已有导入任务 JSON 和历史 revision 保持兼容。
- 文件选择、拖放、翻译开关、说话人分离、进度、取消和完成跳转行为保持不变。

## 验证

- 测试语言选项的中文显示名及 `en`/`zh` 映射。
- 测试默认选择为英语、中文和本地 WhisperKit Large V3。
- 测试 `makeOptions()` 写入稳定代码和真实模型 ID。
- 测试当前模型目录只有一个可选本地项，并携带 WhisperKit Provider 信息。
- 运行聚焦测试、完整 `swift test`、Release 构建、签名及 `dist/HySimulatranslate.app` 重打包。
