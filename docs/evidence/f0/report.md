# F0 验收设施运行记录

日期：2026-11-16。环境：Linux 6.12.113+ x86_64，Python 3.12.3。没有 Swift、没有 MLX、没有目标 Mac。

命令：

```bash
python3 -m unittest discover -s pocs/speculative_replay -p 'test_*.py'
```

结果：18 项测试，退出码 0。日志在同目录 `unittest.txt`。

这些测试检查的是令牌序列、缓存复用/回滚、取消和一次提交。报告对象里的 `t4_ms` 和 `milliseconds` 固定为 null。通过 F0 只说明这台 Linux 上的契约测试通过，不说明 Mac 上的延迟或质量。
