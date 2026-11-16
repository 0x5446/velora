"""Desensitized endpoint traces and the timing contract.

This module does not load a model and does not measure milliseconds. A CPU
replay may count tokens. Milliseconds appear only when classifying a citation
of the already archived Mac request-completion summary, and those citations
keep ``t4_ms`` null.
"""

from __future__ import annotations

from polisher import HashLM, TokenPolisher


class ContractError(ValueError):
    pass


SCHEMA_ENDPOINT = "velora.endpoint_trace.v1"
SCHEMA_BLOCK = "velora.block_trace.v1"

_BANNED_FIELDS = frozenset(
    {
        "text",
        "transcript",
        "confirmed_text",
        "oral",
        "asr",
        "prompt",
        "hypothesis",
        "output_text",
        "draft_text",
        "audio_path",
        "wav_path",
        "pcm_path",
        "journal",
        "raw",
    }
)

_ENDPOINT_KINDS = frozenset({"endpoint", "end", "focus_change", "cancel_session", "asr_fault"})
_TOKEN_KINDS = frozenset({"endpoint", "end"})


def collect_endpoints(rows, *, source, corpus_id, representative=False):
    """Build an endpoint trace from numeric metadata.

    ``source`` is ``synthetic`` or ``public_frozen_corpus``. A row that carries
    a transcript, a path, or any string is refused. ``t4_ms`` is always null.
    """
    if source not in {"synthetic", "public_frozen_corpus"}:
        raise ContractError("collector accepts only synthetic or public_frozen_corpus metadata")
    if not isinstance(corpus_id, str) or not corpus_id or "/" in corpus_id:
        raise ContractError("corpus_id must be a public id, not a path")
    if source == "synthetic" and representative:
        raise ContractError("a synthetic trace cannot be marked representative")
    events = []
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ContractError("endpoint row must be an object")
        banned = _BANNED_FIELDS.intersection(row)
        if banned:
            raise ContractError("refusing text or path field: %s" % ",".join(sorted(banned)))
        kind = row.get("kind", "endpoint")
        if kind not in _ENDPOINT_KINDS:
            raise ContractError("unknown endpoint kind")
        for key, value in row.items():
            if key == "kind":
                continue
            if isinstance(value, str):
                raise ContractError("string field %s is not endpoint metadata" % key)
        event = {"index": index, "kind": kind}
        if kind in _TOKEN_KINDS:
            if "confirmed_tokens" not in row:
                raise ContractError("confirmed_tokens required")
            confirmed = _nonneg_int(row["confirmed_tokens"], "confirmed_tokens")
            if confirmed < 1:
                raise ContractError("confirmed_tokens must be positive")
            event["confirmed_tokens"] = confirmed
            if "new_tokens" in row and row["new_tokens"] is not None:
                event["new_tokens"] = _nonneg_int(row["new_tokens"], "new_tokens")
            else:
                event["new_tokens"] = None
        if "trailing_silence_ms" in row and row["trailing_silence_ms"] is not None:
            silence = row["trailing_silence_ms"]
            if isinstance(silence, bool) or not isinstance(silence, (int, float)) or silence < 0:
                raise ContractError("trailing_silence_ms must be a non-negative number or null")
            event["trailing_silence_ms"] = silence
        else:
            event["trailing_silence_ms"] = None
        events.append(event)
    if not any(event["kind"] == "endpoint" for event in events):
        raise ContractError("trace needs at least one endpoint")
    return {
        "schema": SCHEMA_ENDPOINT,
        "source": source,
        "corpus_id": corpus_id,
        "representative": bool(representative),
        "t4_ms": None,
        "hardware_ms": None,
        "events": events,
    }


def validate_endpoint_trace(trace):
    if trace.get("schema") != SCHEMA_ENDPOINT:
        raise ContractError("endpoint schema")
    if trace.get("t4_ms") is not None or trace.get("hardware_ms") is not None:
        raise ContractError("an endpoint trace cannot carry T4 or hardware milliseconds")
    if trace.get("source") == "synthetic" and trace.get("representative"):
        raise ContractError("a synthetic trace cannot be marked representative")
    if "speedup" in trace:
        raise ContractError("an endpoint trace has no speedup")
    return trace


def replay_endpoint_trace(trace, *, vocab=48, seed=0, k=4, kmax=16, max_tokens=8):
    """Replay token lengths through the fake argmax model.

    The report counts prefill, verify, and generate tokens and records each
    block's context length, block length, and accepted count. It does not
    invent milliseconds, a speedup, or a T4.
    """
    validate_endpoint_trace(trace)
    if trace.get("source") not in {"synthetic", "public_frozen_corpus"}:
        raise ContractError("token replay does not replay a recorded timing row")
    model = HashLM(vocab, seed)
    polisher = TokenPolisher(model, eos=set(), k=k, kmax=kmax)
    requests = []
    draft = []
    last_confirmed = None
    end_started_generation = False
    for event in trace["events"]:
        kind = event["kind"]
        if kind in {"focus_change", "cancel_session", "asr_fault"}:
            continue
        if kind not in _TOKEN_KINDS:
            raise ContractError("unknown endpoint kind")
        confirmed = event["confirmed_tokens"]
        if kind == "end" and last_confirmed is not None and confirmed == last_confirmed:
            continue
        if kind == "end":
            end_started_generation = True
        prompt = [((index * 17) + 3) % vocab for index in range(confirmed)]
        draft_tokens = len(draft)
        _out, stats = polisher.polish(prompt, draft=draft, max_tokens=max_tokens)
        _reject_elapsed(stats["blocks"])
        proposed = stats["proposed"]
        requests.append(
            {
                "kind": kind,
                "prompt_tokens": confirmed,
                "draft_tokens": draft_tokens,
                "window": k,
                "kmax": kmax,
                "accepted": stats["accepted"],
                "proposed": proposed,
                "acceptance": (stats["accepted"] / proposed) if proposed else None,
                "prefill_tokens": stats["prefill_tokens"],
                "verify_tokens": stats["verify_tokens"],
                "generate_tokens": stats["generate_tokens"],
                "blocks": stats["blocks"],
            }
        )
        draft = list(_out)
        last_confirmed = confirmed
    return {
        "schema": SCHEMA_BLOCK,
        "source": "cpu_replay",
        "t4_ms": None,
        "milliseconds": None,
        "requests": requests,
        "end_started_another_generation": end_started_generation,
    }


def group_blocks(trace):
    """Group blocks by phase, context length, block length, and acceptance.

    Every group leaves ``elapsed_ms`` null. This is the split a later recorded
    block log has to fill; the CPU replay only shows that the buckets exist.
    """
    validate_block_trace(trace)
    if trace.get("source") != "cpu_replay":
        raise ContractError("group_blocks on a CPU replay does not import recorded milliseconds")
    grouped = {}
    for request in trace["requests"]:
        for block in request["blocks"]:
            _reject_elapsed([block])
            if block["phase"] == "prefill":
                band = "prefill"
            else:
                band = _acceptance_band(block["accepted"], block["block_len"])
            key = (block["phase"], block["context_tokens"], block["block_len"], band)
            grouped[key] = grouped.get(key, 0) + 1
    return {
        "t4_ms": None,
        "milliseconds": None,
        "groups": [
            {
                "phase": phase,
                "context_tokens": context_tokens,
                "block_len": block_len,
                "acceptance_band": band,
                "count": count,
                "elapsed_ms": None,
            }
            for (phase, context_tokens, block_len, band), count in sorted(grouped.items())
        ],
    }


def validate_block_trace(trace):
    if trace.get("schema") != SCHEMA_BLOCK:
        raise ContractError("block schema")
    if trace.get("t4_ms") is not None or trace.get("milliseconds") is not None:
        raise ContractError("a block trace cannot carry T4")
    if "speedup" in trace or "speedup_ratio" in trace:
        raise ContractError("a block trace has no speedup")
    source = trace.get("source")
    if source not in {"cpu_replay", "recorded_block_log"}:
        raise ContractError("block trace source")
    if trace.get("representative") and trace.get("constructed_repeat"):
        raise ContractError("a constructed repeat cannot be representative")
    requests = trace.get("requests")
    if not isinstance(requests, list) or not requests:
        raise ContractError("block trace needs requests")
    for request in requests:
        if request.get("constructed_repeat") and request.get("representative"):
            raise ContractError("a constructed repeat cannot be representative")
        blocks = request.get("blocks")
        if not isinstance(blocks, list) or not blocks:
            raise ContractError("request needs blocks")
        for block in blocks:
            for key in ("phase", "context_tokens", "block_len", "accepted"):
                if key not in block:
                    raise ContractError("block missing %s" % key)
            if block["phase"] not in {"prefill", "verify", "generate"}:
                raise ContractError("block phase")
            elapsed = block.get("elapsed_ms", None)
            if source == "cpu_replay" and elapsed is not None:
                raise ContractError("cpu replay cannot carry elapsed_ms")
            if source == "recorded_block_log" and block["phase"] != "prefill" and elapsed is None:
                raise ContractError("recorded verify/generate block needs elapsed_ms")
            if isinstance(elapsed, bool) or (elapsed is not None and not isinstance(elapsed, (int, float))):
                raise ContractError("elapsed_ms")
    return trace


def classify_recorded_request(row):
    """Split one archived request-completion citation.

    The numbers are copied from the Mac summary. They are not recomputed, and
    they are not a T4. Per-block lengths and per-block milliseconds stay null
    until a recorded block log exists.
    """
    if row.get("source") != "recorded_request_completion":
        raise ContractError("only an archived request-completion citation can carry milliseconds")
    if row.get("t4_ms") is not None:
        raise ContractError("request completion is not T4")
    for banned in ("speedup", "speedup_ratio", "t4_p50_ms", "t4_p90_ms"):
        if banned in row:
            raise ContractError("do not summarize this citation as a speedup or a T4")
    if row.get("representative"):
        raise ContractError("this citation is not a representative natural-dictation sample")
    if row.get("constructed_repeat") and row.get("representative"):
        raise ContractError("a constructed repeat cannot be representative")
    if row.get("block_lengths_observed") is not None:
        raise ContractError("the archived summary has no per-block lengths; do not invent them")
    accepted = _nonneg_int(row["accepted"], "accepted")
    proposed = _nonneg_int(row["proposed"], "proposed")
    if proposed < 1:
        raise ContractError("proposed")
    if row.get("draft_tokens") == accepted and accepted != row.get("output_tokens"):
        raise ContractError("accepted tokens are not the draft length")
    prefill = _millis(row["prefill_ms"])
    verify = _millis(row["verify_ms"])
    generate = _millis(row["generate_ms"])
    total = _millis(row["request_completion_ms"])
    draft_tokens = row.get("draft_tokens")
    if draft_tokens is not None:
        draft_tokens = _nonneg_int(draft_tokens, "draft_tokens")
    return {
        "id": row["id"],
        "t4_ms": None,
        "prompt_tokens": _nonneg_int(row["prompt_tokens"], "prompt_tokens"),
        "output_tokens": _nonneg_int(row["output_tokens"], "output_tokens"),
        "window": _nonneg_int(row["window"], "window"),
        "draft_tokens": draft_tokens,
        "accepted": accepted,
        "proposed": proposed,
        "acceptance": accepted / proposed,
        "prefill_ms": prefill,
        "verify_ms": verify,
        "generate_ms": generate,
        "request_completion_ms": total,
        "component_sum_ms": prefill + verify + generate,
        "components_equal_request": (prefill + verify + generate) == total,
        "verify_is_largest_component": verify > prefill and verify > generate,
        "representative": False,
        "constructed_repeat": bool(row.get("constructed_repeat")),
        "may_generalize": False,
        "accepted_exceeds_draft": draft_tokens is not None and accepted > draft_tokens,
        "block_lengths_observed": None,
        "per_block_milliseconds": None,
        "citation": row.get("citation"),
    }


def _acceptance_band(accepted, block_len):
    if block_len <= 0:
        raise ContractError("block_len")
    if accepted == 0:
        return "0"
    if accepted == block_len:
        return "1"
    if accepted < 0 or accepted > block_len:
        raise ContractError("accepted outside block")
    return "partial"


def _reject_elapsed(blocks):
    for block in blocks:
        if block.get("elapsed_ms") is not None:
            raise ContractError("cpu replay cannot carry elapsed_ms")


def _nonneg_int(value, name):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ContractError(name)
    return value


def _millis(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
        raise ContractError("milliseconds")
    return value
