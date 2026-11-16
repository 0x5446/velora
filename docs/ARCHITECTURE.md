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

## 还缺的源文件

隔离原型不在这台机器上。若要审查它和 `LocalPolisher` 的差异，最小附件是：

- `/Users/alpha/specdict/evidence/mac-draft-20261116-192758/sources/run_real_mlx_v2.py`
- 同目录的 `FINDINGS.md`，只要它写了和 `pipeline/local_polish.py` 不同的地方

不要把权重、音频或 jsonl 原文贴进公开仓库。真实端点日志用 `pocs/speculative_replay/fixtures/endpoint_trace_skeleton.json` 的数字 schema（`velora.endpoint_trace.v1`），不要带确认文本。`t4_ms` 保持 null。3099/442 的逐块毫秒还没有；引用合计在 `fixtures/recorded_request_citations.json`，不能当成新的测量。
