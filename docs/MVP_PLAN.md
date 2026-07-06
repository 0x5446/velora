# MVP 执行计划

版本：2026-07-05

统一语言（详见 PRODUCT_TECH_DESIGN.md §0）：两个模式（输入/翻译）；纠错属于 ASR 能力；Polish 是必经层且分级；翻译=同一次 compose 调用多输出一个语种字段；专用翻译引擎是兜底槽位。

## 1. MVP 定义

MVP 要证明这句话：

用户按住快捷键自然说话，Velora在本地结合语境、热词做识别和润色，把文本插入当前输入位置；翻译模式默认插入原文和译文。

MVP 不追求：

- 完整 App Store 上架。
- 多端同步。
- 所有语言支持。
- 完美 UI 动效。
- 企业级管理。

## 2. 阶段划分

当前状态：Phase 0 已完成。2026-07-05 完成统一模型重构：两模式（input/translate）、compose 单次调用（规则地板 + Ollama JSON 输出 + deadline 降级 + 语言校验）、翻译审阅改为 reviewRequired 驱动、插入带目标 App 保护、network guard、模型路径启动方式无关、trace 诚实化（未并行前 context/hotword 计入关键路径）、Fn 停止零消歧延迟。实测 warm 翻译单次 compose 约 1.5-2.0s（qwen3:8b），Ollama 冷路径由 deadline 兜住。已完成：常驻 ASR（SenseVoice sherpa-onnx 替换 whisper CLI，18× 提速）、录音期并行化（context/hotword 移进录音期）、SQLite 记忆层（从 correction journal 学习）、插入机制自检脚本。下一步是目标 App 插入矩阵真人验收、speculative compose 移进录音期，以及 Phase 4 的真机键盘插入验证。

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

状态：进行中。AVAudioEngine 录音和 `audioPath` pipeline 已接通；`whisper.cpp` CLI adapter 已接入 Mac 默认 POC，`.caf` 录音会自动转 16k WAV；Ollama `qwen3:8b` 已接入 compose（单次调用出 polished + target）。默认 `Fn`（输入）、`Fn ⇧`（翻译）、可切换 Space 组合键、实时音量 voice bar、pasteboard+CmdV 插入（fail-closed 目标 App 保护）、剪贴板延迟恢复、真实 stage tracing、模型预热、ASR 模型模式、compose 与翻译兜底的 deadline/降级链均已实现并通过测试。还缺目标 App 插入矩阵验收、IMK/AX 更稳插入路径、录音期并行化，以及 Apple/WhisperKit/FluidAudio 真实 benchmark。

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
- Mac 主 ASR 已切 SenseVoice-Small（sherpa-onnx int8 常驻 sidecar），whisper.cpp 自动回退；80 条真实语料实测胜出（详见调优报告 §3.4）。
- 实现 `MacContextProvider`。
- 实现 `MacInsertionEngine`。
- 实现 streaming partial 和 speculative compose；CLI adapter 只能做 finalize，不是最终形态。
- 把 context capture、hotword ranking 移到录音期间。当前 trace 诚实标记为 `after_release` 且计入关键路径；真正移进录音期后再改标 `during_recording`。
- 做 Notes、Mail、Slack、VS Code 插入验证。

验收：

- 10 秒以内短句可以录音、识别、上屏。
- 默认不联网（network guard 默认阻断非 loopback 的 LLM endpoint；仅开发期可用 `VELORA_ALLOW_REMOTE_LLM=1` 显式覆盖，发布构建应禁用该覆盖）。
- 插入失败时结果留在浮动条并可复制。
- 输入 warm path p50 释放后到上屏低于 800ms，p95 低于 1.3s。
- 翻译 warm path p50 释放后到上屏低于 1.0s，p95 低于 1.8s。
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
- 强化 `HotwordCorrector`（保持在 ASR 能力边界内）：分数阈值、上下文门控、中文同音词保守匹配、低置信替换触发审阅。

验收：

- 至少 20 个自定义术语可命中。
- 诊断能看到选中热词和原因。
- 错改可以拒绝并降低权重。
- 不把完整历史注入模型。

### Phase 3：润色和翻译模式

周期：1 周。

交付：

- `输入 / 翻译` 两模式打磨（compose 单次调用合同已落地）。
- 翻译语言对设置。
- 双语上屏（已默认）。
- `target_only` 和 `review_card` 插入策略（已实现）。
- Apple Translation 接入兜底槽位（TranslationEngine）。

任务：

- 接 Apple Translation 作为兜底翻译引擎。
- 扩展语言检测覆盖（NLLanguageRecognizer），解除 zh/en/ja/ko 限制。
- 完善 reviewRequired 触发面（术语冲突、命名实体不一致）。
- 加邮件、条列、简洁三种润色风格（compose style 参数已预留）。

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
// 热词纠错 HotwordCorrector 属于 ASR 能力边界，orchestrator 在 ASR 输出后立即执行，
// 结构化 edits 保留给诊断和反馈学习。

public protocol ContextProvider {
    func currentSnapshot(for request: PipelineRunRequest) async -> ContextSnapshot
}

public protocol MemoryStore {
    func rankHotwords(for snapshot: ContextSnapshot, limit: Int) async throws -> [HotwordCandidate]
}

// 单次调用：必经润色 + 可选目标语言（翻译模式多一个输出字段）。
public protocol TextIntelligenceEngine {
    func compose(_ request: ComposeRequest) async throws -> ComposeResult
}

// 兜底槽位：compose 产不出 target 时才使用。
public protocol TranslationEngine {
    func translate(_ request: LocalTranslationRequest) async throws -> LocalTranslationOutput
}

public protocol InsertionEngine {
    func insert(_ request: InsertionRequest) async throws -> InsertionResult
}
```

## 5. 决策记录

| 决策 | 结论 | 原因 |
| --- | --- | --- |
| 先 Mac 后 iPhone | 是 | Mac 可实现完整体验，能先验证核心价值 |
| iPhone 键盘直接录音 | 不作为目标 | 自定义键盘扩展不能访问麦克风 |
| 默认双语翻译 | 是 | 这是对 Typeless 翻译模式的明确补强 |
| 默认云端禁用 | 是 | 隐私和速度是产品基础；network guard 默认阻断非 loopback，开发期显式 env 覆盖，发布禁用 |
| 性能优先 | 是 | release-to-insert 是核心指标，北极星任何模式 p50 ≤ 1s，冷启动不能进默认路径 |
| iPhone 授权最小化 | 是 | 首次启动 0 弹窗，默认录音只问麦克风 |
| 只注入 Top K 热词 | 是 | 控制隐私、延迟和 prompt 污染 |
| 两模式统一语言（2026-07-05） | 输入 / 翻译 | 纠错归 ASR 能力；Polish 是必经层不是模式；dictate/polish 旧值归一到 input |
| Polish 必须但分级（2026-07-05） | 规则地板 + LLM deadline 增强 | "每次输出都经过润色层"≠"每次都等 LLM"；LLM 不可用产品仍工作 |
| 翻译默认引擎（2026-07-05 反转） | compose 单次调用直接输出 target | 省一次 prompt eval；润色和翻译共享上下文与术语。专用翻译引擎降为兜底槽位（iPhone 无 LLM 时走 Apple Translation） |
| 翻译审阅策略（2026-07-05） | reviewRequired 驱动，不无条件审阅 | 语言校验失败、target 缺失、deadline 降级才进审阅 |
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
cd /Users/alpha/workspace/velora
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
