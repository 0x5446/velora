"""Checks for the M1 collector plan. No Swift, no Ollama, no invented timings."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from plan import (
    BASELINE_MODEL,
    MODEL_ENV,
    SOURCE_DEFAULT_MODEL,
    accepts_llm_baseline,
    assert_model_env_matches_source,
    keep_time_lines,
    missing_model_report,
    parse_api_show,
    parse_ollama_show,
    parse_rss,
    process_env,
    redact_run,
    swift_invocation,
)


class ScriptContractTests(unittest.TestCase):
    def test_shell_entry_uses_the_approved_model_and_does_not_copy(self):
        script = (Path(__file__).resolve().parents[2] / "docs/evidence/m1/collect_baseline.sh").read_text()
        self.assertIn('MODEL="${VELORA_M1_MODEL:-qwen3:8b}"', script)
        self.assertIn('[[ "$MODEL" != "qwen3:8b" ]]', script)
        self.assertNotIn(":-qwen3:14b", script)
        self.assertNotIn("m1-baseline-14b", script)
        self.assertIn("VELORA_OLLAMA_MODEL", script)
        self.assertNotIn("--copy", script)
        self.assertNotIn("ollama pull", script)
        for baked in ("282", "5017", "635.6"):
            self.assertNotIn(baked, script)


class SourceContractTests(unittest.TestCase):
    def test_env_name_is_the_one_in_local_model_engines(self):
        assert_model_env_matches_source()
        source = (Path(__file__).resolve().parents[2] / "Velora/Sources/Velora/LocalModelEngines.swift").read_text()
        self.assertIn(f'environment["{MODEL_ENV}"] ?? "{SOURCE_DEFAULT_MODEL}"', source)

    def test_approved_baseline_is_the_source_default(self):
        self.assertEqual(SOURCE_DEFAULT_MODEL, "qwen3:8b")
        self.assertEqual(BASELINE_MODEL, "qwen3:8b")
        with self.assertRaises(ValueError):
            process_env("qwen3:14b", {})


class InvocationTests(unittest.TestCase):
    def test_command_sets_the_existing_env_and_does_not_copy(self):
        root = Path("/Users/alpha/workspace/velora")
        audio = Path("/tmp/clip.caf")
        command = swift_invocation(root, audio)
        self.assertNotIn("--copy", command)
        self.assertIn("--sensevoice", command)
        self.assertIn("--mode", command)
        self.assertEqual(command[command.index("--mode") + 1], "input")
        env = process_env(
            BASELINE_MODEL,
            {"HOME": "/Users/alpha", "VELORA_ALLOW_REMOTE_LLM": "1", MODEL_ENV: "qwen3:14b"},
        )
        self.assertEqual(env[MODEL_ENV], "qwen3:8b")
        self.assertNotIn("VELORA_ALLOW_REMOTE_LLM", env)

    def test_missing_model_has_zero_runs_and_no_milliseconds(self):
        report = missing_model_report(BASELINE_MODEL)
        encoded = json.dumps(report)
        self.assertEqual(report["n"], 0)
        self.assertEqual(report["runs"], [])
        self.assertFalse(report["model_present"])
        self.assertNotIn("release_to_insert_ms", encoded)
        self.assertNotIn("qwen3:8b measurement", encoded)


class RedactionTests(unittest.TestCase):
    def test_transcript_is_dropped_and_reload_is_kept(self):
        payload = {
            "finalText": "明天开会",
            "asr": {"text": "明天开会", "engine": "sensevoice.sherpa-onnx", "modelVersion": "int8"},
            "compose": {
                "engine": "ollama:qwen3:8b",
                "polishedText": "明天开会",
                "edits": [{"from": "明天开会", "to": "明天开会"}],
                "warnings": [
                    "ollama_model_reload:4200ms",
                    "compose_llm_error:private body",
                ],
            },
            "insertion": {"inserted": False, "strategy": "none"},
            "trace": {
                "stages": [
                    {"name": "asr", "durationMS": 40, "phase": "after_release", "critical": True},
                    {"name": "compose", "durationMS": 900, "phase": "after_release", "critical": True},
                ]
            },
        }
        row = redact_run(payload, audio_sha256="abc", audio_bytes=10, pass_index=0, exit_code=0)
        encoded = json.dumps(row, ensure_ascii=False)
        self.assertNotIn("明天开会", encoded)
        self.assertNotIn("private body", encoded)
        self.assertEqual(row["compose_engine"], "ollama:qwen3:8b")
        self.assertTrue(row["llm_error"])
        self.assertNotIn("private body", encoded)
        self.assertFalse(accepts_llm_baseline(row, "qwen3:8b"))
        self.assertEqual(row["asr_chars"], 4)
        self.assertEqual(row["release_to_insert_ms"], 940)
        self.assertEqual(row["ollama_reload_ms"], 4200)
        self.assertEqual(row["load_observation"], "reload_warning")
        self.assertEqual(row["redacted_warning_count"], 1)
        self.assertFalse(row["insertion_inserted"])

    def test_no_reload_warning_is_not_labeled_warm(self):
        payload = {
            "finalText": "",
            "asr": {"text": "", "engine": "sensevoice.sherpa-onnx"},
            "compose": {"engine": "ollama:qwen3:8b", "warnings": []},
            "trace": {"stages": []},
        }
        row = redact_run(payload, audio_sha256="abc", audio_bytes=1, pass_index=1, exit_code=0)
        self.assertEqual(row["load_observation"], "no_reload_warning")
        self.assertIsNone(row["ollama_reload_ms"])
        self.assertTrue(accepts_llm_baseline(row, "qwen3:8b"))

    def test_rules_and_fallbacks_are_not_an_llm_baseline(self):
        rules = redact_run(
            {
                "finalText": "明天开会",
                "asr": {"text": "明天开会", "engine": "sensevoice.sherpa-onnx"},
                "compose": {"engine": "rules", "warnings": ["compose_llm_error:Ollama 本地模型服务不可用。请先运行 Ollama，并确认 qwen3:8b 已下载。"]},
                "trace": {"stages": [{"name": "compose", "durationMS": 12, "phase": "after_release", "critical": True}]},
            },
            audio_sha256="abc",
            audio_bytes=4,
            pass_index=0,
            exit_code=0,
        )
        self.assertEqual(rules["compose_engine"], "rules")
        self.assertTrue(rules["llm_error"])
        self.assertNotIn("请先运行", json.dumps(rules, ensure_ascii=False))
        self.assertFalse(accepts_llm_baseline(rules, "qwen3:8b"))

        deadline = redact_run(
            {
                "asr": {"text": "", "engine": "sensevoice.sherpa-onnx"},
                "compose": {"engine": "rules", "warnings": ["compose_deadline_fallback:4000ms"]},
                "trace": {"stages": []},
            },
            audio_sha256="abc",
            audio_bytes=4,
            pass_index=1,
            exit_code=0,
        )
        self.assertEqual(deadline["deadline_fallback_ms"], 4000)
        self.assertFalse(accepts_llm_baseline(deadline, "qwen3:8b"))

        named = {
            "exit": 0,
            "compose_engine": "ollama:qwen3:8b",
            "llm_error": False,
            "rule_floor_used": True,
            "deadline_fallback_ms": None,
        }
        self.assertFalse(accepts_llm_baseline(named, "qwen3:8b"))
        self.assertFalse(accepts_llm_baseline({**named, "rule_floor_used": False, "compose_engine": "ollama:qwen3:14b"}, "qwen3:14b"))


class IdentityParserTests(unittest.TestCase):
    def test_two_line_show_keeps_digest_only(self):
        text = """
Model
    architecture        qwen3
Parameters
    14.8B
Quantization
    Q4_K_M
Digest
    sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
FROM ./Modelfile
SYSTEM you are a long private prompt
"""
        parsed = parse_ollama_show(text)
        self.assertEqual(parsed["parameters"], "14.8B")
        self.assertEqual(parsed["quantization"], "Q4_K_M")
        self.assertEqual(parsed["digest"], "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        self.assertNotIn("private prompt", json.dumps(parsed))

    def test_api_show_drops_the_modelfile_prompt(self):
        parsed = parse_api_show(
            {
                "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "modelfile": "SYSTEM 明天开会",
                "details": {"parameter_size": "14.8B", "quantization_level": "Q4_K_M"},
            }
        )
        encoded = json.dumps(parsed, ensure_ascii=False)
        self.assertEqual(parsed["parameters"], "14.8B")
        self.assertEqual(parsed["quantization"], "Q4_K_M")
        self.assertNotIn("明天开会", encoded)
        self.assertNotIn("modelfile", encoded)

    def test_stderr_and_process_list_do_not_keep_text(self):
        kept = keep_time_lines("        1.20 real         0.80 user         0.10 sys\n明天开会\n            1024  maximum resident set size\n")
        self.assertNotIn("明天开会", kept)
        self.assertIn("maximum resident set size", kept)
        rss = parse_rss("12345 /usr/local/bin/ollama serve\n999 python3 scripts/sensevoice_sidecar.py\n1 say 明天开会\n")
        encoded = json.dumps(rss, ensure_ascii=False)
        self.assertEqual(rss["ollama_rss_kb"], 12345)
        self.assertEqual(rss["sensevoice_rss_kb"], 999)
        self.assertNotIn("明天开会", encoded)


if __name__ == "__main__":
    unittest.main()
