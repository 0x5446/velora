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

## 2026-11-16 · F0 验收设施与 Mac 摘要归档

- 范围：把两份 Mac 摘要入库；按研究仓库 `pipeline/local_polish.py` 的 `LocalPolisher` 做 CPU 验收设施；写明架构方向。没有改 `Apps/` 或 `Velora/Sources/`，没有加载 4B，没有新的付费裁判，没有改研究仓库。
- PR 13 在这次更新前没有评审、没有会话评论、没有行内评论。
- Mac 摘要不是产品通过。质量 JSON 七个集合窗口合计 1304，不是口头的 1314。相对 4B / v4.1 和 e2e60 保持 not judged。草稿计时的 T4 为 null；9853/1024 那条是重复单元。详见 [`evidence/mac-2026-11-16/report.md`](evidence/mac-2026-11-16/report.md)。
- F0：`python3 -m unittest discover -s pocs/speculative_replay -p 'test_*.py'`，18 项，退出码 0。证据 [`evidence/f0/report.md`](evidence/f0/report.md)。这不关闭 M0 或 M1。
- 未审查：`/Users/alpha/specdict/evidence/mac-draft-20261116-192758/` 里的原型源码。需要对照时只要 `sources/run_real_mlx_v2.py` 和写了差异的 `FINDINGS.md`。

## 2026-11-16 · F1 端点契约，并更正 1314 与 1304

- 更正上一则 devlog：1314 是实际推理条数，1304 是质量汇总排除 realx 5 条和 gentest 5 条之后的有效分母。JSON 记录的是这个分母。两者不是计数矛盾。相对 4B / v4.1 和 e2e60 仍是 not judged。说明改在 [`evidence/mac-2026-11-16/report.md`](evidence/mac-2026-11-16/report.md)。
- 范围：在 F0 同一设施上加数字端点 schema、采集器、CPU 回放和计时契约。没有改 `Apps/` 或 `Velora/Sources/`，没有加载 4B，没有新的付费裁判，没有改研究仓库，没有合并或部署。
- F1 通过规则写在 [`MILESTONE_GATES.md`](MILESTONE_GATES.md)。运行 `python3 -m unittest discover -s pocs/speculative_replay -p 'test_*.py'`，32 项，退出码 0。证据 [`evidence/f1/report.md`](evidence/f1/report.md)。
- 3099/442 的引用拆分保留 verify 3691.4 ms 和接受 289/1151，并写明逐块长度和逐块毫秒仍是 null。9853/1024 保持 constructed repeat，不能外推。CPU 回放没有生成这些毫秒，也没有 T4。
- 未做：目标机器上的逐块日志和真实 ASR 端点日志。路径见 [`HANDOFF.md`](HANDOFF.md)。本环境没有访问 `/Users/alpha`。

## 2026-11-16 · 修正 F1 的内容身份，并写明最短接缝

- 上一则把 F1 标成通过时，回放用 `confirmed_tokens` 判断结束事件是否重复。token 数相同、内容不同的结束事件不会重新生成。该判定作废。
- 端点和结束事件现在必须带 `content_revision`：token id 按十进制用换行拼接后的 sha256。采集器仍拒绝原文。同长度不同 revision 会重新生成，并提交新的输出 token。相同 revision 不另开一轮。
- 回放报告的 `model` 为 `cpu_mock`，`mlx_token_identity` 为 null。把后者写成 true，测试失败。文本调度那条路径也加了同长度不同字符串必须提交新输出的测试。这两边都是 mock 对 mock，不是 MLX 正确性。
- 重跑 `python3 -m unittest discover -s pocs/speculative_replay -p 'test_*.py'`，38 项，退出码 0。证据更新在 [`evidence/f1/`](evidence/f1/report.md)。
- 架构写明最短路径：端点识别和 1.7B 润色都是默认关闭的长驻 sidecar，日志只留 revision，草稿来自上一轮输出。没有改 `Apps/` 或 `Velora/Sources/`。M4 仍未通过。
- M0 仍未通过。缺的是工作区 status 和权重哈希文件，不是产品 T4。交接命令在 [`HANDOFF.md`](HANDOFF.md)。

## 2026-11-16 · M0 通过，并审阅隔离原型与新实测

- 用户机器的 `HEAD` 是 `73e83ec`，tracked 与 staged diff 为空，未跟踪文件只有设计稿。本机 `origin/main` `accab725` 是过期 tracking，GitHub `main` 仍是 `73e83ec`。判定见 [`evidence/m0/report.md`](evidence/m0/report.md)。
- 1.7B 单文件 sha256 前缀与冻结值一致，但完整哈希复用先前验证，这轮没有重读 3.4GB。test_id、checks、realx manifest、gentest v5 manifest 的哈希匹配。0.6B、pcm 串接和 4B 缓存记为未测。
- 隔离原型的 `draft_core.py` 裁短 `max_tokens`、不输出匹配到的 EOS、异常时清空 cache。研究 `LocalPolisher` 不是这样。CPU 设施补上 EOS 不输出，仍不加载 MLX。
- 新的 3099/442 块日志是 5 个请求、1919 块的重跑，不是 5017.2 ms 那一轮。当前块校验接受它。公共端点摘要没有 `revision`，采集器拒绝。三种条件的 decoder 完成时间是 937.214 / 3874.732 / 281.655 ms，T4 为 null。
- M1 采集脚本在 [`evidence/m1/collect_baseline.sh`](evidence/m1/collect_baseline.sh)。本环境没有跑。没有改 `Apps/` 或 `Velora/Sources/`。

## 2026-11-17 · M1 基线改为本机已有的 qwen3:14b

- 用户批准：这台 Mac 没有默认的 `qwen3:8b`，用已安装的 `qwen3:14b` 作本机对照，并写明契约变更。昨天的采集器对 `ollama show qwen3:8b` 退出码 1，SenseVoice 在，`runs` 为 n=0。没有补造毫秒。
- 源码默认仍是 `LocalModelEngines.swift` 的 `VELORA_OLLAMA_MODEL` 缺省 `qwen3:8b`。采集进程只设置这个已有变量。不写 UserDefaults，不下载 8B，不改质量门槛。
- 采集器默认不传 `--copy`。每个音频跑两遍。冷热只记录产品已有的 `ollama_model_reload` 警告。digest 来自本机 `/api/show`，Modelfile 不落盘。原文不入库。M1 仍未通过，要等真实 `runs.json` 审查。
