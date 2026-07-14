# Deep Review 综合结论

**VERDICT**: NEEDS_FIX
**轮次**：1 / 3（--plan-only，不自动 fix）
**类型**：mixed（14 维度）

> 范围：未提交的 polish 优化改动（规则层口癖清理、inputSystem 口癖/分段规则与 few-shot、appFormatProfile、predictBudget、filler_eval 门禁、导出器、单测、文档），排除 Velora/Sources/Velora/AppleSpeechASREngine.swift（用户在途修改）
> Review engine：codex codex-cli 0.144.3（host: claude; engine_source: auto）
> Cursor：composer-2.5 smoke 失败，跳过
> 维度：14 个 codex 并行（correctness errors security concurrency data observability design tests completeness clarity feasibility consistency extensibility risk），全部成功
> Phase 2 验证：机械事实用可执行证据回证（真实正则复现、ollama 实测 prompt tokens），高共识高置信项按规则免回证
> Repo: /Users/alpha/workspace/velora
> HeadSHA: accab722e0af0f9a473f31c22b70dbb70e2b60b7（工作区含未提交改动）
> RunDir: /var/folders/00/s7tt4dgj53v123y8671yb3b00000gn/T/deep-review-velora-accab72-1784031388.F1uB
> 规模：222 insertions / 112 deletions / 13 文件

## 🔴🔴 顶级必修

### 1. [Warning×12维度] pocs/tuning/filler_eval.py:90-93
> **一句话**：新增的口癖评测失败时进程仍返回成功，门禁形同虚设。

- **Category**: Completeness/ErrorHandling
- **共识**: 12/14 维度独立命中，Confidence 0.92-1.0（免回证）
- **问题**: 脚本计算了 ok/fails 但末尾没有 `raise SystemExit(1)`，与其他五套门禁和文档承诺（"任一 case 失败即非零退出"）不符。
- **修复**: 末尾补 `if any(not r["ok"] for r in results): raise SystemExit(1)`。

### 2. [Warning×3维度] pocs/tuning/*-results.json（cand 溯源断链）
> **一句话**：仓库里的评测绿灯记录标着调参期候选名，无法证明测的就是线上提示词。

- **Category**: Consistency/VersionSkew/Observability
- **共识**: observability/design/consistency 三维度命中，Confidence 0.9（免回证）
- **问题**: 结果文件记录 `cand: final_v3`（手工提取期产物），导出器输出 `id: shipped`。最新 /tmp 结果已是 shipped，但没有回拷仓库。
- **修复**: 用官方导出器重跑六套门禁后统一回拷 `cand: shipped` 的结果文件。

### 3. [Warning×3维度，实证 CONFIRMED] Velora/Sources/Velora/TextComposition.swift:160-164 (strippedFillers)
> **一句话**：转述别人应答的「说嗯，好的」会被规则层删掉一个字，属于本次改动引入的确定性误删。

- **Category**: DataIntegrity
- **共识**: correctness/data/risk 三维度命中；本地真实正则复现确认：
  `他说嗯，好的→他说，好的`、`帮我回复嗯，好的→帮我回复，好的`、`他说嗯嗯，收到→他说，收到`（新回归）；`她嗯哼了一声→她哼了一声`、`嗯哼，可以→哼，可以`（存量误杀，一并修）。
- **修复**: 嗯 分支加报告动词 guard（说/回/答/复/道 后要求右侧粘汉字，恢复旧行为）+ 全部 嗯 分支加 `(?!哼)`；呃 保持宽松（`他说呃，先等等` 删掉引述的迟疑声属于可接受润色）。补 guard 单测。

## 🔴 新发现 Critical（deep-review 维度之外，E2E 后续实证发现）

### 4. [Critical] Velora/Sources/Velora/LocalModelEngines.swift（OllamaLocalClient keep_alive 编码）
> **一句话**：模型常驻开关一开，所有润色请求直接被本地模型服务拒绝，功能整体失效。

- **实证**: `keep_alive:"-1"`（字符串）→ ollama HTTP 400 `time: missing unit in duration "-1"`；数值 `-1` 正常。Swift 客户端 `keepAlive` 是 String，常驻模式发的就是 `"-1"`。
- **影响**: 常驻模式下每次 compose/prewarm 全部 400 → try? 吞错/降级规则层，且比冷启动问题更严重。存量 bug（本次改动之前就存在），今天向用户推荐开启后暴露。
- **修复**: `OllamaGenerateRequest` 对 keep_alive 做数值感知编码（纯数字字符串按 JSON number 编码），加单测；重建后实测 /api/ps 常驻生效。

## 🟡 单维度（已核实，按建议处理）

5. **[security] 真实听写句固化进公开仓库评测集**（filler_eval.py CASES，0.90）——两句来自 journal 的原句进了公开 repo，违反"听写文本不出本机"边界。修复：CASES 全部换成保留口癖形态的合成句（同时解决 #7 泄漏问题）。
6. **[security] 终端场景新增换行的提交风险**（appFormatProfile developer，0.82）——**接受的权衡，不修**：用户主场景是 iTerm 里的 AI CLI 输入框（多行粘贴安全，现代 shell 有 bracketed paste），列表输出本就带换行，分段正是本次需求。留档：若未来发现裸 shell 误提交，可加"源文本无换行则终端不新增换行"守卫。
7. **[tests] 评测集与 few-shot 撞句（数据泄漏）**（filler_eval CASES，0.86）——inline_nage/jiushi_hedge 与 few-shot 近同句，测的是复述不是泛化。修复：与 #5 一并换合成句。
8. **[design] few-shot 教删「这个需求」与规则 5 保留清单矛盾**（inputSystem，0.78）——修复：few-shot 输出改为保留「这个需求」，只删 hedge「就是」。
9. **[tests] para 断言过弱**（format_eval.py，0.9）——修复：按空行切段断言 ≥2 段且无列表标记。
10. **[consistency] 评测脚本硬编码旧 profile 文案**（filler_eval/format_eval 等，0.85）——修复：同步为 appFormatProfile 当前字符串。
11. **[extensibility] 导出器 num_predict 固定 400**（EditCaptureAnalysisTests，0.9）——修复：提到 1024（生产 input cap），避免长输出评测被假截断。
12. **[observability] 解析失败丢 ctx 压力线索**（composeWithLLM，0.86）——修复：throw reason 携带 runtimeWarnings。
13. **[clarity] inputSystem 旁注只列四套门禁**（0.92）——修复：改为指向 LEARNING_PIPELINE 的六套门禁清单。
14. **[tests] predictBudget 无边界单测**（Suggestion，0.82）——修复：补单测。

## ❌ 已驳回（实证 FALSE_POSITIVE / 降级）

- **[correctness/data/feasibility] predictBudget 提高后长输入可能挤爆 num_ctx**：实测最坏形态（system 2651 字符 + 8 组 sound_alike + 历史句例 + 400 字 nearby + 660 字正文）prompt_eval_count=2645，加满 1024 预算总计 3669，距 4096 仍有 427 token 余量。溢出主张不成立；输出命中 1024 cap 导致 JSON 截断只在退化性复读输出时出现（cap 多大都会发生），维持现状 + 补注释实测数据。

## 维度元信息

| 来源 | VERDICT | issues | exit |
|---|---|---|---|
| correctness | NEEDS_FIX | 3 | 0 |
| errors | NEEDS_FIX | 1 | 0 |
| security | NEEDS_FIX | 2 | 0 |
| concurrency | SAFE | 0 | 0 |
| data | NEEDS_FIX | 3 | 0 |
| observability | NEEDS_FIX | 3 | 0 |
| design | NEEDS_FIX | 3 | 0 |
| tests | NEEDS_FIX | 4 | 0 |
| completeness | NEEDS_FIX | 1 | 0 |
| clarity | NEEDS_FIX | 1 | 0 |
| feasibility | NEEDS_FIX | 2 | 0 |
| consistency | NEEDS_FIX | 3 | 0 |
| extensibility | NEEDS_FIX | 2 | 0 |
| risk | NEEDS_FIX | 2 | 0 |

## 原始报告

- 各维度：`$RUN_DIR/dim-{name}.md`；prompts：`dim-{name}.prompt.md`
- 实证回证：本报告内嵌（正则复现输出、ollama prompt_eval_count 实测、keep_alive 400 复现）

## 修复结果（同日执行，用户授权继续）

| # | 状态 | 验证 |
|---|---|---|
| 1 filler_eval 无失败退出 | ✅ 已修 | 补 `SystemExit(1)`，与其他五套一致 |
| 2 结果溯源断链 | ✅ 已修 | 官方导出器重跑六套，回拷结果全部 `cand: shipped` |
| 3 引述应答误删 | ✅ 已修 | 报告动词 guard + 嗯哼 豁免；7 个新 guard 单测全过 |
| 4 keep_alive "-1" 400 | ✅ 已修 | 数值感知编码 + 单测；实测 /api/ps expires_at=2318 年（永久钉住） |
| 5+7 评测集隐私/撞句 | ✅ 已修 | CASES 全部换合成句，注释明确禁止 journal 原文入库 |
| 6 终端换行提交风险 | 📋 接受权衡 | 主场景为 AI CLI 输入框 + bracketed paste；留档未来守卫方案 |
| 8 few-shot 教删「这个需求」 | ✅ 已修 | few-shot 输出保留「这个需求」，只删 hedge |
| 9 para 断言过弱 | ✅ 已修 | 按空行切段断言 ≥2 段 |
| 10 profile 文案漂移 | ✅ 已修 | filler/format/ambiguity/homophone/translate 五脚本同步为线上字符串 |
| 11 导出器 num_predict 400 | ✅ 已修 | 提到 1024（生产 input cap） |
| 12 解析失败丢 warning | ✅ 已修 | throw reason 携带 runtimeWarnings |
| 13 旁注只列四套 | ✅ 已修 | 指向 LEARNING_PIPELINE 六套门禁 |
| 14 predictBudget 无单测 | ✅ 已修 | 边界单测覆盖两模式 floor/growth/cap |
| ❌ num_ctx 溢出主张 | 📋 已驳回 | 实测最坏 2645+1024=3669，余量 427；数据写进 predictBudget 注释 |

修复后全量验证：swift test 121/121；六套门禁全绿（repair 14/14、format 15/15、homophone 10/10、ambiguity 11/11、translate_repair 8/8、filler 11/11，filler 复跑 3 次稳定）；app 重建后常驻模式实测生效。
