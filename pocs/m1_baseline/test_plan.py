"""Checks for the M1 collector plan. No Swift, no Ollama, no invented timings."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from plan import (
    BASELINE_MODEL,
    MODEL_ENV,
    SOURCE_DEFAULT_MODEL,
    accepts_llm_baseline,
    assert_model_env_matches_source,
    failure_class,
    identity_from_show_and_tags,
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
        supplement = (Path(__file__).resolve().parents[2] / "docs/evidence/m1/supplement_blocked.sh").read_text()
        self.assertIn('VELORA_M1_RSS_SUPPLEMENT:-0', supplement)
        self.assertIn('VELORA_M1_COLLECTOR:-', supplement)
        self.assertIn("collector_status=0", supplement)
        self.assertNotRegex(supplement, r"(?m)^status=")
        self.assertNotIn("ollama pull", supplement)
        self.assertNotIn("ollama rm", supplement)
        self.assertNotIn("cartesia", supplement.lower())


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
        self.assertEqual(failure_class(rules), "rules")
        self.assertEqual(failure_class(deadline), "deadline_fallback")
        self.assertEqual(failure_class(named), "rule_floor")
        clean = {**named, "rule_floor_used": False}
        self.assertEqual(failure_class(clean), "llm")


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
        rss = parse_rss(
            "12345 /usr/local/bin/ollama serve\n"
            "999 python3 scripts/sensevoice_sidecar.py\n"
            "5196160 llama-server\n"
            "1 say 明天开会\n"
        )
        encoded = json.dumps(rss, ensure_ascii=False)
        self.assertEqual(rss["ollama_rss_kb"], 12345)
        self.assertEqual(rss["sensevoice_rss_kb"], 999)
        self.assertEqual(rss["llama_server_rss_kb"], 5196160)
        self.assertNotIn("明天开会", encoded)


class ZshSupplementTests(unittest.TestCase):
    script = Path(__file__).resolve().parents[2] / "docs/evidence/m1/supplement_blocked.sh"

    def test_this_zsh_rejects_assigning_status(self):
        probe = subprocess.run(["zsh", "-c", "status=0"], capture_output=True, text=True)
        self.assertNotEqual(probe.returncode, 0)
        self.assertIn("read-only variable: status", probe.stderr)

    def test_zsh_runs_the_collector_when_a_failure_sample_exits_1(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log = root / "collector.log"
            stub = root / "collector.sh"
            stub.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$STUB_LOG\"\nexit \"$STUB_EXIT\"\n",
                encoding="utf-8",
            )
            stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
            env = os.environ.copy()
            env.update(
                {
                    "VELORA_M1_RSS_SUPPLEMENT": "1",
                    "VELORA_M1_COLLECTOR": str(stub),
                    "VELORA_ROOT": str(root),
                    "VELORA_M1_OUT": str(root / "out"),
                    "STUB_LOG": str(log),
                    "STUB_EXIT": "1",
                }
            )
            proc = subprocess.run(
                ["zsh", str(self.script), "short.caf", "zh_long.caf"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("collector_exit=1", proc.stdout)
            self.assertIn("snapshots, not peaks", proc.stdout)
            self.assertEqual(log.read_text(encoding="utf-8").strip(), "short.caf zh_long.caf")

            env["STUB_EXIT"] = "2"
            refused = subprocess.run(
                ["zsh", str(self.script), "short.caf", "zh_long.caf"],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(refused.returncode, 2, refused.stderr)
            self.assertIn("collector_exit=2", refused.stdout)

            env.pop("VELORA_M1_RSS_SUPPLEMENT")
            skipped = subprocess.run(
                ["zsh", str(self.script)],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(skipped.returncode, 0, skipped.stderr)
            self.assertIn("RSS supplement not requested", skipped.stdout)


class Ollama040DigestTests(unittest.TestCase):
    def test_tags_digest_is_not_the_wrapper_manifest_hash(self):
        registry = "500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41"
        wrapper = "b3d9ba7c" + ("ab" * 28)
        parsed = identity_from_show_and_tags(
            {
                "details": {"parameter_size": "8.2B", "quantization_level": "Q4_K_M"},
                "modelfile": "SYSTEM secret",
            },
            {
                "models": [
                    {"name": "qwen3:8b", "digest": "sha256:" + registry},
                    {"name": "qwen3:14b", "digest": "sha256:" + ("cd" * 32)},
                ]
            },
            "qwen3:8b",
            wrapper_manifest_sha256="sha256:" + wrapper,
        )
        self.assertEqual(parsed["digest"], registry)
        self.assertEqual(parsed["digest_source"], "/api/tags (show details validated)")
        self.assertEqual(parsed["parameters"], "8.2B")
        self.assertEqual(parsed["quantization"], "Q4_K_M")
        self.assertEqual(parsed["wrapper_manifest_sha256"], wrapper)
        self.assertNotEqual(parsed["digest"], parsed["wrapper_manifest_sha256"])
        self.assertNotIn("secret", json.dumps(parsed))
        wrong_name = identity_from_show_and_tags(
            {"details": {"parameter_size": "8.2B", "quantization_level": "Q4_K_M"}},
            {"models": [{"name": "qwen3:8b:latest", "digest": registry}]},
            "qwen3:8b",
            wrapper_manifest_sha256=wrapper,
        )
        self.assertIsNone(wrong_name["digest"])
        self.assertEqual(wrong_name["wrapper_manifest_sha256"], wrapper)

    def test_missing_show_details_or_show_error_does_not_borrow_a_tag(self):
        registry = "500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41"
        tags = {"models": [{"name": "qwen3:8b", "digest": registry}]}
        errored = identity_from_show_and_tags({"error": "model not found"}, tags, "qwen3:8b")
        self.assertIsNone(errored["digest"])
        incomplete = identity_from_show_and_tags(
            {"details": {"parameter_size": "8.2B"}},
            tags,
            "qwen3:8b",
        )
        self.assertIsNone(incomplete["digest"])

    def test_show_digest_is_kept_when_present(self):
        shown = "a" * 64
        parsed = identity_from_show_and_tags(
            {
                "digest": "sha256:" + shown,
                "details": {"parameter_size": "8.2B", "quantization_level": "Q4_K_M"},
            },
            {"models": [{"name": "qwen3:8b", "digest": "b" * 64}]},
            "qwen3:8b",
        )
        self.assertEqual(parsed["digest"], shown)
        self.assertEqual(parsed["digest_source"], "/api/show")


if __name__ == "__main__":
    unittest.main()
