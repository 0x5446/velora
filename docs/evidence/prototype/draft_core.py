"""Isolated greedy fixed-draft prototype. No MLX import; not product code.
Derived from research pipeline/local_polish.py, with explicit boundary/rollback rules.
Backend: tokens list, forward(ids)->next-token argmax per input row, trim(n), clear().
No sampler/logits processors supported. Only deterministic causal greedy is claimed.
"""
import ast
from pathlib import Path

# Reuse the exact research align function, not a lookalike proposer.
_src = (Path(__file__).parent / "sources/pipeline__local_polish.py").read_text()
_node = next(n for n in ast.parse(_src).body if isinstance(n, ast.FunctionDef) and n.name == "align")
_scope = {"TAIL_LENS": (8, 4, 2, 1)}
exec(compile(ast.fix_missing_locations(ast.Module(body=[_node], type_ignores=[])), "research-align", "exec"), _scope)
align = _scope["align"]

class Cancelled(Exception):
    pass

class Engine:
    def __init__(self, backend, k=4, kmax=128, max_context=40960):
        if not 1 <= k <= kmax:
            raise ValueError("invalid block bounds")
        self.b = backend
        self.k, self.kmax, self.max_context = k, kmax, max_context
        self.key = None

    def run(self, prompt, draft=(), eos=frozenset({0}), max_tokens=1024,
            cache_key="same-model-tokenizer-template-precision", cancel=lambda: False):
        prompt, draft = list(prompt), list(draft)
        if not prompt or max_tokens < 0 or len(prompt) + max_tokens > self.max_context:
            raise ValueError("empty prompt, negative cap or context overflow")
        if cache_key != self.key:
            self.b.clear()
            self.key = cache_key
        st = {"prompt_tokens": len(prompt), "draft_tokens": len(draft), "reused": 0,
              "proposed": 0, "accepted": 0, "blocks": [], "finish": None}
        def check():
            if cancel():
                raise Cancelled()
        try:
            check()
            common = 0
            for a, b in zip(self.b.tokens, prompt):
                if a != b:
                    break
                common += 1
            # Last prompt token must be recomputed to recover the first logits.
            common = min(common, len(prompt) - 1)
            self.b.trim(common)
            st["reused"] = common
            if max_tokens == 0:
                st["finish"] = "length"
                st["out_tokens"], st["acceptance"] = 0, None
                return [], st
            check()
            y = self.b.forward(prompt[common:], "prefill")[-1]
            check()
            out, ptr, win = [], None, self.k
            while True:
                check()
                if y in eos:
                    st["finish"] = "eos"
                    break
                if len(out) >= max_tokens:
                    st["finish"] = "length"
                    break
                out.append(y)  # y is pending, not in KV yet.
                if len(out) >= max_tokens:
                    st["finish"] = "length"
                    break
                pos = align(draft, out, ptr) if draft else None
                if pos is not None:
                    ptr = pos
                prop = draft[pos:pos + min(win, max_tokens - len(out))] if pos is not None else []
                base = len(self.b.tokens)
                check()
                # preds[j] predicts prop[j] from [pending y, prop[:j]].
                # preds[len(prop)] is the bonus or next ordinary token.
                preds = self.b.forward([y] + prop, "verify" if prop else "generate")
                check()
                a, hit_eos = 0, False
                while a < len(prop) and prop[a] == preds[a]:
                    if prop[a] in eos:
                        hit_eos = True
                        break
                    a += 1
                out.extend(prop[:a])
                self.b.trim(base + 1 + a)
                st["proposed"] += len(prop)
                st["accepted"] += a
                st["blocks"].append({"block": len(prop), "accepted": a,
                    "context_before": base, "remaining_before": max_tokens - (len(out) - a),
                    "bonus": bool(prop and a == len(prop)), "eos_in_block": hit_eos})
                if hit_eos:
                    st["finish"] = "eos"
                    break
                if len(out) >= max_tokens:
                    st["finish"] = "length"
                    break
                # First rejection is never emitted from draft. Emit the target token
                # next iteration; when all match this is the bonus token instead.
                y = preds[a]
                win = min(2 * win, self.kmax) if prop and a == len(prop) else self.k
            st["out_tokens"] = len(out)
            st["acceptance"] = st["accepted"] / st["proposed"] if st["proposed"] else None
            return out, st
        except BaseException:
            # A backend may fail mid-forward, leaving different layer offsets.
            # Invalidate everything rather than guessing a trim position.
            self.b.clear()
            raise
