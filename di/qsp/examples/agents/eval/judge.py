"""Grade a conversational run as the surveillance eval graded its own: every check, and a judge.

    python3 -I judge.py CONVERSATIONS RUNDIR

For each turn, a separate claude -p - no tools, so it judges only what it is shown - is given the
question, the truth the surveillance eval wrote for it, the names of the checks its reply had to
pass, and our agent's reply. It answers, as JSON, whether each check holds and whether the reply
agrees with the truth. A turn is correct when every check holds and the judge agrees, as there.
Writes RUNDIR/judged.json and prints a table, with the surveillance run's verdict beside ours.

An LLM judge is not a replay: it can be wrong, and the surveillance one could be too. Read the
replies of the turns it fails before trusting a figure.
"""
import argparse, json, os, re, subprocess, sys

EVAL = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, EVAL)
import run_openai as ro  # noqa: E402

PROMPT = """You are grading one reply from a data assistant against the known truth. Be strict about
figures and names: a reply passes a check only if it actually states what the check names, and
agrees with the truth only if its answer and figures are consistent with the truth (rounding is
fine; a different method is fine only where the truth says so).

Question:
{question}

The truth:
{truth}

The checks the reply must pass:
{checks}

The reply:
{reply}

Answer with JSON only, no other text: {{"checks": {{"<check>": true or false, ...}}, "judge": true or false, "why": "<one sentence>"}}"""


def grade(t, reply, openai_model=None, api_key=None, base_url="https://api.openai.com/v1"):
    checks = "\n".join(f"- {c}" for c in t["checks"]) or "- (none)"
    prompt = PROMPT.format(question=t["question"], truth=t["truth"], checks=checks, reply=reply or "(no reply)")
    if openai_model:
        try:
            resp = ro.openai_chat(api_key, base_url, openai_model, [{"role": "user", "content": prompt}], [])
            text = resp["choices"][0]["message"].get("content") or ""
            g = json.loads(re.search(r"\{.*\}", text, re.S).group(0))
            u = resp.get("usage") or {}
            usage = {
                "prompt_tokens": u.get("prompt_tokens", 0),
                "cached_tokens": (u.get("prompt_tokens_details") or {}).get("cached_tokens", 0),
                "completion_tokens": u.get("completion_tokens", 0),
            }
            g["cost"] = round(ro.calc_cost(openai_model, usage), 6)
            return g
        except Exception as e:
            return {"checks": {}, "judge": False, "why": f"unreadable judge output: {e}", "cost": None}

    p = subprocess.run(["claude", "--tools", "", "--output-format", "json", "-p", prompt],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=600)
    try:
        out = json.loads(p.stdout)
        text = out.get("result", "")
        g = json.loads(re.search(r"\{.*\}", text, re.S).group(0))
        g["cost"] = out.get("total_cost_usd")
        return g
    except Exception as e:  # a judge that cannot be read is a failed grade, not a pass
        return {"checks": {}, "judge": False, "why": f"unreadable judge output: {e}", "cost": None}


def main():
    a = argparse.ArgumentParser()
    a.add_argument("conversations")
    a.add_argument("rundir")
    a.add_argument("--openai-model", default=None, help="Grade with an OpenAI model (e.g. gpt-5.4) instead of claude")
    a.add_argument("--base-url", default=os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1"))
    o = a.parse_args()
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if o.openai_model and not api_key:
        sys.exit("judge.py: --openai-model requires OPENAI_API_KEY in the environment")

    convs, rundir = json.load(open(o.conversations)), o.rundir
    rows = []
    for conv in convs:
        f = os.path.join(rundir, conv["id"] + ".json")
        if not os.path.exists(f):
            continue
        got = {t["turn"]: t for t in json.load(open(f))["turns"]}
        for t in conv["turns"]:
            r = got.get(t["turn"])
            if not r:
                continue
            g = grade(t, r["reply"], o.openai_model, api_key, o.base_url)
            ok = bool(g.get("judge")) and all(g.get("checks", {}).get(c, False) for c in t["checks"])
            rows.append({"id": conv["id"], "turn": t["turn"], "question": t["question"], "correct": ok,
                         "checks": g.get("checks"), "judge": g.get("judge"), "why": g.get("why"),
                         "surveillance": t["surveillance"]["correct"], "cost": r["cost"], "judge_cost": g.get("cost"),
                         "refused": r["refused"], "seconds": r["seconds"]})
            print(f"{conv['id']:14} {t['turn']}  {'yes' if ok else 'no ':3}  (surveillance {'yes' if t['surveillance']['correct'] else 'no'})  {g.get('why', '')[:90]}", flush=True)
    json.dump(rows, open(os.path.join(rundir, "judged.json"), "w"), indent=1)
    n = len(rows)
    print(f"\ncorrect: {sum(r['correct'] for r in rows)}/{n}   surveillance: {sum(r['surveillance'] for r in rows)}/{n}"
          f"   refused: {sum(r['refused'] for r in rows)}   agent cost ${sum(r['cost'] or 0 for r in rows):.2f}"
          f"   judge cost ${sum(r['judge_cost'] or 0 for r in rows):.2f}")


if __name__ == "__main__":
    main()
