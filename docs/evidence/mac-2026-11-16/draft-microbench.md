# REAL RESULTS — 真实1.7B GPU验证（本轮）

## 已完成
- 仅加载现有微调 Qwen3-1.7B v5.3，MLX BF16，未加载4B/额外draft模型。
- 原冻结polish_v3.3、enable_thinking=False、greedy temperature0、max_tokens1024、tokenizer EOS不变。
- 真实smoke成功；纠正runner初次外部预填KV身份初始化问题后，正式v2完成：**30/30输出逐token与官方无draft reference相同**。是4个独立合成prompt（2长度×2相邻端点）的重复，不是30条独立自然样本；每个官方reference另重复两次也一致。
- verifier只做因果对齐后的logits argmax并比较draft token ID，**没有softmax/人为抬高draft概率**。官方reference接口为了返回logprobs内部计算logsumexp，但不参与下面的性能比较。
- 当前12项CPU测试PASS，含2000随机性质case及新cache-seed回归。

## 已完成三条件计时（固定核对窗口16，warmup1，正式重复3次）
同一模型、同一最终prompt，条件隔离cache但均预热同一系统前缀。提前两条件的最终请求复用KV数量完全相同，draft来自上轮已完成的目标1.7B输出，文本重新tokenize。不加nonce，不改生成参数。

|实际prompt/output tokens|条件|最终请求中位数ms|prefill ms|verify ms|普通generate ms|接受/提议|
|---|---|---:|---:|---:|---:|---:|
|2735/68|end-only，系统前缀warm|1243.8|93.0|0|1148.6|—|
|2735/68|提前重写，无draft|1194.3|48.9|0|1143.4|—|
|2735/68|提前重写，历史draft|635.6|49.7|415.4|169.7|49/139=35.3%|
|3099/442|end-only，系统前缀warm|7956.6|378.8|0|7565.1|—|
|3099/442|提前重写，无draft|7612.7|50.4|0|7549.8|—|
|3099/442|提前重写，历史draft|5017.2|50.8|3691.4|1254.5|289/1151=25.1%|

每列为独立中位数，组件不必严格相加等于总时间；总时间还含host对齐/argmax取回等。接受率分母包含拒绝后废弃的token提议，可能超过输出长度，不是仅“输出里有多少历史token”。

同调度同cache的配对draft收益：
- 较短case：每次分别1.867/1.876/1.888倍，配对比值中位数**1.88倍**，省557.8ms。
- 较长输出case：1.518/1.515/1.519倍，中位数**1.52倍**，省2595.0ms。
- 不能从两条合成case断言总体加速率或“上下文越长越快/慢”：上下文、输出长度、接受率都改变了。
- 不能忽略预计算成本：两个提前请求总compute中位数，history-draft约1733.8/12825.3ms，对应end-only1243.8/7956.6ms。最终请求更快，但整段总计算仍更多；最终体验要看说话期间是否有足够空隙隐藏它。

## 范围限制
- 所有输入均是人工合成的相邻端点；前一轮先完成再发后一轮，不是实时ASR端点回放，没有模拟supersede取消的真实频率。
- 这是request-completion微基准，**T4全部null**：未接ASR收尾、真实松键R、输入法写入/最后字符交付。不能把635ms/5017ms叫松键延迟。
- end-only不含vLLM自身prompt/output suffix lookup，**不是论文B3的完整复刻**。
- forward前后mx同步、每种相同长度/窗口warmup、模式顺序随机排列，n=3，仅初步实证。没有统计总体置信区间，没有声称任意文本/精度/硬件都逐token相同。
- 启动时PID64521质量进程已结束。仅中断了本任务自己启动、baseline标签错误的pilot；未停止用户任何服务。

## 修正与证据
- 最初smoke的system prefix被Engine初始cache_key清空，导致end-only实际为cold（reused=0）。真实输出等价仍有效，但其“system-warm”标签无效，**不用于正式warm baseline比较**。
- 正在跑的旧pilot被SIGINT中止并保留（real-pilot.*）。随后runner在外部seed前设定cache身份，加CPU回归，再跑正式v2；正式baseline复用2652 token，提前最终请求复用2707/3071 token。
- 完整真实数据 real-paired-v2.jsonl；分析 real-paired-v2.summary.json / real-paired-v2-summary.txt；执行日志 real-paired-v2.log。实际执行源码快照 sources/run_real_mlx_v2.py。
- 原源码/版本引用和边界推导见FINDINGS.md；其旧“未执行GPU”状态是上一阶段历史，以上述本文件为最新。

## 已完成：真正较长上下文的补充实验
real-longcontext-v2.jsonl 完成，新增15/15真实输出逐token相同；两个官方reference各两次一致。正式两份v2合计 **45/45** 输出检查通过（6个独立合成prompt，不是45个独立自然样本），全部GPU任务已退出。

|prompt/output tokens|条件|最终请求中位数ms|prefill ms|verify ms|普通generate ms|接受率|
|---|---|---:|---:|---:|---:|---:|
|9853/1024|end-only，system warm|29958.8|7868.1|0|21920.3|—|
|9853/1024|提前重写，无draft|22044.9|76.3|0|21898.4|—|
|9853/1024|提前重写，历史draft|6290.8|88.9|6163.2|22.7|920/936=98.3%|

同调度配对比值3.495/3.429/3.639倍，中位数3.49倍。cache复用对比清楚：end-only2652 tokens，提前两条件同为9825tokens。因此29959→22045ms主要是prefill缓存收益；22045→6291ms才是本case的历史草稿校验收益，不能混算。

**这个case刻意由512个重复单元构造，不具自然语料代表性。** 前一端点输出仅18token，最终输出触及1024上限；align反复重定位并循环复用这段短草稿（920个accepted不代表历史草稿本来有920token）。98.3%高接受率与3.49倍主要适用于这种人工高重复内容，**不能当自然长听写收益或质量通过**。输出被cap截断，不能认定完整清理完成；但它确实验证了真实模型1024 token长度边界下与无draft逐token一致、没有超额或漏bonus。

这说明长上下文并不使draft在接口上不可用，但核对仍有代价：此case verify本身6.16秒，并非“校验免费”。接受率下降或输出不重复时收益会不同，前两条非完全重复case已显示接受率仅25–35%，不能据此单独拟合上下文长度效应。

两个提前请求总compute中位数：无draft30073.0ms、history-draft14482.0ms；end-only29958.8ms。与前两个case“提前总计算更多”不同，高重复draft能抵消额外提前轮次的计算。三条case的共同结论仅是收益依赖接受率、输入/输出长度和调度，不能无条件保证。

## 精确执行命令
所有命令在本证据目录；PY=/Users/alpha/workspace/speculative-dictation/experiments/streaming_asr/.venv/bin/python。依次串行执行、没有重叠GPU任务：
```
$PY -u run_real_mlx.py --gpu-idle-confirmed --lengths 2,16 --blocks 16 --unique-units --reps 3 --warmups 1 --out "$PWD/real-paired-v2.jsonl"
$PY -u run_real_mlx.py --gpu-idle-confirmed --lengths 512 --blocks 16 --reps 3 --warmups 1 --out "$PWD/real-longcontext-v2.jsonl"
```
原输出文件拒绝覆盖；重跑选本目录新文件名。三次重复是初步结果，不是完整窗口/真实公共语料benchmark。

当前下一关应是公有音频真实ASR相邻端点、supersede-only调度及真实文本sink交付；此阶段仍未接Velora产品，M0和质量裁判gate不由上述结果自动通过。

