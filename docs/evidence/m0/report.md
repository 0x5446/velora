# M0 证据判定

日期：2026-11-16。判定依据是 [`M0_RESEARCH_AUDIT.md`](../../M0_RESEARCH_AUDIT.md) 第 8 节，加上本目录的三份交接文件。本环境没有访问 `/Users/alpha`。下面的存在性和哈希来自交接文件，不是这台 Linux 重新计算权重或语料。

**M0 通过。** 通过范围是第 8 节里已经有“存在 + 哈希”或“明确未测”的项。产品 T4、SenseVoice + Ollama 基线和真实松键都不在本关。

## 8.1 用户工作区

来源：`workspace-status.txt`，采集时间 2026-11-16T23:33:31+08。

| 命令结果 | 值 |
|---|---|
| `HEAD` | `73e83ec44363a1968c61da4865fb594bacbeda82` |
| `git status --short` | 只有未跟踪 `docs/SPECULATIVE_POLISH_UPGRADE.md` |
| `git diff --stat` | 空 |
| `git diff --cached --stat` | 空 |
| 本机 `origin/main` | `accab7259f64b0b89546eb0a2b7b2a13dfae9f26` |

本仓库的 `origin/main` 是 `73e83ec`。`accab725` 是 `73e83ec` 的祖先，所以用户机器上的 `origin/main` 是过期的 tracking ref，不是 GitHub 当前 `main`。`git log origin/main..HEAD` 打出的 `e1f1e12`、`0a64eec`、`73e83ec` 已经在 GitHub `main` 上。tracked 和 staged diff 都是空的。

未跟踪文件仍是那份升级设计稿。这次交接没有重新计算它的 sha256。本仓库已有副本 `docs/m0/inputs/SPECULATIVE_POLISH_UPGRADE.md`，sha256 `fb7fb5e51e8d992e475eb758d4757d299ddb71169c87a193898ee6957d8129b6`。不能据此证明用户机器上的未跟踪副本字节没变。

## 8.2 研究资产

| 项 | 判定 |
|---|---|
| Qwen3-1.7B v5.3 | 路径 `/Users/alpha/specdict/evidence/mac-eval-20261116-180318/models/qwen3-1_7b-xcorr-v53/model.safetensors`，3,441,185,608 字节。完整 sha256 `eabcdc5c813b1e0b9b23aadb14c7dbc32e476f88a4fd92fc0c1bb5e85e76402f`，前 16 位与冻结前缀 `eabcdc5c813b1e0b` 一致。该哈希引自先前的 `weights-1_7b.json`，`hash_reused_not_recomputed_this_round` 为 true。这轮只复核了文件名和字节数，没有重读 3.4GB。只有一个 safetensors 时，`cat model.safetensors \| shasum -a 256` 与对单文件做 sha256 相同；冻结说明原来没写出拼接命令，这个单文件定义现在是明确的 |
| 提示词 `polish_v3.3` | 交接里的 sha256 等于冻结值 `d7e55c158e10bcd7b4ae8d8c373ccc74ed6388cc701330319f01ab89c93f358b`。JSON 没有写出这轮被哈希的文件路径 |
| `test_id.jsonl` | 完整 sha256 `8a3dbcae102672873e16bb5470f487d2114d74fd2f45576aa4e83ed4f64b6803`，前缀匹配，570 行，1,917,933 字节 |
| `test_id.checks.jsonl` | 完整 sha256 `0482dd629785ad22f8cb26a49b1a0007e7f615e72aed6bd33279b3be5a343c17`，前缀匹配，570 行 |
| realx v2 manifest | 两个路径字节数和 sha256 都是 `dfe1cc84881155c8537060847f343ed7145aaa2567b20ee45af73daa9d6f46cf`，145 行。与“推理 1314、打分分母 1304”里的 realx 145 条一致。这不是把 5 条排除重新数过 |
| gentest v5 manifest | sha256 `67ab18edbf80312e5fe312d85b9e8b4004e80ec4838f7bd5e8ff8fb2de319d8e`，402 行 |
| 0.6B 权重 | 本交接未提供。选定路径不加载它 |
| v5.3 train / val / manifest 全文哈希 | 冻结文档仍是缩写。本交接没有这些文件的完整 sha256 |
| realx 与 gentest 的 pcm 串接 | 冻结哈希已引用，本交接没有重新计算 |
| X-ASR 目录哈希 | 冻结说明本身没有哈希。公共回放记录了模型名和 `sherpa-onnx` 2.0.1，没有目录 sha256 |
| `agentic-refiner`、4B 缓存、`verify-cost-*.json`、`config.local.env` | 本交接未提供。4B 按决定不下载、不加载 |

语料原文没有入库。`frozen-data-hashes.json` 写明 `raw_dataset_rows_copied` 为 false。

## 8.3

第 8.3 节是 M1 开始前的 Mac 运行资产，不是 M0 的通过条件。命令在 [`../m1/collect_baseline.sh`](../m1/collect_baseline.sh)。本环境没有执行。
