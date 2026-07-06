#!/usr/bin/env python3
"""Self-repair (说话人自纠正) polish eval: does the prompt apply corrections
without fabricating or over-deleting?"""
import json
import time
import urllib.request

OLLAMA = "http://127.0.0.1:11434/api/generate"

# expect_contains: must appear; expect_absent: must NOT appear (the retracted part / repair marker)
TEXTS = [
    {"id": "count_repair", "text": "对了我有三点想说一下第一点我不是是两点第一点需要理点需求第二点需要充分测试",
     "contains": ["两点", "需求", "充分测试"], "absent": ["三点", "我不是，是", "我不是,是"]},
    {"id": "soft_should_be", "text": "预算大概五万应该是八万",
     "contains": ["八万"], "absent": ["五万"]},
    {"id": "casual_switch", "text": "周三开会啊不周四下午三点算了还是周五上午吧",
     "contains": ["周五"], "absent": ["周三", "周四", "算了"]},
    {"id": "three_way", "text": "发给小王吧不对小李算了还是发给小张",
     "contains": ["小张"], "absent": ["小王", "小李"]},
    {"id": "restate", "text": "这个方案可以呃我是说前面那个方案可以",
     "contains": ["前面那个方案"], "absent": ["我是说"]},
    {"id": "time_repair", "text": "会议定在周三吧不对周四下午三点",
     "contains": ["周四", "下午三点"], "absent": ["周三", "不对"]},
    {"id": "name_repair", "text": "把文档发给小王说错了发给小李",
     "contains": ["小李"], "absent": ["小王", "说错"]},
    {"id": "no_repair_negation", "text": "我不是本地人是从北京过来的",
     "contains": ["不是本地人", "北京"], "absent": []},
    {"id": "no_repair_quote", "text": "他说的不是周三是周四你确认一下",
     "contains": ["不是周三", "周四"], "absent": []},
    {"id": "no_repair_clean", "text": "帮我回复他说好的没问题我明天上午把文档发过去",
     "contains": ["好的", "没问题", "文档"], "absent": []},
    {"id": "no_repair_disagree", "text": "我不是不同意就是想再确认一下时间", "contains": ["不同意", "确认"], "absent": []},
    {"id": "no_repair_list", "text": "我有两点想说第一点进度没问题第二点预算要加", "contains": ["两点", "进度", "预算"], "absent": []},
    {"id": "no_repair_speculation", "text": "他应该是去开会了你等他回来再问吧", "contains": ["应该是", "开会"], "absent": []},
    {"id": "no_repair_choice", "text": "你觉得会议定在周三还是周四比较好", "contains": ["周三", "周四"], "absent": []},
]

CANDIDATES = json.load(open("/tmp/velora-eval/repair_candidates.json"))


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
    for item in TEXTS:
        body, wall = call(cand["model"], cand["system"], f"输入：{item['text']}", cand["options"])
        try:
            polished = json.loads(body.get("response", "")).get("polished", "") or ""
        except json.JSONDecodeError:
            polished = "<PARSE_FAIL>"
        ok_contains = all(c in polished for c in item["contains"])
        ok_absent = all(a not in polished for a in item["absent"])
        results.append({"cand": cand["id"], "text": item["id"], "wall": wall,
                        "ok": ok_contains and ok_absent, "contains_ok": ok_contains,
                        "absent_ok": ok_absent, "polished": polished})
        mark = "PASS" if ok_contains and ok_absent else "FAIL"
        print(f"{cand['id']:14s} {item['id']:20s} {mark}  {polished[:80]}", flush=True)

json.dump(results, open("/tmp/velora-eval/repair-results.json", "w"), ensure_ascii=False, indent=1)
for cand in CANDIDATES:
    rs = [r for r in results if r["cand"] == cand["id"]]
    print(f"== {cand['id']}: {sum(r['ok'] for r in rs)}/{len(rs)} pass")
