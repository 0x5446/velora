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
    content_revision,
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
                {
                    "kind": "endpoint",
                    "confirmed_tokens": 12,
                    "new_tokens": 12,
                    "revision": content_revision(list(range(12))),
                },
                {"kind": "focus_change"},
                {
                    "kind": "endpoint",
                    "confirmed_tokens": 20,
                    "new_tokens": 8,
                    "revision": content_revision(list(range(20))),
                },
                {
                    "kind": "end",
                    "confirmed_tokens": 20,
                    "revision": content_revision(list(range(20))),
                },
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

    def test_missing_or_prose_revision_is_refused(self):
        with self.assertRaises(ContractError):
            collect_endpoints(
                [{"confirmed_tokens": 4}],
                source="synthetic",
                corpus_id="skeleton-token-counts",
            )
        with self.assertRaises(ContractError):
            collect_endpoints(
                [{"confirmed_tokens": 4, "revision": "same length different words"}],
                source="synthetic",
                corpus_id="skeleton-token-counts",
            )

    def test_revision_tracks_ids_not_the_token_count(self):
        left = [1, 2, 3, 4]
        right = [4, 3, 2, 1]
        self.assertEqual(len(left), len(right))
        self.assertNotEqual(content_revision(left), content_revision(right))
        with self.assertRaises(ContractError):
            content_revision("1\n2\n3\n4")

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
        self.assertEqual(report["model"], "cpu_mock")
        self.assertIsNone(report["mlx_token_identity"])
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

    def test_same_token_count_and_different_revision_commits_the_new_output(self):
        left = content_revision([1, 2, 3, 4])
        right = content_revision([9, 8, 7, 6])
        trace = collect_endpoints(
            [
                {"kind": "endpoint", "confirmed_tokens": 4, "revision": left},
                {"kind": "end", "confirmed_tokens": 4, "revision": right},
            ],
            source="synthetic",
            corpus_id="same-length-revision",
        )
        report = replay_endpoint_trace(trace, max_tokens=4)
        self.assertEqual(report["model"], "cpu_mock")
        self.assertIsNone(report["mlx_token_identity"])
        self.assertTrue(report["end_started_another_generation"])
        self.assertEqual(report["committed_revision"], right)
        self.assertEqual(len(report["requests"]), 2)
        self.assertNotEqual(report["requests"][0]["output"], report["requests"][1]["output"])
        self.assertEqual(report["committed_output"], report["requests"][1]["output"])
        self.assertNotIn("text", report)
        self.assertNotIn("confirmed_text", report)

    def test_same_revision_does_not_start_another_generation(self):
        revision = content_revision([1, 2, 3, 4])
        trace = collect_endpoints(
            [
                {"kind": "endpoint", "confirmed_tokens": 4, "revision": revision},
                {"kind": "end", "confirmed_tokens": 4, "revision": revision},
            ],
            source="synthetic",
            corpus_id="same-revision",
        )
        report = replay_endpoint_trace(trace, max_tokens=3)
        self.assertFalse(report["end_started_another_generation"])
        self.assertEqual(len(report["requests"]), 1)
        self.assertEqual(report["committed_revision"], revision)
        self.assertEqual(report["committed_output"], report["requests"][0]["output"])

    def test_cpu_replay_cannot_claim_mlx_token_identity(self):
        trace = json.loads((FIXTURES / "endpoint_trace_skeleton.json").read_text())
        report = replay_endpoint_trace(trace, max_tokens=2)
        report["mlx_token_identity"] = True
        with self.assertRaises(ContractError):
            validate_block_trace(report)

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


class ArchivedMacEvidenceTests(unittest.TestCase):
    def test_3099_rerun_block_log_validates_and_is_not_the_5017_row(self):
        path = REPO / "docs/evidence/mac-2026-11-16/recorded-block-trace.json"
        document = json.loads(path.read_text())
        validate_block_trace(document)
        self.assertIsNone(document["t4_ms"])
        self.assertFalse(document["representative"])
        self.assertEqual(len(document["requests"]), 5)
        self.assertEqual(sum(len(item["blocks"]) for item in document["requests"]), 1919)
        final = next(
            item
            for item in document["requests"]
            if item["condition"] == "early_history_draft" and item["prompt_tokens"] == 3099
        )
        self.assertEqual(final["output_tokens"], 442)
        self.assertEqual(final["accepted"], 289)
        self.assertEqual(final["proposed"], 1151)
        self.assertNotEqual(final["request_completion_ms"], 5017.2)
        verify = [block for block in final["blocks"] if block["phase"] == "verify"]
        self.assertGreater(len({block["block_len"] for block in verify}), 1)
        verify_ms = sum(block["elapsed_ms"] for block in verify)
        self.assertGreater(verify_ms, 3700)
        self.assertNotEqual(round(verify_ms, 1), 3691.4)

    def test_public_endpoint_summary_has_no_revision_and_no_t4(self):
        path = REPO / "docs/evidence/mac-2026-11-16/public-endpoint-replay-summary.json"
        document = json.loads(path.read_text())
        self.assertIsNone(document["t4_ms"])
        self.assertFalse(document["representative"])
        self.assertTrue(document["constructed_join"])
        counts = [event["confirmed_tokens"] for event in document["endpoint_events"]]
        self.assertEqual(len(counts), len(set(counts)))
        self.assertEqual(sum(event["kind"] == "endpoint" for event in document["endpoint_events"]), 9)
        with self.assertRaises(ContractError):
            collect_endpoints(
                document["endpoint_events"],
                source="public_frozen_corpus",
                corpus_id="xasr-public-join",
            )
        by_condition = {item["condition"]: item for item in document["conditions"]}
        self.assertIsNone(by_condition["early_history_draft"]["t4_ms"])
        self.assertTrue(by_condition["early_history_draft"]["equals_official_reference"])
        self.assertAlmostEqual(
            by_condition["early_history_draft"]["replayed_release_to_decoder_completion_ms"],
            281.655,
            places=2,
        )
        self.assertAlmostEqual(
            by_condition["endonly_system_warm"]["replayed_release_to_decoder_completion_ms"],
            937.214,
            places=2,
        )
        self.assertAlmostEqual(
            by_condition["early_nodraft"]["replayed_release_to_decoder_completion_ms"],
            3874.732,
            places=2,
        )


REPO = Path(__file__).resolve().parents[2]


if __name__ == "__main__":
    unittest.main()
