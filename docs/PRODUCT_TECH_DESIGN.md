# Velora 产品与技术设计

版本：2026-07-05

## 0. 统一语言

全项目统一用这套概念，文档和代码不再使用旧的三模式（dictate/polish/translate 阶段串行）语言：

- **纠错属于 ASR 能力本身**。热词纠错是 ASR 能力边界内的实现细节，出了 ASR 这个框，文本就是"用户说的话"。结构化 edits 仍然保留，供诊断和反馈学习使用，但纠错不是独立 pipeline 阶段。
- **Polish 是必须的能力**，不是可选模式。每次输出都经过润色层；润色分级：规则清理是永远可用的地板，LLM 在 deadline 内返回才采用，超时或不可用就上规则结果。"Polish 必须"指"每次输出都经过润色层"，不是"每次都等 LLM"。
- **翻译是在 Polish 基础上做第二语言渲染**。翻译模式不是多一个 pipeline 阶段，而是同一次 LLM 调用的输出 schema 多一个字段：`{ polished }` 变成 `{ polished, target }`。专用翻译引擎（Apple Translation / LLM 单独翻译）降级为兜底槽位，只在 compose 调用产不出 target 时使用。

因此用户模式只有两个：

```text
输入模式：ASR（含纠错）→ compose { polished } → 上屏
翻译模式：ASR（含纠错）→ compose { polished, target } → 双语渲染 → 上屏
```

当前工程状态：

- Swift Package `Velora`：核心模型挂在 `ASREngine`、`TextIntelligenceEngine`（单方法 `compose`）、`TranslationEngine`（兜底槽位）、`InsertionEngine` 协议后面。
- `DictationMode` 只有 `input` 和 `translate` 两个值；旧存量值 dictate/polish 解码时归一到 input。
- compose 已实现分级：规则地板 + Ollama qwen3:8b 单次 JSON 调用（`{"polished","target"}`），带 deadline（输入 4s / 翻译 6s，生产目标 250/500ms），超时或 LLM 失败自动降级规则结果并打 warning。
- 翻译模式一律弹确认层（2026-07-05 定稿，推翻更早的置信度门控方案）：跨语言输出用户无法自查，必须由用户决策而非模型置信度。弹层展示原文+译文（双语仅在此展示），原文/译文均可编辑，改原文后可 ⌘R 重译；上屏永远单语（默认译文，可选原文）。弹层内的用户修改写入本地 correction journal，供记忆层进化热词/glossary。
- 输入模式保持直接上屏（高频路径，快是一切）。
- Mac App：默认 `Fn`（输入模式）、`Fn ⇧`（翻译模式）、可切换 Space 组合键、菜单栏入口、非激活 voice bar、pasteboard+CmdV 插入（带目标 App 重激活保护）和剪贴板恢复。录音中裸 Fn 立即触发，不付 140ms 消歧延迟。
- Ollama 客户端带 network guard：非 loopback endpoint 直接失败（`VELORA_ALLOW_REMOTE_LLM=1` 才可覆盖）。
- iOS 主 App 和 Keyboard Extension 已建立。主 App 写 App Group，键盘扩展读最近候选并插入。iOS 主 App 已实现麦克风 preflight sheet。
- 翻译模式默认双语：`原文 + 译文`。`target_only` 只影响插入文本，不影响双语审阅展示。
- 当前 iOS 默认 ASR 仍是占位 adapter。真实 iPhone ASR 等真机 benchmark 后再选。Mac 上 Apple Speech 实测 `kLSRErrorDomain Code=201`，只保留为可选 adapter。

## 1. 目标

做一个纯本地的个人语音输入系统。优先支持 Mac 和 iPhone。

核心目标不是“把语音转文字”。核心目标是把自然说话变成用户愿意直接上屏的文字：

- 本地 ASR：音频不出设备。
- 语境纠错：结合当前 App、窗口、附近文本、用户长期热词和历史纠错。
- 润色排版：把口语整理成适合当前场景的文本。
- 翻译模式：说语言 A，输出语言 B，并默认同时上屏语言 A 原文，方便用户校验。
- 可解释和可控：用户能知道哪些热词参与了纠错，能关闭某个 App 或某类记忆。
- 延迟目标：性能和体验流畅度第一。核心指标是 release-to-insert（从"松开录音键"到"文本完成上屏"）。北极星：任何模式 warm p50 ≤ 1s。分模式预算：Mac 输入 p50 ≤ 800ms / p95 ≤ 1.3s；Mac 翻译 p50 ≤ 1.0s / p95 ≤ 1.8s。冷启动不能进入默认关键路径。

## 2. 非目标

第一版不做这些：

- 不做云端账号系统。
- 不做团队协作、共享词库、企业管理后台。
- 不做跨设备云同步。之后可以做局域网或用户自管同步。
- 不复制 GPL 或非商业许可证项目的代码。可以研究交互和架构思路，但实现必须 clean-room。
- 不承诺 iPhone 上能像 Mac 一样直接向任意 App 注入文本。iOS 沙箱限制更强，必须按系统允许的入口设计。

## 3. 外部参考与取舍

### 3.1 Typeless

Typeless 的核心体验值得参考：

- 入口轻：按住快捷键，说完松开，文本进入当前 App。
- 用户不需要说标点和格式指令。
- 输出不是原始逐字稿，而是可发送文本。
- UI 不抢主任务，只在录音和确认时出现。

我们要补足的地方：

- 严格本地化，不把音频、识别文本、上下文传云端。
- 翻译模式默认双语上屏：`原文 + 译文`。
- 长期语境和热词不是单一自定义词典，而是带来源、场景、频率、最近使用时间和置信度的本地记忆。
- 提供可解释诊断：为什么改成这个词，哪些记忆参与了决策。

### 3.2 开源项目可吸收部分

| 项目 | 可吸收 | 需要避开的点 |
| --- | --- | --- |
| TypeWhisper | Mac 系统级 dictation、工作流、history、dictionary、snippets、插件化思路 | GPL-3.0，不直接复用代码；iOS 不是主成熟面 |
| Dictus | iOS 键盘方向、WhisperKit 本地识别、离线隐私定位 | 功能面还窄，长期语境、润色和双语翻译需要自建 |
| OpenTypeless | 热键说话、跨桌面、LLM polishing、自定义词典 | 不是 Apple 平台优先；不是默认完全本地 |
| OpenWhispr | history、semantic search、dictionary、桌面本地模型经验 | iPhone 入口缺失；多 provider 设计需要收敛到本地优先 |
| Local Whisper 类项目 | 移动端 keyboard、替换规则、模式化输入 | 许可证和成熟度要逐项审查，不作为代码基线 |

结论：没有现成项目能完整满足需求。策略是参考产品交互和模块边界，代码自建。

## 4. 产品形态

### 4.1 Mac

Mac 是第一主战场。可以做到接近 Typeless 的系统级体验。

入口：

- 全局快捷键：默认 `Fn` 切换录音，翻译默认 `Fn ⇧`。
- 备用快捷键：设置面板可切到 `⌥ Space`、`⌃ Space`、`⌘ ⇧ Space` 等组合键，适合外接键盘或 Fn/Globe 被系统占用的环境。
- 菜单栏入口（极简，accessory 形态无 Dock 图标）：常态只有「开始听写／开始翻译／设置…／退出」四项；录音中变为「完成并上屏／取消」，待确认时变为「确认并上屏／放弃」，无障碍权限缺失时顶部动态出现修复入口。调试项（模式/ASR 档位/探针）全部收进设置面板里的「开发者模式」开关，产品形态不可见。
- 浮动录音条：只在录音、转写、确认、错误时出现。
- 输入法入口：用 `InputMethodKit` 做真正输入法候选和文本提交。
- Accessibility 入口：对无法走输入法提交的 App，用 AX 或剪贴板回退。

主要流程：

```text
用户按住快捷键
  -> 浮动条显示波形和当前模式
  -> 本地 VAD 切分音频
  -> ASR 生成候选和置信度
  -> 读取当前 App/窗口/附近文本
  -> 本地记忆系统选热词
  -> 本地纠错/润色/翻译
  -> 生成一个可插入结果和一个可审阅结果
  -> 默认直接上屏，低置信度时弹出审阅条
```

### 4.2 iPhone

iPhone 必须正视系统限制。Apple 的自定义键盘扩展不能访问设备麦克风，所以不能把“第三方键盘里直接录音”作为唯一方案。

第一版采用三个入口：

- 主 App 录音：打开 App，录音，得到结果，复制、分享或插入到内置编辑区。
- 键盘扩展插入：键盘读取 App Group 里的最近结果，把文本插入当前输入框。
- Shortcut / Action Button：触发录音，完成后把结果放到剪贴板或打开键盘候选页。

iPhone 推荐流程：

```text
用户在目标 App 打开 Velora 键盘
  -> 点击麦克风按钮
  -> 系统跳到主 App 录音页
  -> 本地完成识别、纠错、润色、翻译
  -> 结果写入 App Group
  -> 用户返回目标 App
  -> 键盘顶部出现待插入结果
  -> 用户点一下插入
```

这比 Mac 多一步，但符合 iOS 权限模型。不能为了“像 Typeless”而做不稳定或违反系统规则的私有 API。

### 4.3 iPhone 授权体验最优解

iPhone 授权策略是：先让用户得到一次价值，再请求更高成本权限。

默认路径：

```text
首次打开 App
  -> 不弹任何系统权限
  -> 用户点击录音
  -> 解释为什么需要麦克风
  -> 系统麦克风授权
  -> 本地 ASR / 纠错 / 润色 / 翻译
  -> 结果复制、分享或写入待插入结果
```

权限阶梯：

| 权限/设置 | 触发时机 | 是否默认路径 | 原因 | 拒绝后的可用性 |
| --- | --- | --- | --- | --- |
| Microphone | 第一次点击录音 | 是 | 采集语音 | 不能录音，但可粘贴文本做润色/翻译，或导入音频 |
| Speech Recognition | 只有用户选择 Apple Speech 引擎时 | 否 | 使用 Apple Speech 后端 | 切回 WhisperKit / 本地 ASR |
| Keyboard Add | 用户开启“快速插入键盘”时 | 否 | 在其他 App 内插入最近结果 | 仍可用复制、分享、快捷指令 |
| Keyboard Full Access | 只有键盘需要读取 App Group 最近结果时 | 否 | 让键盘读取主 App 生成的结果 | 不启用增强键盘，改用剪贴板/分享 |
| Contacts | 用户开启“联系人姓名学习”时 | 否 | 本地提高人名识别 | 手动热词 |
| Calendar | 用户开启“会议语境学习”时 | 否 | 本地提高会议名识别 | 手动热词 |
| Notifications | 后续需要后台提醒时 | 否 | 非核心输入能力 | 不影响输入 |

关键取舍：

- 默认 ASR 不依赖 Apple Speech 权限。优先用 WhisperKit 或其他本地引擎，只请求麦克风。
- 自定义键盘的 Full Access 提示心理成本高，不放进首轮引导。它只作为“快速插入增强功能”。
- 不读取系统剪贴板，避免触发剪贴板隐私提示。可以写入剪贴板，但不把读取剪贴板作为核心能力。
- Contacts 和 Calendar 只在用户明确开启个性化后请求。手动热词永远是无授权兜底。
- 每个授权弹窗前都有一页本地说明，说明数据用途、是否离线、拒绝后还能怎么用。

授权文案要求：

- 说人话，不用“提升体验”这种空话。
- 明确写“音频只在本机处理”。
- 明确写“不同意也可以复制/分享结果”。
- 对 Keyboard Full Access 单独提示：这是 iOS 对键盘共享数据的系统要求，我们只用它读取本机最近结果；默认本地模式下仍禁止网络。

授权失败处理：

- 不弹二次系统权限。
- 显示一个恢复按钮：打开 Settings。
- 保留低权限替代路径：文本输入、导入音频、复制/分享、手动热词。
- 记录诊断状态，但不记录用户正文。

## 5. 模式设计

只有两个用户模式。Polish 不是模式，是每次输出都经过的必经层。

### 5.1 输入模式

目标：把用户的话变成可直接发送的文本。ASR（含热词纠错）之后，compose 调用输出 `{ polished }`。

Polish 分级（同一个 compose 调用内部的降级链）：

```text
规则清理（永远可用的地板）
  -> 口癖删除、重复词删除、空白折叠、按主导文字选终止标点、保留段落
  -> 毫秒级

LLM 润色（deadline 内返回才采用）
  -> 更好的语言组织、断句、大小写、场景排版
  -> 结构化输出，超时/失败自动落回规则结果并打 warning
```

可选风格（style 参数）：原样整理、简洁、邮件、条列、正式。

场景来源：

- 当前 App：Mail、Slack、Notes、Pages、浏览器。
- 附近文本：用户已经写的上文。
- 用户风格记忆：常用称呼、签名、表达习惯。

适合：聊天、备忘、搜索、邮件——这是最高频路径。

### 5.2 翻译模式

目标：说语言 A，得到语言 B，同时保留语言 A 供校验。

实现形态：翻译模式只是 compose 调用的输出 schema 多一个字段——同一次 LLM 调用同时产出 `polished`（保持源语言）和 `target`（目标语言）。相比"先润色再翻译"两次调用，省掉一整次 prompt eval 和往返，翻译相对输入模式的增量成本只有目标语言的输出 token。

兜底链（`TranslationEngine` 槽位，只在 compose 产不出 target 时启用）：

```text
compose 正常   -> { polished, target } 一次拿到（Mac 默认）
compose 超时   -> 规则清理原文 + 专用翻译引擎兜底，reviewRequired=true
LLM 不存在     -> 同上（iPhone 无本地大模型时的常态路径，翻译走 Apple Translation）
```

质量守护（代码层，不信任模型自觉）：

- `polished` 语言校验：模型把译文填进 polished 时，自动换回纠错后的原文并打 `compose_polished_was_target_language`。
- `target` 语言校验：译文读起来还是源语言时打 `translation_language_uncertain` 并 reviewRequired。

默认插入策略：

```text
原文:
明天上午十点我和 Alex 开会，帮我确认一下 agenda。
译文:
I have a meeting with Alex tomorrow at 10 a.m. Please help me confirm the agenda.
```

可配置插入策略：

- `bilingual`：默认。原文和译文都上屏。
- `target_only`：只上屏目标语言，适合熟练用户。
- `review_card`：原文作为引用，译文作为正文，适合邮件和文档。

翻译模式必须保留这些字段：

```json
{
  "source_language": "zh",
  "target_language": "en",
  "source_text": "...",
  "corrected_source_text": "...",
  "target_text": "...",
  "display_text": "...",
  "insert_text": "...",
  "glossary_hits": ["agenda"],
  "warnings": []
}
```

设计原则：

- 翻译前先纠正原文，但不能把原文改到偏离用户意思。
- 术语表优先级高于通用翻译。
- 翻译一律经确认弹层再上屏，由用户决策（识别对不对、翻译对不对、可直接改），不由模型置信度决定。
- 双语审阅是产品差异点：弹层同时展示原文与译文；但**上屏永远单语**（默认译文），不把双语块插进目标 App。

## 6. UI / UX 设计

### 6.1 视觉基调

产品类型是生产力工具，不做营销式页面。界面要安静、轻、明确。

采用：

- Apple 原生控件优先。
- SF Pro / 系统字体，支持 Dynamic Type。
- SF Symbols 作为图标系统。
- 4/8pt 间距系统。
- 8pt 以内圆角。
- 亮暗模式都要可读。
- 录音状态用红色；处理中用蓝色；完成用绿色；错误用红色并给恢复路径。

设计 token 初稿：

| Token | Light | Dark | 用途 |
| --- | --- | --- | --- |
| `surface` | `#F8FAFC` | `#0B1220` | 背景 |
| `panel` | `#FFFFFF` | `#111827` | 面板 |
| `textPrimary` | `#0F172A` | `#F8FAFC` | 主文本 |
| `textSecondary` | `#475569` | `#CBD5E1` | 次文本 |
| `primary` | `#1E3A5F` | `#7BA7D9` | 主操作 |
| `recording` | `#DC2626` | `#F87171` | 录音 |
| `processing` | `#2563EB` | `#60A5FA` | 处理中 |
| `success` | `#059669` | `#34D399` | 完成 |
| `border` | `#E4E7EB` | `#263244` | 分割线 |

### 6.2 Mac 浮动录音条

尺寸：

- 最小宽度：320pt。
- 高度：56pt。
- 最大宽度：520pt。
- 位置：当前光标附近；拿不到位置时居中靠下。

内容：

- 左侧：状态图标和波形。
- 中间：实时识别片段或状态文字。
- 右侧：模式按钮、取消按钮。

状态：

| 状态 | UI | 行为 |
| --- | --- | --- |
| Idle | 不显示 | 菜单栏保留状态 |
| Listening | 红点 + 波形 + 计时 | `Esc` 取消，松开提交 |
| Transcribing | 蓝色进度环 | 禁止重复提交，可取消 |
| Reviewing | 显示候选文本和差异 | `Enter` 插入，`Esc` 丢弃，`Tab` 切候选 |
| Inserted | 绿色短反馈 800ms | 自动消失 |
| Error | 错误原因，6s 自动消失 | HUD 不可交互；恢复路径在菜单栏（重试、无障碍设置）；结果文本保底在剪贴板 |
| NoSpeech | "没有听到声音" 轻提示，1.6s 自动消失 | 静音是常态输入不是错误；whisper 空输出与 [BLANK_AUDIO] 类占位标记都归入此态 |

快捷键：

| 快捷键 | 行为 |
| --- | --- |
| `Fn` | 开始/停止录音；有待确认结果时确认上屏 |
| `Fn ⇧` | 切到翻译模式并开始/停止录音 |
| `⌥ Space` | 可选备用：开始/停止录音 |
| `Esc` | 取消 |
| `Enter` | 插入当前候选 |
| `⌘ Z` | 尝试撤回上次插入 |
| `⌘ ,` | 打开设置 |

### 6.3 iPhone 主 App

底部 Tab 不超过 4 个：

- Record：录音和编辑。
- History：历史结果。
- Memory：热词、术语表、风格。
- Settings：模型、隐私、语言。

Record 页：

- 顶部：模式分段控件 `输入 / 翻译`。
- Translate 模式显示语言对：`中文 -> English`。
- 中间：大录音按钮，44pt 以上触控范围。
- 录音中：波形、计时、取消。
- 结果区：原文、译文或润色结果。
- 底部：复制、分享、写入键盘候选、插入策略。

键盘扩展：

- 顶部候选条显示最近一条结果。
- 插入按钮明确显示目标：`插入双语`、`只插入译文`。
- 如果 App Group 没有结果，显示小提示和“打开录音”按钮。
- 不在键盘里承诺直接录音。

### 6.4 设置结构

| 页面 | 设置项 |
| --- | --- |
| Models | ASR 引擎、文本引擎、翻译引擎、模型下载、占用空间 |
| Modes | 默认模式、每个 App 默认模式、翻译插入策略 |
| Memory | 热词、术语、替换规则、风格、按 App 开关 |
| Privacy | 本地数据位置、加密、清理、网络禁用、导出 |
| Shortcuts | Mac 全局快捷键、iPhone Shortcut、Action Button 指南 |
| Diagnostics | 最近一次处理耗时、选中热词、模型版本、错误日志 |

## 7. 系统架构

```text
┌──────────────────────────┐
│ Platform Shell            │
│ macOS App / IMK / AX       │
│ iOS App / Keyboard / Intent│
└────────────┬─────────────┘
             │
┌────────────▼─────────────┐
│ Capture Layer             │
│ AVAudioEngine / VAD / PCM  │
└────────────┬─────────────┘
             │
┌────────────▼─────────────┐
│ Session Orchestrator       │
│ mode, language, context    │
└──────┬─────────┬─────────┘
       │         │
┌──────▼───┐ ┌───▼──────────┐
│ ASR      │ │ Context       │
│ Adapter  │ │ Memory Store  │
└──────┬───┘ └───┬──────────┘
       │         │
┌──────▼─────────▼─────────┐
│ Text Intelligence Layer    │
│ compose: polish + target?  │
└────────────┬─────────────┘
             │
┌────────────▼─────────────┐
│ Renderer + Insertion       │
│ IMK / AX / Keyboard / Copy  │
└──────────────────────────┘
```

模块边界：

- Platform Shell 只管权限、系统入口和 UI。
- Capture Layer 只产出音频 chunk 和 VAD 事件。
- ASR Adapter 产出候选并完成热词纠错（纠错属于 ASR 能力边界；结构化 edits 供诊断），不负责润色。
- Context Memory 只选择相关上下文，不把全部历史塞给模型。
- Text Intelligence 只暴露 compose：必经润色 + 翻译模式多输出一个 target 字段。
- TranslationEngine 是兜底槽位，只在 compose 产不出 target 时使用。
- Renderer 负责不同模式的插入文本。

## 8. 数据合同

### 8.1 DictationSession

```json
{
  "id": "uuid",
  "created_at": "2026-06-27T12:00:00Z",
  "platform": "macos",
  "mode": "translate",
  "source_language": "zh",
  "target_language": "en",
  "app_bundle": "com.apple.mail",
  "window_title_hash": "sha256",
  "input_surface": "global_hotkey",
  "duration_ms": 8400,
  "network_allowed": false
}
```

### 8.2 ContextSnapshot

```json
{
  "app_bundle": "com.apple.mail",
  "window_title": "Draft",
  "selected_text": "",
  "nearby_text": "Need to confirm agenda...",
  "mode": "translate",
  "language_pair": "zh-en",
  "privacy_scope": "ephemeral"
}
```

隐私规则：

- `nearby_text` 默认只在本次 session 内使用。
- 只有用户明确开启“从上下文学习”时，才保存提取出的术语或 correction event。
- 保存历史时默认保存结果文本，不保存原始音频。
- 原始音频只允许临时缓存，默认处理后删除。

### 8.3 MemoryTerm

```json
{
  "term": "prompt injection",
  "replacement": "prompt injection",
  "language": "en",
  "domains": ["ai", "security"],
  "apps": ["com.apple.mail", "com.microsoft.VSCode"],
  "source": "accepted_correction",
  "edit_count": 19,
  "last_seen_at": "2026-06-27T11:30:00Z",
  "confidence": 0.92,
  "disabled": false
}
```

### 8.4 PipelineResult

```json
{
  "raw_asr": "The biggest risk is prom injection in velora.",
  "corrected_source": "The biggest risk is prompt injection in Velora.",
  "final_text": "The biggest risk is prompt injection in Velora.",
  "alternatives": [],
  "edits": [
    {
      "from": "prom injection",
      "to": "prompt injection",
      "reason": "selected_hotword",
      "confidence": 0.88
    }
  ],
  "selected_hotwords": ["prompt injection", "Velora"],
  "latency": {
    "asr_ms": 620,
    "context_ms": 18,
    "text_ms": 240,
    "insert_ms": 32
  }
}
```

## 9. ASR 管线

### 9.1 引擎优先级

第一版不要押注单一 ASR。

| 引擎 | Mac | iPhone | 角色 |
| --- | --- | --- | --- |
| Apple Speech / SpeechAnalyzer | 可用时优先评测 | 可用时优先评测 | 系统级低功耗候选 |
| WhisperKit | 强候选 | 强候选，但要测包体和耗电 | Apple 平台本地 ASR 主候选 |
| whisper.cpp | Mac 强候选 | 可做实验 | 性能和模型选择灵活 |
| sherpa-onnx | 备选 | 备选 | 多模型、多语言离线能力 |
| FunASR / SenseVoice / Qwen-ASR 类模型 | 实验 | 实验 | 中文和中英混说专项评测 |

### 9.2 ASR 输出要求

ASR Adapter 必须输出：

- `text`
- `segments`
- `tokens`
- `timestamps`
- `confidence`
- `alternatives`
- `language`
- `engine`
- `model_version`

不要把 ASR 输出直接插入。必须经过 `Text Intelligence Layer`。

### 9.3 音频处理

- 采样率：16kHz 或引擎推荐格式。
- 声道：mono。
- VAD：本地 WebRTC VAD 或模型内置 VAD。
- 分段策略：短句整段处理；长段每 8-12 秒滚动处理。
- 保存策略：默认不保存音频。用户开启 Debug 时只保存最近 N 条，并明确标红。

### 9.4 延迟优先管线

核心测量点是 release-to-insert，不是录音开始到完成。

必须提前做的工作：

- App 启动后预热默认 ASR 和轻量文本引擎。
- 用户按下录音键时立即建立音频 session。
- 录音时并行采集当前 App、窗口、选中文本和附近文本。
- 录音时完成 Top K 热词排名。
- 录音时启用 streaming ASR partial。
- 录音时对 partial transcript 做 speculative compose（润色和目标语言草稿）。

松手后关键路径只允许这些工作：

```text
VAD flush
  -> ASR finalize（含热词纠错）
  -> compose reconcile（polished，翻译模式再多一个 target 字段）
  -> render insert text
  -> insert
```

不能放进关键路径的工作：

- 模型冷加载。
- 大模型长生成。
- 全量历史检索。
- embedding 重建。
- 大量 UI 动画。
- 网络请求。
- 同步写大量日志。

插入策略：

- 默认先插入足够好的结果。
- 如果高质量润色超过预算，先上屏基础结果，再在浮动条给“替换为优化版”。
- 低置信度才进入审阅。不能让所有输入都卡在审阅 UI。
- 文本引擎要支持 deadline。超过 deadline 返回 best effort，不继续阻塞插入。

预算（北极星：任何模式 warm p50 ≤ 1s）：

| 场景 | Warm p50 | Warm p95 | 关键要求 |
| --- | ---: | ---: | --- |
| Mac 输入 | 800ms | 1300ms | ASR streaming，compose deadline 250ms（生产目标），超时规则结果上屏 |
| Mac 翻译 | 1000ms | 1800ms | 单次 compose 出双语，deadline 500ms（生产目标），双语 render 小于 20ms |
| iPhone 翻译 bridge | 1600ms | 2600ms | 主 App 先完成结果，键盘只负责插入 |

当前开发期 deadline 先放宽到输入 4s / 翻译 6s（whisper CLI + Ollama 形态下的现实值，主要用于兜住 Ollama 冷路径 5-12s 的长尾）；换常驻 ASR 和常驻小模型后收紧到生产目标。

## 10. 上下文与长期记忆

### 10.1 记忆来源

- 手动添加热词。
- 用户接受的纠错。
- 用户撤回或手动修改后的差异。
- App 场景：邮件、聊天、代码编辑、笔记。
- 本地联系人和日历中的人名、会议名。默认关闭，需要用户授权。
- 用户导入的项目词表。

### 10.2 排名策略

候选热词得分：

```text
score =
  app_match * 3.0
  + domain_match_count * 2.0
  + nearby_text_match * 4.0
  + min(3.0, log1p(edit_count))
  + recency_bonus
  + mode_bonus
  - disabled_penalty
```

只把 Top K 热词传给纠错或 LLM。K 默认 12，最大 20（2026-07-05 从 8 上调：ASR 同音术语对入表后 8 会把低分词挤出截断线；rank 阶段拿不到 ASR 文本，无法按命中动态提权，SQLite 记忆层落地时再做两段式选择）。

### 10.3 防止记忆污染

- 用户拒绝一次修改，降低该记忆在当前 App 的权重。
- 用户连续拒绝三次，自动暂停该记忆。
- 不从密码框、隐私窗口、银行类 App、系统设置中学习。
- 每条记忆保留来源，用户可以删除或禁用。
- LLM prompt 不直接塞完整历史，只塞选择后的术语和短上下文。

## 11. 本地文本智能

### 11.1 任务形态

文本智能层是一次 compose 调用：

- 纠错（热词/实体保真）在 ASR 能力边界内完成，不进文本智能层。
- Polish：必经层，分级（规则地板 + LLM deadline 内增强）。
- Translation：同一次调用多输出一个 `target` 字段，不是第二次调用。

原则修正：反对的是"不可评测的混合字符串输出"，不是"一次调用"。合并调用是允许且默认的，前提是输出结构化——`polished` 和 `target` 是独立字段，可以分别评测、分别做语言校验。

### 11.2 引擎选择

| 引擎 | 使用场景 |
| --- | --- |
| 规则引擎 | compose 的地板层：空白/标点/段落/模板，永远在默认路径 |
| Apple Foundation Models | 可用时作为 compose 的 LLM 层（润色 + 可选 target）；不可用时降级规则地板 |
| Apple Translation | 兜底槽位；iPhone 无本地 LLM 时的常态翻译路径（2026-07-05 从"默认引擎"降级） |
| MLX Swift | Mac / 高端 iPhone 本地小模型实验，先不进入默认路径 |
| llama.cpp | Mac 本地模型和可控推理，先不进入默认路径 |
| Ollama | Mac 开发期 compose 默认 LLM，不作为生产依赖 |

所有引擎必须挂在同一协议后面：

```swift
protocol TextIntelligenceEngine {
    // 单次调用：必经润色 + 可选目标语言。翻译模式只是输出多一个字段。
    func compose(_ request: ComposeRequest) async throws -> ComposeResult
}

// 兜底槽位：compose 产不出 target 时才使用。
protocol TranslationEngine {
    func translate(_ request: LocalTranslationRequest) async throws -> LocalTranslationOutput
}
```

### 11.3 结构化输出

LLM 输出必须是结构化 JSON，禁止只让模型返回一段字符串。分两层合同：

模型原始输出（compose 调用）：

```json
{"polished": "整理后的原文", "target": "目标语言译文（仅翻译模式）"}
```

引擎返回（`ComposeResult`，代码层组装并校验）：

- `polishedText`（+ 翻译模式的 `targetText`）
- `edits`
- `glossaryHits`
- `warnings`
- `confidence`
- `reviewRequired`
- `engine`

语言校验在代码层强制：polished 不许是译文、target 不许是原文、检测器不覆盖的语言对必须 reviewRequired。

## 12. 本地翻译

### 12.1 默认方案

翻译的默认路径是 compose 调用直接输出 `target`（决策反转记录：旧决策是"Apple Translation 默认、LLM 补充"，2026-07-05 起改为"compose LLM 默认、专用翻译引擎兜底"，理由是省一次 prompt eval、润色和翻译共享同一上下文和术语注入）。

双语上屏由 `TranslationModeRenderer` 保证，不依赖翻译模型本身。

### 12.2 兜底方案（TranslationEngine 槽位）

兜底槽位必须保留，因为翻译模式没有"无模型"的规则降级：

- Mac：compose 超时/失败时，用专用翻译引擎单独重试（当前 Ollama，候选 Apple Translation lowLatency）。
- iPhone：本地大模型不可保证存在。LLM 不可用时翻译直接走 Apple Translation，这是 iPhone 的常态兜底路径，不是异常。
- 小型专用翻译模型：后续 POC 再决定是否引入。
- 用户术语表：始终优先于通用翻译。

更完整的模型策略见 `docs/LOCAL_MODEL_STRATEGY.md`。

### 12.3 翻译质量保护

翻译模式进入审阅的条件：

- ASR 置信度低。
- 翻译引擎返回 unsupported language。
- 术语冲突。
- 原文过长。
- 出现命名实体不一致。
- 用户开启“翻译永远审阅”。

## 13. 插入策略

### 13.1 Mac 插入优先级

```text
InputMethodKit commit
  -> Accessibility focused element setSelectedText
  -> pasteboard paste fallback
  -> copy to clipboard and notify
```

剪贴板回退必须保护用户原剪贴板：

- 插入前读取原剪贴板。
- 写入临时文本并触发粘贴。
- 1 秒后恢复原剪贴板，除非用户在这期间手动复制了新内容。

### 13.2 iPhone 插入优先级

```text
Keyboard textDocumentProxy.insertText
  -> Share sheet
  -> Clipboard
  -> In-app editor
```

键盘扩展只负责插入。录音和模型推理由主 App 完成。

## 14. 隐私与安全

硬规则：

- 默认网络关闭。
- 音频默认不保存。
- 原文、译文、热词、历史保存在本地。
- 本地数据库可导出、可删除。
- 用户能按 App 禁用学习。
- 任何云能力如果未来加入，必须是显式开关，并标记为非本地模式。

实现要求：

- SQLite 数据库放在 App Sandbox 容器。
- iOS 主 App 和键盘通过 App Group 共享最小数据。
- 敏感字段加密，密钥走 Keychain。
- 日志默认不写正文，只写耗时、模型、状态码。
- Debug 日志需要用户显式打开，且有自动过期。

网络验证：

- 开发期加一个 network guard。
- 本地模式下发起网络请求直接失败并记录。
- 发布前用系统防火墙或代理抓包验证。

## 15. 评测指标

“超过 Typeless”必须变成可测指标。没有 Typeless 内部指标，就用同一套输入任务做外部对比。

### 15.1 数据集

自建 300 条个人输入测试：

- 80 条中文日常输入。
- 60 条英文输入。
- 60 条中英混说。
- 40 条邮件和工作消息。
- 30 条术语密集内容。
- 30 条翻译模式。

每条保存：

- 音频。
- 期望文本。
- 可接受变体。
- 目标 App。
- 模式。
- 必须保留的实体。

### 15.2 指标

| 指标 | 目标 |
| --- | --- |
| WER / CER | 不低于所选 ASR baseline |
| Entity accuracy | 热词、人名、产品名命中率优先高于原始 ASR |
| Correction precision | 错改率低于 1% |
| Translation review usefulness | 双语上屏能让用户发现翻译问题 |
| Release-to-insert latency | 北极星：任何模式 warm p50 ≤ 1s。Mac 输入 p50 < 800ms，p95 < 1.3s；Mac 翻译 p50 < 1.0s，p95 < 1.8s；iPhone bridge p50 < 1.6s，p95 < 2.6s |
| Cold-start isolation | 冷启动不进入默认录音关键路径；模型冷加载只能发生在 App 启动、设置切换或显式预热 |
| Local-only | 默认模式 0 网络请求 |
| Battery | iPhone 连续 20 次短句不过热、不明显掉帧 |
| User edits after insertion | 相比原始 ASR 降低 40% 以上 |

### 15.3 对比方法

- 同一段音频或同一段朗读文本，分别用 Typeless 和 Velora。
- 记录最终上屏结果，而不是只看转写。
- 标注实体错误、格式错误、语气错误、翻译错误。
- 翻译模式额外看：目标语言准确度、原文保留是否帮助校验。

## 16. 已完成 POC 结论

### 16.1 翻译模式输出合同

文件：`pocs/translation_mode_poc.py`

结论：

- `source_text`、`corrected_source_text`、`target_text`、`display_text`、`insert_text` 可以分离。
- `bilingual`、`target_only`、`review_card` 三种插入策略可用。
- glossary hits 可以进入结果，用于诊断和 UI 展示。

### 16.2 语境热词选择

文件：`pocs/context_hotword_poc.py`

结论：

- SQLite 本地 memory terms 足够支撑第一版。
- app、domain、nearby text、edit_count、recency、mode 的加权策略可解释。
- 不需要把全部历史注入 prompt，只需要注入 Top K 热词。
- POC 能把 `prom injection` 改成 `prompt injection`，把 `velora` 改成 `Velora`。

### 16.3 Apple 平台能力探测

文件：`pocs/apple_platform_probe.sh`

本机结果：

- macOS SDK 26.4。
- Xcode 26.4。
- Swift 6.3。
- `Speech`、`NaturalLanguage`、`AppKit`、`InputMethodKit`、`AVFoundation`、`Accessibility`、`FoundationModels`、`Translation` 都能 import。

结论：当前机器可以开始 Apple 平台原型开发。

### 16.4 延迟预算合同

文件：`pocs/latency_budget_poc.py`

结论：

- 性能目标要用 release-to-insert 衡量。
- context capture、hotword ranking、partial ASR、speculative correction/translation 必须在录音期间并行。
- 冷启动路径必然超预算，所以模型必须预热。
- 默认路径不能依赖大模型长生成。

### 16.5 iPhone 授权流合同

文件：`pocs/ios_permission_flow_poc.py`

结论：

- 首次打开 App 不请求任何系统权限。
- 默认录音路径只请求麦克风。
- Apple Speech、键盘 Full Access、Contacts、Calendar 都是后置可选授权。
- 每个授权都必须有拒绝后的替代路径。

## 17. 后续 POC

优先级从高到低：

1. Mac 插入 POC  
   验证 `InputMethodKit commit -> AX -> pasteboard fallback` 三层插入。

2. iPhone 键盘桥接 POC  
   验证主 App 写 App Group，键盘读取并 `insertText`。

3. ASR benchmark POC  
   对比 Apple Speech / SpeechAnalyzer、WhisperKit、whisper.cpp、sherpa-onnx。

4. 延迟预算 POC  
   把 release-to-insert 作为自动检查，任何默认路径超过预算都失败。

5. iPhone 授权流 POC  
   验证首次启动 0 权限、默认录音只问麦克风、增强键盘后置授权。

6. 本地文本智能 POC  
   对比 Foundation Models、MLX Swift、llama.cpp 在纠错、润色、翻译上的延迟和质量。

7. 翻译质量 POC  
   验证 Apple Translation + glossary 后处理是否足够；不够再加本地 LLM。

8. 网络隔离 POC  
   默认模式下，强制所有网络请求失败，确认功能仍可用。

9. 记忆学习 POC  
   用户接受、拒绝、撤回修改后，热词权重是否正确变化。

## 18. 工程落地顺序

推荐先做 Mac，再做 iPhone。

原因：

- Mac 能实现完整系统级体验，更容易验证核心价值。
- Mac 插入、上下文、快捷键、模型推理都更开放。
- iPhone 的关键风险不是模型，而是系统入口。需要在 Mac 核心管线稳定后再做移动入口。

顺序：

1. 建 Swift workspace，抽出 `CorePipeline`。
2. 做 Mac 菜单栏 + 全局快捷键 + 录音。
3. 接一个本地 ASR 引擎。
4. 接 context/hotword SQLite。
5. 做纠错和基础润色。
6. 做翻译模式双语上屏。
7. 做插入回退。
8. 做 history/memory/settings。
9. 做 iPhone 主 App。
10. 做 iPhone 键盘 App Group 插入。
11. 做评测套件和 Typeless 对比。

## 19. 风险

| 风险 | 影响 | 处理 |
| --- | --- | --- |
| iOS 键盘不能录音 | iPhone 体验无法完全复制 Mac | 主 App 录音 + 键盘插入 + Shortcut |
| 本地 LLM 延迟高 | 润色慢 | 小模型、规则优先、低置信才审阅 |
| 模型冷启动 | 第一次输入很慢 | App 启动预热、设置切换预热、冷启动状态明确显示 |
| ASR 对中英混说不稳 | 核心体验差 | 多引擎 benchmark，热词前后处理 |
| iPhone 授权过重 | 首次体验流失 | 首次启动 0 弹窗，默认录音只问麦克风，键盘 Full Access 后置 |
| 过度纠错 | 用户不信任 | 结构化 edits、低置信审阅、拒绝学习 |
| 记忆污染 | 越用越差 | 来源记录、权重衰减、用户禁用 |
| 剪贴板插入破坏用户内容 | 体验差 | 保护和恢复剪贴板，失败时只复制不粘贴 |
| GPL / 非商业许可证污染 | 商业风险 | clean-room 实现，只做行为参考 |
| 模型包体过大 | iPhone 安装和更新困难 | 模型按需下载，分语言包 |

## 20. 第一版验收标准

Mac MVP：

- 按住快捷键录音，松开后在当前 App 上屏。
- 默认本地，无网络请求。
- 能用热词纠正至少 20 个用户术语。
- 能把中英混说整理成自然文本。
- 翻译模式默认双语上屏。
- 设置里能查看和禁用记忆。
- History 能查最近结果。
- 失败时能复制结果，不丢内容。

iPhone MVP：

- 主 App 本地录音和处理。
- 翻译模式显示并插入双语结果。
- 键盘能插入主 App 生成的最近结果。
- Shortcut 能触发录音或打开录音页。
- 默认不联网。
- 用户能清理所有本地数据。

## 21. 参考链接

- Typeless: https://www.typeless.com/
- TypeWhisper: https://github.com/TypeWhisper/typewhisper-mac
- Dictus: https://github.com/getdictus/dictus-ios
- OpenTypeless: https://github.com/tover0314-w/opentypeless
- OpenWhispr: https://github.com/OpenWhispr/openwhispr
- Apple Foundation Models: https://developer.apple.com/documentation/foundationmodels
- Apple Translation: https://developer.apple.com/documentation/translation
- Apple Speech: https://developer.apple.com/documentation/speech
- Apple InputMethodKit: https://developer.apple.com/documentation/inputmethodkit
- Apple Custom Keyboard Extension: https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html
