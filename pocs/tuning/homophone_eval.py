#!/usr/bin/env python3
"""Context-based ASR homophone correction eval for the polish prompt."""
import json
import time
import urllib.request

OLLAMA = "http://127.0.0.1:11434/api/generate"

TEXTS = [
    # ASR 同音误识：上下文能确定原意，应当修正
    {"id": "hp_timeout", "text": "这个接口超市了你看下日志", "contains": ["接口超时"], "absent": ["超市"]},
    # These three are seeded production hotwords. Mirror composeWithLLM's
    # sound_alike block instead of evaluating an unrealistically signal-free
    # prompt after pretending the deterministic correction tier did not run.
    {"id": "hp_release_note", "text": "帮我把发不说明整理一下再发出去", "glossary": "发不说明 / 发布说明", "contains": ["发布说明"], "absent": ["发不说明"]},
    {"id": "hp_agenda", "text": "下午的会先过一遍疑程", "glossary": "疑程 / 议程", "contains": ["议程"], "absent": ["疑程"]},
    {"id": "hp_regression", "text": "把回归册是跑完再上线", "glossary": "回归册是 / 回归测试", "contains": ["回归测试"], "absent": ["回归册是"]},
    {"id": "hp_feedback", "text": "有个用户反愦了一个登录的问题", "contains": ["反馈"], "absent": ["反愦"]},
    {"id": "hp_rollout", "text": "这个功能还在灰度先别全量方开", "contains": ["放开"], "absent": ["方开"]},
    # 防误杀：同音词在此语境下是本意，禁止改
    {"id": "guard_supermarket", "text": "我下班去趟超市买点东西", "contains": ["超市"], "absent": ["超时"]},
    {"id": "guard_roster", "text": "这份名册是最新的你直接用", "contains": ["名册"], "absent": ["测试"]},
    {"id": "guard_steady", "text": "先把需求文档稳稳当当过一遍", "contains": ["稳"], "absent": []},
    {"id": "guard_ambiguous", "text": "他说想去看看那个新开的超市", "contains": ["超市"], "absent": ["超时"]},
]

CANDIDATES = json.load(open("/tmp/velora-eval/homophone_candidates.json"))


def call(model, system, prompt, options):
    payload = {"model": model, "system": system, "prompt": prompt, "stream": False,
               "keep_alive": "30m", "think": False, "format": "json", "options": options}
    req = urllib.request.Request(OLLAMA, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = json.loads(resp.read())
    return body, int((time.monotonic() - t0) * 1000)


results = []
for cand in CANDIDATES:
    profile = "work_chat: concise paragraphs with light punctuation; avoid formal email framing"
    call(cand["model"], cand["system"], f"app_format_profile={profile}\n输入：预热", {**cand["options"], "num_predict": 8})
    for item in TEXTS:
        prompt = f"app_format_profile={profile}\n"
        if item.get("glossary"):
            prompt += f"sound_alike:\n{item['glossary']}\n"
        prompt += f"输入：{item['text']}"
        body, wall = call(cand["model"], cand["system"], prompt, cand["options"])
        try:
            polished = json.loads(body.get("response", "")).get("polished", "") or ""
        except json.JSONDecodeError:
            polished = "<PARSE_FAIL>"
        ok = all(c in polished for c in item["contains"]) and all(a not in polished for a in item["absent"])
        results.append({"cand": cand["id"], "text": item["id"], "ok": ok, "polished": polished, "wall": wall})
        print(f"{cand['id']:16s} {item['id']:18s} {'PASS' if ok else 'FAIL'}  {polished[:70]}", flush=True)

json.dump(results, open("/tmp/velora-eval/homophone-results.json", "w"), ensure_ascii=False, indent=1)
for cand in CANDIDATES:
    rs = [r for r in results if r["cand"] == cand["id"]]
    print(f"== {cand['id']}: {sum(r['ok'] for r in rs)}/{len(rs)} pass")
if any(not r["ok"] for r in results):
    raise SystemExit(1)
