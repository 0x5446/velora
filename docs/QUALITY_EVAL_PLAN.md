# Velora质量评测计划

版本：2026-06-28

## 目标

效果问题不能靠手感判断。每次换 ASR、润色模型、翻译模型或 prompt，都必须跑同一组评测，记录：

- ASR：CER、WER、耗时、模型模式、音频时长、热词上下文。
- 纠错：热词是否命中，是否把错词留到译文里。
- 润色：实体是否保留，是否输出解释、标题或 `<think>`。
- 翻译：原文/译文双语渲染是否正确，实体和术语是否保留。
- 延迟：release 后关键路径耗时，尤其是 ASR 和本地 LLM。

## 当前脚本

```bash
scripts/quality_eval.sh
```

脚本会构建 `VeloraDiagnostics`，然后跑固定文本用例：

- `translate_bilingual_review_terms`：覆盖“拥护 -> 用户”“上评 -> 上屏”“终于门对照 -> 中英文对照”。
- `translate_entity_retention`：检查 `Alex`、`agenda` 这类实体和术语。
- `polish_keeps_entities`：检查润色不丢实体、不输出模型解释。

脚本默认会自动探测 Ollama。Ollama 可用时会同时跑本地 LLM 路径；不可用时只跑规则/Stub 逻辑路径，并在结果里标记本地模型跳过原因。

输出位置：

```text
pocs/out/quality-eval/<timestamp>/
```

包括：

- `summary.json`
- `results.jsonl`

## ASR 音频评测

单条音频：

```bash
VELORA_TEST_AUDIO=/path/to/audio.wav \
VELORA_ASR_REFERENCE="reference transcript" \
VELORA_ASR_SOURCE=en \
scripts/quality_eval.sh
```

多条音频用 JSONL manifest：

```jsonl
{"id":"zh_product_terms_01","audio":"/path/to/01.wav","reference":"展示给用户确认之后再上屏，中英文对照就是这个价值","source":"zh","context":"用户,上屏,中英文对照","max_cer":0.18}
{"id":"en_mixed_terms_01","audio":"/path/to/02.wav","reference":"I have a meeting with Alex tomorrow at 10 a.m. Please confirm the agenda.","source":"en","context":"Alex,agenda","max_wer":0.22}
```

运行：

```bash
VELORA_ASR_AUDIO_MANIFEST=/path/to/asr_cases.jsonl \
VELORA_ASR_MODES="fast accurate fallback" \
scripts/quality_eval.sh
```

## 默认阈值

| 模块 | 当前阈值 | 说明 |
| --- | ---: | --- |
| 文本逻辑路径 | 1.5s | 不应碰本地 LLM，主要验证产品逻辑。 |
| 本地 LLM 翻译/润色 | 12-15s | 先记录真实基线，后续要压到更低。 |
| ASR CER | 0.35 | 没有领域音频集前先用宽阈值。 |
| ASR WER | 0.45 | 英文和中英混说先以对比趋势为主。 |

## 下一步评测集

先录 20 条中文、中英混说、英文短句，每条 5-15 秒：

- 5 条产品术语：用户、上屏、中英文对照、确认、翻译模式。
- 5 条会议/工作：Alex、agenda、PRD、roadmap、review。
- 5 条自然聊天：口语、停顿、重复、改口。
- 5 条翻译：中文说话，输出英文，同时保留原文供确认。

每条音频都写 reference。之后每次换模型只比较同一套 manifest。
