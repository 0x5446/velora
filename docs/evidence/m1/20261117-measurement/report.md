# M1 测量字段验证：2026-11-17

判定：M1 仍 blocked。这两条只验证 `8eb669d2bde510892fd6247d2a9892667d13739e` 的新字段。它们不并进 [`../20261117/report.md`](../20261117/report.md) 的 31 次，也不参加 M5 预注册。

固定提交 `8eb669d2bde510892fd6247d2a9892667d13739e`。Mac 摘要：Swift 6.3，包测试 128 项退出码 0，Python 采集器测试 17 项退出码 0，CLI 与菜单栏 Xcode 构建退出码 0。菜单栏没有启动。交接说明写的是 Xcode 26.4。本环境没有重跑这些测试。用户工作区前后一致是 Mac 交接说明，不是本环境核对的磁盘。

## 两条公开音频

`runs.json` sha256 `414f54d09b9ff163bf24a5fee5e375ca30aa29cef182ec1af4e81318148791b1`。摘要 sha256 `2673ff4b6ddcc759f16822c2be71c15d5a49a645c39497a8c11f2f6857ba1031`。没有原文。`physical_key_and_insert_observed` 都是 false。

| 音频 | 类 | ASR | compose | critical | 规则地板 | LLM 等待 | 护栏 | Ollama 计数 |
|---|---|---|---|---|---|---|---|---|
| zh_short `99f6b8eb…` | deadline_fallback | 852 | 4276 | 5128 | 1 ms，`rule_engine_only` | 4273 ms，`deadline_or_error_envelope` | null | 全 null |
| xasr_1 `8bfb42c9…` | llm | 781 | 2348 | 3129 | 1 ms，`rule_engine_only` | 2308 ms，`generate_only` | 0 | prompt 1626，load 5077042 ns，eval 19，eval 465464000 ns |

critical 等于各 critical 阶段之和。规则地板、LLM 等待和护栏都标了 `measurement_exclude_from_critical_sum`，没有再加进 5128 或 3129。`zh_short` 的响应没完成，计数保持 null。`xasr_1` 的护栏 0 ms 是测到的不足 1 ms，不是用 0 填空缺。`hud_wall_ms` 和 `insert_ms` 都是 null。这是 CLI，不是松键。

## 源码比较

相对父提交，下列片段的 sha256 相同。这只说明源码一致，不是两次生成的位级等价，也不是测量零开销。

| 片段 | sha256 |
|---|---|
| inputSystem | `08544bdc43fbf1644942efb0ebf19ec61346a71410fe77663555bf154dd14c69` |
| translateSystem | `c580248f0a0c6c49b0c4a667c337ad773e5d5eb5d781f31e995ff4144c66d8d2` |
| fallbackTranslateSystem | `60896d1da484667e517a137584f2321541066e69b64873c3791d27862a049adf` |
| 请求构造 | `2ff91e706ce331b450b927a910fede3aea34089a380207edeac8c8a5f0922b3a` |

温度 0.1、`num_ctx`、predict budget、deadline 契约的比较结果都是 identical。构建结果文件 sha256 `805c0dcfb386e3315d8616caf84ff50db98ea3f253b531b5be20b92b175feaa9`，源码比较文件 sha256 `23e8ad05318c9ab3a31091d46bd3563208252d651cd3a74b24fe85b4ba823b0d`。这两份没有入库。

## 原文逐项

已经满足，依据是 31 次基线，不是这两条：

- n=19，另有 12 次失败回退。n 不是 0。规则回退没有算进 n。
- digest `500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41`，Q4_K_M，8.2B。音频 sha256 已记录。
- `releaseToInsertMS`：31 次全部样本 critical p50/p90 = 2144/5326 ms；19 次严格 LLM 是 2087.0/4430.8 ms。
- ASR 阶段和失败回退类别。

这两条新验证满足的是字段能不能记下来：规则地板、LLM 等待、护栏，以及完成后的 `prompt_eval_count`、`load_duration`、`eval_count`、`eval_duration`。翻译回退那一支没有动态跑到。

按原文写 blocked，不再用 CLI 去补：

- 功耗。没有仪表，`powermetrics` 未采样。
- prefill 时间。`prompt_eval_count` 不是时长。响应里的 prefill duration 没有进入 schema。
- 阶段 RSS 峰值。原文要的是三个时点的 RSS，不是峰值。
- 质量六套。标成非确定性现状，不作为这次回归通过。7 月分数不是本 HEAD。

仍强制 blocked：

- GUI 文件回放的 HUD 和 insert 还没测。测到之后来源必须是 `debug_file`，只能和 critical 合计分列，不能填物理 T4。
- 真实物理 T4。`app.velora.debug.dictate` 会粘贴，但没有物理按键松开。`physicalKeyAndInsertObserved` 必须保持 false。
- 录音前、模型常驻后、一次长句之后的 Velora、sidecar Python、`ollama` RSS。现有 llama-server 数字是 CLI 快照，不是这三个时点。
- 预热是否落在录音期内。CLI 没有录音期。
- M5 最小效应仍是 TBD。本关没通过，不登记。

环境身份不是“从未采集”。Mac 交接里已有先前的 `env.txt` 和 `sensevoice.sha256`。本仓库报告还没抄入这些文件，由主助手补入，不要重新采集。

## 下一动作

不要跑音频，不要启动菜单栏，不要粘贴。现编好的 App 还没有来源字段，不能拿去测。

用户专项同意粘贴之后，先编入来源修正，再用公开文件走 `app.velora.debug.dictate`。那是 GUI 文件回放：`observationSource` 必须是 `debug_file`，HUD 和 insert 可以是实测，`physicalKeyAndInsertObserved` 必须是 false，`physical_t4_ms` 必须是 null。不要把这次写成物理松键。

真实物理 T4 仍缺。它要一次真实按键松开，不在这次文件回放里，门槛不降。1.7B 不接入。
