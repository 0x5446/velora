"""Replay confirmed-transcript events. One final commit, or none.

Events are cumulative confirmed text, which is what LocalPolisher consumes.
Identity is the text itself. Two strings of equal length and different
characters are different events. This harness injects a caller-supplied
model; a passing test is not MLX token identity.

This is not SenseVoice whole-file re-recognition, and it does not insert text
on intermediate endpoints. A result whose job id is no longer current is dropped.
"""

from __future__ import annotations

from polisher import Cancelled


class SessionError(RuntimeError):
    pass


class CancelFlag:
    def __init__(self):
        self._set = False

    def set(self):
        self._set = True

    def is_set(self):
        return self._set


class Session:
    def __init__(self, polish, inline=True):
        self.polish = polish
        self.inline = inline
        self.job_id = 0
        self.current = None
        self.draft = []
        self.jobs = []
        self.dropped = []
        self.commits = []
        self.awaiting_commit = False
        self.faulted = False
        self.focus_changes = 0

    def replay(self, events):
        for event in events:
            self.handle(event)
        return self.report()

    def handle(self, event):
        kind = event["kind"]
        if kind == "focus_change":
            self.focus_changes += 1
            return
        if kind == "cancel_session":
            self._abort("cancel_session")
            return
        if kind == "asr_fault":
            self._abort("asr_fault")
            return
        if self.faulted:
            raise SessionError("event after abort: %s" % kind)
        if kind == "endpoint":
            self._start(event["confirmed_text"])
            return
        if kind == "end":
            self._end(event["confirmed_text"])
            return
        raise SessionError("unknown event %s" % kind)

    def complete(self, job_id, output, stats):
        """Manual mode: deliver a finished generation. Stale ids are dropped."""
        if self.faulted or self.current is None or self.current["id"] != job_id or self.current["cancel"].is_set():
            self.dropped.append({"id": job_id, "reason": "stale"})
            return False
        self._adopt(output, stats)
        if self.awaiting_commit:
            self._commit()
        return True

    def report(self):
        requests = []
        for job in self.jobs:
            if "stats" not in job:
                continue
            stats = job["stats"]
            requests.append(
                {
                    "id": job["id"],
                    "text": job["text"],
                    "prefill_tokens": stats["prefill_tokens"],
                    "verify_tokens": stats["verify_tokens"],
                    "generate_tokens": stats["generate_tokens"],
                    "accepted": stats["accepted"],
                    "proposed": stats["proposed"],
                    "reused": stats["reused"],
                    "rolled_back": stats["rolled_back"],
                    "out_tokens": stats["out_tokens"],
                }
            )
        return {
            "schema": "velora.speculative_replay.report.v1",
            "model": "injected_cpu_mock",
            "mlx_token_identity": None,
            "t4_ms": None,
            "milliseconds": None,
            "commit_count": len(self.commits),
            "commits": [
                {"text": item["text"], "out_tokens": len(item["out"])} for item in self.commits
            ],
            "requests": requests,
            "dropped_stale": len(self.dropped),
            "focus_changes": self.focus_changes,
            "faulted": self.faulted,
            "request_prefill_tokens": sum(item["prefill_tokens"] for item in requests),
            "final_request": requests[-1] if requests else None,
        }

    def _abort(self, reason):
        if self.current is not None:
            self.current["cancel"].set()
            if not self.current.get("done"):
                self.dropped.append({"id": self.current["id"], "reason": reason})
        self.current = None
        self.awaiting_commit = False
        self.faulted = True
        self.commits = []

    def _start(self, text):
        if self.commits:
            raise SessionError("generation started after commit")
        if self.current is not None and not self.current.get("done"):
            self.current["cancel"].set()
        self.job_id += 1
        job = {
            "id": self.job_id,
            "text": text,
            "draft": list(self.draft),
            "cancel": CancelFlag(),
            "done": False,
        }
        self.jobs.append(job)
        self.current = job
        self.awaiting_commit = False
        if self.inline:
            self._run(job)

    def _run(self, job):
        try:
            output, stats = self.polish(job["text"], job["draft"], job["cancel"])
        except Cancelled:
            self.dropped.append({"id": job["id"], "reason": "cancelled"})
            return
        if job["cancel"].is_set() or self.current is None or self.current["id"] != job["id"]:
            self.dropped.append({"id": job["id"], "reason": "stale"})
            return
        self._adopt(output, stats)

    def _adopt(self, output, stats):
        self.current["done"] = True
        self.current["out"] = list(output)
        self.current["stats"] = stats
        self.draft = list(output)

    def _end(self, text):
        if self.commits:
            raise SessionError("second end")
        if self.current is None or self.current["text"] != text or not self.current.get("done"):
            if self.current is not None and self.current["text"] == text and not self.current.get("done"):
                self.awaiting_commit = True
                return
            self._start(text)
        if self.current is None or self.current["text"] != text or not self.current.get("done"):
            self.awaiting_commit = True
            return
        self._commit()

    def _commit(self):
        if self.faulted:
            raise SessionError("commit after fault")
        if self.commits:
            raise SessionError("second commit")
        if self.current is None or not self.current.get("done") or "out" not in self.current:
            raise SessionError("commit without a finished generation")
        self.commits.append(
            {"text": self.current["text"], "out": list(self.current["out"]), "stats": self.current["stats"]}
        )
        self.awaiting_commit = False
