"""Ask an OpenAI model each conversation, one session per conversation, writing judge.py's format.

    OPENAI_API_KEY=sk-... python3 -I converse_openai.py CONVERSATIONS RUNDIR [id ...] \\
        --model gpt-5.4 --port 5198

Each conversation keeps one message history across its turns, bound to the conversation's persona
(-direct -user), with eval/agent/CLAUDE.md and the server's primer in the system prompt, and the
same qsp tools as run_openai.py. Writes RUNDIR/<id>.json for judge.py.
"""
import argparse
import json
import os
import sys
import time
import uuid

EVAL = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, EVAL)
import run_openai as ro  # noqa: E402


def run_turn(user, question, messages, port, model, api_key, base_url, max_turns, reasoning_effort=None, ctx=None):
    start_len = len(messages)
    use_responses = bool(reasoning_effort and reasoning_effort != "none")
    prev_id_start = ctx["prev_id"] if ctx is not None else None
    system = messages[0]["content"]
    if not use_responses:
        messages.append({"role": "user", "content": question})
    calls = []
    usage = {"prompt_tokens": 0, "cached_tokens": 0, "completion_tokens": 0}
    reply = ""
    stderr = ""
    exit_code = 0
    resolved_model = model
    t0 = time.time()

    try:
        if use_responses:
            prev_id = prev_id_start
            next_input = [{"role": "user", "content": question}]
            for _ in range(max_turns):
                resp = ro.openai_response(
                    api_key, base_url, model, system, next_input,
                    tools=ro.RESP_TOOLS, reasoning_effort=reasoning_effort, previous_response_id=prev_id,
                )
                prev_id = resp.get("id")
                resolved_model = resp.get("model") or model
                text, fcalls, u = ro.parse_response_output(resp)
                usage["prompt_tokens"] += u["prompt_tokens"]
                usage["cached_tokens"] += u["cached_tokens"]
                usage["completion_tokens"] += u["completion_tokens"]
                if not fcalls:
                    reply = text
                    break
                next_input = []
                for fc in fcalls:
                    name = fc["name"]
                    try:
                        args = json.loads(fc["arguments"])
                    except ValueError:
                        args = {}
                    call_name = ro.CALL_MAP.get(name)
                    if not call_name:
                        ok, out_text = False, f"Unknown tool: {name}"
                    else:
                        ok, out_text = ro.call_q(port, user, call_name, args.get("query"))
                    calls.append({"tool": name, "input": args, "error": not ok, "result": out_text[:4000]})
                    next_input.append({"type": "function_call_output", "call_id": fc["id"], "output": out_text})
            else:
                resp = ro.openai_response(
                    api_key, base_url, model, system,
                    [{"role": "user", "content": "Please provide your final answer now based on the tool results above."}],
                    tools=None, reasoning_effort=reasoning_effort, previous_response_id=prev_id,
                )
                prev_id = resp.get("id")
                text, _, u = ro.parse_response_output(resp)
                usage["prompt_tokens"] += u["prompt_tokens"]
                usage["cached_tokens"] += u["cached_tokens"]
                usage["completion_tokens"] += u["completion_tokens"]
                reply = text
            if ctx is not None:
                ctx["prev_id"] = prev_id
        else:
            for _ in range(max_turns):
                resp = ro.openai_chat(api_key, base_url, model, messages, ro.TOOLS)
                resolved_model = resp.get("model") or model
                u = resp.get("usage") or {}
                usage["prompt_tokens"] += u.get("prompt_tokens", 0)
                usage["cached_tokens"] += (u.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
                usage["completion_tokens"] += u.get("completion_tokens", 0)

                msg = resp["choices"][0]["message"]
                wire_msg = {"role": "assistant", "content": msg.get("content")}
                tcs = msg.get("tool_calls") or []
                if tcs:
                    wire_msg["tool_calls"] = tcs
                messages.append(wire_msg)

                if not tcs:
                    reply = msg.get("content") or ""
                    break

                for tc in tcs:
                    name = tc["function"]["name"]
                    try:
                        args = json.loads(tc["function"].get("arguments") or "{}")
                    except ValueError:
                        args = {}
                    call_name = ro.CALL_MAP.get(name)
                    if not call_name:
                        ok, text = False, f"Unknown tool: {name}"
                    else:
                        ok, text = ro.call_q(port, user, call_name, args.get("query"))
                    calls.append({"tool": name, "input": args, "error": not ok, "result": text[:4000]})
                    messages.append({"role": "tool", "tool_call_id": tc["id"], "content": text})
            else:
                messages.append({"role": "user", "content": "Please provide your final answer now based on the tool results above."})
                resp = ro.openai_chat(api_key, base_url, model, messages, tools=None)
                u = resp.get("usage") or {}
                usage["prompt_tokens"] += u.get("prompt_tokens", 0)
                usage["cached_tokens"] += (u.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
                usage["completion_tokens"] += u.get("completion_tokens", 0)
                msg = resp["choices"][0]["message"]
                reply = msg.get("content") or ""
                messages.append({"role": "assistant", "content": reply})
    except Exception as e:
        exit_code = 1
        stderr = str(e)
        del messages[start_len:]
        if ctx is not None:
            ctx["prev_id"] = prev_id_start

    secs = time.time() - t0
    cost = round(ro.calc_cost(model, usage), 6)
    return {
        "question": question,
        "reply": reply,
        "model": resolved_model,
        "queries": [c["input"].get("query") for c in calls if c["tool"] == "qsp_query"],
        "tools": [c["tool"] for c in calls],
        "refused": sum(c["error"] for c in calls),
        "cost": cost,
        "usage": usage,
        "seconds": round(secs, 1),
        "exit": exit_code,
        "stderr": stderr[-2000:],
    }


def main():
    a = argparse.ArgumentParser()
    a.add_argument("conversations")
    a.add_argument("rundir")
    a.add_argument("ids", nargs="*")
    a.add_argument("--model", default="gpt-5.4")
    a.add_argument("--port", default=os.environ.get("QSP_PORT", "5100"))
    a.add_argument("--base-url", default=os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1"))
    a.add_argument("--no-primer", action="store_true")
    a.add_argument("--max-turns", type=int, default=30)
    a.add_argument("--reasoning-effort", default=None, help="Reasoning effort (none, low, medium, high; default medium for gpt-5/o*)")
    a.add_argument("--skip-existing", action="store_true")
    o = a.parse_args()

    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        sys.exit("converse_openai.py: set OPENAI_API_KEY in the environment")

    effort = o.reasoning_effort if o.reasoning_effort is not None else ro.default_reasoning_effort(o.model)
    os.makedirs(o.rundir, exist_ok=True)
    instructions = open(ro.INSTRUCTIONS_MD).read()
    primer_cache = {}

    for conv in json.load(open(o.conversations)):
        if o.ids and conv["id"] not in o.ids:
            continue
        out_path = os.path.join(o.rundir, conv["id"] + ".json")
        if o.skip_existing and os.path.exists(out_path):
            print(f"{conv['id']:14} skipped (exists)", flush=True)
            continue

        user = conv["persona"]
        system = instructions + f"\n\nYou act for qsp user {user}: every query runs as {user}, and no tool can act as anyone else."
        if not o.no_primer:
            if user not in primer_cache:
                primer_cache[user] = ro.fetch_primer(o.port, user)
            system += "\n\n" + primer_cache[user]

        session = str(uuid.uuid4())
        messages = [{"role": "system", "content": system}]
        ctx = {"prev_id": None}
        turns = []
        for t in conv["turns"]:
            r = run_turn(user, t["question"], messages, o.port, o.model, api_key, o.base_url, o.max_turns, reasoning_effort=effort, ctx=ctx)
            r["turn"] = t["turn"]
            turns.append(r)
            print(
                f"{conv['id']:14} turn {r['turn']}  {len(r['tools']):2} calls  {r['refused']} refused  "
                f"${r['cost']:.3f}  {r['seconds']:5.1f}s"
                + (f"  ERR: {r['stderr'][:60]}" if r["stderr"] else ""),
                flush=True,
            )

        with open(out_path, "w") as f:
            json.dump(
                {"id": conv["id"], "persona": user, "session": session, "model": o.model,
                 "primer": not o.no_primer, "turns": turns},
                f,
                indent=1,
            )


if __name__ == "__main__":
    main()
