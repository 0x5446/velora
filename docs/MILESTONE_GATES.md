# Milestone 关卡

状态日期：2026-11-16。协议见 [`ENGINEERING_PROTOCOL.md`](ENGINEERING_PROTOCOL.md)。审计见 [`M0_RESEARCH_AUDIT.md`](M0_RESEARCH_AUDIT.md)。方向见 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

**M0 通过。F0 和 F1 验收设施已在 Linux 上通过。M1 及以后的产品改动不得开始。** 质量阈值没有因为新的 Mac 摘要而降低。论文相对 4B / v4.1 的门槛改为 not judged，因为用户明确这次不跑 4B，也没有新的 v4.1 对照；不另写一个绝对百分比来顶替它们。F1 通过不是 M1 或 M5 通过。公共回放的 281.655 ms 也不是产品延迟。

## 全局目标

在 macOS 上保持 Velora 的本地语音输入：断网可用、音频和文本默认不出本机、松键后提交一次、翻译走确认卡、保真护栏和规则地板仍在。重构只为了缩短并稳定“松键到文本就绪”的等待，并且不增加幻觉或静默改义。

实现方向已经选定，见 [`ARCHITECTURE.md`](ARCHITECTURE.md)：带端点的流式识别、只常驻微调 1.7B、草稿是上一轮目标输出并精确核对、前缀缓存可回滚、过期结果不提交、输入模式只在结束时提交一次。选定方向不是质量通过，也不是延迟通过。现有产品文档中的预算（输入 warm p50 ≤ 800 ms、p95 ≤ 1.3 s；翻译 warm p50 ≤ 1.0 s、p95 ≤ 1.8 s）仍是设计目标，**未复测**。Mac 摘要里的 635.6 / 5017.2 / 6290.8 ms 是合成请求的完成时间，T4 为 null，不能拿来当作这些预算已达标或已失败。

## 共同失败条件

任一关出现下面情况即失败，停在该关：

- 报告缺硬件、模型摘要或数据哈希。F0 和 F1 不加载模型，所以没有权重哈希。F0 的报告里必须没有毫秒数。F1 可以引用已经归档的请求完成毫秒，但必须标明是引用，不能写成这次测出的 T4。这只说明设施测试本身，不是产品通过
- 用论文表格、调优报告、设计稿或 `docs/evidence/mac-2026-11-16/` 的合成请求毫秒数代替本次产品运行
- 用相对加速比代替绝对 T4；用重复文本上的高接受率代替自然听写
- 质量门禁失败后用“再跑几次”算通过（现行 `docs/LEARNING_PIPELINE.md` 的三次复跑规则只描述现状，不是后续关卡）
- 候选改动没有独立开关，或关掉开关后行为与上一关已记录的基线不一致
- 证据里出现密钥、用户 journal 原文或许可不允许再分发的语料

## M0 · 研究、可复现性与工程现状

目的：分清论文主张、已有实测和工程假设，并固定后续关卡。不做产品实现。

| 项 | 通过标准 | 2026-11-16 状态 |
|---|---|---|
| 源码与论文阅读 | 审计写明两边的 HEAD、机制差异、不能外推的数字 | 已完成。Velora `73e83ec`；研究仓库 `143a5f52` |
| 远程与本机差异 | 用户工作区 `git status` 与 `origin/main...HEAD` 已记录；未跟踪文件有清单 | **通过。** `HEAD` `73e83ec` 与 GitHub `main` 相同。tracked / staged diff 为空。未跟踪文件只有设计稿。本机 `origin/main` `accab725` 是过期 tracking，不是 GitHub HEAD |
| 研究资产 | 第 8 节只读清单逐项有“存在 + 哈希”或“缺失” | **通过，带未重算项。** 1.7B 单文件前缀匹配，但完整 sha256 复用先前验证，这轮没有重读权重。五个冻结清单匹配。0.6B、pcm 串接、v5.3 train/val 全文、4B 缓存未测，已写明 |
| 产品基线 | 不要求在 M0 测出延迟。要求写明当前没有可引用的 HEAD 实测 | 已写明。不是延迟通过 |
| 无产品改动 | M0 不改产品行为 | 仍然成立。F0 只加 CPU 设施，没有改 `Apps/` 或 `Velora/Sources/` |

**M0 总判定：通过。** 证据是 [`docs/evidence/m0/report.md`](evidence/m0/report.md)。1.7B 的完整 sha256 没有在这轮重算，报告里保持这个限制，不把它写成新的 `sha256sum`。未测的 0.6B、pcm 串接和 4B 缓存是记录过的缺口，不再当成“工作区证据没交到”。

M0 通过不测量产品 T4，也不允许改 `Apps/` 或 `Velora/Sources/`。下一项是 M1。

## F0 · 调度与精确草稿的 CPU 验收设施

前置：M0 的源码/论文阅读已完成，且 [`ARCHITECTURE.md`](ARCHITECTURE.md) 已写明方向。不要求 M0 的资产清单通过。允许的原因：目标 Mac 离线，产品基线测不了；用户要求在这种情况下先交付可执行的验收设施，而不是再写一份不能运行的计划。

范围：`pocs/speculative_replay/`。用假的因果 argmax 在 CPU 上锁定 `LocalPolisher` 的核对、前缀回滚、`max_tokens`、取消、过期结果丢弃，以及结束时只提交一次。不加载 1.7B，不测毫秒。

通过（2026-11-16 已满足，证据 [`docs/evidence/f0/report.md`](evidence/f0/report.md)）：

```bash
python3 -m unittest discover -s pocs/speculative_replay -p 'test_*.py'
```

在本环境退出码 0，当时 18 项。报告对象不含 `speedup`，`t4_ms` 为 null。F1 加入后同一命令会跑 32 项；F0 的通过记录仍以 [`docs/evidence/f0/`](evidence/f0/report.md) 为准。

失败：测试未运行却标通过；fixture 里写入非 null 的 `t4_ms`；把 F0 写成 M1 或 M5 通过。

F0 不测量真实 ASR 端点，也不测量松键到上屏。

## F1 · 端点 fixture、采集器、回放与计时契约

前置：F0 通过。不要求 M0 的资产清单。这是验收设施，不是产品关。允许的原因与 F0 相同：目标 Mac 离线，而用户要求先交付可运行的下一最小设施。

范围：仍是 `pocs/speculative_replay/`。采集器只收数字元数据，拒绝听写原文。CPU 回放按上下文长度、块长和接受档留下块记录，毫秒保持 null。已归档的 5017.2 ms 请求作为引用行拆开，不由 fixture 重新生成。

较早的 32 项运行漏了“token 数相同但内容不同”。这条补进契约之后才重跑。证据 [`docs/evidence/f1/report.md`](evidence/f1/report.md) 记录的是重跑：

```bash
python3 -m unittest discover -s pocs/speculative_replay -p 'test_*.py'
```

在本环境退出码 0。补上 revision 时是 38 项。同一命令在入库新实测并锁住 draft EOS 之后是 41 项，日志见 [`docs/evidence/f1/unittest.txt`](evidence/f1/unittest.txt)。具体锁住的断言：

- 采集器拒绝 `confirmed_text`、路径和其他字符串。端点和结束事件必须带 token id 的 sha256 `revision`。`confirmed_tokens` 相同而 `revision` 不同时必须重新生成，并提交新的输出 token。合成 trace 不能标成 representative。`t4_ms` 为 null。
- CPU 回放的 `model` 是 `cpu_mock`，`mlx_token_identity` 为 null。把后者写成 true 即失败。报告不含 `speedup`，块上没有 `elapsed_ms`。分组后的 `elapsed_ms` 仍是 null。
- 2026-11-16 较早的 32 项运行把相同 token 数当成内容没变。该判定作废。当前证据是补上 revision 之后的 38 项。
- 引用行 3099/442 保留 prompt 3099、窗口 16、接受 289/1151、verify 3691.4 ms、请求完成 5017.2 ms。组件中位数之和不等于总时间。`block_lengths_observed` 和 `per_block_milliseconds` 为 null。`may_generalize` 为 false。
- 引用行 9853/1024 的 `constructed_repeat` 为 true，草稿长度 18，接受数 920 可以大于草稿长度。标成 representative 即失败。

失败：把引用毫秒或 CPU 分组写成 T4；用 1.52 倍或 98.3% 接受率代替上述拆分；用 token 数判断内容没变还标通过；把 `cpu_mock` 写成 MLX 逐 token 一致；为了让本关通过而放宽 M1–M6。

F1 没有逐块实测 3691.4 ms。归档摘要只有合计。逐块 `context_tokens`、`block_len`、`accepted` 和 `elapsed_ms` 仍要等目标机器上的数字日志。

## M1 · 产品基线（仍不改用户可见行为）

前置：M0 通过。环境：目标 Mac，记录 `sysctl -n machdep.cpu.brand_string`、内存、macOS 版本、Xcode、Swift、Ollama 版本、`ollama show qwen3:8b` 的摘要、SenseVoice `model.int8.onnx` 的 sha256。Linux CI 不能代替本关。

测量对象是现行 Mac 产品路径：`SenseVoiceASREngine` 整段识别 + `OllamaTextIntelligenceEngine`（默认 `qwen3:8b`）+ 现有护栏 + 现有一次粘贴。`VeloraDiagnostics asr` 构造的是 `WhisperCLIASREngine`，不能当作这条路径。`debugInjectClip` 会走产品管线，但要求开发者模式并且会粘贴；用它时必须把模型就绪和粘贴分开计时。

三个现成数字不是同一个指标，报告里要分列：

- HUD `wall_ms`：输入模式含粘贴。
- `PipelineTrace.releaseToInsertMS`：`critical` 阶段之和。`context_capture` 和 `hotword_rank` 仍标成 `after_release`，即使控制器已在录音期算过。
- Ollama 响应里的 `prompt_eval_count`、`load_duration`。当前客户端没有把 eval duration 解码进 `OllamaGenerateOutput`；M1 若要 prefill/decode 分段，先记录响应里实际有的字段，缺的字段写 blocked，不要用调优报告填。

指标：

- 松键到润色文本就绪：p50、p90，以及样本量允许时的 bootstrap 95% CI。粘贴单独记。
- 分段：ASR、规则地板、LLM 等待、护栏、失败回退。预热是否落在录音期内，单独记。
- 质量：先沿用 M2 定稿前的现行六套脚本，结果标成“非确定性现状”，不作为回归通过。
- 内存：录音前、模型常驻后、一次长句之后，分别记录 Velora、sidecar Python 和 `ollama` 的 RSS。能耗若无仪表，写明 blocked，以及 `powermetrics` 是否被允许。不要估一个瓦数。
- `LatencyBudgetTests` 通过不算测量。那些阶段时长是源码里的常数。

通过：`docs/evidence/m1/report.md` 含上述字段、命令、n、音频清单哈希、模型摘要。音频本身不入库。缺音频或模型则整关 blocked，不编造 n。

本关结束时必须 **事前登记** M5 的延迟规则：比较对象是 M1 基线，统计是配对差的 bootstrap 95% CI，最小效应由 M1 的区间宽度和产品预算缺口决定。登记之前最小效应保持 TBD。不得把设计稿的 30% 或 20% 抄进来。

失败：任一必填字段缺失；或报告把调优报告的 50 ms / 600–1700 ms 写成这次的测量。

## M2 · 可执行的质量契约

前置：M0 通过。可以与 M1 的证据收集并行准备脚本，但在 M0 通过前不改产品提示词或默认模型。

范围：把现行六套文本门禁变成失败即非零、可重复的检查。

- 脚本：`pocs/tuning/repair_eval.py`、`format_eval.py`、`homophone_eval.py`、`ambiguity_eval.py`、`translate_repair_eval.py`、`filler_eval.py`。
- 现行问题（源码事实，不是新测量）：候选从 `/tmp/velora-eval/` 读取，不读仓库里的 `*_candidates.json`；请求温度 0.1。`docs/LEARNING_PIPELINE.md` 允许偶发失败后再跑三次。`scripts/quality_eval.py` 检查诊断报告的 `output`，而 `VeloraDiagnostics text` 把 `output` 设为 `finalText`。翻译的 `finalText` 是待上屏译文，`PipelineOrchestratorTests` 断言它不含 `原文:`；双语对照在 `translation.displayText`。因此现行 `quality_eval` 翻译用例与现行契约不一致。本环境没有运行该脚本，所以这不是一次已观察到的失败，而是 M2 必须消除的契约错位。
- 通过：温度 0 或等价的贪心设置下，同一模型摘要连续两次命令退出码和逐条判定一致；六套全过才算过；`quality_eval` 要么改测现行契约，要么从门禁中删除并在 devlog 说明。模型摘要写进证据。
- 失败：任何一套失败；或仍依赖“复跑三次”。
- 语义保真与幻觉：沿用现有护栏所覆盖的 URL、邮箱、路径、标识符、数字、术语和过短相似度。不在本关发明新的幻觉分数。论文的检查项通过率是另一份提示词（`polish_v3.3.txt`）上的结果，不能当作这六套的分数。

现行文档记录的 `qwen3:8b` 分数（14/14、15/15、10/10、11/11、8/8、11/11）是 2026-07 的历史结果。M2 未重跑前，这些分数 **不是本 HEAD 的通过记录**。

## M3 · 会话健壮性基线

前置：M0 通过。在目标 Mac 上对 **未改行为** 的构建做检查。目的是让以后的加速不能悄悄破坏这些路径。

必须有命令或 UI 步骤，并留下日志：

| 场景 | 要留下的观察 | 代码阅读不能代替的部分 |
|---|---|---|
| 录音中 Esc | HUD 文案，以及 caf 是否还在 | 本环境未跑 |
| 管线进行中 Esc | 是否粘贴，任务是否还在跑 | 未跑 |
| 录音中切换 App | 录音是否继续；最终粘贴进哪个应用 | 未跑。松键时的前台由 `MacInsertionTarget.captureFrontmost()` 读取，这只是源码事实 |
| 松键时目标不可用 | 是否发送 ⌘V | 未跑 |
| 无语音 / sidecar 失败 / Ollama 不可用 | 各自的 HUD 或是否落到规则地板；学习 journal 有没有写入这次文本 | 未跑 |
| 断网且未设 `VELORA_ALLOW_REMOTE_LLM` | 实际请求的端点和错误正文。`ComposeEngineTests` 只拒绝非环回 URL | 未跑 |
| 安全输入框 | 是否写入学习。判决函数在 `MacLearningPrivacy` | 未跑 |

通过：每行有一次成功观察或一次明确的产品缺陷记录。缺陷可以记入后续修复关，但不能写成“已正常”。自动化测试优先；做不到时用步骤加日志，并写明不能在 Linux 上复现。

失败：用代码阅读代替一次运行；或把“代码看起来会取消”写成测试通过。

## M4 · 机制决定

前置：M1、M2、M3 都通过。本关只提交一份决定，不改调度。

方向已经按 [`ARCHITECTURE.md`](ARCHITECTURE.md) 选定。M4 仍然未通过：没有 M1–M3 的产品证据之前，不能把这条方向写成默认行为，也不能开始改 `Apps/` 或 `Velora/Sources/`。

相对当初的四条：

1. 只换更小的 Ollama 模型：不作为这条重构的方向。
2. 用现有 SenseVoice 对累计音频整段重识别：不采用。那不是论文的端点，也不是 `LocalPolisher` 的输入。
3. 端点式流式识别：方向的一部分。和 SenseVoice 的质量对比仍是产品关的必做项，现在没有。
4. 逐请求历史输出做精确草稿：方向的另一部分。Mac 摘要只证明合成请求上的逐 token 一致和请求完成时间，不证明产品 T4。论文 A10G 上更快不是选择理由。

通过：`docs/evidence/m4/decision.md` 引用 M1–M3 的产物路径，确认产品路径仍守住一次提交、取消、焦点、离线和保真，并重复 M1 已登记的延迟规则。没有这条规则，决定无效。

失败：在 M1–M3 之前改产品默认路径；或用合成请求的相对倍数宣布延迟达标。

## M5 · 实现所选定的一个机制

前置：M4 通过。一个开关，默认保持 M1 的行为，直到本关证据通过后才讨论默认打开。

通过（全部）：

- M2 六套在同一模型摘要上不下降。
- M3 各场景不比基线记录更差。新失败即失败。
- 延迟满足 M1 登记的规则。规则未登记则本关不能开始。
- 报告内存增量。能耗沿用 M1 的方法；M1 若为 blocked，这里仍是 blocked，不能改口说“功耗可接受”。
- 离线：新进程若会下载模型，安装步骤必须显式、可关闭，运行时默认不访问网络。证据是一次断网运行的日志。
- 关掉开关后，用 M1 的回放命令得到与基线同一路径。

失败：质量、取消、焦点、粘贴或离线任一回归；延迟 CI 跨过登记的零点或没达到最小效应；需要常驻两个润色模型才能工作。

## M6 · 依赖与发布

前置：M5 通过，且决定将该机制作为默认。

通过：

- 模型文件、Ollama 标签或 GGUF、sidecar 依赖有版本和哈希，安装文档与代码搜索路径一致。现行 README 写的 Application Support SenseVoice 路径与 `SenseVoiceASREngine.resolvedDefault` 不一致，发布前必须消除。
- 没有新增默认出站。
- 发布物仍是开发签名或文档如实写明未公证。不把“已公证”写成完成，除非公证日志存在。
- devlog 与 handoff 指向该发布的证据目录。

失败：权重来源不明；运行时从公网拉取模型；文档仍描述另一条引擎为默认。

## 明确不在这些关卡里的事

- 不把流式逐字粘贴列进计划。现行产品是一次粘贴；论文的 T3 依赖插入过程中的流式输出。
- 不把 LA-2 式冻结已提交文本列进计划。论文表明它会丢掉跨句改口。
- 不把 v5.3 1.7B 写成已经胜过底座 4B 的产品模型。它是用户指定的唯一常驻模型。相对 4B 和 v4.1 的原门槛是 not judged，不是通过。
