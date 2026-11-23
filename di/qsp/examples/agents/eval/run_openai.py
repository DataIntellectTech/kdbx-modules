"""Ask an OpenAI model each eval question through qsp, writing the same format as run.py.

    OPENAI_API_KEY=sk-... python3 -I run_openai.py QUESTIONS RUNDIR [id ...] \\
        --model gpt-5.4 --port 5198

One fresh conversation per question, bound to the question's persona (-direct -user), with
eval/agent/CLAUDE.md and the server's primer in the system prompt, and the same qsp tools as
run.py (describe, rules, primer, validate, explain, estimate, query). Uses only the Python
standard library.

Writes RUNDIR/<id>.json (scored by score.q) and RUNDIR/<id>.jsonl (message/tool trace).
A qsp server must be listening on --port: start one with ../server.q.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

EVAL = os.path.dirname(os.path.abspath(__file__))
CLAUDE_DIR = os.path.join(os.path.dirname(EVAL), "claude")
CLIENT_Q = os.path.join(CLAUDE_DIR, "client.q")
INSTRUCTIONS_MD = os.path.join(EVAL, "agent", "CLAUDE.md")

# USD per million tokens: (input, cached_input, output)
PRICING = {
    "gpt-5.4": (2.50, 0.25, 15.00),
    "gpt-5.4-mini": (0.75, 0.075, 4.50),
    "gpt-4.1": (2.00, 0.50, 8.00),
    "gpt-4.1-mini": (0.40, 0.10, 1.60),
}

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "qsp_describe",
            "description": (
                "Everything you need before writing q as the bound user: granted tables and columns, "
                "column types, bytes per row, descriptions, partition column, row filter, permitted "
                "functions, limits, data shape, business terms, and qsp's rules. Call before your first query."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "qsp_rules",
            "description": "The rules for writing q that qsp accepts, with good/bad examples and refusal patterns.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "qsp_primer",
            "description": "The 'q under qsp' primer as markdown. Call only if not already in the system prompt.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "qsp_validate",
            "description": "Check whether a q-SQL query is allowed for the bound user without running it.",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string", "description": "The q-SQL query, as one string"}},
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "qsp_estimate",
            "description": (
                "Estimate rows and bytes a query will read and return against the limits, with a verdict "
                "(fits, large, or toobig) and sizing advice."
            ),
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string", "description": "The q-SQL query, as one string"}},
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "qsp_explain",
            "description": "Show the query as qsp would rewrite and run it for the bound user.",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string", "description": "The q-SQL query, as one string"}},
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "qsp_query",
            "description": (
                "Run a q-SQL query as the bound user. Returns JSON with `ran` (the rewritten query), "
                "`rows`, `columns`, `types`, `data` (first 100 rows), and `truncated`, or a `qsp: ...` refusal."
            ),
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string", "description": "The q-SQL query, as one string"}},
                "required": ["query"],
            },
        },
    },
]

CALL_MAP = {
    "qsp_describe": "brief",
    "qsp_rules": "rules",
    "qsp_primer": "primer",
    "qsp_validate": "validate",
    "qsp_estimate": "estimate",
    "qsp_explain": "explain",
    "qsp_query": "query",
}


def qbin():
    return os.environ.get("QBIN") or os.path.expanduser("~/.kx/bin/q")


def call_q(port, user, call, query=None):
    cmd = [qbin(), CLIENT_Q, "-port", str(port), "-call", call, "-direct", "-user", user, "-q"]
    if query is not None:
        cmd += ["-query", query]
    if call == "query":
        cmd += ["-json", "-rows", os.environ.get("QSP_ROWS", "100")]
    try:
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return False, "refused: query timed out after 60s — narrow its dates or instruments, or filter both sides of a join first"
    out = (p.stdout + p.stderr).strip()
    is_err = (p.returncode != 0) or out.lstrip().startswith("refused")
    return (not is_err), out


def fetch_primer(port, user):
    ok, out = call_q(port, user, "primer")
    if not ok:
        sys.exit(f"run_openai.py: cannot read the primer from port {port}: {out}")
    return out


def default_reasoning_effort(model):
    if model.startswith(("gpt-5", "o1", "o3", "o4")):
        return "medium"
    return None


RESP_TOOLS = [
    {
        "type": "function",
        "name": t["function"]["name"],
        "description": t["function"]["description"],
        "parameters": t["function"]["parameters"],
    }
    for t in TOOLS
]


def _post_json(url, api_key, payload):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
        method="POST",
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=240) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")
            if e.code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            raise RuntimeError(f"OpenAI HTTP {e.code}: {err_body[:600]}") from e
        except urllib.error.URLError as e:
            if attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            raise RuntimeError(f"OpenAI network error: {e}") from e


def openai_chat(api_key, base_url, model, messages, tools=None, reasoning_effort=None):
    url = base_url.rstrip("/") + "/chat/completions"
    payload = {"model": model, "messages": messages}
    if tools:
        payload["tools"] = tools
    return _post_json(url, api_key, payload)


def openai_response(api_key, base_url, model, instructions, input_items, tools=None,
                    reasoning_effort=None, previous_response_id=None):
    url = base_url.rstrip("/") + "/responses"
    payload = {"model": model, "instructions": instructions, "input": input_items}
    if tools:
        payload["tools"] = tools
    if reasoning_effort and reasoning_effort != "none":
        payload["reasoning"] = {"effort": reasoning_effort}
    if previous_response_id:
        payload["previous_response_id"] = previous_response_id
    return _post_json(url, api_key, payload)


def parse_response_output(resp):
    """Extract (text, function_calls, usage_dict) from a /v1/responses object."""
    texts = []
    fcalls = []
    for item in resp.get("output") or []:
        if item.get("type") == "function_call":
            fcalls.append({
                "id": item.get("call_id") or item.get("id"),
                "name": item.get("name"),
                "arguments": item.get("arguments") or "{}",
            })
        elif item.get("type") == "message":
            for c in item.get("content") or []:
                if c.get("type") == "output_text" and c.get("text"):
                    texts.append(c["text"])
    u = resp.get("usage") or {}
    usage = {
        "prompt_tokens": u.get("input_tokens", 0),
        "cached_tokens": (u.get("input_tokens_details") or {}).get("cached_tokens", 0),
        "completion_tokens": u.get("output_tokens", 0),
    }
    return "\n".join(texts).strip(), fcalls, usage


def calc_cost(model, usage):
    rates = PRICING.get(model)
    if not rates:
        for prefix, r in PRICING.items():
            if model.startswith(prefix):
                rates = r
                break
    if not rates:
        return 0.0
    in_r, cache_r, out_r = rates
    cached = usage.get("cached_tokens", 0)
    uncached = max(0, usage.get("prompt_tokens", 0) - cached)
    out = usage.get("completion_tokens", 0)
    return (uncached * in_r + cached * cache_r + out * out_r) / 1_000_000.0


def ask(q, port, outdir, model, api_key, base_url, use_primer, max_turns, instructions, primer_cache, reasoning_effort=None):
    user = q["persona"]
    system = instructions + f"\n\nYou act for qsp user {user}: every query runs as {user}, and no tool can act as anyone else."
    if use_primer:
        if user not in primer_cache:
            primer_cache[user] = fetch_primer(port, user)
        system += "\n\n" + primer_cache[user]

    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": q["question"]},
    ]
    trace = []
    calls = []
    usage = {"prompt_tokens": 0, "cached_tokens": 0, "completion_tokens": 0}
    answer = ""
    stderr = ""
    exit_code = 0
    resolved_model = model
    turns = 0
    t0 = time.time()

    try:
        use_responses = bool(reasoning_effort and reasoning_effort != "none")
        prev_id = None
        next_input = [{"role": "user", "content": q["question"]}]
        for _ in range(max_turns):
            turns += 1
            if use_responses:
                resp = openai_response(
                    api_key, base_url, model, system, next_input,
                    tools=RESP_TOOLS, reasoning_effort=reasoning_effort, previous_response_id=prev_id,
                )
                prev_id = resp.get("id")
                resolved_model = resp.get("model") or model
                text, fcalls, u = parse_response_output(resp)
                usage["prompt_tokens"] += u["prompt_tokens"]
                usage["cached_tokens"] += u["cached_tokens"]
                usage["completion_tokens"] += u["completion_tokens"]
                trace.append({"turn": turns, "usage": u, "text": text[:500], "calls": len(fcalls)})
                if not fcalls:
                    answer = text
                    break
                next_input = []
                for fc in fcalls:
                    name = fc["name"]
                    try:
                        args = json.loads(fc["arguments"])
                    except ValueError:
                        args = {}
                    call_name = CALL_MAP.get(name)
                    if not call_name:
                        ok, out_text = False, f"Unknown tool: {name}"
                    else:
                        ok, out_text = call_q(port, user, call_name, args.get("query"))
                    calls.append({"tool": name, "input": args, "error": not ok, "result": out_text[:4000]})
                    next_input.append({"type": "function_call_output", "call_id": fc["id"], "output": out_text})
                    trace.append({"turn": turns, "tool_result": {"name": name, "ok": ok, "len": len(out_text)}})
                continue

            resp = openai_chat(api_key, base_url, model, messages, TOOLS)
            resolved_model = resp.get("model") or model
            u = resp.get("usage") or {}
            usage["prompt_tokens"] += u.get("prompt_tokens", 0)
            usage["cached_tokens"] += (u.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
            usage["completion_tokens"] += u.get("completion_tokens", 0)

            msg = resp["choices"][0]["message"]
            trace.append({"turn": turns, "usage": u, "message": msg})

            wire_msg = {"role": "assistant", "content": msg.get("content")}
            tcs = msg.get("tool_calls") or []
            if tcs:
                wire_msg["tool_calls"] = tcs
            messages.append(wire_msg)

            if not tcs:
                answer = msg.get("content") or ""
                break

            for tc in tcs:
                name = tc["function"]["name"]
                try:
                    args = json.loads(tc["function"].get("arguments") or "{}")
                except ValueError:
                    args = {}
                call_name = CALL_MAP.get(name)
                if not call_name:
                    ok, text = False, f"Unknown tool: {name}"
                else:
                    ok, text = call_q(port, user, call_name, args.get("query"))
                calls.append({"tool": name, "input": args, "error": not ok, "result": text[:4000]})
                tool_msg = {"role": "tool", "tool_call_id": tc["id"], "content": text}
                messages.append(tool_msg)
                trace.append({"turn": turns, "tool_result": {"name": name, "ok": ok, "len": len(text)}})
        else:
            if not answer and messages and messages[-1].get("role") == "assistant":
                answer = messages[-1].get("content") or ""
    except Exception as e:
        exit_code = 1
        stderr = str(e)

    secs = time.time() - t0
    cost = round(calc_cost(model, usage), 6)
    ran = [c for c in calls if c["tool"] == "qsp_query" and not c["error"]]
    rec = {
        "id": q["id"],
        "persona": user,
        "question": q["question"],
        "model": resolved_model,
        "primer": use_primer,
        "query": ran[-1]["input"].get("query") if ran else None,
        "queries": [c["input"].get("query") for c in calls if c["tool"] == "qsp_query"],
        "tools": [c["tool"] for c in calls],
        "refused": sum(c["error"] for c in calls),
        "turns": turns,
        "cost": cost,
        "usage": usage,
        "seconds": round(secs, 1),
        "answer": answer,
        "exit": exit_code,
        "stderr": stderr[-2000:],
    }
    with open(os.path.join(outdir, q["id"] + ".jsonl"), "w") as f:
        for ev in trace:
            f.write(json.dumps(ev) + "\n")
    with open(os.path.join(outdir, q["id"] + ".json"), "w") as f:
        json.dump(rec, f, indent=1)
    print(
        f"{q['id']:5} {len(calls):2} calls  {rec['refused']} refused  ${cost:.3f}  {secs:5.1f}s  {resolved_model}"
        + (f"  ERR: {stderr[:80]}" if stderr else ""),
        flush=True,
    )


def main():
    a = argparse.ArgumentParser()
    a.add_argument("questions")
    a.add_argument("rundir")
    a.add_argument("ids", nargs="*")
    a.add_argument("--model", default="gpt-5.4")
    a.add_argument("--port", default=os.environ.get("QSP_PORT", "5100"))
    a.add_argument("--base-url", default=os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1"))
    a.add_argument("--no-primer", action="store_true")
    a.add_argument("--max-turns", type=int, default=15)
    a.add_argument("--reasoning-effort", default=None, help="Reasoning effort (none, low, medium, high; default medium for gpt-5/o*)")
    a.add_argument("--skip-existing", action="store_true")
    o = a.parse_args()

    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        sys.exit("run_openai.py: set OPENAI_API_KEY in the environment")

    effort = o.reasoning_effort if o.reasoning_effort is not None else default_reasoning_effort(o.model)
    os.makedirs(o.rundir, exist_ok=True)
    instructions = open(INSTRUCTIONS_MD).read()
    primer_cache = {}
    qs = [q for q in json.load(open(o.questions)) if not o.ids or q["id"] in o.ids]
    for q in qs:
        if o.skip_existing and os.path.exists(os.path.join(o.rundir, q["id"] + ".json")):
            print(f"{q['id']:5} skipped (exists)", flush=True)
            continue
        ask(q, o.port, o.rundir, o.model, api_key, o.base_url, not o.no_primer, o.max_turns, instructions, primer_cache, reasoning_effort=effort)


if __name__ == "__main__":
    main()
