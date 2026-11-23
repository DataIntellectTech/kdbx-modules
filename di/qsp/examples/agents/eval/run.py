"""Ask the agent each question, as agent.sh does, and keep what happened.

    python3 -I run.py QUESTIONS RUNDIR [id ...] [--port 5100] [--no-primer] [--budget 3]

One `claude -p` per question, bound to the question's persona (QSP_AGENT_USER), with the server's
primer in the system prompt, qsp's MCP server (di/qsp/mcp, in q) and no built-in tools. It runs from
eval/agent, whose CLAUDE.md is the example's instructions without the example's dates and users,
so the same agent can be asked about any database. --no-primer leaves the primer out, to measure
what it is worth.

Writes RUNDIR/<id>.jsonl, the stream claude printed, and RUNDIR/<id>.json: every qsp tool call,
the queries it ran, the last that succeeded, turns, cost, seconds and the model. Score the run
with score.q. A qsp server must be listening on the port: start one with ../server.q.
"""
import argparse, json, os, subprocess, sys, time

EVAL = os.path.dirname(os.path.abspath(__file__))
AGENT = os.path.join(os.path.dirname(EVAL), "claude")
MCP = os.path.normpath(os.path.join(EVAL, "..", "..", "..", "mcp", "qsp-mcp"))
TOOLS = ",".join("mcp__qsp__qsp_" + t for t in ("describe", "rules", "primer", "validate", "explain", "estimate", "query"))


def qbin():
    return os.environ.get("QBIN") or os.path.expanduser("~/.kx/bin/q")


def primer(port, user):
    p = subprocess.run([qbin(), os.path.join(AGENT, "client.q"), "-port", str(port), "-call", "primer",
                        "-direct", "-user", user, "-q"], stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if p.returncode:
        sys.exit(f"run.py: cannot read the primer from port {port}: {p.stdout}{p.stderr}")
    return p.stdout


def parse(stream):
    """(tool calls, final result event, model) from claude's stream-json output."""
    calls, pending, final, model = [], {}, {}, None
    for line in stream.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "system" and ev.get("subtype") == "init":
            model = ev.get("model")
        if ev.get("type") == "assistant":
            for c in ev["message"].get("content", []):
                if c.get("type") == "tool_use":
                    pending[c["id"]] = {"tool": c["name"].split("__")[-1], "input": c.get("input", {})}
        if ev.get("type") == "user" and isinstance(ev["message"].get("content"), list):
            for c in ev["message"]["content"]:
                if c.get("type") == "tool_result" and c.get("tool_use_id") in pending:
                    r = c.get("content")
                    text = "".join(x.get("text", "") for x in r) if isinstance(r, list) else str(r)
                    call = pending.pop(c["tool_use_id"])
                    call["error"] = bool(c.get("is_error")) or text.lstrip().startswith("refused")
                    call["result"] = text[:4000]
                    calls.append(call)
        if ev.get("type") == "result":
            final = ev
    return calls, final, model


def ask(q, port, out, use_primer, budget):
    user = q["persona"]
    system = f"You act for qsp user {user}: every query runs as {user}, and no tool can act as anyone else."
    if use_primer:
        system += "\n\n" + primer(port, user)
    mcp = {"mcpServers": {"qsp": {"command": MCP, "args": ["-port", str(port), "-user", user],
                                  "env": {"QBIN": qbin()}}}}
    cmd = ["claude", "--mcp-config", json.dumps(mcp), "--strict-mcp-config", "--tools", "",
           "--allowedTools", TOOLS, "--append-system-prompt", system, "--max-budget-usd", str(budget),
           "--output-format", "stream-json", "--verbose", "-p", q["question"]]
    t0 = time.time()
    p = subprocess.run(cmd, cwd=os.path.join(EVAL, "agent"), stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=900)
    secs = time.time() - t0
    open(os.path.join(out, q["id"] + ".jsonl"), "w").write(p.stdout)
    calls, final, model = parse(p.stdout)
    ran = [c for c in calls if c["tool"] == "qsp_query" and not c["error"]]
    rec = {"id": q["id"], "persona": user, "question": q["question"], "model": model, "primer": use_primer,
           "query": ran[-1]["input"].get("query") if ran else None,
           "queries": [c["input"].get("query") for c in calls if c["tool"] == "qsp_query"],
           "tools": [c["tool"] for c in calls], "refused": sum(c["error"] for c in calls),
           "turns": final.get("num_turns"), "cost": final.get("total_cost_usd"), "seconds": round(secs, 1),
           "answer": final.get("result"), "exit": p.returncode, "stderr": p.stderr[-2000:]}
    json.dump(rec, open(os.path.join(out, q["id"] + ".json"), "w"), indent=1)
    print(f"{q['id']:5} {len(calls):2} calls  {rec['refused']} refused  ${rec['cost'] or 0:.3f}  {secs:5.0f}s  {model}", flush=True)


def main():
    a = argparse.ArgumentParser()
    a.add_argument("questions")
    a.add_argument("rundir")
    a.add_argument("ids", nargs="*")
    a.add_argument("--port", default=os.environ.get("QSP_PORT", "5100"))
    a.add_argument("--no-primer", action="store_true")
    a.add_argument("--budget", default="3")
    o = a.parse_args()
    os.makedirs(o.rundir, exist_ok=True)
    qs = [q for q in json.load(open(o.questions)) if not o.ids or q["id"] in o.ids]
    for q in qs:
        ask(q, o.port, o.rundir, not o.no_primer, o.budget)


if __name__ == "__main__":
    main()
