"""Ask the agent each conversation, one session per conversation, and keep every turn.

    python3 -I converse.py CONVERSATIONS RUNDIR [id ...] [--port 5100] [--no-primer] [--budget 3]

As run.py asks a question - bound to the conversation's user, the server's primer in the system
prompt, from eval/agent - but each conversation is one claude session: the first turn starts it
with a fixed session id, and each later turn resumes it, so "Was that the whole sector?" knows
what "that" was. Writes RUNDIR/<id>.json: each turn's question, reply, the queries it ran,
refusals, cost and seconds. Grade the run with judge.py.
"""
import argparse, json, os, subprocess, sys, time, uuid

EVAL = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, EVAL)
import run  # noqa: E402  run.py's primer, parse and tool list


def turn(conv, t, session, first, port, use_primer, budget):
    user = conv["persona"]
    system = f"You act for qsp user {user}: every query runs as {user}, and no tool can act as anyone else."
    if use_primer:
        system += "\n\n" + run.primer(port, user)
    mcp = {"mcpServers": {"qsp": {"command": run.MCP, "args": ["-port", str(port), "-user", user],
                                  "env": {"QBIN": run.qbin()}}}}
    cmd = ["claude", "--mcp-config", json.dumps(mcp), "--strict-mcp-config", "--tools", "",
           "--allowedTools", run.TOOLS, "--append-system-prompt", system, "--max-budget-usd", str(budget),
           "--output-format", "stream-json", "--verbose"]
    cmd += ["--session-id", session] if first else ["--resume", session]
    cmd += ["-p", t["question"]]
    t0 = time.time()
    p = subprocess.run(cmd, cwd=os.path.join(EVAL, "agent"), stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=1200)
    calls, final, model = run.parse(p.stdout)
    return {"turn": t["turn"], "question": t["question"], "reply": final.get("result"), "model": model,
            "queries": [c["input"].get("query") for c in calls if c["tool"] == "qsp_query"],
            "tools": [c["tool"] for c in calls], "refused": sum(c["error"] for c in calls),
            "cost": final.get("total_cost_usd"), "seconds": round(time.time() - t0, 1),
            "exit": p.returncode, "stderr": p.stderr[-2000:]}


def main():
    a = argparse.ArgumentParser()
    a.add_argument("conversations")
    a.add_argument("rundir")
    a.add_argument("ids", nargs="*")
    a.add_argument("--port", default=os.environ.get("QSP_PORT", "5100"))
    a.add_argument("--no-primer", action="store_true")
    a.add_argument("--budget", default="3")
    o = a.parse_args()
    os.makedirs(o.rundir, exist_ok=True)
    for conv in json.load(open(o.conversations)):
        if o.ids and conv["id"] not in o.ids:
            continue
        session = str(uuid.uuid4())
        turns = []
        for i, t in enumerate(conv["turns"]):
            r = turn(conv, t, session, i == 0, o.port, not o.no_primer, o.budget)
            turns.append(r)
            print(f"{conv['id']:14} turn {r['turn']}  {len(r['tools']):2} calls  {r['refused']} refused  "
                  f"${r['cost'] or 0:.3f}  {r['seconds']:5.0f}s", flush=True)
        json.dump({"id": conv["id"], "persona": conv["persona"], "session": session, "primer": not o.no_primer,
                   "turns": turns}, open(os.path.join(o.rundir, conv["id"] + ".json"), "w"), indent=1)


if __name__ == "__main__":
    main()
