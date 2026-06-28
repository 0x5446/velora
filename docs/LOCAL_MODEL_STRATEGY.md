# 本地模型策略：翻译、纠错、润色

版本：2026-06-28

## 1. 结论

翻译和润色不能用同一个“大 prompt”解决。Velora的默认策略是拆成三个任务：

- Correction：纠错、标点、实体保真。
- Polish：按场景轻量润色和排版。
- Translation：专用翻译引擎生成目标语言，再由渲染层双语上屏。

第一版默认引擎：

| 任务 | iPhone 默认 | Mac 默认 | 原因 |
| --- | --- | --- | --- |
| ASR | 待真机评测：SpeechAnalyzer / WhisperKit / FluidAudio | 当前开发默认 `whisper.cpp` CLI；下一轮评测 SpeechAnalyzer / WhisperKit / FluidAudio | Mac 先可体验；iPhone 不把默认路径绑到 Speech Recognition 权限 |
| 纠错 | 规则 + 热词 + Foundation Models 可用时补充 | 当前规则 + 热词；上下文 LLM 纠错后置 | 纠错必须低延迟、可解释、少错改 |
| 润色 | 规则 + Foundation Models，可用性不满足时降级 | 当前 `Ollama qwen3:8b`；生产候选 Foundation Models / MLX / llama.cpp | 润色需要本地 LLM 能力，但冷启动不能进关键路径 |
| 翻译 | Apple Translation low-latency 优先，LLM 兜底 | 当前 `Ollama qwen3:8b`；生产候选 Apple Translation lowLatency + LLM 术语修正 | 翻译先验证双语产品合同，后续按语言对和延迟换引擎 |
| 术语约束 | 前处理 + 后处理 + 审阅 | 前处理 + 后处理 + 审阅；必要时本地 LLM 二次修正 | Apple Translation 不应被当作可完全控术语的 LLM |

关键点：iPhone 上如果 Apple Foundation Models 不可用，产品仍然要能工作。基础体验不能依赖“端侧大模型一定存在”。

工程实现状态：

- `ASREngine`、`TextIntelligenceEngine`、`TranslationEngine` 已经是可替换协议。
- Mac POC 已接 `WhisperCLIASREngine`、`OllamaTextIntelligenceEngine`、`OllamaTranslationEngine`。当前可体验路径是：录音 `.caf` -> 自动转 16k WAV -> `whisper-cli` -> 热词纠错 -> qwen3 润色/翻译 -> 双语渲染 -> pasteboard 插入。
- `AppleSpeechASREngine` 仍保留为可选 adapter，但本机实测出现 `kLSRErrorDomain Code=201`，说明系统 Speech/Siri/Dictation 当前不可用，不能作为唯一默认 ASR。
- iOS 默认路径暂不绑定 Apple Speech。原因是 Apple Speech 会引入 Speech Recognition 权限，不符合“首次启动 0 弹窗、默认录音只请求麦克风”的目标。
- 当前已下载并验证 `ggml-base.bin`、`ggml-tiny.bin`、`ggml-large-v3-turbo-q5_0.bin`。Mac adapter 已支持 `fast / accurate / fallback` 三种 ASR 模型模式，而不是靠文件候选顺序隐式选择。
- 模型可以在工程完成后替换，但替换必须经过同一套评测：错词率、实体准确率、release-to-insert、冷启动、内存、耗电、授权成本、离线行为。

## 1.1 2026-06-28 模型判断

Mac 本地 ASR 不能简单说“Whisper 就是最优解”。当前更准确的判断是：

| 候选 | 当前定位 | 优点 | 风险 |
| --- | --- | --- | --- |
| Apple SpeechAnalyzer / SpeechTranscriber | Apple 平台系统候选，必须 POC | 系统管理模型、实时 AsyncSequence、系统语言资源、低集成成本 | iOS/macOS 26+；语言包下载和可用性要实测；不能覆盖旧系统 |
| WhisperKit / Argmax OSS Swift | Apple 原生 Swift/CoreML Whisper 路线 | iOS/Mac 统一，实时、VAD、时间戳、模型选择成熟 | Whisper 系模型在英文极速和专名召回上未必最强；热词能力要自建 |
| FluidAudio / Parakeet CoreML | 英文和低延迟强候选 | CoreML/ANE、本地低延迟，含 VAD/diarization 生态，Parakeet v3 CoreML 可用 | 中文和中英混说不是强项；项目变化快，API 要锁版本 |
| whisper.cpp | 当前工程默认开发 adapter | 安装快、Metal 可用、CLI 和 C API 成熟、模型易换 | CLI 进程启动、文件 I/O 和 `.caf` 转换有额外开销；不是最终低延迟形态 |
| NVIDIA Parakeet / NeMo / MLX 路线 | 英文和欧洲语言极速候选 | Parakeet 0.6B v3 在公开榜单上 WER/吞吐强，社区已有 Apple CoreML 转换 | 官方模型主要 25 个欧洲语言；中文不适合作为唯一默认 |

短期策略：`whisper.cpp` 负责把产品闭环跑起来。中期策略：同一套 `ASREngine` 评测 SpeechAnalyzer、WhisperKit、FluidAudio/Parakeet。最终默认不按名气选，按本机评测集的 CER/WER、实体准确率和 release-to-insert 选。

当前 Mac ASR 模式：

| 模式 | 首选模型 | 用途 | 备注 |
| --- | --- | --- | --- |
| `fast` | `ggml-base.bin` | 默认体验，优先低延迟 | 当前 UI 和菜单默认；中文混英文术语仍要依赖热词纠错 |
| `accurate` | `ggml-large-v3-turbo-q5_0.bin` | 术语、人名、混说更敏感的场景 | 实测质量更稳，但 CLI 路径短句也可能到 2.6-4.0s |
| `fallback` | `ggml-tiny.bin` | 模型缺失、极限低资源、故障兜底 | 不能作为质量标杆 |

环境变量也可切换：

```bash
VELORA_WHISPER_MODE=accurate
VELORA_WHISPER_MODE=fast
VELORA_WHISPER_MODE=fallback
```

CLI 也可以切换：

```bash
Velora/.build/debug/VeloraMac --mode dictate --audio /path/to.wav --source en --asr-mode accurate --json
```

显式模型路径仍然优先：

```bash
VELORA_WHISPER_MODEL=/absolute/path/to/ggml-large-v3-turbo-q5_0.bin
```

## 2. iPhone 上有没有可调用的本地大模型

有，但不能把它当成无条件存在的基础设施。

Apple Foundation Models framework 可以让 App 调用系统本地语言模型能力，适合结构化输出、摘要、改写、分类、工具调用一类任务。它依赖 Apple Intelligence 可用状态。真实产品里必须在运行时检查：

- 设备是否支持 Apple Intelligence。
- 用户是否开启 Apple Intelligence。
- 模型资源是否 ready。
- 当前语言是否支持。
- 当前请求是否适合端侧模型。

因此 iPhone 策略是：

```text
Foundation Models available
  -> 用于 Correction / Polish 的结构化输出
  -> 每次请求设置 deadline
  -> 超时返回规则引擎结果

Foundation Models unavailable
  -> 规则引擎 + 热词替换 + 格式模板
  -> 翻译仍走 Apple Translation
```

不把 Foundation Models 作为默认翻译主引擎。原因：

- 翻译有专门的 Translation framework。
- 翻译模式需要更稳定的语言对支持和更低延迟。
- LLM 翻译更难保证术语一致性、低功耗和可预测延迟。

## 3. Mac 上的选择更多

Mac 生产默认仍优先考虑 Apple 原生能力，因为系统集成、安装体积和低功耗更好。但当前开发默认先走 `whisper.cpp + Ollama`，原因是它今天已经能完全本地跑通，不依赖系统 Speech 可用状态。

Mac 可选引擎分层：

| 层级 | 引擎 | 用途 | 是否进默认关键路径 |
| --- | --- | --- | --- |
| L0 | 规则、热词、模板 | 标点、替换、轻量格式 | 是 |
| L1 | Apple Translation | 翻译 | 是 |
| L1 | Apple Foundation Models | 纠错、润色、结构化输出 | 可进入，但必须带 deadline |
| L2 | MLX Swift | 本地小模型实验，Apple Silicon 优化 | 先不默认 |
| L2 | llama.cpp | Mac 本地模型、量化模型、可控推理 | 先不默认 |
| L3 | Ollama | 当前开发期润色/翻译默认，快速切模型 | 生产默认要替换或常驻预热 |

Mac 的本地小模型可以更激进：

- 纠错：小型 instruct 模型或专门纠错模型。
- 润色：3B-8B 量化模型，按 deadline 返回。
- 翻译：只有在 Apple Translation 不支持语言对，或术语约束明显不够时，才引入本地 LLM 或专用 MT 模型。

## 4. 翻译管线

翻译模式不是直接把 ASR 原文送去翻译。

默认流程：

```text
ASR candidates
  -> hotword/entity correction
  -> corrected source text
  -> Apple Translation low-latency
  -> glossary/entity consistency check
  -> bilingual renderer
  -> insert
```

双语上屏由渲染层保证，不依赖翻译模型。

默认插入：

```text
原文:
{correctedSourceText}
译文:
{targetText}
```

如果用户选择 `target_only`，UI 仍展示双语审阅，插入时只插目标语言。

## 5. 术语和上下文如何参与翻译

术语不靠“把所有历史塞给 LLM”解决。

处理顺序：

1. 从当前 App、窗口标题、附近文本、长期记忆中选 Top K 热词。
2. 翻译前保护实体：人名、产品名、会议名、代码名、英文术语。
3. 调用翻译引擎。
4. 翻译后做术语一致性检查。
5. 如果命名实体丢失、术语冲突或语言对低置信，进入 review，不静默上屏。

示例：

```json
{
  "source_text": "明天上午十点我和 Alex 开会，帮我确认一下 agenda。",
  "corrected_source_text": "明天上午十点我和 Alex 开会，帮我确认一下 agenda。",
  "target_text": "I have a meeting with Alex tomorrow at 10 a.m. Please help me confirm the agenda.",
  "glossary_hits": ["Alex", "agenda"],
  "warnings": []
}
```

## 6. 润色管线

润色按场景分级，不能所有输入都调用大模型。

```text
基础清理
  -> 口癖删除、重复词删除、标点、段落
  -> 100ms 级别

场景模板
  -> 邮件、条列、会议纪要、聊天
  -> 规则 + 小模板

Foundation Models / 本地小模型
  -> 只处理需要改写的部分
  -> 输出结构化 edits
  -> deadline 到期就返回前一层结果
```

润色必须返回：

- `finalText`
- `edits`
- `warnings`
- `confidence`
- `reviewRequired`

禁止只返回一段改写后的字符串。否则无法解释错改，也无法做用户反馈学习。

## 7. 延迟策略

性能优先级高于“每次都最聪明”。

默认 deadline：

| 任务 | Mac deadline | iPhone deadline | 超时策略 |
| --- | ---: | ---: | --- |
| correction reconcile | 100ms | 150ms | 插入规则纠错结果 |
| polish reconcile | 250ms | 350ms | 先插基础整理，后台给优化版 |
| translation reconcile | 300ms | 450ms | 插入已有翻译；低置信则 review |
| bilingual render | 20ms | 20ms | 必须同步完成 |

不允许进入 release-to-insert 关键路径：

- 模型冷启动。
- 大模型长生成。
- 语言包下载。
- 网络请求。
- 全量历史检索。

## 8. 需要真机 POC 的问题

必须在目标设备上实测，不能凭文档判断：

| 问题 | POC |
| --- | --- |
| Foundation Models 在目标 iPhone 上是否可用 | 真机 availability probe |
| Foundation Models 中文润色是否稳定 | 50 条中文口语样本 |
| Apple Translation 语言包下载和离线行为 | 飞行模式 + 预下载语言包测试 |
| low-latency 与 high-fidelity 的差异 | 同一评测集延迟、质量、耗电对比 |
| 本地 LLM 是否值得进入 Mac 默认路径 | MLX / llama.cpp 延迟和错改率 benchmark |
| 术语一致性是否足够 | 100 条中英混说 + 专有名词测试 |

## 9. 当前产品决策

- 翻译：Apple Translation 是 Apple 平台第一默认。
- 润色：Foundation Models 可用时作为第一本地智能引擎，不可用时降级到规则和模板。
- Mac 实验：MLX Swift 和 llama.cpp 可以并行 benchmark，但先不绑死。
- iPhone 实验：不默认塞第三方 LLM 包，除非真机证明延迟、耗电、包体都可接受。
- 双语上屏：由产品合同保证，不由模型决定。
- 云端：默认禁用。任何云翻译或云 LLM 都不是本项目第一版路径。

## 10. 调研来源快照

2026-06-28 查到的高价值来源：

| 方向 | 来源 | 对本项目的影响 |
| --- | --- | --- |
| Apple SpeechAnalyzer | `developer.apple.com/documentation/speech/speechanalyzer`、`developer.apple.com/documentation/speech/speechtranscriber` | SpeechAnalyzer 是 Apple 新一代本地实时转写 API，必须做功能和延迟 POC |
| Apple Translation | `developer.apple.com/documentation/translation/translationsession`、`translationsession/strategy/lowlatency` | TranslationSession 声明文本内容在用户设备上处理，`lowLatency` 可作为翻译默认候选 |
| Apple Foundation Models | `developer.apple.com/documentation/foundationmodels`、`languagemodelsession` | 适合纠错、润色、结构化输出，但要检查 Apple Intelligence、语言和上下文限制 |
| Argmax OSS / WhisperKit | `github.com/argmaxinc/argmax-oss-swift` | Apple 平台 Whisper/CoreML 路线成熟，适合替换 whisper.cpp CLI 的低延迟实现 |
| FluidAudio / Parakeet CoreML | `github.com/FluidInference/FluidAudio`、`huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml` | ANE/CoreML 方向值得 POC，尤其英文极速路径 |
| llama.cpp / MLX Swift | `github.com/ggml-org/llama.cpp`、`github.com/ml-explore/mlx-swift` | Mac 本地 LLM 的两条主线；生产要按延迟、内存和可集成性选 |
| Qwen3 | `github.com/QwenLM/Qwen3`、`qwen.readthedocs.io` | 当前 Ollama `qwen3:8b` 可作为开发期本地 LLM；生产要用非 thinking 模式和短 prompt |
