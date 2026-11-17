# 推测式重生成升级方案（第二版，待确认）

版本：2026-11-16。依据：论文 *Speculative Regeneration over Streaming Input*（~/workspace/speculative-dictation，冻结说明 results/paper/v5-freeze.md）、本仓库现状调查、一轮深度审查（DS v4.1 flash，goalfit / consistency / feasibility / redteam，结论 NEEDS_FIX，本版已逐条处理，见 §9）。

原则：简单可依赖、清晰易维护、灵活可扩展。先做最便宜、收益确定的；每一步都能单独关掉回到现状。

## 0. 结论

Velora 现在是"说完才润色"：第二次按 Fn 后跑 SenseVoice（约 50 ms），再调一次 Ollama qwen3:8b（compose 600–1700 ms，瓶颈是逐 token 解码），整段粘贴。慢在松键后的 LLM 解码。

按收益/代价排序，分三层，前一层不达标才做后一层：

1. **换更小的模型**（不写新代码，只换 Ollama 模型名并过门禁）。解码时间和模型大小近似成正比，这是最便宜的一步。
2. **录音期提前润色**：录音中在停顿处用"到目前为止的音频"整段识别并润色，松键时只剩最后一小段。只用现有 SenseVoice sidecar 与 Ollama，不引入新运行时。
3. **上一版输出作草稿**：需要自建一个能接收逐请求草稿的本地解码 sidecar（现成运行时都不支持）。只有第 2 层实测后松键后仍有可观的解码时间，才做。

规则地板、deadline、保真护栏、app 格式路由、学习闭环、整段粘贴、翻译确认卡、只连本机，全部不变。

## 1. 现状（调查结果，代码位置见附录）

| 环节 | 现状 | 已有数字 |
|---|---|---|
| 录音 | toggle 热键；AVAudioEngine tap 写整段 .caf；录音期只抓上下文与预热 | — |
| ASR | SenseVoice 常驻 sidecar，按行 JSON 请求/响应（按 id 匹配），松键后整段识别；无流式、无端点 | p50 约 50 ms |
| 润色 | Ollama `/api/generate`，`stream:false`，`format:json`，temperature 0.1；system 静态（命中前缀缓存），user 段依次为 app_format_profile、sound_alike、correction_history、style、nearby_context、`输入：转写` | compose 600–1700 ms；前缀缓存把 prefill 从 0.53 s 降到 0.11 s；冷重载约 4 s |
| 上屏 | pasteboard + ⌘V 一次性粘贴 | — |
| 度量 | HUD 单次 `wall_ms`；无端到端 p50/p90 | — |

## 2. 搬什么、不搬什么

| 论文成果 | 处理 | 理由 |
|---|---|---|
| 端点处提前整段重生成 | **搬（第 2 层）** | 松键前算好大部分输出 |
| 只追加的提示 + 前缀缓存 | **搬（第 2 层）**，需调整 user 段顺序（§4.2） | 每轮只预填新增部分 |
| 上一版输出作逐请求草稿 | **视第 2 层实测决定（第 3 层）** | 论文中的决定性部件，但在 Mac 上需自建解码器 |
| 仅被取代时取消 + 最小触发间隔 | **搬** | 防止触发过密时每轮都被取消 |
| 流式逐字上屏 | 不搬 | 往任意 App 反复粘贴不可靠，保持整段粘贴，目标压 T4 |
| LA-2 冻结已提交文本 | 不搬 | 后文改口改不了前文 |
| v5.3 微调 1.7B | 第 1 层作为候选之一参评 | 训练时是纯文本 + v3.3 提示，与 Velora 契约不同，过门禁才用 |

## 3. Mac 上的约束（论文附录实测，M4 Pro 24 GB）

- 多 token 校验代价取决于量化内核：4-bit 验证 8 个 token 46.9 ms（单步 14 ms）；bf16 41.3 ms（单步 35.9 ms）；k=17、33 有跳变。草稿接受率 80% 时 4-bit 只有约 1.24× 加速。第 3 层是否值得，取决于实测接受率与量化档位。
- 现成运行时都不支持"把一段文本当草稿传进来"：Ollama 不支持；llama.cpp 投机解码是服务级配置（草稿模型或 n-gram 查找）；上游 mlx-lm server 只支持草稿模型。bf16 下多 token 前向与单 token 前向不逐位相同，Mac 上最多"近似无损"。
- 内存：同时常驻 Ollama 模型与新解码器模型会争 24 GB 内存。任何时候只预热一个润色后端。

## 4. 设计

### 4.1 录音期提前润色（第 2 层）

```text
录音中：tap 帧 → 内存环形缓冲（新增，同时照旧写 .caf）
        停顿检测（复用现有 RMS 电平：静音 ≥ 400 ms）或连续说话满 3 s
          → 把"从开头到现在"的音频存成临时 wav → SenseVoice 整段识别（现有请求/响应协议，不加新字段）
          → 转写有变化且距上次触发 ≥ 600 ms → 发起一轮润色（取消在途请求）
松键后：整段识别（与现在完全相同，作最终输入）→ 最后一轮润色 → 护栏 → 整段粘贴
```

要点：
- **不加 VAD 模型、不改 sidecar 协议**。停顿检测用已有的 RMS 电平；每次识别都是"开头到现在"的整段音频，用的是同一个引擎，所以录音期转写与松键后转写的前缀大概率一致（P2 实测一致率），也避开了"分段拼接与整段识别断句不同"的问题。SenseVoice 非自回归，60 s 音频整段识别预计数百毫秒以内（P0 实测）。
- **连续说话也会触发**：满 3 s 无停顿强制触发一次。
- **取消**：Ollama 请求可直接中断 HTTP 连接；同一时刻最多一个在途请求；新触发到来时取消旧请求（仅被取代时取消）。
- **改动面（如实列出）**：`MacAudioCaptureService` 加环形缓冲与快照导出；新增调度器 `RollingComposer`；`OllamaTextIntelligenceEngine` 增加"可取消"的调用入口。sidecar、提示词库、护栏不改。

### 4.2 只追加的提示（第 2 层，需过门禁）

现有 user 段里 `sound_alike` 和 `correction_history` 依赖当前转写，且排在 `输入：` 之前；转写一变，它们就变，前缀缓存从这里失效。调整为：

```text
system（不变）
user：app_format_profile / style / nearby_context（录音开始时取定，整次听写不变）
      输入：<转写>
      sound_alike / correction_history（按当前转写计算，放在转写之后）
```

前缀 = system + 固定上下文 + 转写，只在转写末尾增长；依赖转写的提示放在后面，每轮重算但很短。顺序改变可能影响质量，必须过六套门禁。不过关就保留原顺序，只是第 2 层的前缀缓存收益变小。

### 4.3 草稿解码 sidecar（第 3 层，条件触发）

只有第 2 层上线后，实测"松键后最后一轮的解码时间"仍占 T4 的大头，才做：
- Python sidecar（与 SenseVoice sidecar 同一模式：按行 JSON、stdin/stdout、不开端口），用 mlx-lm 的模型加载与 prompt cache，自写草稿分块校验（k 按实测取，约 8）。
- 读线程收取消消息，校验循环每块检查取消标志（每块约 50 ms，取消延迟有界）。
- 模型从本地目录加载（`~/Library/Application Support/Velora/models/`），进程设 `HF_HUB_OFFLINE=1`，不出站；模型由安装脚本显式下载一次。
- 生命周期与 SenseVoice 一致：App 启动时预热，崩溃自动重启，失败时这一轮回退 Ollama，再失败回退规则地板。
- 通过 `PolishBackend` 协议接入（见 4.4），启用它时不预热 Ollama。

### 4.4 接口

只加一个协议，放在 `PipelineContracts.swift` 旁边：

```swift
protocol PolishBackend: Sendable {
    // system / prompt / maxTokens / format 与现有 generateDetailed 相同；draft 为空时退化为普通生成
    func generate(system: String, prompt: String, maxTokens: Int, format: String?,
                  draft: String?) async throws -> PolishOutput   // 含 text、promptTokens、loadDurationMS 等现有诊断字段
}
```

`OllamaLocalClient` 原样实现它（忽略 draft），现有告警（`ollama_model_reload`、`ollama_ctx_pressure`）不丢。`ComposeRequest` 不改。调度器调用的是 `TextIntelligenceEngine.compose`（含规则地板、deadline、JSON 解析、护栏），不绕过。第 2 层不需要这个协议，第 3 层才引入。

## 5. 分阶段与验收

延迟指标统一用 T4（松键到最终文本就绪，含 ASR、润色、护栏，不含粘贴动画），报 p50/p90 和配对差的 bootstrap 95% CI。质量指标：六套门禁 + quality_eval。门禁脚本先改为贪心解码、确定性判定（不再"失败复跑三次"）。

| 阶段 | 改动 | 验收（可判定） | 估时 |
|---|---|---|---|
| P0 量测 | 在 `VeloraDiagnostics` 现有子命令上加 `replay`：读音频文件，走 ASR→compose 全流程，记 T4 与各阶段耗时；数据用论文的中英真人与 AASR 子集 + 现有评测音频；同时测 SenseVoice 对 10/30/60 s 音频的整段识别耗时 | 得到现状 T4 p50/p90 与识别耗时曲线 | 0.5 天 |
| P1 换小模型 | 门禁脚本改贪心；Ollama 候选：qwen3:8b（现状）、qwen3:4b、qwen3:1.7b、v5.3 1.7B（GGUF 导入）；temperature 改 0 作为设置项（随"润色模型"一起切换） | 选门禁全过的最小模型；T4 p90 相对 P0 下降且 CI 不跨 0 | 1 天 |
| P2 录音期提前润色 | 4.1 + 4.2；设置开关"录音时提前润色" | T4 p90 再降 ≥ 30%（CI 不跨 0）；输入超过 30 s 的段收益更大；门禁不降；录音期转写与最终转写的前缀一致率、每次听写额外 GPU/CPU 时间如实报告 | 2–3 天 |
| P3 草稿解码（条件） | 4.3 + 4.4；先测本机 4/8-bit/bf16 的单步与 k 校验耗时，以及真实听写里的草稿接受率 | 端到端 T4 p90 相对 P2 再降 ≥ 20%（CI 不跨 0），否则不上线、保留结论 | 2–3 天 |
| P4 翻译 | 翻译模式复用 P2 调度 | 另立 | 另议 |

## 6. 回退

- 每层一个设置开关：润色模型（含其 temperature）、"录音时提前润色"、"草稿解码后端"。关掉即回到上一层的行为；P1 的 temperature 跟随模型设置，切回 qwen3:8b 时恢复 0.1。
- 第 2 层出任何异常（识别失败、请求超时），松键后照常走现有路径，只是没有提前算好的结果。

## 7. 不变的东西

规则地板、deadline 与回退、保真护栏、app 格式路由、热词与纠错学习、整段粘贴、翻译确认卡、network guard。第 3 层新增的出站风险（模型下载）由"本地目录加载 + HF_HUB_OFFLINE"堵住。

## 8. 风险

| 风险 | 应对 |
|---|---|
| 换小模型后质量不够 | 门禁不过就不换；第 2 层对现有模型同样有效 |
| 提示顺序调整伤质量 | 门禁不过就保留原顺序 |
| 录音期反复识别和润色增加功耗 | 最小触发间隔 600 ms；同一时刻最多一个在途请求；P2 报告每次听写额外耗时 |
| 停顿过密或连续说话 | 最小间隔 + 连续 3 s 强制触发；两种极端在 P2 的回放集里各取样验证 |
| 录音期转写与最终转写差异大，提前结果用不上 | 最终仍以松键后整段识别为准，最坏情况等于现状；P2 报告前缀一致率 |
| 第 3 层自建解码器的维护成本 | 条件触发；协议一个方法；sidecar 与现有 SenseVoice sidecar 同一模式 |

## 9. 深度审查意见的处理

| 意见 | 处理 |
|---|---|
| 最便宜的"换小模型"没有独立成阶段 | 新增 P1，排在最前 |
| P2 验收只是组件级理想值、无效应量 | 全部改为端到端 T4，配对 CI，给出下降门槛 |
| 录音期音频帧到 sidecar 的通路缺失；"其余模块不改"不成立 | 改为"开头到现在的音频快照 + 现有请求/响应协议"，不加 VAD、不改协议；如实列出改动面 |
| sound_alike / correction_history 破坏只追加 | §4.2 调整顺序，过门禁才用 |
| PolishBackend 签名丢 system/maxTokens/format 与诊断 | 签名与现有 generateDetailed 对齐，保留诊断字段；第 3 层才引入 |
| 调度器绕过 compose 会丢护栏 | 调度器调用 compose，不绕过 |
| 连续说话无端点、端点过密 | 连续 3 s 强制触发 + 最小间隔 600 ms |
| 单线程 sidecar 无法取消 | 第 2 层用 Ollama（断开连接即取消）；第 3 层读线程 + 每块检查取消 |
| 温度改动不可单独回退；门禁未覆盖温度 | 温度跟随模型设置；门禁脚本先改贪心与确定性判定 |
| 双后端内存压力；sidecar 冷启动/崩溃/离线下载 | 只预热一个后端；生命周期与回退写明；本地目录加载 + HF_HUB_OFFLINE |
| 分段拼接与整段识别断句不同，草稿命中低 | 改为每次整段识别"开头到现在"，并实测前缀一致率 |
| P0 应复用现有入口 | 在 VeloraDiagnostics 上加 replay 子命令 |

## 附录：现状代码位置

- 会话生命周期：`Apps/VeloraMac/MacSystemInputController.swift`（`startRecording` :759、`stopAndRunPipeline` :867、`makePipeline` :1352）
- 录音：`Apps/VeloraMac/VeloraMacApp.swift:718` `MacAudioCaptureService`
- ASR：`Velora/Sources/Velora/SenseVoiceASREngine.swift`、`scripts/sensevoice_sidecar.py`
- 润色：`Velora/Sources/Velora/LocalModelEngines.swift`（`compose` :811、user 段拼装 :864-899、`OllamaPromptLibrary` :1413、`OllamaLocalClient` :1543）
- deadline：`Velora/Sources/Velora/TextComposition.swift:281`
- 协议：`Velora/Sources/Velora/PipelineContracts.swift:478-515`
- 诊断入口：`Velora/Sources/VeloraDiagnostics/main.swift`（子命令 :55-73）
- 门禁：`pocs/tuning/*_eval.py`
