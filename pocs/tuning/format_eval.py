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
    {"id": "ordinal_3", "text": "这次改动主要有三块第一是把asr换成了sensevoice第二是加了记忆层第三是录音期并行化", "profile": "document: complete punctuation, topic paragraphs, and lists for explicit enumerations", "expect": "list", "must": ["1.", "2.", "3."]},
    {"id": "shopping", "text": "帮我记一下要买牛奶鸡蛋面包还有酸奶", "profile": "personal_chat: short natural paragraphs with light punctuation", "expect": "list", "must": ["-"]},
    {"id": "yishi_ershi", "text": "问题有两个一是延迟太高二是偶尔会崩溃", "profile": "work_chat: short paragraphs, one independent topic per paragraph, light punctuation; avoid formal email framing", "expect": "list", "must": ["1.", "2."]},
    {"id": "todo", "text": "今天的任务是修复登录bug然后写周报最后回复邮件", "profile": "document: complete punctuation, topic paragraphs, and lists for explicit enumerations", "expect": "list", "must": []},
    {"id": "steps", "text": "部署流程首先拉最新代码然后跑测试接着打包最后上线", "profile": "developer: preserve code identifiers, paths, flags, acronyms, and Markdown; use lists only for explicit enumerations; split clearly independent topics into separate paragraphs", "expect": "list", "must": []},
    # flat guards — must NOT become a list / multi-line
    {"id": "flat_reply", "text": "帮我回复他说好的没问题我明天上午把文档发过去", "expect": "flat"},
    {"id": "flat_one", "text": "明天上午十点开会帮我确认一下议程", "expect": "flat"},
    {"id": "flat_greeting", "text": "好的收到我马上处理", "expect": "flat"},
    {"id": "flat_sentence", "text": "这个接口超时了你看下是不是后端的问题", "expect": "flat"},
    # paragraph: multiple distinct topics → line breaks acceptable, not required as list
    {"id": "multi_topic", "text": "今天先把测试跑完然后明天上午过一遍发布说明下午三点和产品对一次会有问题的话周四再留一天缓冲", "expect": "any"},
    # paragraph splitting: clearly independent topics in one dictation must be
    # broken into paragraphs (newlines, NOT list markers) under profiles that
    # ask for it. Journal 2026-07-14: zero of 94 real insertions contained a
    # newline; these cases pin the paragraph behavior.
    {"id": "para_dev_topics", "text": "接口超时的问题我看了一下是重试逻辑写错了我今天会修掉另外明天的发布计划需要你确认一下范围最后提醒一下我周五下午要请假", "profile": "developer: preserve code identifiers, paths, flags, acronyms, and Markdown; use lists only for explicit enumerations; split clearly independent topics into separate paragraphs", "expect": "para"},
    {"id": "para_chat_topics", "text": "数据迁移脚本已经跑完了没有丢数据然后新来的实习生下周一入职你帮忙准备一下权限对了下午的会改到四点", "profile": "work_chat: short paragraphs, one independent topic per paragraph, light punctuation; avoid formal email framing", "expect": "para"},
    # flat guards under the paragraph-enabled profiles: a single-topic
    # sentence must NOT get split just because the profile allows paragraphs.
    {"id": "para_dev_flat_guard", "text": "这个接口超时了你看下是不是后端的问题", "profile": "developer: preserve code identifiers, paths, flags, acronyms, and Markdown; use lists only for explicit enumerations; split clearly independent topics into separate paragraphs", "expect": "flat"},
    {"id": "para_chat_flat_guard", "text": "好的收到我马上处理另外那份文档我看完了没什么问题", "profile": "work_chat: short paragraphs, one independent topic per paragraph, light punctuation; avoid formal email framing", "expect": "any"},
    {"id": "para_chat_flat_guard2", "text": "这个接口超时了你看下是不是后端的问题", "profile": "work_chat: short paragraphs, one independent topic per paragraph, light punctuation; avoid formal email framing", "expect": "flat"},
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
    warm_profile = "other: neutral punctuation; preserve wording and use structure only when clearly signaled"
    call(cand["model"], cand["system"], f"app_format_profile={warm_profile}\n输入：预热", {**cand["options"], "num_predict": 8})
    for case in CASES:
        profile = case.get("profile", warm_profile)
        body, ms = call(cand["model"], cand["system"], f"app_format_profile={profile}\n输入：{case['text']}", cand["options"])
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
        elif case["expect"] == "para":
            # Blank-line separated paragraphs, at least two, and no list
            # markers — a single stray newline must not count as "split".
            paragraphs = [p for p in pol.split("\n\n") if p.strip()]
            ok = len(paragraphs) >= 2 and not has_list
        else:
            ok = pol != "<PARSE_FAIL>" and pol != ""
        results.append({"cand": cand["id"], "case": case["id"], "expect": case["expect"], "ok": ok, "ms": ms, "polished": pol})
        print(f"{cand['id']:14s} {case['id']:16s} {case['expect']:5s} {'PASS' if ok else 'FAIL'}  {pol[:70].replace(chr(10),'/')}", flush=True)

json.dump(results, open("/tmp/velora-eval/format-results.json", "w"), ensure_ascii=False, indent=1)
for cand in CANDS:
    rs = [r for r in results if r["cand"] == cand["id"]]
    print(f"== {cand['id']}: {sum(r['ok'] for r in rs)}/{len(rs)}")
if any(not r["ok"] for r in results):
    raise SystemExit(1)
