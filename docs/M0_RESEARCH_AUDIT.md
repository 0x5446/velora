# M0 研究、可复现性与工程现状审计

状态日期：2026-11-16。协议见 [`ENGINEERING_PROTOCOL.md`](ENGINEERING_PROTOCOL.md)。关卡见 [`MILESTONE_GATES.md`](MILESTONE_GATES.md)。

**判定：未通过。** 源码和论文阅读完成。用户本机工作区、研究权重、v5 音频和 Velora 在目标 Mac 上的现行行为都没有在本环境核实。没有 `docs/evidence/m0/report.md`。不得把本文件写成 M0 通过，也不得开始 M1 及以后的产品改动。

证据等级沿用工程协议。下面每节标题后的括号是该节的主等级。混在一节里的例外会单独标出。

## 1. 本次实际执行的检查

环境：Linux 云端虚拟机，`uname` 为 `Linux 6.12.113+ x86_64`。`swift`、`xcodebuild`、`ollama` 不在 `PATH`。没有 NVIDIA GPU。`/Users/alpha/workspace` 不存在。未运行 `swift test`、`xcodebuild`、六套门禁、`scripts/quality_eval.py`，也未重跑论文。

| 检查 | 命令或接口 | 结果 |
|---|---|---|
| Velora `origin/main` | `git fetch origin main` 后 `git rev-parse origin/main`；随后 `git ls-remote origin refs/heads/main` | 两者都是 `73e83ec44363a1968c61da4865fb594bacbeda82` |
| 三笔提交是否在该 `main` 上 | `git merge-base --is-ancestor` | `e1f1e12`、`0a64eec`、`73e83ec` 都是祖先 |
| 本分支相对 `origin/main` | `git rev-list --left-right --count origin/main...HEAD`（文档提交前） | `0 0` |
| 设计稿是否已在 `origin/main` | `git ls-tree -r --name-only origin/main` | 没有 `SPECULATIVE_POLISH_UPGRADE.md`，也没有本审计文件 |
| 设计稿副本 | `sha256sum docs/m0/inputs/SPECULATIVE_POLISH_UPGRADE.md` | `fb7fb5e51e8d992e475eb758d4757d299ddb71169c87a193898ee6957d8129b6` |
| 研究仓库元数据 | GitHub API `GET /repos/0x5446/speculative-dictation` | 私有，默认分支 `main`，`pushed_at` `2026-11-16T08:21:38Z` |
| 研究仓库 HEAD | 同一 API 的 commits 列表 | `143a5f52ce380b00a4dda43c3e105d6bc0ace131`，说明为 `paper: explain T3 vs T4 gap ...` |
| 研究仓库 git 树 | `GET /repos/0x5446/speculative-dictation/git/trees/143a5f52?recursive=1` | 490 个条目，`truncated: false`。无 `.safetensors`、`.gguf`、`.onnx`、`.bin`、`.pt` |
| 研究仓库 git 凭据 | `git ls-remote https://github.com/0x5446/speculative-dictation.git HEAD` | `remote: Repository not found` |
| GitHub CLI 身份 | `gh repo view 0x5446/speculative-dictation` | `Could not resolve to a Repository`。CLI 身份看不到该私有库 |
| 论文与冻结说明 | API 读取 `paper/main.tex`、`paper/tables/*.tex`、`results/paper/v5-freeze.md`、`realx-freeze.md`、`gentest-freeze.md`、`verify-cost.md`、`experiments/verify_cost_mlx.py`、`rerun/config.env`、`.gitignore`、`README.md` | 读到的是上述 SHA 的文件。没有本地工作副本 |

研究仓库的阅读只来自仓库所有者的 GitHub API。本环境没有它的 clone，也没有向它推送。

## 2. 远程与本机差异尚未消除

任务说明写的是：`/Users/alpha/workspace/velora` 的 `main` 比当时的 `origin/main` 多三笔提交，并且有未跟踪的 `docs/SPECULATIVE_POLISH_UPGRADE.md`。

2026-11-16 这次 `git fetch` 看到的 GitHub `main` 已经是 `73e83ec`，三笔提交都在上面：

| SHA | 日期（提交说明时区） | 说明 | 本提交触及的路径 |
|---|---|---|---|
| `e1f1e12a1115a0afbdbaa457780b4d4ffcbe1208` | 2026-07-14 20:48 +0800 | polish quality round：filler、段落、六套门禁、resident `keep_alive` | `LocalModelEngines.swift`、`TextComposition.swift`、两处测试、`LEARNING_PIPELINE.md`、`LOCAL_MODEL_STRATEGY.md`、`pocs/tuning/*`、`.review/2026-07-14-polish-filler-paragraph-review.md` |
| `0a64eecb217f7a9fb5b21940c7420103403c44db` | 2026-07-14 20:56 +0800 | Apple Speech 热词 contextual phrases | 只改 `AppleSpeechASREngine.swift`，给非空 `contextualPhrases` 设置 `contextualStrings` |
| `73e83ec44363a1968c61da4865fb594bacbeda82` | 2026-07-14 21:25 +0800 | 对齐 README 与调优报告 | `README.md`、`README.zh-CN.md`、`docs/ASR_POLISH_TUNING_REPORT.md` |

这三笔提交没有把设计稿带进 git。若某台机器的 `origin/main` 仍旧停在 `accab72` 之前，需要补的就是上表这些路径的 diff，而不是一份未知补丁。当前 GitHub 不缺这三笔。

仍然未消除的差异：

- `/Users/alpha/workspace/velora` 没有挂载。本审计看不到那台机器的 `git status`、未暂存 diff，以及其他未跟踪文件。任务点名的设计稿只以本次附件副本存在，路径是 `docs/m0/inputs/SPECULATIVE_POLISH_UPGRADE.md`。不能推断用户磁盘上的路径、是否还有第二份改动，或工作区是否干净。
- 因此不能写“已充分理解用户本地树”。充分理解的缺口就是第 8.1 节那四条只读命令的输出。
- 设计稿是研究输入，不是已批准架构。它里面的 P0–P4、30%、20% 和工时不进入关卡。其中对当前源码位置的描述（`startRecording` 759、`stopAndRunPipeline` 867、`makePipeline` 1352）与本 HEAD 行号一致；延迟数字仍是历史报告或待测项，不是本 HEAD 的实测。

## 3. 两个仓库各自是什么

### 3.1 Velora（源码事实）

公开仓库 `https://github.com/0x5446/velora`。产品是 macOS 菜单栏听写：`Fn` 切换录音，`Fn⇧` 进入翻译，Esc 取消，翻译走确认卡后单语上屏。当前上屏实现是 pasteboard + ⌘V，并在松键时记下前台应用再激活。`docs/POC_RESULTS.md` 写明还没有做 InputMethodKit commit。`docs/PRODUCT_TECH_DESIGN.md` 仍把 IMK 写成入口。代码里的 `InputMethodKit` 只出现在延迟预算注释和文档，没有 IMK 提交实现。

现行 Mac 路径：

1. 录音开始时启动 Ollama `prewarm()`，并异步做上下文与热词准备（`MacSystemInputController.startRecording`）。
2. `AVAudioEngine` 把整段写成 `.caf`。录音中不做识别。
3. 松键后 `stopAndRunPipeline` → `runPipeline`。先取松键时的前台应用，再 `await` 录音期准备任务。
4. `makePipeline` 优先 `SenseVoiceASREngine`，资产缺失时回退 `WhisperCLIASREngine`。文本引擎是 `OllamaTextIntelligenceEngine`。插入引擎是 `MacPasteboardInsertionEngine`。
5. SenseVoice 是常驻 Python sidecar，一行 JSON 进、一行 JSON 出，请求带整段音频路径。`transcribe` 不接收 partial，也没有端点回调。
6. compose 先算规则地板，再在 deadline 内调一次 Ollama。输入默认 deadline 4000 ms，翻译 6000 ms（`ComposeRequest`）。这是放弃 LLM、改发规则结果的上限，不是已测到的延迟。
7. 输入模式直接粘贴。翻译模式总是确认卡（控制器注释，2026-07-05 产品决定）。

Ollama 调用（`OllamaLocalClient.generateDetailed`）：`POST` 到 `127.0.0.1:11434/api/generate`，`stream: false`，`format: json`，`think: false`，`temperature` 默认 0.1，`num_ctx` 4096，`repeat_penalty` 1.0。模型名默认 `qwen3:8b`，可用 `VELORA_OLLAMA_MODEL` 覆盖。非环回端点在未设置 `VELORA_ALLOW_REMOTE_LLM=1` 时抛 `network_guard_blocked_non_loopback`。`ComposeEngineTests` 覆盖了这个拒绝。这是单元测试，不是一次拔网线的运行。

输入模式 user 段顺序：`app_format_profile`、`sound_alike`、`correction_history`、非 clean 的 `style`、`nearby_context`、`输入：`。system 字符串是常量。依赖当前转写的 `sound_alike` 和 `correction_history` 排在 `输入：` 之前。

保真护栏在采纳 LLM 润色前检查：URL、邮箱、路径样字面量、标识符、数字（检测到自纠正信号时允许数字变化）、词表实体，以及长度 ≥12 且无自纠正信号时相似度低于 0.5 的过度改写。这是现行契约，不是论文的检查项通过率。

`SenseVoiceASREngine.resolvedDefault` 只搜索 `VELORA_SENSEVOICE_ROOT`、进程当前目录、`~/workspace/velora` 下的 `Models/sensevoice/`。README 还写了 `~/Library/Application Support/Velora/`。Application Support 在代码里用于热词 FST、学习数据和可选录音保留，不用于这个模型解析。这个不一致留到发布关，不在 M0 改行为。

`VeloraDiagnostics asr` 构造的是 `WhisperCLIASREngine`，不是 SenseVoice。`text` 子命令的 `output` 是 `PipelineRunResult.finalText`。翻译模式下 `finalText` 是确认后要上屏的译文；`PipelineOrchestratorTests` 断言它不含 `原文:`，双语对照在 `translation.displayText`。`scripts/quality_eval.py` 的翻译用例却要求 `output` 含 `原文:`。按当前源码，这条检查对不上现行契约。M2 要处理它，本审计不把它算作已失败的一次运行，因为脚本没有在这里执行。

`LatencyBudget` 把 `streaming_asr_partial` 和 `speculative_compose` 放进录音期阶段，时长写死为 0。`LatencyBudgetTests` 比较的是这些常数（例如输入路径 `compose == 250`，翻译 `compose_bilingual == 420`）。测试通过只说明常数满足常数，不是本 HEAD 的延迟分布。`PipelineTrace.releaseToInsertMS` 是标记为 `critical` 的阶段毫秒之和。编排器仍把 `context_capture` 和 `hotword_rank` 标成 `after_release` 且 critical；控制器若已在录音期算完，这两段的测量值会接近等待缓存快照的时间，标签本身并不改成 `during_recording`。HUD 的 `wall_ms` 在输入模式包含粘贴。三个数不是同一个指标。

`docs/MVP_PLAN.md`（2026-07-05）把“speculative compose 移进录音期”写成当时的下一步，并把测试数写成 39。那是过期计划，不是本审计批准的机制。`docs/LEARNING_PIPELINE.md` 记录的六套分数 14/14、15/15、10/10、11/11、8/8、11/11 是文档中的 2026-07 历史结果，温度 0.1，并允许偶发失败后再跑三次。本环境没有重跑。

### 3.2 speculative-dictation（论文主张 + 仓库记录的实测）

私有仓库。同一 HEAD 里有两套不能混用的说明。

- `README.md` 描述早期演示：Soniox `stt-rt-v5` + `gpt-4.1-mini`，合成语音，每条件 5–6 次，并写“真人语音评估进行中”。运行入口是 `pipeline/bench.py`，依赖 `OPENAI_API_KEY` 和 `SONIOX_API_KEY`。`pipeline/requirements.txt` 只有 `aiohttp` 和 `numpy`。
- `paper/main.tex` 是 2026-11 草稿，标题 *Speculative Regeneration over Streaming Input*。正文实验是另一套系统，数字来自 `results/rerun/make_tables.py` 生成的 `paper/tables/numbers.tex`。重跑依赖在 `rerun/requirements.txt`（含 `sherpa-onnx==2.0.1`）。机器相关覆盖写在被忽略的 `rerun/config.local.env`。

按 README 的 `bench.py` 不能复现正文表格。本审计没有运行其中任何一个。

正文方法（`paper/main.tex` 第 3–4 节，论文主张）需要同时具备：

1. 带端点的流式识别器。实现描述是 sherpa-onnx 的 X-ASR 中英 transducer，480 ms 分块，尾静音 0.3 s 判端点。松键后再送 1.5 s padding。论文明确不另加 VAD，也不在未确认的 partial 上重生成。
2. 端点处对“到目前为止的已确认转写”整段重生成。提示词只追加，上一轮输出不写回提示词。
3. 上一轮输出作为该请求自己的投机解码草稿，并用精确校验。实现是 vLLM 0.18 的 per-request draft 补丁（`experiments/vllm_draft`）。服务模型是 Qwen3-4B-Instruct-2507，FP8，temperature 0，单张 NVIDIA A10G 24 GB。
4. 只在下一轮开始时取消。松键后若转写又变了，再跑一轮；已完成就整段插入，否则边生成边插入。T3 是松键到第一个插入字符，T4 是松键到最后一个插入字符。

正文自己的限度（仍是论文主张，不是 Velora 指标）：

- 全量主表 n=220：本文方法 T4 P50 487 ms [462, 513]，P90 765 ms [724, 819]；最强松键后基线 B3 P90 2066 ms。T3 全体 P50 146 ms。硬件是 A10G，识别器是 X-ASR，输出会流式插入。Velora 是整段粘贴，没有这条 T3。
- 没有草稿时，提前重生成主要藏掉首 token。长段完成时间回到基线量级（消融 P90：有草稿 854 ms，无草稿 2077 ms）。
- 无损指 batch-invariant kernel 下 162/162 与同提示词贪心解码一致。默认 kernel 下与 B3 逐字相同的只有 91/220。延迟表用的是更快的默认 kernel。
- 微调 Qwen3-1.7B v5.3 没有达到事先登记的门槛：realx v2 上相对底座 4B 为 +1.2 pp [−1.5, +4.0]。论文把它写成未通过。相对只在合成数据上训练的 v4.1 是 +3.5 pp [+1.2, +5.8]。删掉旧说法的比例约 50–56%，底座 4B 为 69%。提示词是 `polish_v3.3.txt`，sha256 `d7e55c158e10bcd7b4ae8d8c373ccc74ed6388cc701330319f01ab89c93f358b`，与 Velora 的 `OllamaPromptLibrary.inputSystem` 不是同一份契约。
- 附录硬件：同一协议（600 个已缓存 token，一次前向送入 k 个新 token，30 次中位数）。M4 Pro 4-bit、k=8 为 46.9 ms，是单步 14.0 ms 的 3.36 倍；k=128 为 16.4 倍。bf16 下 k=8 为单步的 1.15 倍，8-bit 为 2.16 倍。A10G bf16 上 k=128 约 1.11 倍。论文据此写：校验若接近 k 个单步的代价，草稿收益很小。
- 这些 M4 数字是前向微基准，不是听写端到端，也不是 Velora 的 Ollama 路径。`experiments/verify_cost_mlx.py` 入库版本默认只加载 `mlx-community/Qwen3-4B-Instruct-2507-4bit`，没有 8-bit 或 bf16 参数。`results/paper/verify-cost.md` 指向 `verify-cost-m4.json` 与 `verify-cost-a10.json`，两份都不在 git 树里。8-bit 和 bf16 两行只有生成后的表格，没有可在本环境重放的原始 JSON。

`.gitignore` 忽略模型、多数音频、多数结果和 `rerun/config.local.env`。git 树里仍有早期演示的 `data/audio/short.pcm`、`data/audio/long.pcm` 和一部分 `data/results/**/*.jsonl`。那是 README 时代的合成演示，不是 v5.3 训练集，也不是 realx v2。忽略规则不会把已跟踪文件移出历史。

## 4. 设计稿与论文的差别（工程判断，不是测量）

`docs/m0/inputs/SPECULATIVE_POLISH_UPGRADE.md` 提出三层：换更小的 Ollama 模型；录音期用 RMS 静音把“开头到现在”的整段音频送进现有 SenseVoice 再润色；条件满足再自建 mlx 草稿 sidecar。

这不是论文算法的移植：

- 论文的触发点是流式识别器端点，不是 RMS，也不是每 3 秒强制切一刀。SenseVoice 在 Velora 里没有端点。
- 论文认为决定性部件是逐请求草稿。设计稿把草稿放在第三层，并承认 Ollama、llama.cpp 服务和上游 mlx-lm server 都不能把一段文本当草稿传入。这个“现成运行时不支持”的句子是设计稿的工程判断；本审计没有在本机运行这三个运行时去复核。
- 设计稿里的 T4 下降 30% 和再降 20% 没有来自 Velora 基线。关卡不采用。
- 设计稿引用的 50 ms、600–1700 ms、prefill 0.53 s→0.11 s、冷重载约 4 s，都能在 `docs/ASR_POLISH_TUNING_REPORT.md` 或源码注释里找到出处。它们是 2026-07 调优记录，不是这次审计的复测，也不是论文表格。

可以保留的研究结论只有定性的：若设备上多 token 校验不便宜，只做“提前跑同一遍解码”主要影响首 token 之后的等待；Velora 是否属于这种情况，要由 M1 的分段计时决定。在那之前四个候选都保持关闭。

## 5. 架构取舍

全局目标写在 [`MILESTONE_GATES.md`](MILESTONE_GATES.md)。这里只固定选择空间。M4 之前不改调度。

产品约束，来自当前代码和产品文档，后续机制必须守住：音频和文本默认不出本机；非环回 LLM 默认失败；输入模式松键后提交一次；翻译走确认卡；规则地板和保真护栏仍在；学习不读安全输入框。iOS 键盘不在这轮范围里。

| 候选 | 它实际依赖什么 | 与论文的关系 | 现在不能选它的原因 |
|---|---|---|---|
| A. 松键后仍单次 compose，只换已过 M2 的更小 Ollama 模型 | 现有 sidecar 与 Ollama | 不使用论文调度。论文的 1.7B 是另一份提示词，且未胜过底座 4B 的事先门槛 | 没有本 HEAD 的质量复跑和延迟分布 |
| B. 录音期用现有 SenseVoice 对累计音频整段识别并 compose | 现有两段运行时，外加调度和取消 | 不是论文算法。论文拒绝在未确认 partial 上重生成；无草稿时完成时间仍随解码增长 | 没有累计音频的识别耗时，也没有前缀是否稳定的测量 |
| C. 先换成带端点的流式识别器，再谈提前重生成 | 新的识别器、端点协议、以及和现有护栏的衔接 | 这才是论文调度的前提。识别器仍不是 Velora 的 SenseVoice | 没有在目标 Mac 上比较过 X-ASR 与 SenseVoice 的质量和端点行为 |
| D. 自建可接收逐请求草稿的解码器 | 新 sidecar、本地权重、取消和回退 | 论文在 A10G 上把它当作决定性部件。M4 4-bit 微基准显示 k=8 已是单步的 3.36 倍，且没有 Velora 听写上的接受率 | 论文没有 Mac 端到端听写结果；8-bit/bf16 原始 JSON 不在 git 中 |

明确不做：流式逐字粘贴；LA-2 式冻结已提交文本；把 v5.3 1.7B 直接换成产品模型；把论文 A10G 的 765 ms 或调优报告的 600–1700 ms 写成产品 SLO；同时实现两个候选。

内存约束来自产品文档的量级（常驻润色模型约 6 GB）和研究冻结说明里的多模型目录。任何方案同时预热两个润色模型，都要在 M5 失败。本环境没有测量这个 6 GB。

## 6. 阶段

执行顺序和通过条件只以 [`MILESTONE_GATES.md`](MILESTONE_GATES.md) 为准。摘要：

| 关 | 做什么 | 2026-11-16 |
|---|---|---|
| M0 | 本审计与协议 | 未通过。阅读完成；资产与用户工作区 blocked |
| M1 | 在目标 Mac 上测量现行路径，不改行为 | 未开始。门槛里的最小效应仍是 TBD |
| M2 | 把六套文本门禁变成可重复失败 | 未开始。历史分数不是通过记录 |
| M3 | 记录取消、失焦、粘贴失败、无语音、sidecar/Ollama 失败、断网、安全输入的现行行为 | 未开始。代码阅读不能代替一次运行 |
| M4 | 只选 A/B/C/D 之一 | 未开始。必须引用 M1–M3 产物 |
| M5 | 实现那一个，默认开关保持 M1 行为 | 未开始 |
| M6 | 依赖哈希、离线安装、签名状态与文档一致 | 未开始 |

M1 与 M2 的证据收集可以在 M0 通过后并行准备。M0 通过前不改提示词、默认模型和调度。

## 7. 成功与失败

M0 的通过只有一种写法：第 8 节每一行都有“存在 + 哈希”或“缺失/blocked”的记录，写进 `docs/evidence/m0/report.md`，并且没有未解释的空行。用户工作区若还有设计稿以外的未提交 diff，报告必须列出路径和 diff 统计，不能写“无差异”。

失败条件：

- 把论文宏、调优报告或设计稿百分比写成 Velora 已达标。
- 在资产清单未齐时把 M0 改成通过。
- 用 `LatencyBudgetTests` 或历史六套分数充当 M1/M2。
- 用 `VeloraDiagnostics asr` 的 whisper 路径充当 SenseVoice 产品基线。
- 修改 `speculative-dictation`、推送用户机器上原有的未提交内容、合并本 PR 或部署。

## 8. 只读资产清单

在持有文件的机器上执行。只打印路径、是否存在、字节数和 sha256。不要 `git add`，不要推送，不要下载或覆盖权重，不要把听写原文、`config.local.env` 或 `.env` 的内容打出来。原始音频和权重不入库；证据目录只收命令、哈希和聚合结论。

### 8.1 用户的 Velora 工作区

在 `/Users/alpha/workspace/velora` 执行：

```bash
git rev-parse HEAD
git status --short
git diff --stat
git diff --cached --stat
git rev-parse origin/main
```

判定：

- `HEAD` 与 `origin/main` 都是 `73e83ec`，且 `status` 只有设计稿或已经为空：提交差已闭合。设计稿内容以本仓库副本的 sha256 为准，不必再粘贴正文。
- `status` 还有其他路径：把 `git diff --stat` 和未跟踪路径清单补进 `docs/evidence/m0/report.md`。这是剩余的最小 diff。不要粘贴文本内容。
- `HEAD` 不是 `73e83ec`：先报告 `git log --oneline origin/main..HEAD`。不要为了“对齐”而推送或重置那台机器。

### 8.2 研究仓库记录的路径

这些路径来自 `results/paper/v5-freeze.md`、`realx-freeze.md`、`gentest-freeze.md` 和 `rerun/config.env`。它们是文档中的位置，不是本环境里的存在性证明。`config.local.env` 若存在会覆盖默认路径；只记录它是否存在和字节数，不打印内容。

| 记录位置 | 记录的哈希或标识 | 本地只读检查 |
|---|---|---|
| `/home/ubuntu/specdict-rerun/pipeline/prompts/polish_v3.3.txt`，以及仓库内 `pipeline/prompts/polish_v3.3.txt` | sha256 `d7e55c158e10bcd7b4ae8d8c373ccc74ed6388cc701330319f01ab89c93f358b` | `sha256sum` 全文。仓库副本可以用 API 或 clone 后核对；本审计未对工作副本做 `sha256sum` |
| `/home/ubuntu/specdict/models/qwen3-1_7b-xcorr-v53` | 冻结说明写“safetensors 拼接 sha256 前 16 位” `eabcdc5c813b1e0b` | 列出目录内文件名和字节数，对每个 `*.safetensors` 做 `sha256sum`。拼接顺序的命令不在本次读到的冻结说明里，前缀是否吻合标 blocked，直到找到原始命令 |
| `/home/ubuntu/specdict/models/qwen3-0_6b-xcorr-v53` | 前 16 位 `99accbdfffffd514` | 同上 |
| `/home/ubuntu/specdict/xcorr/v5test/test_id.jsonl` | 冻结说明只给 sha256 前 16 位 `8a3dbcae10267287` | `sha256sum` 全文，比较前 16 位；同时记录完整哈希 |
| 同目录 `test_id.checks.jsonl` | 前 16 位 `0482dd629785ad22` | 同上 |
| v5.3 train / val / manifest | 冻结说明给了被截断的 sha256 前缀 | 找到冻结说明里的本机副本 `results/data_v5/v53/` 后对清单文件做完整 `sha256sum`。git 树只有 `SHA256SUMS` 和 qa 报告，没有 jsonl 正文 |
| `~/specdict/data/realx_v2/manifest.jsonl` | `dfe1cc84881155c8537060847f343ed7145aaa2567b20ee45af73daa9d6f46cf` | `sha256sum` 该文件 |
| `~/specdict/data/realx_v2/pcm/*.pcm` 按文件名排序后的内容串接 | `36a5769b2f3e52b3dfc96b36a4450a608d5c82c61c938e5ea3f6b04344a3e103` | 只在确认排序与冻结说明一致时计算。不一致就记录文件数和总字节，哈希标 blocked |
| `~/specdict/data/gentest_v5/manifest.jsonl` | `67ab18edbf80312e5fe312d85b9e8b4004e80ec4838f7bd5e8ff8fb2de319d8e` | `sha256sum` |
| `~/specdict/data/gentest_v5/*.pcm` 串接，软链取目标内容 | `a1fcabc4aeb2b2dafc707b6195059bc4f2d60ab7eceb812e805bb4aa081ec172` | 同上，软链规则必须与冻结说明一致才计算 |
| `$HOME/specdict/models/sherpa-onnx-x-asr-480ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05` | `rerun/config.env` 的默认 `XASR_DIR`；无哈希 | 记录目录是否存在。没有哈希就不要编一个“版本已确认” |
| `$HOME/specdict/models/agentic-refiner` | 默认 `REFINER_DIR`；无哈希 | 同上 |
| Qwen3-4B-Instruct-2507 的 HF 缓存 | `HF_CACHE` 默认 `$HOME/.cache/huggingface`；论文写 FP8、vLLM 0.18 | 记录 snapshot 目录名。不下载 |
| `verify-cost-m4.json`、`verify-cost-a10.json` | `results/paper/verify-cost.md` 点名，git 中没有 | 找到则记录路径和 sha256；找不到就写缺失。8-bit 与 bf16 若没有单独 JSON，保持缺失 |
| `rerun/config.local.env` | git 忽略 | `test -f` 与 `wc -c`。不 `cat` |

建议的存在性循环（不打印文件内容）：

```bash
check() {
  if [ -e "$1" ]; then
    if [ -d "$1" ]; then
      printf 'DIR  %s\n' "$1"
      find "$1" -maxdepth 2 -type f -printf '%s %p\n' | sort
    else
      printf 'FILE %s\n' "$1"
      wc -c "$1"
      sha256sum "$1"
    fi
  else
    printf 'MISSING %s\n' "$1"
  fi
}
```

### 8.3 目标 Mac 上的 Velora 运行资产

M0 不要求测出延迟。M1 开始前，同一台 Mac 需要这些只读事实；缺一项则 M1 blocked：

```bash
sysctl -n machdep.cpu.brand_string
sysctl -n hw.memsize
sw_vers
xcodebuild -version
swift --version
ollama --version
ollama show qwen3:8b
```

上面的 `qwen3:8b` 是当时写下的原计划。2026-11-17 用户批准本机基线改为已安装的 `qwen3:14b`，见 [`evidence/m1/BASELINE.md`](evidence/m1/BASELINE.md)。不要把这段历史命令当成现在的测量。`ollama show` 的输出只保留名称、参数规模、量化名和摘要哈希，不粘贴 Modelfile 里的长提示词。SenseVoice：

```bash
# 根目录按 resolvedDefault 的实际搜索顺序，不要改用 README 里多出来的 Application Support
sha256sum Models/sensevoice/model.int8.onnx Models/sensevoice/tokens.txt
```

文件不存在就写缺失。不要为了审计重新 `curl` 模型。

## 9. 2026-11-16 补充（不改变上面的未通过判定）

同日晚些时候收到两份 Mac 摘要，归档在 [`evidence/mac-2026-11-16/`](evidence/mac-2026-11-16/report.md)。本环境仍然没有那台机器的文件系统。摘要把质量标成研究 rubric 上的绝对通过率，把草稿标成合成请求完成时间，T4 为 null。M0 的资产清单和用户工作区 `git status` 仍缺，所以第 1 节的未通过判定保持不变。

同一次阅读补上了先前没覆盖的 `pipeline/local_polish.py`。`LocalPolisher` 用同一模型的上一轮输出做草稿，并按最长公共前缀截断 KV。这不是 mlx-lm 的 `draft_model`。F0 设施锁定的是这段契约，见 [`../pocs/speculative_replay/README.md`](../pocs/speculative_replay/README.md)。

## 10. 交接

下一步、不能做的事和当前 HEAD 见 [`HANDOFF.md`](HANDOFF.md)。开发日志见 [`DEVLOG.md`](DEVLOG.md)。
