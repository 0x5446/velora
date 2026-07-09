#!/usr/bin/env python3
"""Contextual-correction eval: glossary/correction_history must fix real
misrecognitions WITHOUT corrupting legitimate uses of the same word, and
history examples must never leak into the output.

The user segment mirrors composeWithLLM: optional glossary block, optional
correction_history block, then 输入：<text>.
"""
import json
import time
import urllib.request

OLLAMA = "http://127.0.0.1:11434/api/generate"

HISTORY_BLOCK = (
    "- 曾误识：新开的会画，看看这个问题还存不存在。\n"
    "  改正为：新开的会话，看看这个问题还存不存在。"
)

CASES = [
    # A. Legitimate use of the glossary LEFT word — must be kept.
    {"id": "keep_yonghu_legit", "glossary": "拥护 => 用户",
     "text": "大家都拥护这个决定，没有反对意见",
     "contains": ["拥护"], "absent": ["用户"]},
    {"id": "keep_chaoshi_legit", "glossary": "超市 => 超时",
     "text": "下班顺路去超市买点菜",
     "contains": ["超市"], "absent": ["超时"]},
    # A2. Novel keep-cases with NO few-shot twin in the prompt — these
    #     measure generalization, not memorization.
    {"id": "keep_shangxian_legit", "glossary": "上线 => 上限",
     "text": "新功能明天正式上线大家关注一下",
     "contains": ["上线"], "absent": ["上限"]},
    {"id": "keep_shifen_legit", "glossary": "十分 => 时分",
     "text": "这个方案十分靠谱就按它来",
     "contains": ["十分"], "absent": ["时分"]},
    # B. True misrecognition in context — must be replaced.
    {"id": "fix_yonghu_error", "glossary": "拥护 => 用户",
     "text": "这个功能上线后拥护反馈很多问题",
     "contains": ["用户"], "absent": ["拥护"]},
    {"id": "fix_chaoshi_error", "glossary": "超市 => 超时",
     "text": "接口老是超市，需要加重试",
     "contains": ["超时"], "absent": ["超市"]},
    # C. Gibberish left side (not a real word): glossary hint should be
    #    enough — this class was UNFIXABLE without the glossary line
    #    (see FakeEngines defaultTerms comment / homophone_eval history).
    {"id": "fix_gibberish_fabu", "glossary": "发不说明 => 发布说明",
     "text": "记得更新发不说明再打包",
     "contains": ["发布说明"], "absent": ["发不说明"]},
    {"id": "fix_gibberish_yicheng", "glossary": "疑程 => 议程",
     "text": "明天会议的疑程发一下",
     "contains": ["议程"], "absent": ["疑程"]},
    # D. correction_history drives the same fix — and must not leak.
    {"id": "history_fix_same_error", "history": True,
     "text": "再开一个会画讨论一下细节",
     "contains": ["会话"], "absent": ["会画", "还存不存在"]},
    {"id": "history_keep_legit_huihua", "history": True,
     "text": "他的会画作品得了一等奖画得真好",
     # 会画 as "can paint" is a stretch, but 绘画-adjacent misuse must not
     # auto-fire just because history mentions it; leakage still checked.
     "absent": ["还存不存在", "新开的"]},
    # E. No signals at all — output must not invent corrections.
    {"id": "no_signal_clean", "text": "我们下午三点开会讨论预算",
     "contains": ["三点", "预算"], "absent": []},
]

CANDIDATES = json.load(open("/tmp/velora-eval/ambiguity_candidates.json"))


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
    call(cand["model"], cand["system"], "输入：预热", {**cand["options"], "num_predict": 8})
    for case in CASES:
        prompt = ""
        if case.get("glossary"):
            pair = case["glossary"].replace(" => ", " / ")
            prompt += f"sound_alike:\n{pair}\n"
        if case.get("history"):
            prompt += f"correction_history:\n{HISTORY_BLOCK}\n"
        prompt += f"输入：{case['text']}"
        body, wall = call(cand["model"], cand["system"], prompt, cand["options"])
        try:
            polished = json.loads(body.get("response", "")).get("polished", "") or ""
        except json.JSONDecodeError:
            polished = "<PARSE_FAIL>"
        ok_contains = all(c in polished for c in case.get("contains", []))
        ok_absent = all(a not in polished for a in case.get("absent", []))
        ok = ok_contains and ok_absent
        results.append({"cand": cand["id"], "case": case["id"], "wall": wall, "ok": ok,
                        "polished": polished})
        print(f"{cand['id']:10s} {case['id']:26s} {'PASS' if ok else 'FAIL'}  {polished[:70]}", flush=True)

json.dump(results, open("/tmp/velora-eval/ambiguity-results.json", "w"), ensure_ascii=False, indent=1)
for cand in CANDIDATES:
    rs = [r for r in results if r["cand"] == cand["id"]]
    print(f"== {cand['id']}: {sum(r['ok'] for r in rs)}/{len(rs)} pass")
