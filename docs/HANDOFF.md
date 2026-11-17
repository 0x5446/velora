# 交接

更新时间：2026-11-17。当前阶段：M0 已通过。F0 和 F1 的 CPU 设施已通过。M1 基线已有：31 次里 19 次严格 LLM、12 次失败回退。`8eb669d` 的测量字段已在 Mac 上用两条公开音频验证，不并进这 31 次。M1 仍 blocked：CLI 没有物理松键。本环境没有 Swift，也没有访问 `/Users/alpha`。

## 现在在哪

- 产品仓库：`https://github.com/0x5446/velora`，分支 `cursor/m0-research-audit-2bb5`，PR https://github.com/0x5446/velora/pull/13 。不要合并，不要部署。
- 产品行为的父提交仍是 `origin/main` `73e83ec44363a1968c61da4865fb594bacbeda82`。`8eb669d` 只加了测量字段。源码比较里 prompt、options、temperature 0.1 和 deadline 与父提交一致；这不是位级等价，也不是零开销证明。
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
| M1 现行产品基线 | blocked。31 次基线在 [`evidence/m1/20261117/report.md`](evidence/m1/20261117/report.md)。字段验证在 [`evidence/m1/20261117-measurement/report.md`](evidence/m1/20261117-measurement/report.md)，不并池。文件回放的 HUD/insert 不是物理松键。真实 T4 仍缺 |
| M2 六套门禁 | 未开始。研究 rubric 的绝对通过率不能代替 |
| M3 取消/焦点/离线的产品观察 | 未开始。F0 只覆盖假模型上的调度 |
| M4 产品决定 | 未通过。方向已写明，默认行为未切换 |
| M5 / M6 | 未开始 |

## 下一最小交付

不要重跑 31 次，不要再跑 CLI，不要重跑六套质量，不要下载模型，不要开麦克风，不要粘贴。先前的 `env.txt` 和 `sensevoice.sha256` 已在 Mac 交接里，补抄进证据即可，不要写成从未采集，也不要重新采集。

`app.velora.debug.dictate` 的 object 是文件路径。它会发生真实粘贴，但没有物理按键松开。修正后的日志把 `observationSource=debug_file` 和 `real_key_release` 分开。文件回放可以有 HUD 和 insert，`physicalKeyAndInsertObserved` 必须是 false，物理 T4 必须是 null。当前已编好的 App 还没有这个字段，用户同意之前不要启动它。真实松键不在这次文件回放里，门槛不降。

原型差异已经写在 [`evidence/prototype/REVIEW.md`](evidence/prototype/REVIEW.md)。产品 sidecar 仍不开始。

## 不要做

- 不要再改产品行为。2026-11-17 的测量日志是 M1 前的一次性例外，不放宽质量或时延门槛。提示词、温度、deadline、回退、上屏和快捷键保持原样。1.7B 仍不接入。
- 不要跑新的 4B，也不要再付费请裁判。相对 4B / v4.1 保持 not judged。
- 不要把 635.6、5017.2、6290.8 ms 或 98.3% 接受率写成产品延迟或质量通过。
- 不要用 SenseVoice 累计重识别代替端点，也不要用 mlx-lm `draft_model` 代替历史目标输出。
- 不要修改研究仓库，不要推送用户机器上尚未提交的文件，不要合并本 PR。
