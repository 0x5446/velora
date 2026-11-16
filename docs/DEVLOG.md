# Devlog

只追加，不改旧条目的结论。更正写成新条目。

## 2026-11-16 · M0 审计与关卡文档

- 范围：研究理解、可复现性与工程现状。没有改产品代码，没有改 `speculative-dictation`，没有合并，没有部署。
- 分支：`cursor/m0-research-audit-2bb5`，基于 Velora `main` `73e83ec44363a1968c61da4865fb594bacbeda82`。
- 阅读依据：Velora 工作区源码与 `docs/`；`speculative-dictation` `main` `143a5f52ce380b00a4dda43c3e105d6bc0ace131`（GitHub API 只读）。`git ls-remote` 与 `gh repo view` 都报 repository not found，没有 clone。研究仓库权重与 v5 音频不在 git 中。本环境没有运行论文实验、`swift test` 或门禁脚本。
- 远程差异：`git fetch origin main` 后 `origin/main` 就是 `73e83ec`，任务点名的 `e1f1e12`、`0a64eec`、`73e83ec` 已在 GitHub `main`。`/Users/alpha/workspace/velora` 未挂载，用户工作区是否还有其他未提交文件仍未知。设计稿未进入 `origin/main`，副本归档在 `docs/m0/inputs/`，sha256 `fb7fb5e51e8d992e475eb758d4757d299ddb71169c87a193898ee6957d8129b6`。
- 结论：M0 **未通过**。源码与论文阅读完成；本机资产、用户工作区脏文件、产品基线均未核实。论文 README 的 Soniox / gpt-4.1-mini 演示与正文的 X-ASR / Qwen3-4B / vLLM 系统不是同一条复现路径。详见 [`M0_RESEARCH_AUDIT.md`](M0_RESEARCH_AUDIT.md) 与 [`MILESTONE_GATES.md`](MILESTONE_GATES.md)。
- 新增协议：[`ENGINEERING_PROTOCOL.md`](ENGINEERING_PROTOCOL.md)。未批准设计稿归档在 [`m0/inputs/`](m0/inputs/README.md)，不作为架构。
- 未完成：[`HANDOFF.md`](HANDOFF.md) 中的只读资产清单。清单完成并写入证据之前，不开始 M1 产品改动。
