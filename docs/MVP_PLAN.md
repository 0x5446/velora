# MVP 执行计划

版本：2026-06-28

## 1. MVP 定义

MVP 要证明这句话：

用户按住快捷键自然说话，Velora在本地结合语境、热词和模式，把文本插入当前输入位置；翻译模式默认插入原文和译文。

MVP 不追求：

- 完整 App Store 上架。
- 多端同步。
- 所有语言支持。
- 完美 UI 动效。
- 企业级管理。

## 2. 阶段划分

当前状态：Phase 0 已完成。Mac 和 iOS/Keyboard 目标已经能构建；核心 pipeline 合同可跑通；iOS App Group 候选写入已在模拟器验证。Phase 1 已进入系统级输入体验：Mac 已有默认 `Fn`、翻译 `Fn ⇧`、可切换 Space 组合键、非激活 voice bar、`whisper.cpp` 本地 ASR、Ollama 本地润色/翻译、pasteboard 插入回退和剪贴板恢复。真实 stage tracing、模型预热、ASR 模型模式已落地。下一步是目标 App 插入矩阵验收、Ollama deadline/fallback、WhisperKit / SpeechAnalyzer / FluidAudio POC，以及 Phase 4 的真机键盘插入验证。

### Phase 0：工程骨架和合同

周期：2-3 天。

状态：已完成。

交付：

- Swift workspace：`Velora.xcodeproj`。
- `CorePipeline` Swift package：`Velora`。
- `PlatformMac` App target：`VeloraMacApp`。
- `PlatformiOS` App target：`VeloraiOS`。
- `KeyboardExtension` target：`VeloraKeyboard`。
- `VeloraTests`：39 个测试。
- 数据合同 Codable 定义：pipeline、translation mode、keyboard bridge、latency、authorization。

任务：

- 定义 `DictationSession`、`ContextSnapshot`、`MemoryTerm`、`PipelineResult`。
- 定义 `ASREngine`、`TextIntelligenceEngine`、`TranslationEngine`、`InsertionEngine` 协议。
- 接 SQLite。
- 接简单日志和耗时 tracing。
- 定义 release-to-insert tracing，所有 pipeline stage 都必须带耗时。

验收：

- 单元测试能跑：已通过。
- 一个 fake ASR 可以走完整 pipeline：已通过。
- fake result 能从 Mac/iOS UI 展示：已通过。
- fake pipeline 能输出 release-to-insert latency report：已通过。
- iOS 主 App 能写 App Group payload：已通过。

### Phase 1：Mac 本地输入 MVP

周期：1 周。

状态：进行中。AVAudioEngine 录音和 `audioPath` pipeline 已接通；`whisper.cpp` CLI adapter 已接入 Mac 默认 POC，`.caf` 录音会自动转 16k WAV；Ollama `qwen3:8b` 已接入润色和翻译。默认 `Fn`、翻译 `Fn ⇧`、可切换 Space 组合键、实时音量 voice bar、pasteboard+CmdV 插入回退、剪贴板延迟恢复、真实 stage tracing、模型预热和 ASR 模型模式均已实现并通过测试。还缺目标 App 插入矩阵、IMK/AX 更稳插入路径、Ollama deadline/fallback，以及 Apple/WhisperKit/FluidAudio 真实 benchmark。

交付：

- 菜单栏 App。
- 全局快捷键：默认 `Fn` toggle，翻译默认 `Fn ⇧`；设置面板可改为 `⌥ Space`、`⌃ Space`、`⌘ ⇧ Space` 等备选。
- AVAudioEngine 录音。
- 浮动录音条：非激活 voice bar，不抢目标 App 焦点；录音时显示实时音量、计时和停止键位。
- 一个本地 ASR 引擎。当前提供 `fast=base`、`accurate=large-v3-turbo`、`fallback=tiny` 三种模式。
- 当前 App 和窗口上下文采集。
- 插入 fallback：当前为 pasteboard+CmdV，并在短延迟后恢复原剪贴板。
- 模型预热和 warm/cold 状态提示。主 UI 启动会预热当前 ASR 模式和 Ollama；切换 ASR 模式后会预热对应模型文件。
- CLI benchmark 入口：`--asr-mode fast|accurate|fallback`。

任务：

- 实现 `AudioCaptureService`。
- 实现 VAD 或最小静音检测。
- 当前已接 `whisper.cpp` CLI 作为第一个真实 ASR；下一步评测 SpeechAnalyzer、WhisperKit、FluidAudio/Parakeet。
- 实现 `MacContextProvider`。
- 实现 `MacInsertionEngine`。
- 实现 streaming partial 和 speculative correction；CLI adapter 只能做 finalize，不是最终形态。
- 把 context capture、hotword ranking 移到录音期间。当前 trace 已标记为 `during_recording`，但录音控制器还需要真正提前触发。
- 做 Notes、Mail、Slack、VS Code 插入验证。

验收：

- 10 秒以内短句可以录音、识别、上屏。
- 默认不联网。
- 插入失败时结果留在浮动条并可复制。
- Dictate warm path p50 释放后到上屏低于 700ms，p95 低于 1.2s。
- Translate warm path p50 释放后到上屏低于 1.1s，p95 低于 1.8s。
- 冷启动必须被识别并显示，不能算作默认路径成功。

### Phase 2：热词和纠错

周期：1 周。

交付：

- 本地 memory SQLite。
- 热词管理 UI。
- Top K 热词选择。
- 纠错结构化输出。
- 诊断视图。

任务：

- 移植 `context_hotword_poc.py` 的 ranking 策略到 Swift。
- 增加手动热词。
- 增加 accepted correction 记录。
- 增加拒绝纠错的负反馈。
- 实现 CorrectionEngine 第一版：规则 + 本地 LLM 或 Foundation Models。

验收：

- 至少 20 个自定义术语可命中。
- 诊断能看到选中热词和原因。
- 错改可以拒绝并降低权重。
- 不把完整历史注入模型。

### Phase 3：润色和翻译模式

周期：1 周。

交付：

- `Dictate / Polish / Translate` 模式。
- 翻译语言对设置。
- 双语上屏。
- `target_only` 和 `review_card` 插入策略。
- Apple Translation 或本地翻译引擎接入。

任务：

- 移植 `translation_mode_poc.py` 的输出合同到 Swift。
- 实现 `TranslationResultRenderer`。
- 接 Apple Translation。
- 加 glossary hits。
- 加低置信度 review。
- 加邮件、条列、简洁三种润色风格。

验收：

- 中文说话可输出英文，并默认插入原文和英文。
- 英文说话可输出中文，并默认插入原文和中文。
- 用户可切换只插入译文。
- 翻译结果保留术语。

### Phase 4：iPhone 主 App 和键盘桥接

周期：1-2 周。

状态：进行中。主 App、Keyboard Extension、App Group payload/store 已完成；模拟器已验证主 App 自动写候选。还缺真机签名、键盘启用流程、目标 App 中实际插入验证。

交付：

- iPhone 主 App Record 页。
- History 页。
- Memory 页。
- Settings 页。
- Keyboard extension。
- App Group 结果共享。
- Shortcut 入口。
- 授权引导和拒绝后的替代路径。

任务：

- 主 App 实现录音和 pipeline。
- 首次启动不请求任何权限。
- 第一次录音前解释麦克风用途，再触发系统弹窗：主 App 已实现本地 preflight sheet。
- 默认本地 ASR 不请求 Speech Recognition。
- 键盘扩展实现候选条。
- 主 App 处理完成后写入 App Group。
- 键盘读取最近结果并插入。
- 增加剪贴板 fallback。
- 写清楚键盘不能直接录音的用户流程。
- 把 Keyboard Full Access 放到增强插入设置，不进入首轮引导。

验收：

- 主 App 能本地识别和翻译。Mac 已跑通，iPhone 待真机模型选型。
- 首次启动 0 系统权限弹窗。
- 默认录音路径只请求麦克风。
- 键盘能插入最近结果。
- Messages、Mail、Notes 插入可用。
- 翻译模式能插入双语。
- 不开启增强键盘时，复制/分享/快捷指令路径仍可用。

当前真机状态：

- 本机可用 Apple Development identity：`HKGB6V2DA9`。
- 当前连接的 `iphone17` 在 `devicectl` 中是 `unavailable`，尚不能部署。
- 通用真机 build 需要 provisioning profile。未传 `-allowProvisioningUpdates` 时会因为 `app.velora.ios` 和 `app.velora.ios.keyboard` 没有 profile 失败。

### Phase 5：评测和打磨

周期：1 周。

交付：

- 300 条评测集。
- Typeless 对比表。
- ASR benchmark 报告。
- 本地模型 benchmark 报告。
- 网络隔离报告。
- 性能优化清单。

任务：

- 建音频和期望文本。
- 跑 WER/CER 和实体准确率。
- 跑延迟和内存。
- 跑 iPhone 耗电和发热。
- 跑 iPhone 授权漏斗：首次启动、第一次录音、拒绝麦克风、开启增强键盘、拒绝 Full Access。
- 对比 Typeless 在同任务上的最终上屏结果。

验收：

- 明确 Mac 默认 ASR。
- 明确 iPhone 默认 ASR。
- 明确文本智能默认引擎。
- 默认本地模式无网络。
- release-to-insert 达到预算。
- iPhone 首次启动 0 弹窗，默认录音 1 个系统弹窗。
- 找出至少 3 个明显超过 Typeless 的场景。

## 3. 第一版文件结构建议

```text
Velora/
  Package.swift
  Apps/
    VeloraMac/
    VeloraiOS/
    VeloraKeyboard/
  Sources/
    CorePipeline/
      Contracts/
      Orchestrator/
      Audio/
      ASR/
      Context/
      Memory/
      TextIntelligence/
      Translation/
      Rendering/
      Insertion/
      Diagnostics/
    PlatformMac/
    PlatformiOS/
  Tests/
    CorePipelineTests/
    MemoryTests/
    TranslationModeTests/
  Models/
    README.md
  Docs/
```

## 4. 关键协议草案

```swift
public protocol ASREngine {
    var id: String { get }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult
}

public protocol ContextProvider {
    func currentSnapshot(mode: DictationMode) async -> ContextSnapshot
}

public protocol MemoryStore {
    func rankHotwords(for snapshot: ContextSnapshot, limit: Int) async throws -> [HotwordCandidate]
    func recordFeedback(_ feedback: CorrectionFeedback) async throws
}

public protocol TextIntelligenceEngine {
    func correct(_ request: CorrectionRequest) async throws -> CorrectionResult
    func polish(_ request: PolishRequest) async throws -> PolishResult
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
}

public protocol InsertionEngine {
    func insert(_ text: String, strategy: InsertionStrategy) async throws -> InsertionResult
}
```

## 5. 决策记录

| 决策 | 结论 | 原因 |
| --- | --- | --- |
| 先 Mac 后 iPhone | 是 | Mac 可实现完整体验，能先验证核心价值 |
| iPhone 键盘直接录音 | 不作为目标 | 自定义键盘扩展不能访问麦克风 |
| 默认双语翻译 | 是 | 这是对 Typeless 翻译模式的明确补强 |
| 默认云端禁用 | 是 | 隐私和速度是产品基础 |
| 性能优先 | 是 | release-to-insert 是核心指标，冷启动不能进默认路径 |
| iPhone 授权最小化 | 是 | 首次启动 0 弹窗，默认录音只问麦克风 |
| 只注入 Top K 热词 | 是 | 控制隐私、延迟和 prompt 污染 |
| 翻译默认引擎 | Apple Translation | 专用翻译优先于通用 LLM，双语上屏由渲染层保证 |
| 润色默认引擎 | 规则 + Foundation Models 可用时补充 | iPhone 不能假设本地大模型一定可用，必须可降级 |
| Mac 本地 LLM | MLX / llama.cpp 只做 benchmark 候选 | 先证明延迟、错改率、耗电，再决定是否进入默认路径 |
| Clean-room 实现 | 是 | 避免开源许可证风险 |

## 6. 每周检查项

每周必须回答：

- 本地模式有没有任何网络请求？
- 用户说完到上屏的 p50 / p95 是多少？
- 有没有冷启动进入默认录音路径？
- iPhone 首次启动是否仍然 0 弹窗？
- 默认录音路径是否仍然只请求麦克风？
- 哪些词被错误纠正了？
- 哪些热词被选中，理由是什么？
- iPhone 流程是不是多了一步但仍能完成？
- 翻译模式是否默认保留原文？
- 新增代码是否让核心 pipeline 更难替换模型？

## 7. 下一步命令

当前工程已建立。下一步常用验证命令：

```bash
cd /Users/alpha/Documents/workspace/velora
xcodegen generate
swift test --package-path Velora
xcodebuild -project Velora.xcodeproj -scheme Velora -destination 'platform=macOS' build
python3 /Users/alpha/.agents/skills/ios-simulator-skill/scripts/build_and_test.py --project Velora.xcodeproj --scheme VeloraiOS --json
```

下一步工程任务：

- Mac：实现全局快捷键、浮动录音条、pasteboard/AX 插入 fallback。
- Mac：用真实短音频测试 `AppleSpeechASREngine`，记录冷启动、授权、on-device 支持和转写延迟。
- iPhone：补 Development Team 后真机部署，验证 App Group entitlement 和键盘插入。
- 模型：接 WhisperKit、SpeechAnalyzer、FluidAudio/Parakeet，跑同一套音频集和延迟 benchmark。

实际建 Swift workspace 时再决定是否用 XcodeGen、Tuist 或原生 Xcode project。当前阶段先不引入项目生成器，避免过早增加工具复杂度。
