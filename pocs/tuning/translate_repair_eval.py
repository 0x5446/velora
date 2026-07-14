#!/usr/bin/env python3
"""Translate-mode self-repair eval: polished keeps only the corrected version
AND target translates only the corrected version; guards must survive."""
import json, os, time, urllib.request

OLLAMA = "http://127.0.0.1:11434/api/generate"
SYSTEM = open("/tmp/velora-eval/translate_system.txt").read()
MODEL = os.environ.get("VELORA_OLLAMA_MODEL", "qwen3:8b")
OPTS = {"temperature": 0.1, "num_ctx": 4096, "repeat_penalty": 1.0, "num_predict": 640}

CASES = [
    {"id": "soft_should_be", "text": "预算大概五万应该是八万",
     "pol_has": ["八万"], "pol_not": ["五万"], "tgt_has": ["80"], "tgt_not": ["50"]},
    {"id": "casual_switch", "text": "周三开会啊不周四下午三点算了还是周五上午吧",
     "pol_has": ["周五"], "pol_not": ["周三", "周四"], "tgt_has": ["Friday"], "tgt_not": ["Wednesday", "Thursday"]},
    {"id": "three_way", "text": "发给小王吧不对小李算了还是发给小张",
     "pol_has": ["小张"], "pol_not": ["小王", "小李"], "tgt_has": [], "tgt_not": []},
    {"id": "time_repair", "text": "会议定在周三吧不对周四下午三点",
     "pol_has": ["周四"], "pol_not": ["周三"], "tgt_has": ["Thursday"], "tgt_not": ["Wednesday"]},
    {"id": "restate", "text": "这个方案我觉得可以我是说前面那个方案可以",
     "pol_has": ["前面那个方案"], "pol_not": ["我是说"], "tgt_has": [], "tgt_not": []},
    # guards
    {"id": "no_repair_quote", "text": "他说的不是周三是周四你确认一下",
     "pol_has": ["不是周三", "周四"], "pol_not": [], "tgt_has": ["Thursday"], "tgt_not": []},
    {"id": "no_repair_negation", "text": "我不是本地人是从北京过来的",
     "pol_has": ["不是本地人", "北京"], "pol_not": [], "tgt_has": ["Beijing"], "tgt_not": []},
    {"id": "no_repair_clean", "text": "明天上午十点开会帮我确认一下议程",
     "pol_has": ["十点", "议程"], "pol_not": [], "tgt_has": ["10", "agenda"], "tgt_not": []},
]

def call(prompt):
    payload = {"model": MODEL, "system": SYSTEM, "prompt": prompt, "stream": False,
               "keep_alive": "30m", "think": False, "format": "json", "options": OPTS}
    req = urllib.request.Request(OLLAMA, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=90) as resp:
        return json.loads(resp.read()), int((time.monotonic() - t0) * 1000)

PROFILE = "work_chat: short paragraphs, one independent topic per paragraph, light punctuation; avoid formal email framing"
call(f"app_format_profile={PROFILE}\nsource_language=zh\ntarget_language=en\n输入：预热")
results = []
for c in CASES:
    body, ms = call(f"app_format_profile={PROFILE}\nsource_language=zh\ntarget_language=en\n输入：{c['text']}")
    try:
        obj = json.loads(body.get("response", ""))
        pol, tgt = obj.get("polished", "") or "", obj.get("target", "") or ""
    except json.JSONDecodeError:
        pol, tgt = "<PARSE_FAIL>", ""
    ok = (all(x in pol for x in c["pol_has"]) and all(x not in pol for x in c["pol_not"])
          and all(x in tgt for x in c["tgt_has"]) and all(x not in tgt for x in c["tgt_not"]))
    results.append({"case": c["id"], "ok": ok, "ms": ms, "polished": pol, "target": tgt})
    print(f"{c['id']:20s} {'PASS' if ok else 'FAIL'}  pol={pol[:40]} | tgt={tgt[:50]}", flush=True)

json.dump(results, open("/tmp/velora-eval/translate-repair-results.json", "w"), ensure_ascii=False, indent=1)
print(f"== {sum(r['ok'] for r in results)}/{len(results)} pass")
if any(not r["ok"] for r in results):
    raise SystemExit(1)
