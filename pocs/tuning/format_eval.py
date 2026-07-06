#!/usr/bin/env python3
"""Formatting eval: does polish produce lists/line breaks WHERE APPROPRIATE
without over-formatting simple utterances?"""
import json
import re
import time
import urllib.request

OLLAMA = "http://127.0.0.1:11434/api/generate"

# want_list: output should contain list markers + newlines
# want_flat: output must stay single-line (no list markers, no newline)
CASES = [
    {"id": "ordinal_3", "text": "这次改动主要有三块第一是把asr换成了sensevoice第二是加了记忆层第三是录音期并行化", "expect": "list", "must": ["1.", "2.", "3."]},
    {"id": "shopping", "text": "帮我记一下要买牛奶鸡蛋面包还有酸奶", "expect": "list", "must": ["-"]},
    {"id": "yishi_ershi", "text": "问题有两个一是延迟太高二是偶尔会崩溃", "expect": "list", "must": ["1.", "2."]},
    {"id": "todo", "text": "今天的任务是修复登录bug然后写周报最后回复邮件", "expect": "list", "must": []},
    {"id": "steps", "text": "部署流程首先拉最新代码然后跑测试接着打包最后上线", "expect": "list", "must": []},
    # flat guards — must NOT become a list / multi-line
    {"id": "flat_reply", "text": "帮我回复他说好的没问题我明天上午把文档发过去", "expect": "flat"},
    {"id": "flat_one", "text": "明天上午十点开会帮我确认一下议程", "expect": "flat"},
    {"id": "flat_greeting", "text": "好的收到我马上处理", "expect": "flat"},
    {"id": "flat_sentence", "text": "这个接口超时了你看下是不是后端的问题", "expect": "flat"},
    # paragraph: multiple distinct topics → line breaks acceptable, not required as list
    {"id": "multi_topic", "text": "今天先把测试跑完然后明天上午过一遍发布说明下午三点和产品对一次会有问题的话周四再留一天缓冲", "expect": "any"},
]

CANDS = json.load(open("/tmp/velora-eval/format_candidates.json"))
LIST_MARK = re.compile(r"(^|\n)\s*(\d+[\.、)]|[-•*])\s", re.M)


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
    call(cand["model"], cand["system"], "输入：预热", {**cand["options"], "num_predict": 8})
    for case in CASES:
        body, ms = call(cand["model"], cand["system"], f"输入：{case['text']}", cand["options"])
        try:
            pol = json.loads(body.get("response", "")).get("polished", "") or ""
        except json.JSONDecodeError:
            pol = "<PARSE_FAIL>"
        has_list = bool(LIST_MARK.search(pol))
        has_nl = "\n" in pol
        if case["expect"] == "list":
            ok = has_list and all(m in pol for m in case.get("must", []))
        elif case["expect"] == "flat":
            ok = not has_list and not has_nl
        else:
            ok = pol != "<PARSE_FAIL>" and pol != ""
        results.append({"cand": cand["id"], "case": case["id"], "expect": case["expect"], "ok": ok, "ms": ms, "polished": pol})
        print(f"{cand['id']:14s} {case['id']:16s} {case['expect']:5s} {'PASS' if ok else 'FAIL'}  {pol[:70].replace(chr(10),'/')}", flush=True)

json.dump(results, open("/tmp/velora-eval/format-results.json", "w"), ensure_ascii=False, indent=1)
for cand in CANDS:
    rs = [r for r in results if r["cand"] == cand["id"]]
    print(f"== {cand['id']}: {sum(r['ok'] for r in rs)}/{len(rs)}")
