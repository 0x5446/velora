#!/usr/bin/env python3
"""Filler (口癖) eval: does polish delete meaningless discourse fillers WITHOUT
touching demonstratives, copular 就是, sequential 然后, or mood particles?

All sentences are SYNTHETIC. They model filler constructs observed in real
usage (hedge 那个/这个, hedge 就是, X啊这些, 然后-chains) but share no content
words with real dictation and no full sentence skeleton with the inputSystem
few-shots — few-shot overlap would test recitation, not generalization. Do not
paste journal utterances in here: this file ships in a public repo.
"""
import json
import time
import urllib.request

OLLAMA = "http://127.0.0.1:11434/api/generate"

# absent: substrings that must NOT appear in polished output
# present: substrings that MUST survive
# max_count: {substring: n} — at most n occurrences allowed
CASES = [
    # --- removal: hedge/filler constructs ---
    {"id": "inline_nage", "text": "冰箱里没有那个过期的牛奶了对吧",
     "absent": ["那个"], "present": ["对吧", "过期"]},
    {"id": "zhege_a_zhexie", "text": "帮我把这个错别字啊这些都清理一下",
     "absent": ["这个", "啊这些"], "present": ["错别字"]},
    {"id": "jiushi_hedge", "text": "我感觉就是这版界面比上一版清爽",
     "absent": ["就是"], "present": ["界面"]},
    {"id": "zhege_nage_stutter", "text": "麻烦把这个那个部署文档更新一下",
     "absent": ["这个那个"], "present": ["部署文档"]},
    # Sentence-initial 然后 is deliberately allowed to survive: dictated
    # utterances are often continuations of a previous message. Only the
    # mid-sentence duplicate must go (3 in input -> at most 2).
    {"id": "ranhou_chain", "text": "然后我就想说然后我们可以先灰度然后再全量",
     "present": ["灰度"], "max_count": {"然后": 2}},
    # --- guards: same surface forms, load-bearing ---
    {"id": "guard_demonstrative_zhege", "text": "这个接口超时了你看下是不是后端的问题",
     "present": ["这个接口"]},
    {"id": "guard_demonstrative_nage", "text": "那个新开的超市周末去看看",
     "present": ["那个"]},
    {"id": "guard_jiushi_copula", "text": "他就是负责人你直接找他",
     "present": ["就是"]},
    {"id": "guard_ranhou_seq", "text": "先拉最新代码然后跑测试",
     "present": ["然后"]},
    {"id": "guard_mood_a", "text": "今天天气挺好啊出去走走",
     "present": ["好啊"]},
    {"id": "guard_duiba", "text": "部署脚本已经没问题了对吧",
     "present": ["对吧"]},
]

CANDS = json.load(open("/tmp/velora-eval/filler_candidates.json"))
PROFILE = "developer: preserve code identifiers, paths, flags, acronyms, and Markdown; use lists only for explicit enumerations; split clearly independent topics into separate paragraphs"


def call(model, system, prompt, options):
    payload = {"model": model, "system": system, "prompt": prompt, "stream": False,
               "keep_alive": "30m", "think": False, "format": "json", "options": options}
    req = urllib.request.Request(OLLAMA, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read()), int((time.monotonic() - t0) * 1000)


results = []
for cand in CANDS:
    call(cand["model"], cand["system"], f"app_format_profile={PROFILE}\n输入：预热", {**cand["options"], "num_predict": 8})
    for case in CASES:
        body, ms = call(cand["model"], cand["system"], f"app_format_profile={PROFILE}\n输入：{case['text']}", cand["options"])
        try:
            pol = json.loads(body.get("response", "")).get("polished", "") or ""
        except json.JSONDecodeError:
            pol = "<PARSE_FAIL>"
        fails = []
        if pol == "<PARSE_FAIL>" or not pol:
            fails.append("parse")
        for s in case.get("absent", []):
            if s in pol:
                fails.append(f"kept:{s}")
        for s in case.get("present", []):
            if s not in pol:
                fails.append(f"lost:{s}")
        for s, n in case.get("max_count", {}).items():
            if pol.count(s) > n:
                fails.append(f"count:{s}>{n}")
        ok = not fails
        results.append({"cand": cand["id"], "case": case["id"], "ok": ok,
                        "fails": fails, "ms": ms, "polished": pol})
        print(f"{cand['id']:16s} {case['id']:24s} {'PASS' if ok else 'FAIL ' + ','.join(fails):24s} {pol[:60].replace(chr(10), '/')}", flush=True)

json.dump(results, open("/tmp/velora-eval/filler-results.json", "w"), ensure_ascii=False, indent=1)
for cand in CANDS:
    rs = [r for r in results if r["cand"] == cand["id"]]
    print(f"== {cand['id']}: {sum(r['ok'] for r in rs)}/{len(rs)}")
if any(not r["ok"] for r in results):
    raise SystemExit(1)
