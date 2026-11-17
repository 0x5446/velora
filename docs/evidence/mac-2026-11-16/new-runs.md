# 2026-11-16 新实测

这些文件是交接来的数值结果。T4 全部为 null。它们不关闭 M1 或 M5。

## 3099/442 块日志重跑

`recorded-block-trace.json`，sha256 `b55ee8d85e9eb4132122fd0d4c940ab01ca7c0ae387e74c38d20d9b25c023e9b`。schema `velora.block_trace.v1`，`source` 为 `recorded_block_log`。当前 `validate_block_trace` 接受它。

`f1-validation.json` 写的是旧 blob `6c24bdf0cb846480bd9dfa1b2e20676f408e4749`。revision 契约加在端点 trace 上，没有加到块日志。所以旧校验通过，不能说明这份日志带有 `revision`。它本身也没有 revision 字段。

文件头写明这是新跑的 5 个请求、1919 个块，不是先归档的 5017.2 ms 那一轮。历史 draft 的最终请求仍是 prompt 3099、输出 442、接受 289/1151，但请求完成约 5113.4 ms，verify 块的 `elapsed_ms` 合计约 3742.0 ms。verify 的 `block_len` 不都是 16。输入标记为合成编号事实，`representative` 为 false。

## 公共冻结音频端点

`public-asr-metadata.json` 来自 X-ASR 480 ms、sherpa-onnx 2.0.1，对公开 `0.wav` 与 `1.wav` 加 800 ms 静音后做流式端点。端点由 `is_endpoint` 产生，不是按字符切开。metadata 去掉了 `confirmed_text`，只留 `confirmed_chars`。9 个 endpoint，再加一个 end。`release_ms` 16303.125 是音频结束再加 350 ms 的标记，不是物理松键。

`public-endpoint-replay-summary.json` 把这些端点按原速回放给同一套 1.7B。事件只保留 `confirmed_tokens`。10 个事件的 token 数互不相同，所以这份文件不会撞上“同长度不同内容”。它仍然没有 `revision`，当前采集器拒绝它。三种条件的最终输出 sha256 相同，并且等于官方 reference 的重复结果。

| 条件 | release 标记到 decoder 完成 | 尾端 available 到 decoder 完成 | T4 |
|---|---:|---:|---|
| end-only | 937.214 ms | 901.205 ms | null |
| 提前，无 draft | 3874.732 ms | 3838.724 ms | null |
| 提前，历史 draft | 281.655 ms | 245.646 ms | null |

无 draft 的回放里有两次 `cancelled_superseded`。历史 draft 这一次 10 个请求都完成。文件自己的限制是：一次拼接、离线 ASR 后再按时钟回放、没有物理按键、没有系统文本提交、没有重复样本。281.655 ms 不是产品延迟，也不是 p90。
