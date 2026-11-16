> 最新状态：本轮已完成真实1.7B验证与计时，请先看 REAL_RESULTS.md。以下保留前阶段审计，原“未GPU执行”状态已被更新。

# Mac 论文式历史草稿：已验证与未验证

## 状态
- 研究 checkout `143a5f52ce380b00a4dda43c3e105d6bc0ace131`；mlx **0.32.4**，mlx-lm **0.32.2**。
- **没有加载模型、没有 GPU 计时、没有停止或更改质量评测**。只写本目录。所有语料是本任务自造的合成字符串，没有读私人听写内容。
- `cpu-tests.log`：**11/11 unittest PASS**，包含固定 seed **2000** 组性质检查，边界子测试另计。
- `tokenizer-tests.log` / `tokenizer-checks.json`：现存真实 1.7B tokenizer 的 CPU 检查通过，不是模型推理。
- `guard-test.log`：质量总控 PID64521 尚存时，GPU runner 在 import MLX **之前拒绝运行**。
- 真实 1.7B 验证脚本已完成语法、help 和保护开关检查；**尚未经过模型运行验证**。真实输出等价性、速度和 T4 均未验证，M0 不因此通过。

## 1. 不是必须从零开发，研究仓库已经有本机实现
绝对路径统一前缀 `/Users/alpha/workspace/speculative-dictation/`。
- `paper/main.tex:95–118`：端点触发全文重生成、只在被取代时取消；上一版已完成输出只作 draft，**不进入 prompt**。论文118行“aligned with full output”是概述，真实 proposer 会在偏离后用尾部重新定位，不能将它误读为固定位置只比前缀。
- `paper/main.tex:124–142`：论文主栈为 vLLM0.18/FP8/A10G、greedy0、16 speculative tokens；全局 suffix tree 关闭，但本请求 prompt/output suffix lookup 仍可能存在。
- `paper/main.tex:75`：T4=松键R到最后字符实际交付；不是生成用时。
- `experiments/vllm_draft/draft_proposer.py:29–53,55–84`：按请求 draft 文本 `encode(add_special_tokens=False)`；`_align` 用8/4/2/1 token尾巴定位，然后由 vLLM 原生 verifier 精确校验。不匹配时可退 suffix proposer。`nospec` 会明确清空提案。
- `experiments/vllm_ssbd/draft_proposer.py:78–101,103–127`：另一个有 SSBD 有损分支；本任务**不使用 ssbd_beta**、不修改 logits 来“多接受”。
- **`pipeline/local_polish.py:22–35,38–114` 的 `LocalPolisher` 已是 MLX 本机历史草稿版本**：token-LCP跨请求KV复用、当前token+K草稿并行验证、接受前缀、拒绝回退、bonus、自适应窗口4→128。不是 `draft_model`，不需要另加载模型。
- 但 `git grep local_polish` 在其他已追踪文件中没有命中；`pipeline/pipeline.py:492–512` 仍是HTTP/vLLM调用。因此不能声称现有端到端评测已经接上 LocalPolisher。
- `experiments/verify_cost_mlx.py:27–44` 只是随机 token forward+trim 微基准；无接受/拒绝、EOS、真实历史输出，不是完整 decoder，也不证明长输入听写收益。

## 2. MLX接口核实（安装源码，不凭在线最新版推测）
完整库前缀：`experiments/streaming_asr/.venv/lib/python3.12/site-packages/mlx_lm/`。
- `generate.py:485–528,534–546,601–628` 的 `speculative_generate_step` 接收真实 `draft_model`，会建它的cache、调用它forward逐token生成草稿；公开签名**没有固定 token 列表或 per-request proposer 参数**。
- `generate.py:667–731` 的 `stream_generate` 有 `draft_model`，没有独立的 fixed-draft 参数；不能把这当成历史token草稿接口已解决，也不应为此再加载小模型。
- 更底层现成接口足够：`models/qwen3.py:183–194` `model(inputs, cache=...)` 可一次取得整块 logits；`models/cache.py:15–40,115–138,339–394` 的 `make_prompt_cache` / `can_trim_prompt_cache` / `KVCache.trim` 支持普通全注意力 cache 回退。
- 现存1.7B config 为 Qwen3ForCausalLM、28层、bf16、max_position_embeddings40960；纯注意力路径在源码上适用，仍需真实加载后校验每层是 plain KVCache 且 offset 一致。**本原型拒绝旋转/不可回滚/线性注意力cache**，不静默降级。
- `tokenizer_utils.py:391–404` 的 wrapper 显式 `return_dict=False`。原型 tokenizer CPU检查最初没设置，得到 BatchEncoding 长度2，已纠正并重跑；现在断言必须是整数token列表。没有将那次无效长度结论用于报告。

## 3. 正确性契约与实证
1. **历史输出**：按原vLLM路径把上次完整输出文本重新encode，无 special tokens；不是原封不动拿不同tokenizer的ID，也不拼进prompt。直接复用同tokenizer原始ID可做未来独立消融，当前不偷换协议。
2. **prompt 更新与KV**：每轮重新序列化完整chat prompt，逐token LCP，裁掉分歧后全部KV（包括旧输出），只保留 `min(LCP,len(prompt)-1)`，至少重算末token得到首个输出预测。文本 append-only 不代表 token append-only，BPE合并及关闭标签/assistant后缀都会破坏简单追加。
3. **实测tokenizer**：6对合成相邻文本均不能将旧完整prompt直接当新prompt前缀。例 `hello→hello world` prompt长度2668→2669，LCP2654；`inter→international` prompt长度2668→2668，LCP2653。中文、英文和accent均覆盖。`encode(a)+encode(b)` 至少4例不同于 `encode(a+b)`。
4. **Unicode**：CPU fake使用UTF8 byte tokens测试中文、组合音标、family emoji、非BMP边界；真实tokenizer合成稀有Unicode中，5个partial-token截断的 `decode→encode` 不等于原token前缀且有末尾替换符。不得以未完成UTF8输出作为“已完成草稿”。这些是人工边界检查，不是自然语料出错率。
5. **因果偏移**：cache内已经有prompt与既往已输入的output，`y`是尚未入cache的正确token。forward `[y]+proposal`：`preds[j]`预测proposal[j]；只接受首个拒绝前的连续相等token；拒绝点下一轮输出**目标模型的preds[a]**；全对则 `preds[K]`是bonus，不能漏掉或重复。
6. **回退**：forward前cache长base，采用a个草稿后仅留 `base+1+a`，不保留错误草稿之后的KV；普通停止时最后pending token可不在cache，后续LCP按真实cached token序列算。
7. **EOS与上限**：对每个accepted token检查EOS，EOS不返回给用户；proposal裁到剩余max_tokens；max_tokens0/1、长draft短输出、context overflow显式覆盖，不把cap后的bonus算进输出。
8. **取消/失败**：单请求串行。块前后及prefill前后检查cancel；任何异常（包括部分layer forward失败）直接废弃本请求cache，禁止猜offset重用。最大取消响应粒度仍是一块forward，不能承诺立即打断Metal kernel。取消请求不得发布draft或提交旧generation；UI提交序号/调度尚未实现。
9. **失效身份**：权重、tokenizer、模板、精度、RoPE/位置或cache布局更换必须改变cache_key并clear；system文本变更也会影响LCP，主动版本失效更明确。不能跨不同模型/会话共享私有draft。

### 已复现的研究实现边界问题（不改原文件）
`test_cpu.py` AST加载真实 `LocalPolisher` 类，用CPU fake覆盖forward/cache。
- max_tokens=2且草稿全对时，原代码实际返回 **5** token：`local_polish.py:96–105` 没有按剩余budget裁块。
- 人工在draft token中注入EOS，原代码会把EOS当普通accepted token输出；`105`整段extend不检查EOS。此为边界回归，**不声称普通自然草稿会含EOS**。
- 原代码只在循环开头查cancel，异常没有cache整体作废；模型身份失效也未显式建模。
隔离 `draft_core.py` 补齐以上边界，保留研究原始align函数；11项测试全通过。假模型是确定性、全历史依赖的因果oracle，错误草稿路径会走不同分支，能发现错位/漏回退，不是简单固定输出比对。

## 4. “数学精确”不等于GPU输出已经逐token相等
`results/paper/equivalence.md:23–54` 已明确报告vLLM FP8批形状/近似平票差异，同prompt ours/ref也非全相同（polish53/60），不应重复其“输出必然逐字相同”的口号。
CPU测试证明本原型在相同确定性因果next-token函数下的算法等价性。MLX BF16多token验证与单token解码可能采用不同kernel/浮点归约；真实1.7B必须独立逐token对比两次官方无draft reference、隔离无draft、隔离历史draft。真实分歧记录首个token index并停止速度结论；若reference自身重复不一致也停止。近似平票的logits margin需要另行同状态探针，尚未准备数值结论。

## 5. 长输入何时快/慢（未测，不编速度）
设当前上下文L、核对k个草稿代价V(L,k+1)、平均接受a个、普通单步代价D(L)，一块大约替代a+1次普通解码。仅当 `V(L,k+1)/(a+1) < D(L)` 且节省超过重tokenize、对齐/回退、额外提前轮次与取消工作时才可能有收益。
- 高接受率、长剩余输出、大片历史输出未变：块验证摊薄权重读取/launch，可能快。
- 开头跨句改口、低接受率、输出很短/快EOS、窗口过大：做了很多注定丢弃的forward，可能慢。
- 长输入一方面提高可复用KV前缀的价值，另一方面每个验证位置都需看长上下文，attention读带宽/临时logits/统一内存压力增大；长草稿≠高接受率，不能从旧4B随机token verify_cost微基准推出1.7B收益。
- 每轮更新prompt造成的prefill减少，与draft减少decode是两种收益，必须以同调度同缓存的early_nodraft隔离。相同prompt反复命中只能作控制，不能当长输入任务证据。
- 先测固定k=4/16/64/128和自适应4→128，不照搬4B的KMAX就称最优。记录真实剩余reference输出长度与budget截断。

## 6. 真实验证准备范围
`run_real_mlx.py` 已准备；guard/语法/help通过，**未GPU执行**。
- 唯一模型：现存 `mac-eval-20261116-180318/models/qwen3-1_7b-xcorr-v53`，不下载、不加4B。
- prompt为冻结polish_v3.3.txt，SHA256 `d7e55c158e10bcd7b4ae8d8c373ccc74ed6388cc701330319f01ab89c93f358b`；greedy0、enable_thinking=False、max_tokens1024、tokenizer EOS，无额外sampling/stop。
- 三条件：endonly_system_warm（最后一次无草稿）、early_nodraft（同端点提前重写无草稿）、early_history_draft（同端点+上次已完成输出）。每组cache隔离、system前缀预热相同，最终prompt完全相同，不加nonce。
- 两个**合成**相邻端点含全文追加和末尾回改前文的内容；并非实际ASR端点，且前一轮总先跑完，所以不模拟真实赶不上端点/被取消的分布。长短用重复单元构造，记录真实token数，不把重复次数叫token长度。
- 同一组输入先跑两次官方generate_step独立无draft reference；不同则失败停止。各条件输出逐token比对reference，有分歧停止；只在正确性过关后讨论计时。
- 同长度/同窗口各条件warmup丢弃；正式模式用预生成随机排列（默认3次，正式建议6次覆盖全部顺序），GPU前后sync。记录prefill/verify/generate/trim时间、真实上下文、cache reused、proposal/accepted、块长、剩余reference输出、全局峰值内存与总请求完成时间。
- 每forward同步的诊断微基准含采集开销，不等于产品最优pipeline吞吐；全局peak_memory也是进程历史最大值，不冒充单次增量峰值。
- **没有复刻vLLM own-prompt/output suffix fallback**；本机endonly条件不是论文强基线B3。仅测历史草稿效应，不能据此宣布论文完整复现。
- 不运行新judge；本任务是算法/时延微基准，不改变正在进行的质量评测。

## 7. 下一关：真正的松键T4
GPU微基准通过后，复用原 `pipeline/record_asr.py` 已冻结的公有音频endpoint脚本，或新录同一公有音频的真实相邻endpoint：以绝对单调时钟回放，所有三条件分别串行跑同一时间轴；保留supersede-only取消、ASR收尾1.5秒padding与实际release R（原论文speech end+350ms）、最后交付事件时间；相同输入未变时不无谓再生成。
- 只在上一轮完成且generation序号仍有效时更新draft；新端点取消上一轮时清KV或保留已证明有效的prompt前缀；旧generation不得覆盖当前draft/输出。
- 真实输入法/文本sink记录最后一字符真正写入时间，`T4=delivery_last-R`；若只到decoder return，只能报告compute-completion微基准，不填T4。当前runner固定T4=null。
- 此端到端MLX调度/交付适配尚未实现，不修改Velora；继续受M0/M1 gate约束。
