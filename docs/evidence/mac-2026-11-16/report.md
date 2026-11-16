# Mac 证据入库说明

日期：2026-11-16。这是证据摘要的归档，不是产品通过，也不是源代码审查。

本环境没有访问 `/Users/alpha/specdict/` 或 `/Users/alpha/workspace/`。下面两份文件是用户附上的摘要，原样入库：

| 文件 | sha256 | 字节 |
|---|---|---|
| `draft-microbench.md` | `a99bdee8dfa79fa62d4060c712636a18a14506f5c053c28cd726da14d1ec4ebe` | 7091 |
| `quality-summary.json` | `8de51163cdc5d640f4724edc78bc086500a266221f1c314b6e9b4a7e4f9bf88c` | 21695 |

原始 jsonl、`run_real_mlx.py`、`FINDINGS.md` 和权重不在本仓库。不能把摘要里的毫秒数写成 Velora 的 T4。

## 质量摘要在说什么

`quality-summary.json` 的 `complete` 为 true，`blocked` 为空。列出的每个文件 `n` 等于 `expected`。七个集合的窗口数是 realx 140、testid 570、gentest 397、xcorr 40、xgpt 17、xdev 40、AASR 100，合计 **1304**。用户口头说的 1314 与这个合计不一致；以 JSON 为准，不把差额补成通过。

主裁判是 DeepSeek V4.1 Flash。gentest 里 source=deepseek 的 130 段改用 Kimi 做主裁判，并有 Gemini 3.8 Flash 复核。第二裁判是 Kimi。Gemini 只覆盖这 130 段，不是七个集合的第三遍全量裁判。JSON 写明 `stamp_rows` 没跑，行上没有 fingerprint。

绝对通过率（主裁判，检查项，不是窗口全对率）：

| 集合 | 检查项通过率 | 95% 区间 | 窗口全对 |
|---|---|---|---|
| realx v2 | 0.860（836 项，115 个会话） | 0.835–0.884 | 68/140 |
| testid v5 | 0.924（3141 项） | 0.912–0.935 | 398/570 |
| gentest v5 | 0.855（2008 项） | 0.836–0.873 | 214/397 |
| 改口池 xcorr+xgpt+xdev | 0.825（97 条） | 0.742–0.897 | 32/40、12/17、36/40 |

DS 与 Kimi 的一致率：realx 0.990（κ 0.961），testid 0.994（κ 0.958），gentest 非 deepseek 部分 0.978（κ 0.920）。deepseek 来源与 Gemini 的重叠一致率 0.975（κ 0.873）。这些是裁判一致，不是质量门槛通过。

JSON 明确列出未判断的原门槛：相对 v4.1、相对底座 4B 的显著性，以及 e2e60。用户要求这次不跑 4B，所以这些比较保持 **not judged**。不另设一个更低的绝对通过率来代替它们。

AASR 主裁判 content 0.886、format 0.601、filter 0.420、rephrase 0.748。filter 这一维不高。这是 `polish_v3.3` 上的研究 rubric，不是 Velora 六套门禁。

## 草稿微基准在说什么

`draft-microbench.md` 写的是只加载 Qwen3-1.7B v5.3、MLX bf16、没有 4B、没有额外 draft 模型。正式 v2 合计 45/45 输出与无 draft 的贪心逐 token 相同。样本是 6 个合成 prompt 的重复，不是 45 条自然听写。

最终请求中位数（不是 T4）：

| prompt/output tokens | 仅松键后 | 提前、无 draft | 提前、历史 draft | 接受/提议 |
|---|---:|---:|---:|---|
| 2735/68 | 1243.8 ms | 1194.3 ms | 635.6 ms | 49/139 = 35.3% |
| 3099/442 | 7956.6 ms | 7612.7 ms | 5017.2 ms | 289/1151 = 25.1% |
| 9853/1024 | 29958.8 ms | 22044.9 ms | 6290.8 ms | 920/936 = 98.3% |

第三行是 512 个重复单元，输出顶到 1024 上限。文档自己写明不能当成自然长听写的收益。前两行的提前总计算高于只在结束时算一次。组件中位数不必加总等于总时间。摘要把 T4 标成 null。5017 ms 是 442 token 合成请求的完成时间，不是松键到上屏。

核对窗口固定 16。n=3，没有置信区间。第一次被 cache 身份清空的 “warm” 标签已作废，不用于比较。

## 不成立的推论

- 不证明 Velora 产品合格，也不证明 M0、M1、M2 或 M5 通过。
- 不证明 SenseVoice 累计重识别等于这篇论文的端点调度。
- 不证明 mlx-lm 的 `draft_model` 参数能表达“上一轮目标输出”这种固定草稿。研究仓库里做这件事的是 `pipeline/local_polish.py` 的 `LocalPolisher`。
- 不把 1.88 倍、1.52 倍或 3.49 倍写成产品加速比。
