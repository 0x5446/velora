# POC 结果

版本：2026-06-28

## 1. POC 清单

| POC | 文件 | 状态 | 结论 |
| --- | --- | --- | --- |
| 翻译模式输出合同 | `pocs/translation_mode_poc.py` | 已完成 | 支持双语、只译文、review card 三种插入策略 |
| 语境热词选择 | `pocs/context_hotword_poc.py` | 已完成 | Top K 热词注入可行，结果可解释 |
| Apple 平台能力探测 | `pocs/apple_platform_probe.sh` | 已完成 | 当前机器可编译关键 Apple framework import |
| 延迟预算合同 | `pocs/latency_budget_poc.py` | 已完成 | release-to-insert 预算可执行，冷启动必须移出关键路径 |
| iPhone 授权流合同 | `pocs/ios_permission_flow_poc.py` | 已完成 | 首次启动 0 弹窗，默认录音只问麦克风，增强授权后置 |
| Swift 工程骨架验证 | `Velora.xcodeproj` / `Velora` | 已完成 | Mac/iOS/Keyboard 目标可构建，App Group payload 可写入 |
| Mac 系统级输入 POC | `Apps/VeloraMac/MacSystemInputController.swift` | 进行中 | 已有默认 `Fn`、翻译 `Fn ⇧`、可切换 Space 组合键、实时音量 voice bar、whisper.cpp ASR、Ollama 润色/翻译、pasteboard 插入回退和剪贴板恢复；待目标 App 矩阵验收 |
| whisper.cpp 本地 ASR POC | `WhisperCLIASREngine` | 已完成首轮 | `ggml-base.bin`、`ggml-tiny.bin`、`ggml-large-v3-turbo-q5_0.bin` 均可用；已支持 fast/base、accurate/large、fallback/tiny 模式 |
| Ollama 本地 LLM POC | `OllamaTextIntelligenceEngine` / `OllamaTranslationEngine` | 已完成首轮 | `qwen3:8b` 可做润色和翻译；warm 翻译可到约 0.7s，但冷/半冷路径可能到 12s，必须预热、压 prompt、加 deadline/fallback |

## 2. 翻译模式输出合同

目标：验证翻译模式不能只产出译文。它必须保留原文、纠正后的原文、译文、展示文本和插入文本。

关键数据结构：

```python
InsertPolicy = Literal["bilingual", "target_only", "review_card"]

@dataclass(frozen=True)
class TranslationResult:
    mode: TranslationMode
    source_text: str
    corrected_source_text: str
    target_text: str
    display_text: str
    insert_text: str
    glossary_hits: list[str]
    warnings: list[str]
```

样例输入：

```text
明天上午十点我和 Alex 开会，帮我确认一下 agenda。
```

默认双语输出：

```text
原文:
明天上午十点我和 Alex 开会，帮我确认一下 agenda。
译文:
I have a meeting with Alex tomorrow at 10 a.m. Please help me confirm the agenda.
```

结论：

- `display_text` 和 `insert_text` 必须分离。UI 可以永远展示双语，但插入可以按用户策略变化。
- `glossary_hits` 必须保留。它会进入诊断 UI，也会用于翻译质量判断。
- `warnings` 必须保留。后续接真实翻译引擎时，unsupported language、术语冲突、低置信度都走这里。

下一步：

- 把 stub translator 换成 Apple Translation。
- 加 glossary 约束后处理。
- 加命名实体一致性检查。
- 加低置信度审阅策略。

## 3. 语境热词选择

目标：验证长期记忆不是“全量塞 prompt”，而是根据当前场景选出少量可解释热词。

输入上下文：

```json
{
  "app_bundle": "com.apple.mail",
  "window_title": "Draft: Velora translation mode design",
  "nearby_text": "Need to explain prompt injection risk and bilingual translation review.",
  "mode": "translate"
}
```

原始 ASR：

```text
The biggest risk is prom injection in velora when we keep long term context.
```

修正结果：

```text
The biggest risk is prompt injection in Velora when we keep long term context.
```

命中修改：

| From | To | 原因 |
| --- | --- | --- |
| `prom injection` | `prompt injection` | selected_hotword |
| `velora` | `Velora` | selected_hotword |

Top 热词示例：

| 热词 | 得分 | 主要原因 |
| --- | ---: | --- |
| `prompt injection` | 15.853 | app match、domain match、nearby text match、edit count、recency |
| `Velora` | 11.639 | app match、domain match、edit count、recency |
| `提示注入` | 11.376 | app match、domain match、translation mode bonus |
| `agenda` | 8.750 | app match、edit count、recency、translation mode bonus |

结论：

- SQLite 可以支撑第一版本地记忆。
- 需要保留每个候选的 reasons，方便用户诊断。
- 只注入 Top K，能减少隐私暴露和 prompt 污染。
- mode bonus 有用。翻译模式下应提高双语术语、人名、会议词的权重。

下一步：

- 增加 per-app denylist。
- 增加用户拒绝纠错后的负反馈。
- 增加 FTS 和 embedding 检索对比。
- 增加中文同音错词测试集。

## 4. Apple 平台能力探测

本机环境：

```text
macOS SDK: 26.4
Xcode: 26.4
Swift: 6.3
```

Import 结果：

| Framework | 结果 |
| --- | --- |
| Speech | ok |
| NaturalLanguage | ok |
| AppKit | ok |
| InputMethodKit | ok |
| AVFoundation | ok |
| Accessibility | ok |
| FoundationModels | ok |
| Translation | ok |

结论：

- 可以开始写 macOS Swift 原型。
- `InputMethodKit`、`Accessibility`、`AVFoundation` 能支持 Mac 系统级输入体验 POC。
- `FoundationModels`、`Translation` 可以进入本地文本智能和翻译 POC。
- 这只是 compile import 检查，不代表 API 行为、权限和性能都满足。后续必须做真实功能 POC。

## 5. 延迟预算合同

目标：把“说完到上屏要极致快”变成可执行约束。

核心定义：

```text
release-to-insert = 用户松开录音键 / VAD 判定结束 到 文本插入完成
```

预算：

| 场景 | Warm p50 | Warm p95 |
| --- | ---: | ---: |
| Mac Dictate | 700ms | 1200ms |
| Mac Polish | 900ms | 1500ms |
| Mac Translate | 1100ms | 1800ms |
| iPhone Translate bridge | 1600ms | 2600ms |

结论：

- context capture、hotword ranking、streaming ASR partial、speculative correction 必须在录音期间完成。
- 松手后只做 finalize、reconcile、render、insert。
- 冷启动 p50 会明显超预算，所以模型冷加载不能出现在默认录音路径。
- 文本智能引擎必须支持 deadline，超时返回 best effort。

下一步：

- 在 Swift pipeline 里加 per-stage tracing。
- 每次输入记录 p50/p95。
- 把超预算 session 标记到 Diagnostics。

## 6. iPhone 授权流合同

目标：iPhone 授权体验必须低摩擦，同时不能牺牲隐私解释。

默认路径：

| Journey | 系统弹窗数 | 说明 |
| --- | ---: | --- |
| first launch | 0 | 首次打开不请求权限 |
| default record with local ASR | 1 | 只请求麦克风 |
| optional Apple Speech engine | 1 | 用户选 Apple Speech 后才请求 |
| optional fast insert keyboard | 1 | Keyboard Full Access 后置 |
| optional context personalization | 1 per feature | Contacts / Calendar 分开请求 |

结论：

- 默认 ASR 路线优先用本地引擎，避免首轮 Speech Recognition 权限。
- 自定义键盘 Full Access 只服务“快速插入增强功能”，不能放到首轮引导。
- 联系人和日历学习是可选个性化，不是核心输入能力。
- 每个授权必须有拒绝后的替代路径。

下一步：

- 做 iOS 真机授权 POC，验证系统文案、Settings 跳转和拒绝路径。
- 做增强键盘网络隔离验证，避免 Full Access 带来不必要的隐私风险。
- 为 App Store 审核准备权限用途说明。

## 7. Swift 工程骨架验证

目标：把前面的产品合同落到可运行工程，而不是只停留在文档。

当前实现：

- `Velora` Swift Package：核心合同、orchestrator、fake ASR、热词纠错、stub 翻译、双语渲染、键盘桥接 payload/store。
- `VeloraMacApp`：SwiftUI 原型、AVAudioEngine 录音、停止录音后把 `audioPath` 交给 pipeline。当前默认真实路径是 `WhisperCLIASREngine`，文本智能和翻译走 `Ollama qwen3:8b`。
- `VeloraiOS`：SwiftUI 原型、主 App 录音骨架、自动写入 Keyboard App Group 候选。
- `VeloraKeyboard`：自定义键盘扩展，读取最近 payload 并通过 `textDocumentProxy.insertText` 插入。
- `project.yml`：XcodeGen 管理 Mac App、iOS App、Keyboard Extension。

已验证：

| 项目 | 结果 |
| --- | --- |
| `swift test --package-path Velora` | 30 tests passed |
| `xcodegen generate` | passed |
| Mac app build | passed，`VeloraMacApp` 已启动 |
| iOS app + keyboard extension build | passed，0 warning |
| iOS simulator install/launch | passed |
| iOS App Group container | `group.app.velora.shared` 可解析 |
| iOS auto-write payload | `latestKeyboardPayload` 写入成功，包含原文、纠错原文、译文、双语插入文本 |

自动写入验证 payload 摘要：

```json
{
  "mode": "translate",
  "sourceLanguage": "zh",
  "targetLanguage": "en",
  "insertPolicy": "bilingual",
  "correctedSourceText": "明天上午十点我和 Alex 开会，帮我确认一下 agenda。",
  "targetText": "I have a meeting with Alex tomorrow at 10 a.m. Please help me confirm the agenda."
}
```

注意：

- `codesign -d --entitlements` 对 simulator 产物显示空 entitlements，但 Xcode 生成的 `*-Simulated.xcent` 含 App Group，`simctl listapps` 也显示了 GroupContainers。真机签名仍要单独验证。
- 结构化 UI 自动化依赖 `idb`，本机当前没有安装；这不影响 App 构建和 App Group 验证。
- iPhone 录音骨架已接通，但 iOS 默认 ASR 还没有绑定真实模型，避免把默认授权路径绑到 Apple Speech。
- iOS 主 App 已加麦克风 preflight sheet：首次启动不弹系统权限；第一次点录音时先显示本地说明，再由用户触发系统麦克风弹窗。
- 当前真机 `iphone17` 在 CoreDevice 中显示 `unavailable`；通用真机 build 因缺少 provisioning profiles 失败，下一步要在设备可用后用 Xcode 自动签名或 `-allowProvisioningUpdates` 生成 profile。

## 8. 本地模型 POC：2026-06-28

本机环境：

```text
macOS: 26.2
CPU/GPU: Apple M4 Pro
Memory: 24GB
whisper-cli: /opt/homebrew/bin/whisper-cli
Ollama: http://127.0.0.1:11434
```

本地模型状态：

| 模型 | 状态 | 说明 |
| --- | --- | --- |
| `Models/whisper.cpp/ggml-base.bin` | 可用，141MB | `fast` 模式默认模型 |
| `Models/whisper.cpp/ggml-tiny.bin` | 可用，74MB | `fallback` 模式模型，不代表最终准确率 |
| `Models/whisper.cpp/ggml-large-v3-turbo-q5_0.bin` | 可用，547MB | `accurate` 模式模型，短中文混英文术语更稳 |
| `ollama qwen3:8b` | 可用，5.2GB Q4_K_M | 当前润色/翻译默认开发模型 |
| `gemma4:12b-mlx` | 已存在 | 暂未进入默认 pipeline |

已验证命令：

```bash
whisper-cli -m Models/whisper.cpp/ggml-tiny.bin -l en -otxt -of /tmp/velora-jfk -nt /opt/homebrew/Cellar/whisper-cpp/1.9.1/share/whisper-cpp/jfk.wav
whisper-cli -m Models/whisper.cpp/ggml-base.bin -l en -otxt -of /tmp/velora-jfk-base -nt -np /opt/homebrew/Cellar/whisper-cpp/1.9.1/share/whisper-cpp/jfk.wav
swift run --package-path Velora VeloraMac --mode translate --audio /tmp/velora-jfk.caf --source en --target zh --local-models
Velora/.build/debug/VeloraMac --mode dictate --audio /opt/homebrew/Cellar/whisper-cpp/1.9.1/share/whisper-cpp/jfk.wav --source en --asr-mode fast --json
Velora/.build/debug/VeloraMac --mode dictate --audio /opt/homebrew/Cellar/whisper-cpp/1.9.1/share/whisper-cpp/jfk.wav --source en --asr-mode accurate --json
Velora/.build/debug/VeloraMac --mode dictate --audio /opt/homebrew/Cellar/whisper-cpp/1.9.1/share/whisper-cpp/jfk.wav --source en --asr-mode fallback --json
```

端到端输出：

```text
原文:
And so my fellow Americans ask not what your country can do for you, ask what you can do for your country.
译文:
因此，我的同胞们，不要问你的国家能为你做什么，而要问你能为你的国家做什么。
```

延迟观察：

| 项目 | 结果 |
| --- | ---: |
| whisper.cpp 首次 Metal library 初始化 | 早期 POC 曾见约 42s；当前同机 warm 后 help 初始化约 43ms |
| `large-v3-turbo-q5_0` 跑 11s JFK wav | wall 约 4.89s；文本正确；RSS 约 842MB |
| CLI pipeline JFK，`large` ASR stage | 约 2205ms |
| CLI pipeline JFK，`base` ASR stage | 约 1471ms |
| CLI `--asr-mode fast` JFK | `ggml-base.bin`，约 1487ms |
| CLI `--asr-mode accurate` JFK | `ggml-large-v3-turbo-q5_0.bin`，约 2997ms |
| CLI `--asr-mode fallback` JFK | `ggml-tiny.bin`，约 1538ms；短音频上 CLI 固定开销明显 |
| 短英文 TTS 2.86s，`tiny` | 约 1079ms，文本正确 |
| 短英文 TTS 2.86s，`base` | 约 998ms，文本正确 |
| 短英文 TTS 2.86s，`large` | 约 4020ms，文本正确 |
| 短中文混英文 TTS 5.04s，`tiny` | 约 960ms，但 `agenda` 错成“哦真的” |
| 短中文混英文 TTS 5.04s，`base` | 约 1057ms，但 `agenda` 错成“而针的”；加 prompt 后仍可能错成 `Ogender` |
| 短中文混英文 TTS 5.04s，`large` | 约 3281ms；加 prompt 后仍保住 `agenda`，约 2.6s |
| qwen3:8b warm 翻译短句 | 可到约 686ms；prompt eval 是主要耗时 |
| qwen3:8b 冷/半冷路径 | 曾出现 5-12s，不能进关键路径 |

结论：

- 当前 Mac 版已经不是 Apple Speech 单点依赖。系统 Speech 报错不会阻断本地 ASR。
- `whisper.cpp` CLI 适合 POC，不适合最终极致延迟。后续要换常驻进程、C API、WhisperKit、SpeechAnalyzer 或 FluidAudio。
- `qwen3:8b` 可用于开发期润色/翻译，但要进入默认体验必须常驻预热、缩短 prompt，并支持 deadline/fallback。
- 当前 `PipelineTrace` 已记录真实 stage wall time，不再使用合同型静态耗时。
- ASR 模型模式已落地：`fast=base`、`accurate=large-v3-turbo-q5_0`、`fallback=tiny`。

## 9. POC 优先队列

### P0：Mac 插入 POC

验证：

- 全局快捷键录音：默认 `Fn` toggle、翻译 `Fn ⇧`、Space 组合键备选已实现并通过构建。
- `InputMethodKit` commit。
- Accessibility 插入：当前只采集 AX 上下文；插入仍待实现。
- pasteboard fallback：已实现。
- 剪贴板恢复：已实现，写入后延迟恢复；如果期间剪贴板被用户改动则不覆盖。

验收：

- 在 Notes、Mail、Slack、VS Code 至少 4 个 App 中插入成功。
- 插入失败时不丢结果。
- 原剪贴板能恢复。

当前未完成项：

- 还没有跑真实目标 App 插入矩阵。
- 还没有对 Apple Speech on-device 做真实短音频延迟和准确率记录。
- 还没有做 IMK commit。当前先用 pasteboard 回退证明端到端体验。

### P0：iPhone 键盘桥接 POC

验证：

- 主 App 写 App Group。
- 键盘扩展读取最近结果。
- `textDocumentProxy.insertText` 插入。
- 插入策略可选双语或只译文。

验收：

- Messages、Mail、Notes 中可插入。
- 键盘无结果时能打开主 App。
- 数据不走网络。

补充授权要求：

- 不把 Full Access 放进首次启动。
- 主 App 录音路径不依赖键盘授权。
- 键盘增强插入必须有“不启用也能使用”的替代路径。

### P1：ASR Benchmark

候选：

- Apple Speech / SpeechAnalyzer。
- WhisperKit。
- whisper.cpp。
- FluidAudio / Parakeet CoreML。
- sherpa-onnx。
- 中文专项模型。

验收：

- 统一音频集。
- 输出 WER/CER、实体准确率、延迟、内存、耗电。
- 给出 Mac 默认引擎和 iPhone 默认引擎建议。

### P1：本地文本智能 Benchmark

候选：

- Foundation Models。
- MLX Swift。
- llama.cpp。
- 规则引擎。

任务：

- 纠错。
- 标点。
- 邮件润色。
- 条列化。
- 翻译术语约束。

验收：

- 每个任务有结构化输出。
- 低置信度能进入审阅。
- 不编造未说出的事实。

### P1：网络隔离 POC

验证：

- 本地模式下所有网络请求被拦截。
- ASR、纠错、翻译仍可运行。
- UI 能显示“本地模式”状态。

验收：

- 抓包无外发。
- 禁网后核心路径可用。

## 10. 当前判断

可以进入产品原型阶段。最大技术风险不是“能不能转写”，而是这三件事：

- iPhone 入口受限，需要设计用户能接受的折中体验。
- 本地模型要做到低延迟和少错改，需要真实 benchmark，且冷启动必须移出关键路径。
- iPhone 授权必须克制，默认路径只能问麦克风，增强键盘和个性化学习都要后置。
- 长期记忆必须防污染，否则越用越差。
