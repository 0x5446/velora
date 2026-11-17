# M1 基线契约

日期：2026-11-17。用户批准：这台 Mac 上没有 `qwen3:8b`，M1 对照改用已经存在的 `qwen3:14b`。

这是基线模型变更，不是一次 8B 测量。源码默认仍是 `OllamaLocalClient` 里的 `VELORA_OLLAMA_MODEL` 缺省值 `qwen3:8b`。采集进程只在自己的环境里设置 `VELORA_OLLAMA_MODEL=qwen3:14b`，不写 UserDefaults，不下载 8B，不改产品默认。

昨天的采集器对 `ollama show qwen3:8b` 退出码 1。SenseVoice 和依赖在。`runs` 为 n=0。这里不补任何毫秒数。

质量六套的门槛和历史 `qwen3:8b` 分数都不因这次换模型而改写。那些分数仍不是本 HEAD 的通过记录。延迟预算仍是设计目标，未复测。M1 要等这份 14B 采集的真实 `runs.json` 经关卡审查后才能通过。

采集记录：本机 `127.0.0.1:11434/api/show` 的 digest、参数规模和量化名。响应里的 Modelfile 不落盘。每个音频默认跑两遍，`pass_index` 只表示这次脚本里的先后。冷热只认产品已有的 `ollama_model_reload` 警告；没有这条警告就写 `no_reload_warning`，不写成已经预热。同时记下音频 sha256、条数、关键阶段毫秒，以及 `ollama` 与 SenseVoice sidecar 的 RSS。没有 `--copy`，不用麦克风，不执行 `ollama pull`。原文不入库。输出目录是 `/Users/alpha/specdict/evidence/m1-baseline-14b`，与昨天那次空的 8B 尝试分开。
