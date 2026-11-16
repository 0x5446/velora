# 推测式重生成的 CPU 验收设施

这里不加载模型，也不改 Velora 的录音、识别或上屏。算法对照的是研究仓库 `speculative-dictation` `143a5f52` 的 `pipeline/local_polish.py`：同一套目标模型，草稿是上一轮已经生成完的目标 token，用 argmax 逐个核对，对不上就截回缓存。没有第二套 draft 模型。

和那份 MLX 循环有一处故意不同：提议会被截短，输出不能超过 `max_tokens`。公开的 `out.extend` 可以越过上限；Mac 摘要说隔离原型修过这个问题。本目录锁的是修过之后的契约。

```bash
python3 -m unittest discover -s pocs/speculative_replay -p 'test_*.py'
```

`fixtures/synthetic_endpoints.json` 是合成的相邻确认文本，只给调度测试用。`t4_ms` 必须是 null。

真实或公开语料的端点日志用 `fixtures/endpoint_trace_skeleton.json`（`velora.endpoint_trace.v1`）。采集器在 `trace.py`：只收 `kind`、token 数和尾部静音，拒绝听写原文、路径和其他字符串。CPU 回放按上下文长度、块长和接受档分组，不写毫秒，也不写加速比。

`fixtures/recorded_request_citations.json` 引用已经归档的 Mac 请求完成中位数，包括 3099/442 的 verify 3691.4 ms 和请求完成 5017.2 ms。这些数字不是本目录生成的，分类结果里的 `t4_ms` 仍是 null，逐块长度也是 null。9853/1024 标成 constructed repeat，不能当作自然听写。

调度约定：

- `endpoint` 开始一轮，草稿是上一轮已经完成的输出。中间轮次不提交。
- 新的一轮开始时才取消上一轮。过期的 `complete` 被丢弃，不能改写草稿。
- `end` 若文本没变，不另开一轮；最终只提交一次。
- `focus_change` 不提交。`cancel_session` 和 `asr_fault` 清空提交。
