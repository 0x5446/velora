# 交接

更新时间：2026-11-16。当前阶段：M0 已通过。F0 和 F1 的 CPU 设施已通过。M1 还没在目标 Mac 上跑。不要改产品代码。本环境没有访问 `/Users/alpha`。

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
| M0 审计与资产清单 | 通过。见 [`evidence/m0/report.md`](evidence/m0/report.md)。1.7B 完整哈希是复用的先前验证；五个冻结清单匹配 |
| F0 CPU 设施 | 通过。当时 18 项，见 [`evidence/f0/report.md`](evidence/f0/report.md)。同一命令现在会连同 F1 一起跑 |
| F1 端点 schema / 采集器 / 回放 / 计时契约 | 通过。同一命令现为 41 项，退出码 0。CPU mock 的 `mlx_token_identity` 为 null。公共端点摘要因没有 revision 被拒绝。不是 M1 或 M5 |
| M1 现行产品基线 | 未开始。脚本 [`evidence/m1/collect_baseline.sh`](evidence/m1/collect_baseline.sh) 测的是现行 SenseVoice + Ollama `qwen3:8b`，不切换默认路径。本环境不能跑 Swift |
| M2 六套门禁 | 未开始。研究 rubric 的绝对通过率不能代替 |
| M3 取消/焦点/离线的产品观察 | 未开始。F0 只覆盖假模型上的调度 |
| M4 产品决定 | 未通过。方向已写明，默认行为未切换 |
| M5 / M6 | 未开始 |

## 下一最小交付

在用户机器上执行，输出写到 `/Users/alpha/specdict/evidence/m1-baseline-20261116`，不要写进 git 工作区：

```bash
chmod +x /Users/alpha/workspace/velora/docs/evidence/m1/collect_baseline.sh
/Users/alpha/workspace/velora/docs/evidence/m1/collect_baseline.sh /path/to/clip1.caf /path/to/clip2.wav
```

脚本使用 `swift run --package-path Velora VeloraMac --mode input --sensevoice --audio … --source zh --json`。没有 `--copy`。音频缺失或 SenseVoice 文件缺失时退出码 2。回来时带 `env.txt`、`sensevoice.sha256` 和 `runs.json`。`runs.json` 只有引擎名、阶段毫秒和字符数。

这还不是 M1 通过。M5 的最小效应仍等这批基线再登记。公共回放的 281.655 ms 不能填进这张表。

原型差异已经写在 [`evidence/prototype/REVIEW.md`](evidence/prototype/REVIEW.md)。产品 sidecar 仍不开始。

## 不要做

- 不要改 `Apps/` 或 `Velora/Sources/`，直到 M1–M3 有证据且 M4 按关卡通过。
- 不要跑新的 4B，也不要再付费请裁判。相对 4B / v4.1 保持 not judged。
- 不要把 635.6、5017.2、6290.8 ms 或 98.3% 接受率写成产品延迟或质量通过。
- 不要用 SenseVoice 累计重识别代替端点，也不要用 mlx-lm `draft_model` 代替历史目标输出。
- 不要修改研究仓库，不要推送用户机器上尚未提交的文件，不要合并本 PR。
