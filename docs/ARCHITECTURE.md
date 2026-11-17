# 架构决定

状态：2026-11-16。这是实现方向，不是 M4 通过，也不是产品默认已经切换。产品行为仍以 [`PRODUCT_TECH_DESIGN.md`](PRODUCT_TECH_DESIGN.md) 为准，直到 M5 的证据通过。

用户授权采用这条路径，并明确这次不跑 4B：

1. 识别器要给出端点，以及一次结束事件。确认后的全文只增不减。SenseVoice 把整段音频在松键后识别一次，不是这个接口。录音期对“开头到现在”的音频反复整段识别，也不等于论文里的端点触发。
2. 常驻一个微调后的 Qwen3-1.7B v5.3。不加载底座 4B，也不加载另一个 draft 模型。草稿只能是上一轮这份 1.7B 已经生成完的输出。
3. 核对是目标模型自己的贪心 argmax，逐 token 相同才接受。不抬高草稿概率。实现对照 `pipeline/local_polish.py` 的 `align` 和 `LocalPolisher.polish`（研究仓库 `143a5f52`）。mlx-lm 的 `draft_model` 是另一套机制，不能拿来代替这段循环。
4. 提示词的公共前缀复用 KV；不一致的尾部截掉。生成被取消或提示不再是前缀时，缓存回滚到仍匹配的位置。至少重算提示词的最后一个 token。
5. 只有被新的一轮取代时才取消。取消后的结果不提交，也不写回草稿。
6. 输入模式只在结束事件提交一次。端点上的中间结果不粘贴。翻译确认卡仍是产品契约，这轮设施还没有翻译事件。

Mac 微基准支持的只有：在合成端点上，历史草稿可以和贪心逐 token 一致，并且最终请求的时间可以短于无草稿的同一请求。它同时表明核对不是免费的（442 token 那条 verify 中位数 3691 ms，最终请求仍有 5017 ms），重复文本上的 98% 接受率不能外推，提前计算的总工作量可能高于只在结束时算一次。所以延迟是否值得，要等真实端点回放的绝对 T4，而不是再报一个相对倍数。

## 现在不改的产品代码

`Apps/` 和 `Velora/Sources/` 在 F0 和 F1 都不动。现行路径仍是松键后 SenseVoice 整段识别，再调 Ollama `qwen3:8b`。Python 设施只约束下一阶段要接入的调度、核对和计时拆分。

## 最短实施路径

这是依赖接缝和部署形态的决定。M0 的审计证据已经入库。M4 仍未通过，默认路径不切换，所以这里仍不改产品代码。隔离原型 `draft_core.py` 和 CPU 设施都不是这条默认路径。

研究侧 `LocalPolisher.polish(text, draft)` 的缓存身份是 `prompt_ids(text)`：系统提示加 `<TRANSCRIPT>` 里的全文，经 chat template 变成 token id。草稿是上一轮输出文本再 `encode`。身份不是字符数，也不是 token 数。公开循环的 `out.extend` 可以越过 `max_tokens`；产品侧用本仓库已经截短的契约。模型必须是能截断 KV 的纯注意力 Qwen3。Qwen3-1.7B v5.3 符合这一点。不加载 4B，不用 mlx-lm 的 `draft_model`。

产品侧现有接缝：

- 识别：`SenseVoiceASREngine` 是长驻 Python sidecar，一次 `transcribe` 返回整段文本，没有端点回调。`resolvedDefault` 按 `VELORA_SENSEVOICE_ROOT`、cwd、`~/workspace/velora` 找 venv 和 `scripts/sensevoice_sidecar.py`。
- 润色：`OllamaTextIntelligenceEngine` 一次 HTTP。源码默认是 `qwen3:8b`，由 `VELORA_OLLAMA_MODEL` 覆盖。M1 对照就是这个默认标签；同名标签的 digest 以实测为准，不写成 7 月那份权重。`VeloraMac/main.swift` 在构造管线时注入引擎。
- 上屏：松键后粘贴一次。翻译仍走确认卡。

选定的部署形态，等 M1–M4 通过后再写进 `Apps/` 和 `Velora/Sources/`：

1. 识别引擎做成 `SenseVoiceASREngine` 的兄弟，默认不选中。它沿用同一个长驻 sidecar 形态，但事件是端点、结束、焦点、取消和故障。不用 SenseVoice 对累计音频反复整段识别来冒充端点。
2. 润色引擎也是一个长驻 sidecar，只加载 Qwen3-1.7B v5.3。请求在本机套接字上带当轮全文；写进证据和日志的身份是 `content_revision`，即 token id 的 sha256，不是原文。响应带回它回答的 revision。revision 对不上当前轮就丢弃。草稿是上一轮这个进程已经生成完的输出。
3. 开关默认关闭，关闭后仍走现在的 SenseVoice + Ollama `qwen3:8b`。8B 和 1.7B 不能同时成为默认依赖。运行时不下载权重。权重路径用 M0 交来的 sha256 核对。
4. 不把 MLX 先链进 App 进程，不新增网络服务，不做流式逐字粘贴。

CPU 回放用的是假 argmax。它通过只说明调度和本仓库移植的循环。它不证明 MLX 的逐 token 结果。报告里的 `mlx_token_identity` 固定为 null。

## 还缺的源文件

隔离原型不在这台机器上。若要审查它和 `LocalPolisher` 的差异，最小附件是：

- `/Users/alpha/specdict/evidence/mac-draft-20261116-192758/sources/run_real_mlx_v2.py`
- 同目录的 `FINDINGS.md`，只要它写了和 `pipeline/local_polish.py` 不同的地方

不要把权重、音频或 jsonl 原文贴进公开仓库。真实端点日志用 `pocs/speculative_replay/fixtures/endpoint_trace_skeleton.json` 的数字 schema（`velora.endpoint_trace.v1`），不要带确认文本。`t4_ms` 保持 null。3099/442 的逐块毫秒还没有；引用合计在 `fixtures/recorded_request_citations.json`，不能当成新的测量。
