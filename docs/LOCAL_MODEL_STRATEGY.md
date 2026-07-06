# 本地模型策略：compose（润色 + 翻译）

版本：2026-07-05

## 1. 结论

统一模型（2026-07-05，详见 PRODUCT_TECH_DESIGN.md §0）：

- 纠错（热词/实体保真）属于 ASR 能力边界，不进文本智能层。
- Polish 是必经层，分级：规则地板永远可用，LLM 在 deadline 内返回才采用。
- 翻译是同一次 compose 调用多输出一个 `target` 字段，不是独立阶段、不是第二次调用。
- 专用翻译引擎（Apple Translation / 单独 LLM 翻译）是兜底槽位。

允许一次调用同时做润色和翻译的前提是输出结构化：`{"polished","target"}` 两个字段独立可评测、独立做语言校验。反对的从来是"不可评测的混合字符串输出"，不是"一次调用"。

第一版默认引擎：

| 任务 | iPhone 默认 | Mac 默认 | 原因 |
| --- | --- | --- | --- |
| ASR（含热词纠错） | 待真机评测：SpeechAnalyzer / WhisperKit / FluidAudio | 当前开发默认 `whisper.cpp` CLI；下一轮评测常驻方案 | Mac 先可体验；iPhone 不把默认路径绑到 Speech Recognition 权限 |
| compose（润色） | 规则地板 + Foundation Models 可用时增强 | 规则地板 + `Ollama qwen3:8b`（deadline 降级） | "每次输出都经过润色层"≠"每次都等 LLM"；LLM 不可用产品仍工作 |
| compose（+target） | LLM 可用时同一次调用；不可用时 Apple Translation 兜底 | 同一次 `Ollama qwen3:8b` 调用输出 target | 省一次 prompt eval；润色和翻译共享上下文与术语注入 |
| 翻译兜底槽位 | Apple Translation lowLatency | 当前 Ollama 单独翻译；候选 Apple Translation | 翻译模式没有"无模型"的规则降级，兜底槽位必须保留 |
| 术语约束 | 前处理 + 后处理 + 审阅 | 前处理 + 后处理 + 审阅 | 语言校验和术语检查在代码层做，不信任模型自觉 |

关键点：iPhone 上如果 Apple Foundation Models 不可用，产品仍然要能工作。输入模式降级到规则地板；翻译模式走 Apple Translation 兜底——这是常态路径，不是异常。

工程实现状态：

- `ASREngine`、`TextIntelligenceEngine`（单方法 `compose`）、`TranslationEngine`（兜底槽位）是可替换协议。
- Mac 当前可体验路径：录音 `.caf` -> 自动转 16k WAV -> `whisper-cli` -> 热词纠错（ASR 边界内，带词边界保护）-> qwen3 单次 compose（JSON `{"polished","target"}`，deadline 降级，双向语言校验）-> 双语渲染 -> pasteboard 插入（带目标 App 重激活保护）。
- 实测（M4 Pro，qwen3:8b warm）：翻译模式单次 compose 约 1.5-2.0s；冷路径由 deadline（当前翻译 6s）兜住并降级。
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
Velora/.build/debug/VeloraMac --mode input --audio /path/to.wav --source en --asr-mode accurate --json
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
  -> 作为 compose 的 LLM 层：润色结构化输出；是否同调用输出 target 待真机 POC
  -> 每次请求设置 deadline
  -> 超时返回规则地板结果

Foundation Models unavailable
  -> 规则地板 + 热词替换 + 格式模板
  -> 翻译走 Apple Translation 兜底槽位（iPhone 常态路径，不是异常）
```

iPhone 上 Foundation Models 是否承担 target 输出，取决于真机 POC 的语言对质量和延迟；在证明之前，iPhone 翻译默认走 Apple Translation 兜底槽位。原因：

- 翻译有专门的 Translation framework，语言对支持和延迟更可预测。
- iPhone 不能假设本地大模型一定存在，兜底槽位必须常备。

## 3. Mac 上的选择更多

Mac 生产默认仍优先考虑 Apple 原生能力，因为系统集成、安装体积和低功耗更好。但当前开发默认先走 `whisper.cpp + Ollama`，原因是它今天已经能完全本地跑通，不依赖系统 Speech 可用状态。

Mac 可选引擎分层：

| 层级 | 引擎 | 用途 | 是否进默认关键路径 |
| --- | --- | --- | --- |
| L0 | 规则、热词、模板 | compose 地板：标点、替换、轻量格式 | 是 |
| L1 | Apple Translation | 翻译兜底槽位 | 兜底时进入，必须带 deadline |
| L1 | Apple Foundation Models | compose 的 LLM 层（润色 + 可选 target） | 可进入，但必须带 deadline |

Mac ASR 现状（2026-07-05）：**SenseVoice-Small（sherpa-onnx int8）常驻 sidecar 为主引擎**，whisper.cpp 自动回退。80 条真实语料实测 SenseVoice 中文 CER 0.073 / 混说 0.190 / 英文 0.021，warm p50 ~50ms——比 whisper-large 快 18× 且质量追平，详见 `docs/ASR_POLISH_TUNING_REPORT.md §3.4`。VAD 由 sherpa-onnx 内建。记忆层已落地：`SQLiteMemoryStore` 从 correction journal（弹层修改 / retry / undo）增量学习热词与负反馈，连续 3 次拒绝自动停用。
| L2 | MLX Swift | 本地小模型实验，Apple Silicon 优化 | 先不默认 |
| L2 | llama.cpp | Mac 本地模型、量化模型、可控推理 | 先不默认 |
| L3 | Ollama | 当前开发期润色/翻译默认，快速切模型 | 生产默认要替换或常驻预热 |

Mac 的本地小模型可以更激进：

- 纠错：小型 instruct 模型或专门纠错模型。
- 润色：3B-8B 量化模型，按 deadline 返回。
- 翻译：只有在 Apple Translation 不支持语言对，或术语约束明显不够时，才引入本地 LLM 或专用 MT 模型。

## 4. 翻译管线

翻译模式不是直接把 ASR 原文送去翻译，也不是独立的翻译阶段。

默认流程：

```text
ASR candidates
  -> hotword/entity correction（ASR 能力边界内）
  -> compose 单次调用 -> { polished（保持源语言）, target }
  -> 语言校验（polished 不许是译文；target 不许是原文）
  -> glossary/entity consistency check
  -> bilingual renderer
  -> insert（reviewRequired 时先审阅）
```

兜底：compose 产不出 target 时走 TranslationEngine 槽位（Mac 当前 Ollama 单独翻译；iPhone 常态是 Apple Translation lowLatency）。

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

## 6. 润色（compose）管线

Polish 是必经层，但按分级实现，不是所有输入都等大模型。

```text
规则地板（VeloraTextComposer）
  -> 空白折叠、保留段落、按主导文字选终止标点、条列模板
  -> 毫秒级，永远可用

LLM compose（deadline 内返回才采用）
  -> 更好的语言组织、断句、场景排版；翻译模式同时输出 target
  -> 输出结构化 JSON，deadline 到期就返回规则地板结果并打 warning
```

compose 必须返回：

- `polishedText`（+ 翻译模式的 `targetText`）
- `edits`
- `glossaryHits`
- `warnings`
- `confidence`
- `reviewRequired`
- `engine`

禁止只返回一段改写后的字符串。否则无法解释错改，也无法做用户反馈学习。

## 7. 延迟策略

性能优先级高于“每次都最聪明”。

deadline（生产目标；开发期在 whisper CLI + Ollama 形态下放宽到输入 4s / 翻译 6s，主要兜 Ollama 冷路径长尾）：

| 任务 | Mac deadline | iPhone deadline | 超时策略 |
| --- | ---: | ---: | --- |
| compose（输入） | 250ms | 350ms | 上屏规则地板结果，后台可给优化版 |
| compose（翻译，含 target） | 500ms | 700ms | 规则地板 + 翻译兜底槽位；低置信则 review |
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

## 8.5 参数调优结论（2026-07-05，M4 Pro 实测）

评测资产在 `pocs/tuning/`（TTS 8 клип zh/en/混说 + 脏文本 9 条 + 扫格/评测脚本），11 组 whisper 参数 × 2 模型串行实测 + 7 组润色 prompt 对照 + 对抗复测。

ASR（已落码 `WhisperCLIConfiguration.tunedDecodeArguments`）：

- 安全组合 = greedy（`-bs 1 -bo 1`）+ 保留温度回退 + `-ac` 裁剪（`ceil(秒)*50+64`，下限 512）+ `-sns`。
- 实测：large-v3-turbo p50 923→467ms（质量持平），base p50 252→214ms；accurate 模式已能装进 1s 预算。
- 禁忌（实测翻车）：beam 与 `-ac` 任意组合（回退救不了 beam，CER 6.5）；`-ac` 下限低于 512（0.4s 短点按输出整句循环）；`-nf` 配 `-ac`（短中文 CER 10+）。
- 防线：ASR 前 RMS 静音门控（静音下 whisper 会幻觉真词"Thank you."/"你"/求赞句式，输出侧防不住）；输出侧幻觉黑名单 + 复读检测（命中则全量上下文重跑一次）。
- 未决 gate：greedy 无损结论基于 TTS 音频，真实麦克风（噪声/口音/远场）语料复测后才能进一步下沉产品默认。

润色（已落码 `OllamaPromptLibrary` + `VeloraTextComposer.strippedFillers`）：

- qwen3:8b 无论怎么写 prompt 都不删口癖（7 组候选实测），口癖清理下沉规则层：嗯/呃 仅限汉字夹缝与句首粘连形态（"嗯，好的"保留、唔 永不删、呃逆 豁免）；口吃折叠用填充词白名单（商量商量 类 ABAB 动词零误杀）；英文 um/uh 只删逗号定界形态且仅限英文源。
- prompt 重构为前缀可缓存：静态指令+few-shot 全在 system（字节级恒定），动态字段在用户段；实测 prefill 0.53s→0.11s。
- options：num_ctx 统一 4096（2048 会被真实最坏 prompt 静默击穿）；repeat_penalty 显式 1.0（qwen3:8b Modelfile 本值，1.1/1.05 会把照抄推向同义改写）；num_predict 随输入长度动态；预热必须用真实 system + 相同 options，否则预热本身制造首次重载。
- 可观测：load_duration>500ms 记 `ollama_model_reload` warning；prompt token 逼近 num_ctx 记 `ollama_ctx_pressure`。
- 注意：与其他 Ollama 客户端（默认 num_ctx）交替使用 qwen3:8b 会触发 2-4s 模型重载；前缀缓存收益依赖较新 Ollama（本机 0.31 实测多前缀共存）。

## 9. 当前产品决策

- 翻译：compose 单次调用直接输出 target 是默认路径（2026-07-05 反转旧决策）。Apple Translation 是兜底槽位，也是 iPhone 无本地 LLM 时的常态路径。
- 润色：必经层，规则地板 + LLM deadline 增强；Foundation Models 是 iPhone 首选增强引擎。
- Mac 实验：MLX Swift 和 llama.cpp 可以并行 benchmark，但先不绑死。
- iPhone 实验：不默认塞第三方 LLM 包，除非真机证明延迟、耗电、包体都可接受。
- 双语上屏：由产品合同保证，不由模型决定。
- 审阅：reviewRequired 驱动（语言校验失败、target 缺失、deadline 降级），不无条件审阅。
- 云端：默认禁用。network guard 默认阻断非 loopback 的 LLM endpoint，仅开发期可用 `VELORA_ALLOW_REMOTE_LLM=1` 显式覆盖，发布构建应禁用该覆盖。任何云翻译或云 LLM 都不是本项目第一版路径。

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
