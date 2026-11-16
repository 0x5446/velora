# 交接

更新时间：2026-11-16。当前阶段：F0 的 CPU 验收设施已通过。M0 未通过。不要改产品代码。

## 现在在哪

- 产品仓库：`https://github.com/0x5446/velora`，分支 `cursor/m0-research-audit-2bb5`，PR https://github.com/0x5446/velora/pull/13 。不要合并，不要部署。
- 产品 HEAD 的父提交仍是 `origin/main` `73e83ec44363a1968c61da4865fb594bacbeda82`。`Apps/` 和 `Velora/Sources/` 没有被这轮修改。
- 研究仓库：`https://github.com/0x5446/speculative-dictation`，`main` `143a5f52ce380b00a4dda43c3e105d6bc0ace131`。不要向它推送。本环境的 git 凭据 clone 不到它；`pipeline/local_polish.py` 是经 GitHub API 读到的。
- 本环境：Linux，Python 3.12.3。没有 Swift、Xcode、Ollama、MLX，也没有 `/Users/alpha`。

## 先读

1. [`ENGINEERING_PROTOCOL.md`](ENGINEERING_PROTOCOL.md)
2. [`ARCHITECTURE.md`](ARCHITECTURE.md)
3. [`MILESTONE_GATES.md`](MILESTONE_GATES.md)
4. [`evidence/mac-2026-11-16/report.md`](evidence/mac-2026-11-16/report.md)
5. [`../pocs/speculative_replay/README.md`](../pocs/speculative_replay/README.md)

## 关卡

| 关 | 状态 |
|---|---|
| M0 审计与资产清单 | 未通过。阅读完成；用户工作区 `git status` 和权重哈希仍缺 |
| F0 CPU 设施 | 通过。`python3 -m unittest discover -s pocs/speculative_replay -p 'test_*.py'`，18 项，见 [`evidence/f0/report.md`](evidence/f0/report.md) |
| M1 现行产品基线 | 未开始。Mac 离线，且新摘要不是 Velora 的 SenseVoice + Ollama 路径 |
| M2 六套门禁 | 未开始。研究 rubric 的绝对通过率不能代替 |
| M3 取消/焦点/离线的产品观察 | 未开始。F0 只覆盖假模型上的调度 |
| M4 产品决定 | 未通过。方向已写明，默认行为未切换 |
| M5 / M6 | 未开始 |

## 下一最小交付

Mac 回来之后，用公开或已授权的音频产生真实端点日志，套 `pocs/speculative_replay/fixtures/synthetic_endpoints.json` 的 schema，`t4_ms` 保持 null。另一次产品路径测量再写绝对 T4：p50/p90，拆 prefill、verify、generate，分冷热、输入/输出长度、接受率、窗口、取消、焦点和故障。要单列不加速的 case。不要只交一个相对倍数。最小效应仍然 TBD。

若要审查隔离原型和 `LocalPolisher` 是否一致，最小附件是：

- `/Users/alpha/specdict/evidence/mac-draft-20261116-192758/sources/run_real_mlx_v2.py`
- 同目录 `FINDINGS.md` 里写明差异的部分

不要上传权重，不要把 jsonl 原文贴进仓库。

## 不要做

- 不要改 `Apps/` 或 `Velora/Sources/`，直到 M1–M3 有证据且 M4 按关卡通过。
- 不要跑新的 4B，也不要再付费请裁判。相对 4B / v4.1 保持 not judged。
- 不要把 635.6、5017.2、6290.8 ms 或 98.3% 接受率写成产品延迟或质量通过。
- 不要用 SenseVoice 累计重识别代替端点，也不要用 mlx-lm `draft_model` 代替历史目标输出。
- 不要修改研究仓库，不要推送用户机器上尚未提交的文件，不要合并本 PR。
