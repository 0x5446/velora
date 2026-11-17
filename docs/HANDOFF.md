# 交接

更新时间：2026-11-17。当前阶段：M0 已通过。F0 和 F1 的 CPU 设施已通过。M1 基线已有：31 次里 19 次严格 LLM、12 次失败回退。另两次 RSS 快照不并进这 31 次。用户已允许一次仅测量的 instrumentation。质量门槛和 deadline 没有放宽。M1 仍要等这条新 trace 的实证，不能凭补丁本身通过。本环境没有 Swift，也没有访问 `/Users/alpha`。

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
| M1 现行产品基线 | blocked。基线在 [`evidence/m1/20261117/report.md`](evidence/m1/20261117/report.md)。测量字段已接到 trace，但还没有新的 Mac trace。31 次和两次快照不并池 |
| M2 六套门禁 | 未开始。研究 rubric 的绝对通过率不能代替 |
| M3 取消/焦点/离线的产品观察 | 未开始。F0 只覆盖假模型上的调度 |
| M4 产品决定 | 未通过。方向已写明，默认行为未切换 |
| M5 / M6 | 未开始 |

## 下一最小交付

不要重跑 31 次，不要重跑六套质量，不要下载模型，不要打开麦克风，不要粘贴。在隔离 worktree 里编译并打一条已经在磁盘上的公开音频，只为看到新的 `trace.measurement`。不要把这次和 31 次合成一个分布。

```bash
git fetch origin cursor/m0-research-audit-2bb5
git worktree add --detach /tmp/velora-m1-measure origin/cursor/m0-research-audit-2bb5
cd /tmp/velora-m1-measure
swift test --package-path Velora
VELORA_ROOT=/tmp/velora-m1-measure \
VELORA_M1_OUT="$HOME/specdict/evidence/m1-measure-fields" \
VELORA_M1_REPEATS=1 \
/tmp/velora-m1-measure/docs/evidence/m1/collect_baseline.sh /path/to/zh_short.caf
```

依赖只有本仓库、已安装的 Swift 6.3、SenseVoice 和 `qwen3:8b`。没有新的包。采集器退出码 1 只表示这一条没被接受为 LLM，`runs.json` 里仍应有 `rule_floor_ms`、`llm_wait_ms`、`guard_ms`、`prompt_eval_count`、`load_duration_ns`。CLI 的 `hud_wall_ms` 和 `insert_ms` 必须是 null。不要启动菜单栏 App。

若 31 次目录里已经有 `env.txt` 和 `sensevoice.sha256`，把这两个文件抄进证据即可。

原型差异已经写在 [`evidence/prototype/REVIEW.md`](evidence/prototype/REVIEW.md)。产品 sidecar 仍不开始。

## 不要做

- 不要再改产品行为。2026-11-17 的测量日志是 M1 前的一次性例外，不放宽质量或时延门槛。提示词、温度、deadline、回退、上屏和快捷键保持原样。1.7B 仍不接入。
- 不要跑新的 4B，也不要再付费请裁判。相对 4B / v4.1 保持 not judged。
- 不要把 635.6、5017.2、6290.8 ms 或 98.3% 接受率写成产品延迟或质量通过。
- 不要用 SenseVoice 累计重识别代替端点，也不要用 mlx-lm `draft_model` 代替历史目标输出。
- 不要修改研究仓库，不要推送用户机器上尚未提交的文件，不要合并本 PR。
