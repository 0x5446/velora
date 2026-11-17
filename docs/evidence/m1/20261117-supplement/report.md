# M1 两次快照：2026-11-17

这是单独的观察，不并进 [`../20261117/report.md`](../20261117/report.md) 的 31 次分布，也不参加 M5 预注册。产品 prompt、temperature、deadline 和回退规则都没有改。`Apps/` 与 `Velora/Sources/` 没有改。

## 复核

`runs.json` 的 `n=1`，`n_attempted=2`，`repeats_per_audio=1`。音频哈希与 31 次里的 `zh_short`、`zh_long` 相同，但是新的两次请求。`pass_index` 从 0 数到 1，因为采集器按脚本顺序计数，不是同一条音频的第二遍。文件里的旧说明“每个音频跑两遍”与这次的 `repeats_per_audio=1` 不符；源码里的说明已经改成按进程设置来写。

| 片段 | failure_class | engine | ASR | compose | critical | llama-server RSS 前→后 |
|---|---|---|---|---|---|---|
| zh_short | llm | `ollama:qwen3:8b` | 768 | 3771 | 4539 | 2408688 → 860272 KiB |
| zh_long | deadline_fallback | `rules` | 1103 | 4271 | 5374 | 860272 → 875632 KiB |

单位是毫秒。长样本的 Swift 退出码是 0，deadline 是 4000 ms，`rule_floor_used` 为 false。这是产品在时限内退回规则并正常结束。采集器因为这一行不是 LLM 样本而退出码 1。外层包装退出码 0。失败样本有效。

sidecar Python 在两次之后分别是 756064 KiB 和 821568 KiB，开始时是 null。`ollama` 守护进程约 20–29 MiB，不是模型内存。两次都是 `no_reload_warning`。`insertion_strategy` 为 null，没有粘贴。digest 仍是 `500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41`，来源 `/api/tags (show details validated)`。这份 `runs.json` 里的 `wrapper_manifest_sha256` 是 null。

这些 RSS 是片段前后的 `ps` 快照。短样本从 2408688 KiB 降到 860272 KiB，不能写成峰值，也不能写成“录音前 / 常驻后 / 长句后”三个协议时点。没有物理 T4，没有 HUD `wall_ms`，没有 `insert_ms`，没有瓦数。

## 原文逐项

31 次已经构成基线：n=19 的严格 LLM，加上 12 次失败回退。12 次失败是旧产品的行为，不是“没有基线”。下面只评关卡原文还要什么。

已经由现行二进制导出，并且 31 次里有数：

- `PipelineTrace.releaseToInsertMS`，也就是 critical 阶段之和。31 次全部样本 p50/p90 是 2144/5326 ms；19 次严格 LLM 是 2087.0/4430.8 ms。两次快照不并进去。
- ASR 阶段、`compose` 整段、失败回退类别、音频 sha256、这次 8B 的 digest 和 Q4_K_M。n 不是 0。规则回退没有被算进 n。

原文允许直接写 blocked 或未测，缺了也不该再跑 CLI：

- 能耗。原文写明没有仪表就写 blocked，并写 `powermetrics` 是否被允许。这次是未采样。不要估瓦数。
- prefill/decode 的 eval duration。原文写明客户端没有把 eval duration 解进 `OllamaGenerateOutput`，缺的字段写 blocked，不要用调优报告填。`prompt_eval_count` 和 `load_duration` 会被解码，但只有超过阈值才变成 `ollama_ctx_pressure` 或 `ollama_model_reload` 警告。这两次都没有这些警告。
- 质量六套。原文要求标成“非确定性现状”，不作为回归通过。这次不重跑。7 月分数不是本 HEAD 的通过记录。
- 粘贴。原文写明 CLI 不传 `--copy`，粘贴不在这批数字里。
- 预热是否落在录音期内。这两次是文件输入，没有录音期。`no_reload_warning` 不是常驻证明。
- 逐输出哈希。redact 丢掉了原文。禁止为补哈希再推理。
- llama-server 峰值。原文要的是三个时点的 RSS，不是峰值。峰值保持未测。

依赖循环，再跑 CLI 也补不出：

M1 的标题是“仍不改用户可见行为”。协议把 `Apps/` 和 `Velora/Sources/` 的改动留到 M1–M3 有证据、并且 M4 通过之后。同一节又要求 HUD `wall_ms`（含粘贴）、粘贴单独计时，以及 ASR、规则地板、LLM 等待、护栏、失败回退的分段。现行 trace 的 compose 只有 `PipelineOrchestrator.swift` 里的一段。`wall_ms` 和 `insert_ms` 只出现在 `MacSystemInputController.swift` 1077–1082 行的浮层字符串，没有进 journal，也没有进 CLI JSON。不改产品源码，这些字段永远是 null。

因此 M1 保持 blocked。阻塞原因是这个循环，不是 12 次失败，也不是这两次快照不够。

## 最小决定

是否允许一次测量补丁：把已经算出来的 `wall_ms`、`insert_ms`，以及已经解码的 `prompt_eval_count`、`load_duration`（响应里若有 `eval_duration` 和 `eval_count` 也写入）放进现有 trace 和 CLI JSON。不改 prompt、temperature 0.1、输入 deadline 4000 ms、翻译 deadline 6000 ms、回退规则和上屏策略。允许之后才有可能做菜单栏测量。不允许则这些字段继续 blocked，M5 最小效应保持 TBD。本审查不实施这个补丁。

`env.txt` 和 `sensevoice.sha256` 已归档在 [`../20261117/`](../20261117/)。没有重新采集。

## 脚本

`809f682` 的 `supplement_blocked.sh` 在 zsh 5.9 里执行 `status=0` 会得到 `read-only variable: status`，采集器不会被调用。正式脚本改为 `collector_status`，采集器路径是 `VELORA_M1_COLLECTOR`，缺省仍是仓库里的 `collect_baseline.sh`。退出码 1 时外层退出码 0。测试用 zsh 实际执行了这个路径。
