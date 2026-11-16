# F1 验收设施运行记录

日期：2026-11-16。环境：Linux 6.12.113+ x86_64，Python 3.12.3。没有 Swift、没有 MLX、没有目标 Mac。本机 `/Users/alpha` 没有挂载，下面的路径是给主助手的采集清单，不是已经读过的文件。

命令：

```bash
python3 -m unittest discover -s pocs/speculative_replay -p 'test_*.py'
```

结果：32 项测试，退出码 0。日志在同目录 `unittest.txt`。其中 F0 原有的调度与精确草稿测试仍然通过；新增的是 `test_trace.py`。

这次通过只说明采集器、回放和计时契约在这台 Linux 上按登记的规则成立。它不关闭 M0、M1 或 M5，也不产生 T4。

## 设施锁住的内容

- `collect_endpoints` 只接受数字元数据。`confirmed_text`、路径和其他字符串字段会被拒绝。合成 trace 不能标成 representative。`t4_ms` 固定为 null。
- `replay_endpoint_trace` 用假的因果 argmax 按端点长度回放。每个块记录 `context_tokens`、`block_len`、`accepted`。报告不含 `speedup`，块上没有 `elapsed_ms`。相同文本的 `end` 不会再开一轮。
- `group_blocks` 按阶段、上下文长度、块长和接受档分组。每一组的 `elapsed_ms` 仍是 null。这是分组契约，不是计时结果。
- `fixtures/recorded_request_citations.json` 引用已归档的 `draft-microbench.md`，没有重算。3099/442 那一行拆开后是 prompt 3099、输出 442、配置窗口 16、接受 289/1151、prefill 50.8 ms、verify 3691.4 ms、generate 1254.5 ms、请求完成 5017.2 ms。verify 是三者里最大的一项。三项之和不等于 5017.2，契约不允许把它们加总后当成总时间。`draft_tokens`、`block_lengths_observed` 和 `per_block_milliseconds` 都是 null：归档摘要没有逐块长度，也没有逐块毫秒。`may_generalize` 为 false。
- 9853/1024 那一行 `constructed_repeat` 为 true，草稿长度按摘要记为 18，接受 920，大于草稿长度。把它标成 representative，或把 920 写成草稿长度，测试都会失败。
- CPU 回放对象不能送进引用分类器。引用毫秒不会从合成 fixture 里生成。

## 还没有的测量

3099/442 的 verify 3691.4 ms 仍然是请求完成微基准的合计，不是按块拆开的实测，也不是松键到上屏。要填上逐块的 context、块长、接受数和 `elapsed_ms`，需要目标机器上的数字日志。清单在 [`HANDOFF.md`](../../HANDOFF.md)。
