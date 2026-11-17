# M1 审查：2026-11-17 8B 采集

判定：blocked。采集完成不是通过。本环境用 `accepts_llm_baseline` 重数了 `runs.json`：31 次尝试，19 次 LLM 接受，12 次拒绝。拒绝是 7 次 deadline fallback 和 5 次 rule floor。31 次 ASR 都是 `sensevoice.sherpa-onnx`。没有私人原文。

## 契约怎么读

原文要求把失败回退单独记下来，并禁止把 `compose.engine=rules` 写成 LLM 成功。n=0 才使整关没有基线。这次 n=19，失败也留在同一份 `runs.json` 里，所以失败特征本身可以当作现行产品的基线，不是“31 次必须全部 LLM 成功”。

通过条件仍要求报告里的必填测量。下面几项是 null，不能用恢复时的算术 smoke 去填。因此关卡保持 blocked，不登记 M5 最小效应。

## 已核实的数字

模型是这次拉取的 `qwen3:8b`，8.2B，Q4_K_M。registry digest `500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41`，来源是 `/api/tags`，因为 Ollama 0.40.16 的 `/api/show` 没有 digest。本地 wrapper manifest 的文件哈希不是这个 registry digest。这不是 7 月 GUI 权重的位级复现。

严格 LLM 样本（n=19）的阶段 p50/p90，单位毫秒：ASR 642.0/916.8，compose 1260.0/3518.6，critical 合计 2087.0/4430.8。

全部 31 次，含失败：critical 合计 p50/p90 = 2144/5326。`zh_long` 5/5 是 deadline，critical 为 5401、5338、5259、5386、5326。`xasr_0` 5/5 的 engine 仍是 `ollama:qwen3:8b`，但 `rule_floor_used=true`，不计入 19。不能用 19 次的尾部代替含长音频失败的产品尾部。

31 次都是 `no_reload_warning`。第一次产品请求前 Ollama 没有驻留模型，却没有 reload 警告，所以这不是受控的冷或热。

音频 sha256：

| id | sha256 | 接受/尝试 |
|---|---|---|
| zh_short | `99f6b8eb776edc0f8f9f64effd3976381652a22bb7579dd88fcb845399c0755d` | 5/6 |
| zh_long | `138bcce428784426389ae7acdab9f49553e15d279e6a3343d24637f730967363` | 0/5 |
| mix_long | `efc01344c831e01ce52e6c4ee48b1f4b5be26f15d40ac0c4aeee4113b2f0cca7` | 4/5 |
| mix_short | `1ea26ffcf4b505f347eda77737dac1e7b787146d96429b98cc85f0cc820a4e14` | 5/5 |
| xasr_0 | `7d93384ca14702cc584a7a33fe2fed92e89e708549161cb12ea38c916882103b` | 0/5 |
| xasr_1 | `8bfb42c963e623ebab31b81ff4404867d07d3102507c87ac14577c4c61663b8c` | 5/5 |

## 保持 blocked 的缺项

当前 trace 和客户端没有这些字段，写 null 是按规定留下的空位，不是漏记：

- 物理 T4、HUD `wall_ms`、粘贴毫秒。CLI 的 `insertionStrategy` 是 none。HUD 上的 `wall_ms` 和 `insert_ms` 只出现在 `MacSystemInputController.swift` 1077–1082 行的浮层，没有落盘。在产品日志补上这两项之前，不要用 debug 注入去粘贴：数字存不住，还会写入当前前台应用。
- compose 内部的规则地板毫秒、护栏毫秒、LLM 独占等待。现有 stage 只有整段 `compose`。
- 产品响应里的 prefill/decode。客户端没有把 eval duration 解出来。
- 逐输出哈希。正式 redact 在包装层之前丢掉了原文，禁止为补哈希再跑一遍推理。
- 功耗。`powermetrics` 未采样。不要估瓦数。
- llama-server 的逐段峰值。采样器匹配了 `ollama` 守护进程（约 28MiB），不能把它当成模型内存。序列结束后的 llama-server RSS 是 5,196,160 KiB，`size_vram` 是 5,076,072,529 字节，这是结束后的快照，不是每段峰值。

14B 的官方 `ollama rm` 和“没有误删其他模型、共享层仍被 8B 引用”沿用 Mac 报告。本环境没有重读那台机器的 blob 目录。

## 最小补测

不改 prompt，不改阈值，不重跑六套质量，不下载模型。只补 RSS 缺口：`VELORA_M1_RSS_SUPPLEMENT=1 docs/evidence/m1/supplement_blocked.sh short.caf long.caf`。`VELORA_M1_REPEATS=1`，模型固定 `qwen3:8b`。采集器现在会把 `llama-server` 的 RSS 和 `failure_class` 分开记。退出码 1 只表示有请求没被接受为 LLM，文件仍然有效。粘贴和功耗继续保持 null。
