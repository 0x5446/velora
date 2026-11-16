# 交接

更新时间：2026-11-16。当前阶段：F0 和 F1 的 CPU 验收设施已通过。F1 已改为用 token id 的 sha256 识别内容，不再用 token 数判断“没变”。M0 未通过，原因只是证据文件还没进本仓库。不要改产品代码。本环境没有访问 `/Users/alpha`。

## 现在在哪

- 产品仓库：`https://github.com/0x5446/velora`，分支 `cursor/m0-research-audit-2bb5`，PR https://github.com/0x5446/velora/pull/13 。不要合并，不要部署。
- 产品 HEAD 的父提交仍是 `origin/main` `73e83ec44363a1968c61da4865fb594bacbeda82`。`Apps/` 和 `Velora/Sources/` 没有被这轮修改。
- 研究仓库：`https://github.com/0x5446/speculative-dictation`，`main` `143a5f52ce380b00a4dda43c3e105d6bc0ace131`。不要向它推送。本环境的 git 凭据 clone 不到它；`pipeline/local_polish.py` 是经 GitHub API 读到的。
- 本环境：Linux，Python 3.12.3。没有 Swift、Xcode、Ollama、MLX，也没有 `/Users/alpha`。

## 先读

1. [`ENGINEERING_PROTOCOL.md`](ENGINEERING_PROTOCOL.md)
2. [`ARCHITECTURE.md`](ARCHITECTURE.md)
3. [`MILESTONE_GATES.md`](MILESTONE_GATES.md)
4. [`evidence/mac-2026-11-16/report.md`](evidence/mac-2026-11-16/report.md)
5. [`../pocs/speculative_replay/README.md`](../pocs/speculative_replay/README.md)

## 关卡

| 关 | 状态 |
|---|---|
| M0 审计与资产清单 | 未通过。阅读完成；用户工作区 `git status` 和权重哈希仍缺 |
| F0 CPU 设施 | 通过。当时 18 项，见 [`evidence/f0/report.md`](evidence/f0/report.md)。同一命令现在会连同 F1 一起跑 |
| F1 端点 schema / 采集器 / 回放 / 计时契约 | 通过。38 项，退出码 0，见 [`evidence/f1/report.md`](evidence/f1/report.md)。CPU mock 的 `mlx_token_identity` 为 null。不是 M1 或 M5 |
| M1 现行产品基线 | 未开始。Mac 离线，且新摘要不是 Velora 的 SenseVoice + Ollama 路径 |
| M2 六套门禁 | 未开始。研究 rubric 的绝对通过率不能代替 |
| M3 取消/焦点/离线的产品观察 | 未开始。F0 只覆盖假模型上的调度 |
| M4 产品决定 | 未通过。方向已写明，默认行为未切换 |
| M5 / M6 | 未开始 |

## 下一最小交付

M0 还差两份已经可以在用户机器上产生、但还没进本仓库的文件。产品 T4 和真实 ASR 端到端不属于这两份。文件进仓库之后，下一步是写 `docs/evidence/m0/report.md` 并只按第 8 节判定 M0；通过之后才能做 M1。M1 的测量命令在审计第 8.3 节，本环境执行不了。

在 `/Users/alpha/workspace/velora` 执行，输出存成 `docs/evidence/m0/workspace-status.txt`。不要粘贴 diff 正文：

```bash
git rev-parse HEAD
git status --short
git diff --stat
git diff --cached --stat
git rev-parse origin/main
git log --oneline origin/main..HEAD
```

权重只交哈希，不交文件本体。目录以冻结说明为准；若本机路径不同，JSON 里写实际路径。`concat_command` 找不到就写 null，不要编：

```bash
python3 - <<'PY'
import hashlib, json, os
root = os.path.expanduser("/home/ubuntu/specdict/models/qwen3-1_7b-xcorr-v53")
# 若该路径不存在，改成本机实际目录后再跑，不要猜哈希。
files = []
for dirpath, _, names in os.walk(root):
    for name in sorted(names):
        if not name.endswith(".safetensors"):
            continue
        path = os.path.join(dirpath, name)
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        files.append({"name": os.path.relpath(path, root), "bytes": os.path.getsize(path), "sha256": digest.hexdigest()})
print(json.dumps({
    "model_dir": root,
    "files": files,
    "recorded_prefix": "eabcdc5c813b1e0b",
    "concat_command": None,
    "concat_sha256_prefix": None,
}, ensure_ascii=False, indent=2))
PY
```

结果存成 `docs/evidence/m0/weights.json`。

隔离原型和 `LocalPolisher` 的差异审查不关闭 M0，但在改产品 sidecar 之前要做。本环境仍未打开这些路径：

- `/Users/alpha/specdict/evidence/mac-draft-20261116-192758/sources/run_real_mlx_v2.py`
- `/Users/alpha/specdict/evidence/mac-draft-20261116-192758/run_real_mlx.py`
- 同目录 `FINDINGS.md` 里写明差异的部分

逐块计时和公共冻结音频端点是产品测量，不是 M0。端点日志的 `revision` 必须是 token id 的 sha256（`pocs/speculative_replay/trace.py` 的 `content_revision`），不能只交 token 数，也不能带原文。逐块文件仍是：

- `/Users/alpha/specdict/evidence/mac-draft-20261116-192758/blocks-3099-442.json`
- `/Users/alpha/specdict/evidence/mac-draft-20261116-192758/endpoint-trace.json`

## 不要做

- 不要改 `Apps/` 或 `Velora/Sources/`，直到 M1–M3 有证据且 M4 按关卡通过。
- 不要跑新的 4B，也不要再付费请裁判。相对 4B / v4.1 保持 not judged。
- 不要把 635.6、5017.2、6290.8 ms 或 98.3% 接受率写成产品延迟或质量通过。
- 不要用 SenseVoice 累计重识别代替端点，也不要用 mlx-lm `draft_model` 代替历史目标输出。
- 不要修改研究仓库，不要推送用户机器上尚未提交的文件，不要合并本 PR。
