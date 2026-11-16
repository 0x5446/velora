"""Token-level exact draft verification.

The control flow follows `pipeline/local_polish.py` `LocalPolisher` at
speculative-dictation `143a5f52`: longest common prefix of the prompt against
the resident cache, rollback of the divergent tail, then greedy argmax with
the previous target output as the draft. There is no second draft model and
no probability bonus.

Two contracts differ from that published loop, both locked by tests:

- A proposal is shortened so the output cannot grow past `max_tokens`.
  The published `out.extend` can pass the cap. The Mac notes say the isolated
  prototype fixed that overrun; this facility enforces the fixed contract.
- This module does not load MLX and does not emit milliseconds.
"""

from __future__ import annotations

TAIL_LENS = (8, 4, 2, 1)


class Cancelled(Exception):
    """Raised when a generation observes cancellation before adopting the next token."""


def align(draft, gen, prev):
    """Return the next draft index, or None. Same search as LocalPolisher.align."""
    if not gen:
        return 0
    lo = max(0, (prev or 0) - 4)
    for n in TAIL_LENS:
        if len(gen) < n:
            continue
        tail = gen[-n:]
        for start in (lo, 0):
            for j in range(start + n, len(draft) + 1):
                if draft[j - n : j] == tail:
                    return j
    return None


def _blank_stats():
    return {
        "prompt": 0,
        "reused": 0,
        "rolled_back": 0,
        "forwards": 0,
        "accepted": 0,
        "proposed": 0,
        "max_proposed": 0,
        "prefill_tokens": 0,
        "prefill_forwards": 0,
        "verify_tokens": 0,
        "verify_forwards": 0,
        "generate_tokens": 0,
        "generate_forwards": 0,
        "out_tokens": 0,
        "stopped": "",
    }


class TokenPolisher:
    def __init__(self, model, eos, k=4, kmax=128):
        self.model = model
        self.eos = set(eos)
        self.k = k
        self.kmax = kmax
        self.cached: list[int] = []

    def clear(self):
        self.cached = []

    def _forward(self, ids, stats, phase):
        preds = self.model.predict(self.cached, ids)
        if len(preds) != len(ids):
            raise RuntimeError("predict returned %s ids for %s inputs" % (len(preds), len(ids)))
        self.cached.extend(ids)
        stats["forwards"] += 1
        stats[phase + "_forwards"] += 1
        stats[phase + "_tokens"] += len(ids)
        return preds

    def _trim_to(self, n):
        if n > len(self.cached):
            raise RuntimeError("trim past cache")
        self.cached = self.cached[:n]

    def polish(self, prompt, draft=None, cancel=None, max_tokens=1024):
        if not prompt:
            raise ValueError("empty prompt")
        draft = list(draft or [])
        common = 0
        for left, right in zip(self.cached, prompt):
            if left != right:
                break
            common += 1
        # Recompute at least the last prompt token so its prediction is fresh.
        common = min(common, len(prompt) - 1)
        rolled_back = max(0, len(self.cached) - common)
        self._trim_to(common)
        stats = _blank_stats()
        stats["prompt"] = len(prompt)
        stats["reused"] = common
        stats["rolled_back"] = rolled_back
        y = self._forward(prompt[common:], stats, "prefill")[-1]
        out: list[int] = []
        ptr = None
        win = self.k
        while y not in self.eos and len(out) < max_tokens:
            if cancel is not None and cancel.is_set():
                raise Cancelled()
            out.append(y)
            room = max_tokens - len(out)
            p = align(draft, out, ptr) if draft else None
            prop = draft[p : p + win] if p is not None else []
            if len(prop) > room:
                prop = prop[:room]
            if p is not None:
                ptr = p
            if not prop:
                preds = self._forward([y], stats, "generate")
                win = self.k
                y = preds[0]
                continue
            base = len(self.cached)
            preds = self._forward([y] + prop, stats, "verify")
            accepted = 0
            while accepted < len(prop) and prop[accepted] == preds[accepted]:
                accepted += 1
            stats["proposed"] += len(prop)
            stats["accepted"] += accepted
            stats["max_proposed"] = max(stats["max_proposed"], len(prop))
            out.extend(prop[:accepted])
            win = min(win * 2, self.kmax) if accepted == len(prop) else self.k
            self._trim_to(base + 1 + accepted)
            y = preds[accepted]
        stats["out_tokens"] = len(out)
        stats["stopped"] = "eos" if y in self.eos else "max_tokens"
        if len(out) > max_tokens:
            raise RuntimeError("output exceeded max_tokens")
        return out, stats


def greedy_ids(model, prompt, eos, max_tokens):
    """Stateless greedy decode using the same last-token prediction rule."""
    eos = set(eos)
    y = model.predict([], prompt)[-1]
    out: list[int] = []
    while y not in eos and len(out) < max_tokens:
        out.append(y)
        y = model.predict(prompt + out[:-1], [y])[-1]
    return out


class HashLM:
    """Deterministic causal argmax. No weights and no timing."""

    def __init__(self, vocab, seed=0):
        if vocab < 2:
            raise ValueError("vocab")
        self.vocab = vocab
        self.seed = seed

    def next_id(self, ctx):
        value = self.seed & 0xFFFFFFFF
        for token in ctx:
            value = (value * 1315423911 + (token + 1) + 2654435761) & 0xFFFFFFFF
        return value % self.vocab

    def predict(self, prefix, new_ids):
        ctx = list(prefix)
        preds = []
        for token in new_ids:
            ctx.append(token)
            preds.append(self.next_id(ctx))
        return preds


class FnLM:
    def __init__(self, fn):
        self.fn = fn

    def predict(self, prefix, new_ids):
        ctx = list(prefix)
        preds = []
        for token in new_ids:
            ctx.append(token)
            preds.append(self.fn(tuple(ctx)))
        return preds
