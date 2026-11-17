# 隔离原型审查

审查对象是 2026-11-16 交来的源码，不是产品代码。`run_real_mlx.py` 与 `sources/run_real_mlx_v2.py` 两份上传的 sha256 都是 `ac19623c9a277f983b33437383b3c1f52465ab40730c36de149bbd3dde3a8cb6`，11828 字节，内容相同。`draft_core.py` 的 sha256 是 `b41d1379021421fd50242a7a3222d333ca23be44d2c1b75537735e0f59f7972f`。`FINDINGS.md` 的 sha256 是 `7038801c106eae6522b8c155788473ffe78cc179f0c1d580e5a2ca42a7d6b03d`。本目录保存了 `draft_core.py` 和 `FINDINGS.md`。runner 含合成提示构造，不入库。

研究仓库 `pipeline/local_polish.py`（`143a5f52`）的 `align` 被 `draft_core.py` 用 AST 原样取出。循环本身不是那份类的拷贝。

| 行为 | 研究 `LocalPolisher` | 隔离 `draft_core.Engine` | 本仓库 CPU `TokenPolisher` |
|---|---|---|---|
| 草稿 | 上一轮输出文本再 encode | 上一轮 token，或 runner 先 decode 再 encode | 上一轮 token |
| 输出上限 | `out.extend` 可以越过 `max_tokens` | proposal 裁到剩余额度 | 同样裁短 |
| EOS | 接受段里的 EOS 会随 `extend` 输出 | 匹配到 EOS 就停止，不输出该 token | 读完原型后改成同样不输出 |
| 因果 | `y` 尚未入缓存，`preds[j]` 对应 proposal[j] | 注释和 forward `[y]+prop` 相同 | 相同 |
| KV trim | `trim_prompt_cache` 到已接受位置 | backend 必须 trim 到恰好 `delta`，层 offset 不一致就失败 | 只截 Python 列表，没有 MLX cache |
| 取消 | 循环开头看 Event | prefill 前后和每块前后都看；异常时清空整个 cache | 循环开头看 flag，不模拟层 offset |
| 浮点 | 未讨论多 token 与单 token kernel | runner 用 MLX argmax，并与 `generate_step` 逐 token 对比 | 假 argmax。`mlx_token_identity` 保持 null |

`FINDINGS.md` 写明：CPU 假模型只证明同一确定性 next-token 函数下的算法关系。MLX BF16 的多 token 验证和单 token 解码可能走不同 kernel。真实 1.7B 必须单独和官方无 draft reference 比。分歧时停在第一个 token，不能继续谈加速。这次公共回放和 3099/442 重跑都报告了 `equals_reference`，那是各次运行的实测，不是这个浮点风险已经消失。

runner 在第一次 `run` 之前写入 cache key，避免引擎把外部种入的前缀清掉。这是先前无效 warm 标签的修复。取消只发生在 forward 前后，Metal kernel 本身不保证能被打断。

这些文件不进入 `Apps/` 或 `Velora/Sources/`。
