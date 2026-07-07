# 学习闭环：上屏后编辑捕捉 → 自动热词 → 微调数据

Velora 的差异化：**从用户修正中学习 + 全本地**。上屏后你手动修正的内容会被捕捉为两类信号——自动热词（越用越准）与微调训练数据（本机沉淀）。本文档是该子系统的实现说明；调研背景与竞品对照见当时的调研报告结论（Wispr Flow 公开描述了同一机制，但其编辑数据上云；Velora 全程不出设备）。

## 架构

```
上屏成功
  ├─ insertion 事件落盘（asr → polished → final 三元组）        MacCorrectionJournal
  ├─ 音频可选入库（默认关闭，2GB 环形配额）                     MacAudioClipVault
  └─ 武装观察器（仅针对刚插入的那个 AX 元素，≤60s）              MacPostInsertObserver
        ├─ AXObserver kAXValueChanged / 焦点变化 / 元素销毁
        ├─ 键盘全局监听 → 只置脏标记，绝不读键值
        └─ 1s 轮询兜底（只在脏时读值）
     结算（静默5s / 焦点切换* / 超时 / 下次听写）
        *焦点/应用切换只在插入段已被改动时才结算——上屏后紧跟的激活抖动
         或"切走看一眼再回来改"都不该终结观察（60s 上限仍兜底）
        ├─ 锚点定位插入段（VeloraSpanAnchor：前后文锚 + 模糊兜底）
        ├─ 字符级 diff + 三分类（VeloraEditAnalyzer）
        └─ post_insert_edit 事件落盘
下次听写开始
  ├─ harvest：结算存活观察 + 懒 diff 上一段（30 分钟内免费召回）
  └─ ingestCorrectionJournal → SQLite terms（候选池 → 晋升）
```

## 隐私契约（反键盘记录器设计，代码中硬性约束）

1. 观察只针对 **Velora 刚插入文本的那一个元素**，窗口 ≤60 秒；
2. 键盘监听**只产生布尔脏标记**，永不读取按键内容（同 undo watch 的既有纪律）；
3. 只 diff 并持久化**插入段本身**，插入段之外的任何文本永不提取；
4. 三层护栏一票否决（`MacLearningPrivacy`）：`IsSecureEventInputEnabled()` 全局暂停 → `AXSecureTextField` subrole 排除（覆盖原生+网页密码框）→ bundle id 黑名单（密码管理器/系统凭据面）。终端**刻意不拉黑**：它是对 CLI agent 听写的主场景，diff 只碰 Velora 自己插入的那段，sudo/ssh 的密码提示会开启 secure input，第 1 层已兜住；
5. 全部数据只写 `~/Library/Application Support/Velora/`（journal、memory.sqlite、clips/），与 History 同隐私层级；
6. 设置里"从我的修改中学习"总开关即时生效；词典逐条可停用/删除。

已知盲区（接受）：CSS 遮罩的伪密码框不带安全角色，无法识别（第 3 层部分兜底）；Google Docs 等 canvas 编辑器不覆盖；Electron 首版未做 `AXManualAccessibility` 懒激活（观察拿不到值时静默放弃）。

终端网格宿主（iTerm2 / Terminal 等）的特殊处理：终端把屏幕暴露为**逐行折行的字符网格**，跨行的插入段中间被塞进硬 `\n`，CJK 双宽字符行尾放不下时还会留**填充空格**（iTerm2 实测 200 列网格、174/975 行带行尾空格）。捕获时精确匹配落空会在**去硬换行空间**（剥掉换行及其前面的行尾填充）重试，命中则整个观察（基线、采样、diff）都在该空间运行；还不中就用 fuzzyLocate 模糊武装（用户可能在捕获重试窗内已开始编辑）。终端回车发送后输入行被清空、文本换位重排，结算时锚不到就回退到**最后一次能定位到 span 的轮询样本**（`anchor_method` 带 `+last_sample` 后缀）。

## 自动化 E2E 与 debug 桥（developer mode）

开发者模式下 Velora 监听两个分布式通知（`MacDebugBridge`，普通用户下完全惰性）：`app.velora.debug.dictate`（object 为 `wav路径` 或 `wav路径|目标pid`，把音频当作刚松开 fn 注入完整生产管线，含 harvest/ingest 前置）与 `app.velora.debug.probeFocused`（object 为 bundle id，用 Velora 自己的 AX 权限输出目标 app 聚焦元素的**结构统计**到 `debug-probe.json`，永不落盘屏幕内容）。观察器状态机的面包屑写在 `debug-observer.log`（只记原因/计数/session，不记文本）。

`scripts/e2e/run_edit_capture_e2e.sh`：Cartesia TTS → 注入 → 靶标窗口（`EditCaptureTarget.swift`，接收粘贴后程序化改自己的文本，模拟人工修正，无需任何 TCC 权限）→ 断言 journal 配对事件与 memory.sqlite 候选/晋升，三轮跑完自动清理合成词条。需要 `CARTESIA_API_KEY`，且启动 Velora 前 `defaults write app.velora.mac velora.developer_mode -bool true`。

## 数据 schema（corrections.jsonl 新增两种事件）

```jsonc
{"kind":"insertion","at":"…","session_id":"…","mode":"input","lang":"zh",
 "app_bundle":"com.apple.mail","asr_text":"…","polished_text":"…","final_text":"…",
 "llm_edits":[{"from":"…","to":"…","reason":"llm_compose"}],
 "audio_ref":null}                       // opt-in 时为 "clips/<session>.wav"

{"kind":"post_insert_edit","at":"…","session_id":"…","mode":"input","lang":"zh",
 "app_bundle":"…","inserted_text":"…","user_final_span":"…",
 "similarity":0.93,"is_rewrite":false,
 "edit_blocks":[{"type":"asr_fix|style|content|reverted_hotword",
                 "before":"超市","after":"超时","pinyin_distance":0}],
 "window_ms":38000,
 "terminated_by":"quiet|focus_change|app_switch|timeout|next_session|element_destroyed|element_unreadable",
 "anchor_method":"anchors|prefix_anchor_fuzzy|suffix_anchor_fuzzy|prefix_anchor_to_end|start_to_suffix_anchor|whole_field|fuzzy"}
 // 网格宿主结算时锚定失败、改用最后可定位样本时，anchor_method 带 "+last_sample" 后缀
```

`session_id` 关联两类事件凑齐 (asr, polished, user_final) 三元组。懒 diff 可能对同一 session 产生第二条 post_insert_edit（以后到的为准）。

## 编辑三分类（VeloraEditAnalyzer，全部确定性规则）

- **asr_fix**：块两侧 1–6 字、拼音近音（CFStringTransform 拉丁化 + 编辑距离预算 ≈ 长度/3）、通过 `VeloraLearnGate`（停用词表 / 无数字URL / 长度上限）→ 热词候选；
- **style**：非近音但整体相似度 ≥0.75，或 ITN 数字格式差异（白名单豁免，绝不进热词）→ 只作润色反馈；
- **content**：纯增删或整段改写（相似度 <0.75 时全体降级）→ 无监督信号；
- **reverted_hotword**：用户把我们的热词替换改了回去 → 最强负反馈，直通拒绝衰减通道。

## 热词晋升（SQLiteMemoryStore 候选池）

学到的词对先进候选池（`promoted=0`，不参与 rank）：**同一词对 ≥2 次且跨 ≥2 个 session** 才生效。既有反污染保留：拒绝衰减 0.8/次、三连拒自动禁用；新增：90 天未命中降回候选、生效学习词上限 200（低分先降）。手动/种子词不受候选池约束。

## 热词兑现三通道

1. **HomophoneReplacer（ASR 内解码后替换，首选）**：sherpa-onnx 官方对 SenseVoice 的热词答案（transducer 专属的 hotwords 不适用于 CTC）。`scripts/build_hotword_fst.py` 把生效词表编译成 `replace.fst`（pypinyin TONE3 + pynini），资产放 `Application Support/Velora/hr/{dict,lexicon.txt,replace.fst}`，sidecar 启动时自动加载（缺失/旧版 sherpa 自动降级）。注意 HR 同音必换、仅中文——所以只喂"生效"词，候选池绝不进入。
2. **HotwordCorrector**（ASR 后字面替换，既有）：与 HR 互补，覆盖拉丁词与字面命中。
3. **LLM glossary**：原仅翻译模式，现扩展到输入模式（`inputSystem` 规则 9），并加拼音域预筛——只注入本句发音里真实出现的词对，防大词表误纠。**提示词已变更：合并前需重跑三套 eval 门禁 `pocs/tuning/repair_eval.py`、`pocs/tuning/format_eval.py`、`pocs/tuning/homophone_eval.py`。**

> 注意作用域：只有源语言的 `asr_fix`（同音验证过的听写纠错）进入 `terms` 热词表，参与 HotwordCorrector 与 HR。翻译确认卡片的**译文侧编辑不进热词表**（只留在 journal 供微调），避免另一种语言的术语偏好污染 ASR 后的字面替换。

## 微调数据与本地 QLoRA

- 文本三元组默认落盘；**音频 opt-in**（设置 → 学习），16k mono WAV，2GB 环形配额，取消的翻译连同音频一起删除。不留音频只能微调润色 LLM；留音频才可能微调 ASR（后者暂不列规划）。
- `scripts/finetune/prepare_polish_dataset.py`：清洗（编辑比率 >0.25 弃、长度比 [0.5,2]、去重、~10% 零编辑正则化）→ mlx chat 格式。
- `scripts/finetune/run_qlora.sh`：mlx_lm.lora（QLoRA，`--mask-prompt`）→ fuse `--de-quantize` → llama.cpp GGUF → `ollama create velora-polish`。文献口径：100–500 对高质量数据可见效。产出必须过 `pocs/tuning/` eval 门禁再切换。

## 运维速查

- 学习开关 / 音频保留 / 词典管理：设置 → 学习。
- 数据位置：`~/Library/Application Support/Velora/{corrections.jsonl, memory.sqlite, clips/, hr/}`。
- 编译热词 FST：`python3 scripts/build_hotword_fst.py`（需 pypinyin + pynini + hr-files 资产），编译后重启 Velora。
- 观察窗参数（60s 窗口 / 5s 静默 / 30min 懒 diff）是初版拍板值，**上线先只看 journal 分布再调**（`terminated_by` 与 `anchor_method` 字段就是为此记录的）。
