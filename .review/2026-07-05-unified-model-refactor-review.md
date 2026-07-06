# Deep Review 综合结论

**VERDICT**: NEEDS_FIX
**轮次**：1 / 3
**类型**：mixed（code + design docs）

> 范围：统一模型重构（两模式 input/translate、compose 单次调用、翻译引擎降级为兜底、deadline 降级链、network guard、Mac 插入目标保护）+ docs/ 三份设计文档一致性
> Review engine：codex-cli 0.142.5（host: claude; engine_source: auto）
> Cursor：unavailable, skipped (composer-2.5 smoke failed)
> 维度：14 个 codex 并行（correctness/errors/security/concurrency/data/observability/design/tests + completeness/clarity/feasibility/consistency/extensibility/risk），全部完成
> Phase 2 验证：3 条 Critical 簇已派（VERIFIED 3 / FALSE_POSITIVE 0 / UNVERIFIABLE 0）；高共识且 Confidence ≥ 0.9 的非 Critical 项按规则免回证
> Repo: /Users/alpha/workspace/velora
> HeadSHA: 370d8a928fdc71abbd444b2d4b8f75dd281620bb
> RunDir: /var/folders/00/s7tt4dgj53v123y8671yb3b00000gn/T/deep-review-velora-370d8a9-1783184220.YOPS
> 规模：+760/-457 行 / 20 文件
> --plan-only：本报告不含自动修复；修复由主流程单独执行

## 🔴🔴 顶级必修

### 1. [Critical] Apps/VeloraMac/MacSystemInputController.swift:957-962 (MacPasteboardInserter.insert)
> **一句话**：目标应用无法唤回时，语音结果仍会粘进当前前台应用，私密文本可能错投递。

- **来源**: correctness(0.95) + errors(0.86) + security(0.90) + feasibility(0.90)，4 维度命中
- **问题**: `target` 非空但 `activateBeforeInsertion()` 失败时没有 guard/return，`postCommandV()` 无条件执行（fail-open）。目标 App 退出、激活被拒、用户已切走时文本粘错地方。
- **修复**: 有 target 时改 fail-closed：激活失败不发 Cmd+V，返回明确失败态（文本留在剪贴板）；激活后二次校验 frontmost pid == target.pid 再粘贴。
- **回证**: VERIFIED @ 908-993 —— if 块只控制等待，粘贴无条件。

### 2. [Critical] Velora/Sources/Velora/PipelineOrchestrator.swift:164-193 (translation fallback)
> **一句话**：本地模型不可用时，翻译兜底会再等最长十几秒然后让整次录音直接报错，用户拿不到已有结果。

- **来源**: errors(0.90) + correctness(0.88) + completeness(0.92) + feasibility(0.90) + risk(0.94)，5 维度命中
- **问题**: 兜底 `translationEngine.translate` 无 deadline、无 catch；`OllamaTranslationEngine` 忽略 `deadlineMS`，单次 12s 超时且语言重试翻倍；Mac 默认主引擎和兜底是同一个 Ollama——主引擎挂了兜底必挂，错误上抛吞掉规则润色结果。
- **修复**: 兜底加 DeadlineRunner + do/catch 降级（保留 polished 原文、warning、reviewRequired）；`OllamaTranslationEngine` 消费 `deadlineMS`；兜底输出改结构化 JSON。
- **回证**: VERIFIED。

### 3. [Warning→合同级] Velora/Sources/Velora/PipelineOrchestrator.swift:220 (finalText)
> **一句话**：翻译模式默认承诺双语上屏，实际默认只插入中文原文，译文被丢掉。

- **来源**: correctness(0.93) + data(0.95)，2 维度命中
- **问题**: `.bilingual` 策略已渲染双语 insertText，但 `finalText = rendered.insertText(preferredLanguage: "zh")` 覆盖为单边原文。Mac 直插、CLI、键盘桥全部吃 finalText。"默认双语上屏"是产品差异点，此处直接违约。
- **修复**: `finalText = rendered.insertText`（策略驱动）；`preferredInsertLanguage` 只用于审阅面板的单边选择。
- **回证**: VERIFIED。

## 🔴 高置信必修（高共识 ≥0.9 免回证）

4. **wall_ms/trace 漏掉真实插入耗时**（observability 0.95 + design 0.95 + completeness 0.94）：Mac 主路径 `insertionStrategy: .none` 后在 pipeline 外插入，`elapsedMS` 在插入前计算，`insert_text` stage 消失。release-to-insert 系统性低估，恰好漏掉本次新增的目标 App 保护成本。修复：插入后计时并计入展示与诊断。
5. **composeWithLLM 缺 polished 时绕过规则地板**（design 0.87 + correctness 0.90）：`payload.polished` 缺失/被判翻译时回填 `request.text`（未清理原文），外层 `isEmpty` 检查永不触发。修复：缺失时返回空串让外层落回 baseline。
6. **文档新旧语言混用**（design 0.98 + clarity 0.93 + consistency 0.96/0.95/0.92 + completeness 0.90）：§6.3 模式分段仍是 Dictate/Polish/Translate；§7 架构图仍是 correction/polish/MT 三段；§11.2 表仍写 Apple Translation 是默认翻译引擎（与 §12.1 反转决策自相矛盾）；§11.3 结构化字段是旧合同；MVP_PLAN Phase 1-3 残留 speculative correction/CorrectionEngine/三模式且 trace 状态写反；network guard 各文档口径不一（强制 vs 可覆盖）。

## 🟡 中置信 / 单维度

7. **LocalProcess 不可取消**（concurrency 0.92）：Esc 取消后 whisper-cli/afconvert 继续跑完，与下一次录音争资源。
8. **pipelineTask/recordingStartTask 旧任务收尾覆盖新任务**（concurrency 0.88）：需 generation 守卫。
9. **CancellationError 被包装成模型错误**（concurrency 0.82）：取消时可能弹"处理失败"。
10. **审阅面板与键盘桥不携带 warnings/reviewRequired**（observability 0.88 + data 0.90 + extensibility 0.84）：低置信翻译在键盘路径可被直接插入，破坏审阅契约。
11. **dominantLanguage 只认 zh/en/ja/ko**（extensibility 0.92 + risk 0.82）：法/德/西语对会被误判或漏判，审阅守卫失效。修复：不支持的语言对标 `language_pair_unverified` + reviewRequired。
12. **nearby_context 注入 prompt 指令区**（security 0.88）：提示注入面。缓解：prompt 数据区声明 + 后续结构化注入。
13. **输入模式无 polished 语言校验**（data 0.78）：模型跑偏输出他语时直接上屏。
14. **HotwordCorrector 无阈值无门控**（feasibility 0.80）：中文同音替换静默错改。→ 与 Phase 2 记忆系统（权重/负反馈）合并处理，暂缓。
15. **测试缺口**（tests 0.82-0.93）：compose 直出 target 主路径、deadline 降级、LocalProcess 大输出、Mac 插入边界均无测试。

## ⚠️ 冲突项

无。

## ❌ 已驳回

无（本轮回证 3/3 VERIFIED）。

## 已知偏差（有意决策，不计为缺陷）

- compose deadline 开发期 4s/6s vs 生产目标 250/500ms（design/consistency/risk 多维度提出）：已在三份文档显式记录为开发期取舍（whisper CLI + Ollama 形态下 250ms 意味着 LLM 永远不参与）；换常驻模型后收紧。遗留动作：deadline 应做成显式可配置，预算测试与运行时口径对齐。

## 维度元信息

| 来源 | VERDICT | issues | exit |
|---|---|---|---|
| correctness | NEEDS_FIX | 4 | 0 |
| errors | NEEDS_FIX | 2 | 0 |
| security | NEEDS_FIX | 2 | 0 |
| concurrency | NEEDS_FIX | 3 | 0 |
| data | NEEDS_FIX | 3 | 0 |
| observability | NEEDS_FIX | 2 | 0 |
| design | NEEDS_FIX | 5 | 0 |
| tests | NEEDS_FIX | 4 | 0 |
| completeness | NEEDS_FIX | 3 | 0 |
| clarity | NEEDS_FIX | 1 | 0 |
| feasibility | NEEDS_FIX | 4 | 0 |
| consistency | NEEDS_FIX | 5 | 0 |
| extensibility | NEEDS_FIX | 3 | 0 |
| risk | NEEDS_FIX | 3 | 0 |
| cursor-holistic | unavailable | — | — |

## 原始报告

- 各维度：`$RUN_DIR/dim-{name}.md`；回证：`$RUN_DIR/verify-{A,B,C}.md`；manifest：`$RUN_DIR/run.json`
