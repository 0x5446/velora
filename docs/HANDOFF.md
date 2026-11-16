# 交接

更新时间：2026-11-16。当前阶段：M0 审计已写入仓库，**关卡未通过**。不要开始产品实现。

## 现在在哪

- 产品仓库：`https://github.com/0x5446/velora`，公开。审计基于 `origin/main` = `73e83ec44363a1968c61da4865fb594bacbeda82`（`docs: align READMEs and tuning report with the polish quality round`）。
- 研究仓库：`https://github.com/0x5446/speculative-dictation`，私有。审计基于 `main` `143a5f52ce380b00a4dda43c3e105d6bc0ace131`（2026-11-16，`paper: explain T3 vs T4 gap ...`）。不要向该仓库推送。
- 本环境：Linux 云端虚拟机。没有 Swift、Xcode、Ollama、NVIDIA GPU，也没有挂载 `/Users/alpha/workspace`。`swift` 与 `xcodebuild` 不在 PATH。未运行 `swift test`、门禁脚本或论文重跑。

## 先读

1. [`ENGINEERING_PROTOCOL.md`](ENGINEERING_PROTOCOL.md)
2. [`M0_RESEARCH_AUDIT.md`](M0_RESEARCH_AUDIT.md)
3. [`MILESTONE_GATES.md`](MILESTONE_GATES.md)
4. 产品契约：[`PRODUCT_TECH_DESIGN.md`](PRODUCT_TECH_DESIGN.md)。它的延迟预算是设计目标，不是本 HEAD 的实测。
5. 未批准输入：[`m0/inputs/SPECULATIVE_POLISH_UPGRADE.md`](m0/inputs/SPECULATIVE_POLISH_UPGRADE.md)。不要按它的 P0–P4 开工。

## 已核实

- 2026-11-16 对 Velora 执行 `git fetch origin main` 后，`git rev-parse origin/main` 为 `73e83ec`。`e1f1e12`、`0a64eec`、`73e83ec` 都是它的祖先。任务里“远程还没有这三笔”的前提，在这次 fetch 时已经不成立。
- 这三笔提交没有把设计稿带进 git。`git ls-tree -r --name-only origin/main` 没有 `SPECULATIVE_POLISH_UPGRADE.md`。本云端工作区里有一份未跟踪副本 `docs/m0/inputs/SPECULATIVE_POLISH_UPGRADE.md`。这不能证明用户磁盘上的路径就是这一份，也不能证明旁边没有别的未跟踪文件。
- 研究仓库可通过仓库所有者的 GitHub API 读取（`get_repository`、commits、recursive tree、文件正文）。本环境的 `git ls-remote https://github.com/0x5446/speculative-dictation.git HEAD` 返回 `Repository not found`；`gh repo view` 同样解析不到。没有执行 clone。本环境没有研究仓库的工作副本，也没有向它推送。
- 研究 git 树 490 项，`truncated: false`，没有 `.safetensors`、`.gguf`、`.bin`、`.onnx`、`.pt`。`.gitignore` 忽略模型、多数音频和多数结果。`data/audio/{short,long}.pcm` 和一部分历史 `data/results/*.jsonl` 仍被跟踪，那是 README 时代的合成演示，不是 v5.3 训练集或 realx v2。
- 设计稿副本 sha256 为 `fb7fb5e51e8d992e475eb758d4757d299ddb71169c87a193898ee6957d8129b6`。`origin/main` 的树里没有该文件。

## 未核实（M0 因此不通过）

- `/Users/alpha/workspace/velora` 的工作区。GitHub `main` 已包含任务点名的三笔提交，但那台机器是否还有其他未提交差异，本审计看不到。设计稿只来自本次附件副本。
- 冻结说明里的权重目录、realx v2 / gentest v5 音频与转写、`rerun/config.local.env`。路径是文档记录，不是本环境里的存在性证明。1.7B / 0.6B 的冻结标识只是 safetensors 拼接哈希的前 16 位，拼接命令没有在本次读到的冻结说明里出现。
- 论文 Mac 前向耗时的原始 JSON。`paper/tables/hw.tex` 有 4-bit、8-bit 和 bf16 汇总；`experiments/verify_cost_mlx.py` 入库版本只覆盖 4-bit 默认模型。`verify-cost-m4.json` 与 `verify-cost-a10.json` 不在 git 树中。
- 仓库内 `polish_v3.3.txt` 的 sha256。冻结说明给了期望值，本环境没有对文件字节做 `sha256sum`。
- Velora 在目标 Mac 上的 release-to-ready 分布、内存、能耗，以及取消 / 焦点 / 上屏 / 离线的现行行为测试。`swift test` 也没有跑。

## 下一步（只读，做完才能重开 M0）

在持有资产的机器上执行 [`M0_RESEARCH_AUDIT.md`](M0_RESEARCH_AUDIT.md) 第 8 节命令。只打印路径、哈希、文件是否存在和 `git status`。不要 `git add`、不要推送用户原来的未提交内容、不要下载或覆盖权重、不要把听写原文贴进仓库。

把结果写成 `docs/evidence/m0/report.md`（新建证据目录的那一次提交）。缺一项就保持 M0 失败，并在报告里写 blocked。全部记录齐了，才把 M0 改为通过并允许进入 M1。

## 不要做

- 不要按设计稿实现环形缓冲、`RollingComposer`、草稿 sidecar 或 `PolishBackend`。
- 不要把 `qwen3-1_7b-xcorr-v53` 换进 Velora。论文事前门槛对底座 4B 未通过，且提示词与 Velora 契约不同。
- 不要把论文的 A10G T4 或调优报告里的 50 ms / 600–1700 ms 写成当前产品 SLO 或回归通过。
- 不要修改研究仓库，不要合并本 PR，不要部署。
