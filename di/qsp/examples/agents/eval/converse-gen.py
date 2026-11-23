"""The surveillance agent's 20 conversational turns, as converse.py asks them.

    python3 -I converse-gen.py SURVEILLANCE_RUNS_DIR > conversations-surveillance.json

SURVEILLANCE_RUNS_DIR is surveillance_ai_agent/documentation/runs. Each conversation - an "arm" -
is the turns of one results.jsonl, at its last level (the techniques guide), in order: the
question, the truth the surveillance eval wrote for it (computed on the same database), and the
names of the checks its reply had to pass. A turn passed there when every check held and an LLM
judge agreed; judge.py asks the same of our replies.
"""
import json, os, re, sys

ARMS = ["2026-10-21-1712-correlation", "2026-10-21-1713-investigation", "2026-10-21-1812-markout",
        "2026-10-21-1928-book", "2026-10-21-1931-boundary", "2026-10-21-1933-complex"]

def main():
    runs = sys.argv[1]
    out = []
    for arm in ARMS:
        recs = [json.loads(l) for l in open(os.path.join(runs, arm, "results.jsonl"))]
        last = recs[-1]["level_id"]
        turns = sorted((r for r in recs if r["level_id"] == last), key=lambda r: r["turn"])
        # the user it was asked as, from its report: "User llmu3, run ..."
        user = re.search(r"User (\w+),", open(os.path.join(runs, arm, "report.md")).read()).group(1)
        out.append({"id": arm.split("-", 4)[-1], "source": arm, "persona": user,
                    "turns": [{"turn": r["turn"], "question": r["question"], "truth": r["truth"],
                               "checks": list((r.get("checks") or {}).keys()),
                               "surveillance": {"correct": r["correct"], "checks": r.get("checks"), "judge": r.get("judge")}}
                              for r in turns]})
    json.dump(out, sys.stdout, indent=1)

if __name__ == "__main__":
    main()
