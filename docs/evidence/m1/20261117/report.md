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

## 环境

[`env.txt`](env.txt) 采集于北京时间 2026-11-17 14:41:21，基线 HEAD `73e83ec44363a1968c61da4865fb594bacbeda82`。Apple M4 Pro，内存 25769803776 字节，macOS 26.2 build 25C56，Xcode 26.4 build 17E192，Swift 6.3，Ollama 0.40.16。模型是源码缺省 `qwen3:8b`，采集进程用 `VELORA_OLLAMA_MODEL`。

[`sensevoice.sha256`](sensevoice.sha256)：`model.int8.onnx` 为 `c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51`，`tokens.txt` 为 `f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc`。这是已采集文件，没有重算。

## 保持 blocked 的缺项

环境身份已归档。下面这些仍缺，不降门槛：

- 真实物理 T4。文件回放的粘贴不是松键，`physicalKeyAndInsertObserved` 不能因此写成 true。
- 输入模式的 HUD `wall_ms` 和 insert。CLI 按构造是 null。文件回放若以后测到，来源必须是 `debug_file`，不能填物理 T4。当前没有粘贴授权。
- 录音前、模型常驻后、一次长句之后的 Velora、sidecar Python 和模型进程 RSS。结束后的 llama-server 快照不是这三个时点，也不是峰值。`ollama` 守护进程不是模型。
- 预热是否落在录音期内。
- prefill 时长。token 数不是时长。
- 功耗。`powermetrics` 未采样。不要估瓦数。
- 质量六套。非确定性现状，不是这次回归通过。
- M5 最小效应仍是 TBD。

14B 的官方 `ollama rm` 和“没有误删其他模型、共享层仍被 8B 引用”沿用 Mac 报告。本环境没有重读那台机器的 blob 目录。

## 随后的两次快照

`zh_short` 和 `zh_long` 各又跑了一次，单独归档在 [`../20261117-supplement/report.md`](../20261117-supplement/report.md)。那两次不并进上面的 31 次分布。llama-server 的前后 RSS 是快照，不是峰值。`8eb669d` 的字段验证在 [`../20261117-measurement/report.md`](../20261117-measurement/report.md)，同样不并进这 31 次。不要再为物理 T4 重跑 CLI。
