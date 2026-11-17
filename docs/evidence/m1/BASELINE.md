# M1 基线契约

当前对照是 SenseVoice + Ollama `qwen3:8b`。产品源码一直是这个缺省值，这次不改 `Apps/` 或 `Velora/Sources/`。采集进程显式设置 `VELORA_OLLAMA_MODEL=qwen3:8b`，避免继承之前的 14B 覆盖。不写 UserDefaults。采集脚本自己不下载模型。

## 时间线

- 2026-07-13 17:50:37 至 2026-07-17 22:24:58（北京时间）：菜单栏 App 的 `corrections.jsonl` 有 27 条 `insertion`，`compose_engine=ollama:qwen3:8b` 且 `compose_fallback=false`。另有 3 条 `rules`，是 deadline fallback。这是 GUI 用过默认 8B 的记录，不是这次 M1 的延迟样本。
- 2026-10-22 已有 14B 缺 GGUF 的日志。不能据此推断删除时间或原因。
- 2026-11-16：第一版采集器按源码默认找 `qwen3:8b`，当时标签不在，退出码 1，n=0。没有补毫秒。
- 2026-11-17 早些时候：曾把采集契约临时改成已有 manifest 的 `qwen3:14b`。该标签没有取得任何被接受的 LLM 样本，n=0。当时的 CLI 是用 `VELORA_OLLAMA_MODEL` 显式覆盖，不是菜单栏 App 的默认配置。
- 2026-11-17：用户决定恢复 `qwen3:8b`，并清理 14B。14B 退出本契约。

## 这次测量

同一标签名不等于 7 月那份权重。digest 和量化以这次 `ollama show` / 本机 `/api/show` 的实际返回为准，写入 `runs.json`。Modelfile 不落盘。不能把这次结果写成历史位级复现。

`compose.engine=rules`、`compose_llm_error`、deadline fallback、或润色文本退回规则地板，都不算 LLM 样本。n 只数 `ollama:qwen3:8b` 且没有这些回退的行。质量门槛不改。7 月的六套分数仍不是本 HEAD 的通过记录。

每个音频默认跑两遍。冷热只认 `ollama_model_reload`；没有这条警告就写 `no_reload_warning`。同时记录音频 sha256、阶段毫秒和 RSS。不传粘贴参数，不用麦克风，原文不入库。

2026-11-17 的 31 次采集已经入库：[`20261117/report.md`](20261117/report.md)。19 次是严格 LLM 样本，12 次是失败回退。失败回退属于基线记录，n 不是 0。关卡仍 blocked，因为物理 T4、粘贴、护栏内部时间、功耗和 llama-server 峰值仍是 null。Ollama 0.40.16 的 digest 取自 `/api/tags`，不能把本地 manifest 文件哈希当成 registry digest。
