# 语音输入后处理与个性化：行业调研及 Velora 落地方案

调研日期：2026-07-13

## 结论

同类产品与技术文献共同指向一条分层路径，而不是用一个通用 LLM prompt 同时承担识别纠错、口语清理、标点、格式化和个性化：

```text
audio
  -> ASR + ITN
  -> 受约束术语/同音候选纠错
  -> 确定性清理 + 专用标点/断句
  -> 按应用类别选择格式策略
  -> 可选 LLM 重排（复杂改口、列表、长段落）
  -> 实体/数字/语言/编辑幅度护栏
  -> insert

post-insert edits
  -> 术语记忆（高精度、需晋升）
  -> 格式偏好（低风险、按应用类别聚合）
  -> 训练语料（离线评测通过后才升级模型）
```

Velora 应保留 SenseVoice 的中文和中英混说优势，但不能把其缺少动态 contextual biasing 的问题全部交给自由生成式 LLM。短期使用拼音检索出来的候选和历史句例做受约束二次纠错；中期评测支持动态热词或 N-best/词图的中文 ASR。

## 同类产品

| 产品 | 公开实现/能力 | 对 Velora 的启示 |
|---|---|---|
| Typeless | 自动移除 filler、重复和改口，自动列表；按 App 改变 tone/style；支持个人词典；2025-12 起声明随使用学习正式/随意/简洁等风格 | 分开“格式偏好”和“内容改写”；应用类别是一级信号；用户应能关闭个性化 |
| Wispr Flow | Auto Edits + 自动个人词典；按 personal messaging/work messaging/email/other 四类显式选择 style；Personalized Style 明确只改大小写、标点和空格，不改语法、措辞或 phrasing | 个性化格式应是低风险、显式、按应用类别存储，不应用整段自由改写学习所有偏好 |
| Superwhisper | 两段式：speech recognition 后接可选 language model；predefined/custom modes 控制 tone、structure、formatting；可为不同任务选不同速度/能力模型 | ASR 与 rewrite 解耦；短句可以跳过 LLM；按任务路由模型和 prompt |
| Willow | 声称 context-aware formatting、style matching 和 auto-learning dictionary；按活动应用/工作流区分术语和格式 | 上下文应服务于候选缩小和格式路由，而不是把大量屏幕文本无约束地塞给模型 |
| VoiceInk（开源） | 生产管线为 transcribe -> filter -> deterministic paragraph formatting -> word replacement -> optional AI enhancement；短文本可跳过 enhancement；上下文分 selected/clipboard/screen text | 确定性地板必须独立于 LLM；上下文来源要分类型；Velora 为隐私应优先光标附近 AX 文本，不默认截图/OCR |
| Handy（开源） | macOS 使用非激活 NSPanel；隐藏动画触发后由独立延时路径调用原生 window hide | HUD 的最终消失必须由原生窗口生命周期保证，SwiftUI 动画只能是装饰 |
| Hex（开源） | 极简状态 HUD；格式化仅做显式 lowercase/remove-punctuation | 为追求稳定和延迟，可提供“原始/轻清理/智能格式”档位，而不是所有输入都走最重路径 |

## 技术证据

### 1. 术语与同音纠错应先做候选约束

- Google Cloud Speech Adaptation 使用 PhraseSet、CustomClass 和 boost，把罕见词、专名和噪声场景的候选偏置放在识别阶段。
- Deepgram Keyterm Prompting 把术语作为明确 keyterm，公开指标称重要术语召回率最高可提升到 90%；Flux 还支持动态更新。
- *ASR Error Correction using Large Language Models*（arXiv:2409.09554）指出自由生成在陌生领域会损害性能，并提出基于 N-best/ASR lattice 的 constrained decoding。
- *ASR-EC Benchmark*（arXiv:2412.03075）在中文数据上发现 prompting 并不有效，微调只对部分模型有效，多模态增强最有效。
- *Large Language Model Should Understand Pinyin for Chinese ASR Error Correction*（arXiv:2409.13262）表明拼音辅助优于纯文本纠错。

因此 Velora 的 correction history 应先用拼音召回，再用当前句上下文选择候选；模型输出应是局部 edit/choice，最终 patch 由代码应用。自由重写只能负责表达层。

### 2. 标点和 ITN 适合专用层

- NVIDIA NeMo 将标点/大小写建模为 BERT 上的 token-level 双分类任务，并把 WFST ITN 定义为 ASR 后处理的独立阶段。
- *A Small and Fast BERT for Chinese Medical Punctuation Restoration*（arXiv:2308.12568）用约 10% 模型尺寸达到大模型约 95% 的性能。
- *PersianPunc*（arXiv:2603.05314）报告轻量 BERT 标点模型 macro F1 91.33%，同时指出 LLM 会过度修改标点之外的内容且计算成本更高。
- *Teaching BERT to Wait*（arXiv:2205.00620）把流式口语不流畅检测建模为序列标注，并在准确率、延迟和稳定性之间动态选择 lookahead。

因此短句的标点、大小写、ITN、filler 与有限重复应走确定性或轻量序列标注路径。LLM 只在检测到复杂改口、明确枚举或多主题长段落时启用。

### 3. 个性化要拆成三条安全等级不同的路径

1. **词汇纠错**：用户修正专名/术语后进入候选池；至少跨两个 session 确认，支持拒绝衰减和禁用。
2. **格式偏好**：只学习标点密度、大小写、段落长度、列表倾向等可逆属性，并按应用类别聚合；提供显式 style 选择覆盖隐式学习。
3. **模型适配**：只使用通过清洗和人工/规则门禁的数据离线训练。生产 prompt、输入字段和 JSON 输出 schema 必须与训练完全一致。

个性化 ASR 研究也支持这一顺序：

- *Personalization of End-to-end Speech Recognition On Mobile Devices For Named Entities*（arXiv:1912.09251）中，仅让用户修正名字即可把专名召回从 2.4% 提升到 64.4%，并强调全流程可在设备上完成。
- *The Gift of Feedback*（arXiv:2310.00141）用用户修正学习新词和长尾词，同时专门处理灾难性遗忘。
- *Fast Contextual Adaptation with Neural Associative Memory*（arXiv:2110.02220）显示上下文记忆与设备端个性化组合优于传统 rescoring。

## Velora 当前差距与迁移

### P0：链路正确性

- prepared fast path 必须携带 correction examples，且 journal ingest 完成后再快照。
- 对已消费 journal 做一次幂等 correction-example backfill。
- 纯标点、空格和换行编辑必须作为 style signal 入 journal。
- 上下文改为光标附近窗口；不可用时取字段末尾，避免终端/长文档拿到最旧内容。
- 输入 polish 使用 ASR 检测语言，配置语言只作 fallback。
- HUD 到期直接隐藏原生 NSPanel；post-insert AX 读取后续移出 MainActor。

### P1：质量架构

- 将同音纠错输出从整段 polished 改成局部候选选择和结构化 edits。
- 增加实体、数字、URL、代码标识符和语言一致性护栏。
- 增加 app category：personal-chat、work-chat、email、document、developer、other。
- 对短句跳过通用 LLM；复杂改口、列表、多主题才路由到 LLM。
- 评测专用中文标点模型，并与 SenseVoice 自带 ITN 组合而非重复生成。

### P2：持续进化

- 增加 per-app-category style profile 和显式 UI 覆盖。
- 训练数据改成真实生产 schema，区分 compose input、ASR output、rule floor、model output、user final。
- 以用户最终编辑距离、实体/数字保留率、标点边界 F1、术语 precision/recall 和 p50/p95 为门禁；不能只看少量 contains/absent 用例。

## 本轮落地与验证

已完成：HUD 使用 presentation ID 防止旧延时任务误隐藏新状态，并在截止时间直接 `orderOut` 原生 NSPanel；journal ingest 与 prepared snapshot 串行；prepared fast path 携带 correction history；历史 journal 幂等回填句级纠错样本；标点/空格/换行编辑进入 style signal；上下文读取光标附近窗口；输入模式使用 ASR 检测语言；按 developer/work-chat/personal-chat/email/document/other 路由格式；增加 URL、数字、代码标识、术语、语言和过度改写护栏；journal 记录 compose engine、耗时、fallback、warning、context source 和 history hit count；微调数据使用生产 system prompt、app profile 输入及 JSON assistant schema。

生产提示词门禁（`qwen3:8b`，2026-07-13）：自纠错 14/14、格式 10/10、同音/热词约束 10/10、歧义防误杀 11/11、翻译自纠错 8/8。Swift Package 117 项测试通过，macOS App Debug 全量构建通过。本机历史回填仅检查计数，correction examples 从 1 条恢复到 4 条，未输出用户文本。

尚未在本轮假装完成：将所有同音纠错收敛为结构化局部 patch、专用中文标点模型、短句跳过 LLM 的路由、per-app style 统计学习，以及真实语料上的标点边界 F1 / p50 / p95 / 最终编辑距离长期指标。这些需要下一阶段真实数据评测，不能由当前小型 contains/absent 集替代。

## 验收指标

- 成功 HUD：到期后 500ms 内原生窗口不可见；切 tab/Space 不影响。
- feedback：新 correction example 下一次符合发音与语境的输入可命中；旧 journal 能幂等回填。
- 术语：纠错 precision >= 99%，在此前错误复现集上的 recall >= 80%。
- 保真：数字、URL、代码标识符、显式专名保留率 100%。
- 格式：标点/句界 F1 和列表决策分别评测；相对当前真实语料至少提升 20%。
- 体验：release-to-insert p50 <= 800ms、p95 <= 1.3s；LLM 超时不得把默认路径拖到 4s。
- 北极星质量：相对当前版本，用户最终编辑距离降低至少 30%。

## 主要来源

产品与开源实现：

- Typeless key features: https://www.typeless.com/help/quickstart/key-features
- Typeless personalization release: https://www.typeless.com/help/release-notes/macos/personalized-smarter
- Wispr Flow Personalized Style: https://wisprflow.ai/post/personalized-style
- Wispr Flow for Developers: https://wisprflow.ai/developers
- Superwhisper model architecture: https://superwhisper.com/models
- Willow product page: https://willowvoice.com/
- VoiceInk pipeline/context, inspected at commit `cf0c366906a52ba2b9950074ed2fd0270548c910`: https://github.com/Beingpax/VoiceInk
- Handy overlay, inspected at commit `ea10f7454e86f893581f5a380a15866476aa6423`: https://github.com/cjpais/Handy
- Hex HUD/formatting, inspected at commit `ca96427990249223cc31027d14c1f2c9ded57910`: https://github.com/kitlangton/Hex

厂商文档与论文：

- Google Cloud Speech adaptation: https://cloud.google.com/speech-to-text/docs/adaptation
- Deepgram Keyterm Prompting: https://developers.deepgram.com/docs/keyterm
- NVIDIA NeMo punctuation/capitalization: https://github.com/NVIDIA/NeMo/blob/stable/docs/source/nlp/punctuation_and_capitalization.rst
- NVIDIA NeMo text normalization/ITN: https://github.com/NVIDIA/NeMo/blob/stable/docs/source/nlp/text_normalization/wfst/wfst_text_normalization.rst
- ASR Error Correction using LLMs: https://arxiv.org/abs/2409.09554
- ASR-EC Benchmark: https://arxiv.org/abs/2412.03075
- Pinyin-enhanced Chinese ASR correction: https://arxiv.org/abs/2409.13262
- Teaching BERT to Wait: https://arxiv.org/abs/2205.00620
- Small and Fast BERT for Chinese punctuation: https://arxiv.org/abs/2308.12568
- Personalized named-entity ASR: https://arxiv.org/abs/1912.09251
- Learning from user corrections: https://arxiv.org/abs/2310.00141

说明：产品页描述属于厂商公开能力声明，不作为独立效果数据；论文结论优先用于架构决策。社区评论只用于识别体验风险（延迟、过度改写、上下文隐私），不作为定量证据。
