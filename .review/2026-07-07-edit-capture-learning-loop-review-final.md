# Deep Review 综合结论 — 上屏后编辑捕捉学习闭环

**VERDICT**: NEEDS_FIX → 已全部修复
**类型**：mixed（Swift + Python + 设计文档）

> 范围：edit-capture 分支相对 main 的 diff（`git diff ea3e999..b712f35`）
> Review engine：codex-cli 0.142.5（host: claude；engine_source: auto）
> Cursor：disabled（composer-2.5 smoke 失败）
> 维度：14 个 codex 并行（code 8 + design 6），全部 exit 0
> Phase 2：核心发现人工源码回证 + 实证（audio_ref 实测为 FALSE_POSITIVE）
> Repo: 0x5446/velora ; HeadSHA: b712f35（修复后另提一 commit）

14 维度共报约 40 条，去重配对后 11 类真问题（2 Critical / 8 Warning / 1 Suggestion），全部已修并有测试或实证覆盖。

## 已修复（🔴 Critical）

1. **学习总开关不覆盖旧日志入口 + 音频库**（7 维度共识）。`recordIfEdited/recordRetryRedictation/recordUndoAfterInsert` 及 `MacAudioClipVault.store` 绕过 `learningEnabled`。
   修复：`learningEnabled` guard 下沉到 `MacCorrectionJournal.append`（唯一 chokepoint，覆盖全部 5 类事件）；`audioRetentionEnabled` 改为 `learningEnabled && …`。

2. **recordInsertion 隐私检查漏传 subrole**（4 维度共识）。网页/自定义密码框靠 AX subrole 识别，但插入日志在观察器 veto 前就落盘且传 `elementSubrole: nil`。
   修复：新增 `MacLearningPrivacy.focusedBlockReason`，在释放时（目标框仍聚焦）算一次统一隐私裁决 `learnBlocked`，音频保管/日志/观察器共用；翻译模式经 `MacPendingTranslationReview.learnBlocked` 贯穿到确认时。

## 已修复（🟡 Warning）

3. 翻译目标侧编辑不再进热词表（只留 journal 供微调），杜绝跨语言污染 ASR 字面替换。
4. `build_hotword_fst.py` 无生效词时清理旧 `replace.fst`/`dict`（清理路径前置，不再依赖 hr-files 存在）。
5. 同 session 的 `post_insert_edit` 摄取"后到为准"（懒 diff 覆盖 live settle），避免临时编辑污染。
6. 锚点定位改为成对求解（按 gap 最接近 span 长度），修复前缀在 span 后重复导致选错。
7. `AXUIElementSetMessagingTimeout` 移到首次 AX 读取之前，防目标应用卡死拖住主线程。
8. SQLite 迁移用 `PRAGMA table_info` 检测列，真错误（磁盘/锁/损坏）抛出而非当"列已存在"吞掉。
9. `ingestCorrectionJournal` 加串行重入闸 + `busy_timeout`，防并发 Task 重复计数。
10. `prepare_polish_dataset.py` 拒绝写空/单行 train.jsonl；`run_qlora.sh` 用 `-s` 兜底。
11. 懒 diff 前复查隐私（30 分钟窗口内元素可能变密码框）；`harvestBeforeNextDictation` 取消未决 captureTask。

## Suggestion

- `run_qlora.sh` 补 `homophone_eval.py`（原漏一套门禁）；文档 `terminated_by`/`anchor_method` 枚举补全。

## 驳回（Phase 2 实证）

- **`audio_ref as Any` 序列化失败/崩溃**（6 维度静态共识）：实测当前 Foundation 下 `Optional<String>.none as Any` 被 JSONSerialization 正确输出为 `null`，未丢数据未崩溃。仍改为显式 `NSNull()` 加固（跨版本稳定），但严重度从 Critical 降为无。

## 未纳入本轮（记录）

- 观察器 health 事件（observability，增强项，用于两周校准，可后续补）。
- 词条按 language 完整 scope 化（extensibility，target 退出热词池后风险大幅缓解，多语言扩展时再做）。
- 观察窗参数策略对象化（extensibility，校准阶段再抽）。
- Mac 观察器状态机 UI 级测试（tests，需注入 AX 适配层；核心算法已有 25 条包级测试）。

验证：`swift test` 97/97 通过；`xcodebuild -scheme Velora` BUILD SUCCEEDED；脚本 guard 与 FST 清理均实测。
