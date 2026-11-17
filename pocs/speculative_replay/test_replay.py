"""CPU checks for exact draft verification and one-shot commit.

Run from the repository root:

    python3 -m unittest discover -s pocs/speculative_replay -p 'test_*.py'
"""

from __future__ import annotations

import json
import random
import unittest
from pathlib import Path

from polisher import Cancelled, FnLM, HashLM, TokenPolisher, align, greedy_ids
from session import Session


class Flag:
    def __init__(self):
        self._set = False

    def set(self):
        self._set = True

    def is_set(self):
        return self._set


class AlignTests(unittest.TestCase):
    def test_empty_generation_starts_at_zero(self):
        self.assertEqual(align([1, 2, 3], [], None), 0)

    def test_tail_match_and_miss(self):
        self.assertEqual(align([7, 8, 9, 4, 5], [1, 4, 5], None), 5)
        self.assertIsNone(align([1, 2, 3], [9, 9], None))


class PolisherTests(unittest.TestCase):
    def test_two_thousand_random_prompts_match_greedy(self):
        rng = random.Random(0)
        model = HashLM(vocab=48, seed=11)
        eos = {-1}
        for _ in range(2000):
            prompt = [rng.randrange(48) for _ in range(rng.randint(1, 24))]
            draft = [rng.randrange(48) for _ in range(rng.randint(0, 36))]
            limit = rng.randint(1, 20)
            polisher = TokenPolisher(model, eos=eos, k=rng.choice((1, 2, 4, 8)), kmax=32)
            if rng.random() < 0.3:
                # Warm the cache with a prefix, including the bug where a runner
                # used to clear that prefix before the measured call.
                polisher.cached = list(prompt[:-1])
            got, _stats = polisher.polish(prompt, draft=draft, max_tokens=limit)
            self.assertEqual(got, greedy_ids(model, prompt, eos, limit))

    def test_warm_prefix_is_reused_and_clear_drops_it(self):
        model = HashLM(vocab=32, seed=3)
        prompt = [1, 2, 3, 4, 5, 6]
        polisher = TokenPolisher(model, eos={-1}, k=4, kmax=16)
        polisher.cached = list(prompt[:-1])
        _out, stats = polisher.polish(prompt, draft=[], max_tokens=4)
        self.assertEqual(stats["reused"], len(prompt) - 1)
        polisher.clear()
        _out, cold = polisher.polish(prompt, draft=[], max_tokens=4)
        self.assertEqual(cold["reused"], 0)

    def test_longer_prompt_reuses_prefix_and_rolls_back_generation(self):
        model = HashLM(vocab=32, seed=5)
        polisher = TokenPolisher(model, eos={-1}, k=4, kmax=16)
        first, _ = polisher.polish([1, 2, 3, 4], draft=[], max_tokens=5)
        self.assertGreater(len(first), 0)
        second, stats = polisher.polish([1, 2, 3, 4, 8, 9], draft=first, max_tokens=5)
        self.assertEqual(second, greedy_ids(model, [1, 2, 3, 4, 8, 9], {-1}, 5))
        self.assertEqual(stats["reused"], 4)
        self.assertGreater(stats["rolled_back"], 0)

    def test_changed_prefix_rolls_the_cache_back_to_zero(self):
        model = HashLM(vocab=16, seed=2)
        polisher = TokenPolisher(model, eos={-1})
        polisher.polish([1, 2, 3, 4], max_tokens=3)
        _out, stats = polisher.polish([9, 9, 9], max_tokens=2)
        self.assertEqual(stats["reused"], 0)
        self.assertGreater(stats["rolled_back"], 0)

    def test_output_stops_at_max_tokens_even_when_the_draft_matches(self):
        model = FnLM(lambda ctx: 3)
        draft = [3] * 30
        polisher = TokenPolisher(model, eos={99}, k=8, kmax=32)
        out, stats = polisher.polish([1], draft=draft, max_tokens=5)
        self.assertEqual(out, [3, 3, 3, 3, 3])
        self.assertEqual(stats["stopped"], "max_tokens")
        self.assertLessEqual(len(out), 5)

    def test_eos_inside_a_matching_draft_is_not_emitted(self):
        def nxt(ctx):
            return 9 if len(ctx) >= 4 else 3

        model = FnLM(nxt)
        out, stats = TokenPolisher(model, eos={9}, k=4, kmax=8).polish(
            [1], draft=[3, 3, 9, 9], max_tokens=8
        )
        self.assertNotIn(9, out)
        self.assertEqual(out, greedy_ids(model, [1], {9}, 8))
        self.assertEqual(stats["stopped"], "eos")
        self.assertLess(stats["accepted"], stats["proposed"])

    def test_eos_is_not_emitted(self):
        def nxt(ctx):
            return 7 if len(ctx) >= 4 else 1

        model = FnLM(nxt)
        out, stats = TokenPolisher(model, eos={7}).polish([1, 1], max_tokens=20)
        self.assertNotIn(7, out)
        self.assertEqual(stats["stopped"], "eos")
        self.assertEqual(out, greedy_ids(model, [1, 1], {7}, 20))

    def test_cancel_raises_and_does_not_return_tokens(self):
        flag = Flag()
        flag.set()
        polisher = TokenPolisher(HashLM(8, seed=1), eos={-1})
        with self.assertRaises(Cancelled):
            polisher.polish([1, 2, 3], cancel=flag, max_tokens=6)

    def test_rejected_draft_accepts_nothing_and_still_matches_greedy(self):
        model = FnLM(lambda ctx: 4)
        # The first generated token is 4, so the draft must contain that tail
        # before later tokens can be proposed and rejected.
        polisher = TokenPolisher(model, eos={99}, k=4, kmax=8)
        out, stats = polisher.polish([1, 2], draft=[4, 8, 8, 8, 8], max_tokens=6)
        self.assertEqual(out, greedy_ids(model, [1, 2], {99}, 6))
        self.assertEqual(stats["accepted"], 0)
        self.assertGreater(stats["proposed"], 0)
        self.assertLess(stats["accepted"] / stats["proposed"], 0.5)
        unused, unused_stats = TokenPolisher(model, eos={99}).polish(
            [1, 2], draft=[8, 8, 8, 8], max_tokens=4
        )
        self.assertEqual(unused, greedy_ids(model, [1, 2], {99}, 4))
        self.assertEqual(unused_stats["proposed"], 0)

    def test_full_accept_grows_the_window(self):
        model = FnLM(lambda ctx: 5)
        polisher = TokenPolisher(model, eos={99}, k=2, kmax=8)
        _out, stats = polisher.polish([1], draft=[5] * 40, max_tokens=16)
        self.assertGreaterEqual(stats["max_proposed"], 4)
        self.assertEqual(stats["accepted"], stats["proposed"])


class SessionTests(unittest.TestCase):
    def test_synthetic_fixture_commits_once_and_claims_no_t4(self):
        path = Path(__file__).with_name("fixtures") / "synthetic_endpoints.json"
        fixture = json.loads(path.read_text(encoding="utf-8"))
        self.assertIsNone(fixture["t4_ms"])
        self.assertFalse(fixture["representative"])
        model = HashLM(vocab=64, seed=9)
        polisher = TokenPolisher(model, eos={-1}, k=4, kmax=16)

        def polish(text, draft, cancel):
            prompt = [ord(ch) for ch in text]
            return polisher.polish(prompt, draft=draft, cancel=cancel, max_tokens=8)

        session = Session(polish)
        report = session.replay(fixture["events"])
        self.assertEqual(report["commit_count"], 1)
        self.assertEqual(report["model"], "injected_cpu_mock")
        self.assertIsNone(report["mlx_token_identity"])
        self.assertIsNone(report["t4_ms"])
        self.assertIsNone(report["milliseconds"])
        self.assertEqual(report["focus_changes"], 1)
        self.assertGreaterEqual(len(report["requests"]), 2)
        self.assertGreater(report["requests"][-1]["reused"], 0)
        self.assertNotIn("speedup", report)
        final = [ord(ch) for ch in fixture["events"][-1]["confirmed_text"]]
        self.assertEqual(session.commits[0]["out"], greedy_ids(model, final, {-1}, 8))

    def test_endpoints_do_not_commit_before_end(self):
        seen = {}

        def polish(text, draft, cancel):
            seen["draft"] = list(draft)
            return ([len(text)], {"prefill_tokens": len(text), "verify_tokens": 0, "generate_tokens": 1,
                                   "accepted": 0, "proposed": 0, "reused": 0, "rolled_back": 0, "out_tokens": 1})

        session = Session(polish)
        session.handle({"kind": "endpoint", "confirmed_text": "aa"})
        self.assertEqual(session.commits, [])
        session.handle({"kind": "endpoint", "confirmed_text": "aabb"})
        self.assertEqual(seen["draft"], [2])
        self.assertEqual(session.commits, [])
        session.handle({"kind": "end", "confirmed_text": "aabb"})
        self.assertEqual(len(session.commits), 1)
        self.assertEqual(session.commits[0]["text"], "aabb")

    def test_stale_completion_is_dropped(self):
        session = Session(polish=None, inline=False)
        session.handle({"kind": "endpoint", "confirmed_text": "a"})
        first = session.current["id"]
        session.handle({"kind": "endpoint", "confirmed_text": "ab"})
        self.assertFalse(session.complete(first, [1], _stats()))
        self.assertEqual(session.draft, [])
        second = session.current["id"]
        self.assertTrue(session.complete(second, [9], _stats()))
        session.handle({"kind": "end", "confirmed_text": "ab"})
        self.assertEqual(len(session.commits), 1)
        self.assertEqual(session.commits[0]["out"], [9])
        self.assertEqual(session.report()["dropped_stale"], 1)
        self.assertIsNone(session.report()["t4_ms"])

    def test_cancel_and_fault_commit_nothing(self):
        session = Session(polish=None, inline=False)
        session.handle({"kind": "endpoint", "confirmed_text": "a"})
        session.handle({"kind": "cancel_session"})
        self.assertFalse(session.complete(1, [1], _stats()))
        self.assertEqual(session.commits, [])
        self.assertTrue(session.faulted)

        other = Session(polish=None, inline=False)
        other.handle({"kind": "endpoint", "confirmed_text": "a"})
        other.complete(1, [1], _stats())
        other.handle({"kind": "asr_fault"})
        self.assertEqual(other.commits, [])

    def test_focus_change_does_not_commit(self):
        calls = []

        def polish(text, draft, cancel):
            calls.append(text)
            return ([1], _stats())

        session = Session(polish)
        session.handle({"kind": "endpoint", "confirmed_text": "a"})
        session.handle({"kind": "focus_change"})
        self.assertEqual(session.commits, [])
        self.assertEqual(calls, ["a"])
        session.handle({"kind": "end", "confirmed_text": "a"})
        self.assertEqual(len(session.commits), 1)

    def test_inline_cancel_inside_polish_does_not_commit(self):
        def polish(text, draft, cancel):
            raise Cancelled()

        session = Session(polish)
        session.handle({"kind": "endpoint", "confirmed_text": "a"})
        session.handle({"kind": "end", "confirmed_text": "a"})
        self.assertEqual(session.commits, [])
        self.assertGreaterEqual(session.report()["dropped_stale"], 1)

    def test_end_with_same_text_does_not_start_a_second_generation(self):
        calls = []

        def polish(text, draft, cancel):
            calls.append(text)
            return ([7], _stats())

        session = Session(polish)
        session.handle({"kind": "endpoint", "confirmed_text": "same"})
        session.handle({"kind": "end", "confirmed_text": "same"})
        self.assertEqual(calls, ["same"])
        self.assertEqual(len(session.commits), 1)

    def test_same_length_different_text_commits_the_new_output(self):
        calls = []

        def polish(text, draft, cancel):
            calls.append(text)
            stats = _stats()
            stats["out_tokens"] = 1
            return ([ord(text[0])], stats)

        session = Session(polish)
        session.handle({"kind": "endpoint", "confirmed_text": "aaaa"})
        session.handle({"kind": "end", "confirmed_text": "bbbb"})
        self.assertEqual(calls, ["aaaa", "bbbb"])
        self.assertEqual(len(session.commits), 1)
        self.assertEqual(session.commits[0]["text"], "bbbb")
        self.assertEqual(session.commits[0]["out"], [ord("b")])
        self.assertIsNone(session.report()["mlx_token_identity"])


def _stats():
    return {
        "prefill_tokens": 1,
        "verify_tokens": 0,
        "generate_tokens": 1,
        "accepted": 0,
        "proposed": 0,
        "reused": 0,
        "rolled_back": 0,
        "out_tokens": 1,
    }


if __name__ == "__main__":
    unittest.main()
