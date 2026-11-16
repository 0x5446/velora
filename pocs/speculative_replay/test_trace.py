"""CPU checks for the desensitized endpoint trace and the timing contract.

Run from the repository root:

    python3 -m unittest discover -s pocs/speculative_replay -p 'test_*.py'
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from polisher import FnLM, TokenPolisher
from trace import (
    ContractError,
    classify_recorded_request,
    collect_endpoints,
    group_blocks,
    replay_endpoint_trace,
    validate_block_trace,
    validate_endpoint_trace,
)


FIXTURES = Path(__file__).resolve().parent / "fixtures"


class CollectorTests(unittest.TestCase):
    def test_numeric_rows_match_the_checked_in_skeleton(self):
        trace = collect_endpoints(
            [
                {"kind": "endpoint", "confirmed_tokens": 12, "new_tokens": 12},
                {"kind": "focus_change"},
                {"kind": "endpoint", "confirmed_tokens": 20, "new_tokens": 8},
                {"kind": "end", "confirmed_tokens": 20},
            ],
            source="synthetic",
            corpus_id="skeleton-token-counts",
        )
        checked = json.loads((FIXTURES / "endpoint_trace_skeleton.json").read_text())
        self.assertEqual(trace, checked)
        validate_endpoint_trace(trace)
        self.assertIsNone(trace["t4_ms"])
        self.assertNotIn("speedup", trace)

    def test_transcript_text_is_refused(self):
        with self.assertRaises(ContractError):
            collect_endpoints(
                [{"kind": "endpoint", "confirmed_tokens": 4, "confirmed_text": "private dictation"}],
                source="public_frozen_corpus",
                corpus_id="public-corpus",
            )

    def test_any_string_field_is_refused(self):
        with self.assertRaises(ContractError):
            collect_endpoints(
                [{"kind": "endpoint", "confirmed_tokens": 4, "note": "speaker name"}],
                source="synthetic",
                corpus_id="skeleton-token-counts",
            )

    def test_synthetic_trace_cannot_claim_to_be_representative(self):
        with self.assertRaises(ContractError):
            collect_endpoints(
                [{"confirmed_tokens": 4}],
                source="synthetic",
                corpus_id="skeleton-token-counts",
                representative=True,
            )

    def test_path_shaped_corpus_id_is_refused(self):
        with self.assertRaises(ContractError):
            collect_endpoints(
                [{"confirmed_tokens": 4}],
                source="public_frozen_corpus",
                corpus_id="/Users/alpha/specdict/audio/private.wav",
            )


class ReplayTests(unittest.TestCase):
    def test_skeleton_replay_splits_blocks_without_milliseconds(self):
        trace = json.loads((FIXTURES / "endpoint_trace_skeleton.json").read_text())
        report = replay_endpoint_trace(trace, k=4, kmax=8, max_tokens=6)
        validate_block_trace(report)
        self.assertEqual(report["source"], "cpu_replay")
        self.assertIsNone(report["t4_ms"])
        self.assertIsNone(report["milliseconds"])
        self.assertNotIn("speedup", report)
        self.assertFalse(report["end_started_another_generation"])
        self.assertEqual([item["kind"] for item in report["requests"]], ["endpoint", "endpoint"])
        self.assertEqual(report["requests"][1]["draft_tokens"], 6)
        for request in report["requests"]:
            if request["proposed"] == 0:
                self.assertIsNone(request["acceptance"])
            else:
                self.assertGreaterEqual(request["acceptance"], 0.0)
                self.assertLessEqual(request["acceptance"], 1.0)
            for block in request["blocks"]:
                self.assertIn(block["phase"], {"prefill", "verify", "generate"})
                self.assertGreaterEqual(block["context_tokens"], 0)
                self.assertGreater(block["block_len"], 0)
                self.assertNotIn("elapsed_ms", block)
        groups = group_blocks(report)
        self.assertIsNone(groups["t4_ms"])
        self.assertTrue(groups["groups"])
        self.assertTrue(all(item["elapsed_ms"] is None for item in groups["groups"]))

    def test_verify_blocks_keep_context_length_and_partial_acceptance(self):
        def always_four(_ctx):
            return 4

        polisher = TokenPolisher(FnLM(always_four), eos=set(), k=4, kmax=16)
        first, _ = polisher.polish([1, 2, 3], draft=[], max_tokens=8)
        self.assertEqual(first, [4] * 8)

        def four_then_diverge(ctx):
            return 9 if len(ctx) >= 8 else 4

        polisher = TokenPolisher(FnLM(four_then_diverge), eos=set(), k=4, kmax=16)
        _out, stats = polisher.polish([1, 2, 3, 5], draft=first, max_tokens=12)
        verify = [block for block in stats["blocks"] if block["phase"] == "verify"]
        self.assertTrue(verify)
        self.assertTrue(any(block["accepted"] < block["block_len"] for block in verify))
        self.assertTrue(any(block["accepted"] > 0 for block in verify))
        for block in verify:
            self.assertGreater(block["context_tokens"], 0)
            self.assertGreater(block["block_len"], 0)
            self.assertLessEqual(block["accepted"], block["block_len"])
        self.assertNotIn("elapsed_ms", stats)

    def test_full_accept_grows_the_recorded_block_length(self):
        def always_four(_ctx):
            return 4

        polisher = TokenPolisher(FnLM(always_four), eos=set(), k=4, kmax=16)
        draft, _ = polisher.polish([1], draft=[], max_tokens=12)
        polisher = TokenPolisher(FnLM(always_four), eos=set(), k=4, kmax=16)
        _out, stats = polisher.polish([1, 2], draft=draft, max_tokens=12)
        lengths = [block["block_len"] for block in stats["blocks"] if block["phase"] == "verify"]
        self.assertEqual(lengths[0], 4)
        self.assertGreater(max(lengths), 4)

    def test_cpu_replay_rejects_elapsed_milliseconds(self):
        trace = json.loads((FIXTURES / "endpoint_trace_skeleton.json").read_text())
        report = replay_endpoint_trace(trace, max_tokens=2)
        report["requests"][0]["blocks"][0]["elapsed_ms"] = 3691.4
        with self.assertRaises(ContractError):
            validate_block_trace(report)

    def test_recorded_block_log_shape_still_has_null_t4(self):
        document = {
            "schema": "velora.block_trace.v1",
            "source": "recorded_block_log",
            "t4_ms": None,
            "milliseconds": None,
            "representative": False,
            "requests": [
                {
                    "blocks": [
                        {"phase": "prefill", "context_tokens": 0, "block_len": 4, "accepted": 0},
                        {
                            "phase": "verify",
                            "context_tokens": 8,
                            "block_len": 4,
                            "accepted": 1,
                            "elapsed_ms": 1.0,
                        },
                    ]
                }
            ],
        }
        validate_block_trace(document)
        document["t4_ms"] = 5017.2
        with self.assertRaises(ContractError):
            validate_block_trace(document)


class CitationTests(unittest.TestCase):
    def _rows(self):
        document = json.loads((FIXTURES / "recorded_request_citations.json").read_text())
        self.assertIsNone(document["t4_ms"])
        return {row["id"]: row for row in document["rows"]}

    def test_5017_row_is_split_without_a_speedup_or_per_block_times(self):
        split = classify_recorded_request(self._rows()["3099-442"])
        self.assertIsNone(split["t4_ms"])
        self.assertNotIn("speedup", split)
        self.assertEqual(split["prompt_tokens"], 3099)
        self.assertEqual(split["output_tokens"], 442)
        self.assertEqual(split["window"], 16)
        self.assertIsNone(split["draft_tokens"])
        self.assertEqual(split["accepted"], 289)
        self.assertEqual(split["proposed"], 1151)
        self.assertAlmostEqual(split["acceptance"], 289 / 1151)
        self.assertEqual(split["verify_ms"], 3691.4)
        self.assertEqual(split["prefill_ms"], 50.8)
        self.assertEqual(split["generate_ms"], 1254.5)
        self.assertEqual(split["request_completion_ms"], 5017.2)
        self.assertTrue(split["verify_is_largest_component"])
        self.assertFalse(split["components_equal_request"])
        self.assertNotEqual(split["component_sum_ms"], split["request_completion_ms"])
        self.assertIsNone(split["block_lengths_observed"])
        self.assertIsNone(split["per_block_milliseconds"])
        self.assertFalse(split["may_generalize"])
        self.assertFalse(split["representative"])

    def test_repeat_case_cannot_be_generalized_or_relabeled(self):
        row = self._rows()["9853-1024"]
        split = classify_recorded_request(row)
        self.assertTrue(split["constructed_repeat"])
        self.assertFalse(split["may_generalize"])
        self.assertEqual(split["draft_tokens"], 18)
        self.assertEqual(split["accepted"], 920)
        self.assertTrue(split["accepted_exceeds_draft"])
        self.assertEqual(split["verify_ms"], 6163.2)
        self.assertTrue(split["verify_is_largest_component"])
        relabeled = dict(row)
        relabeled["representative"] = True
        with self.assertRaises(ContractError):
            classify_recorded_request(relabeled)
        mistaken_draft = dict(row)
        mistaken_draft["draft_tokens"] = mistaken_draft["accepted"]
        with self.assertRaises(ContractError):
            classify_recorded_request(mistaken_draft)

    def test_short_row_is_kept_separate_from_the_long_row(self):
        rows = self._rows()
        short = classify_recorded_request(rows["2735-68"])
        long = classify_recorded_request(rows["3099-442"])
        self.assertEqual(short["request_completion_ms"], 635.6)
        self.assertEqual(short["verify_ms"], 415.4)
        self.assertEqual(short["accepted"], 49)
        self.assertEqual(short["proposed"], 139)
        self.assertNotEqual(short["prompt_tokens"], long["prompt_tokens"])
        self.assertNotEqual(short["acceptance"], long["acceptance"])

    def test_cpu_replay_cannot_be_classified_as_the_recorded_row(self):
        trace = json.loads((FIXTURES / "endpoint_trace_skeleton.json").read_text())
        report = replay_endpoint_trace(trace, max_tokens=2)
        with self.assertRaises(ContractError):
            classify_recorded_request(report["requests"][0])


if __name__ == "__main__":
    unittest.main()
