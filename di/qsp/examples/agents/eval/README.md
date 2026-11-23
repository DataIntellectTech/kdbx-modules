# The agent eval

How well an LLM agent answers questions through qsp, measured the way the surveillance agent
measures itself, so the two can be compared. Results are in [results.md](results.md).

## The questions

The surveillance agent's 22 held-out questions (h-1 to h-22): analytics questions no template
covers, each with the q that answers it. They come from its question set
(`qsp/semantic/eval/questions.yaml` in the original qsp repository), via `gen.py`:

| file | asked of | as |
|---|---|---|
| `questions-surveillance.json` | the surveillance database, under `examples/equities/policylargeequitiesdb` | `llmu2`, as the surveillance agent was |
| `questions-example.json` | the equities example's database | `quant1` (`compliance1` for h-11) |

The example holds far fewer rows than the surveillance database, so `gen.py` widens three
windows in its set, and ends h-17's sessions at 16:00. On the surveillance set, nothing changes,
and the truth qsp computes matches the surveillance agent's stored truth on all 22.

Its 20 conversational turns - six conversations whose turns build on one another, such as "Was
that the whole tech sector, or just that name?" - are in `conversations-surveillance.json`, from
`converse-gen.py`. Each holds its turns, the truth the surveillance eval wrote for each, the checks
its reply had to pass, and the user it was asked as: `llmu3` for the boundary conversation, which
tests explaining a refusal, `llmu2` for the rest.

## Running it

```sh
# a server for the database, with the timeout the surveillance gateway had
q di/qsp/examples/agents/server.q -p 5198 -T 10 -db .../largeequitiesdb -policy .../policylargeequitiesdb

# ask each question: one claude -p each, bound to its user, the primer in the system prompt
cd di/qsp/examples/agents/eval
python3 -I run.py questions-surveillance.json runs/NAME --port 5198      # --no-primer to leave it out

# or against an OpenAI model (requires OPENAI_API_KEY in the environment):
python3 -I run_openai.py questions-surveillance.json runs/NAME --model gpt-5.4 --port 5198

# score it
q score.q -questions questions-surveillance.json -run runs/NAME -db .../largeequitiesdb -policy .../policylargeequitiesdb
```

Conversations, one claude session each, resumed turn by turn, then graded:

```sh
python3 -I converse.py conversations-surveillance.json runs/NAME --port 5198
python3 -I judge.py conversations-surveillance.json runs/NAME
```

`score.q -check` instead checks that each reference query scores itself, and that no truth is
empty. A run costs about $3-5 and takes 12-15 minutes. `runs/` is not in git.

## How it is scored

### Single questions

The truth is each question's reference q, run through qsp as the question's user. Every query
the agent ran is replayed as that user, and a question is correct if one returns the truth:

- **A number:** a cell of its first five rows within tolerance.
- **A table:** each of the truth's first five rows found in one of its rows, by value,
  whatever the agent called its columns.

This follows the surveillance agent's own `replay.py`, which replays every read, with its two
#543 fixes:

- A time is compared as time of day.
- A symbol column the question fixed need not be echoed back.

Unlike surveillance, the row count isn't required to match exactly, so this scoring is slightly
more lenient. The last query alone is scored too.

### Conversations

A turn passes when every one of its checks holds and an LLM judge agrees that the reply matches the
truth, as in the surveillance eval. The judge is a separate `claude -p` with no tools. A judge can
be wrong, so read the replies of the turns it fails.

## Files

| file | what it is |
|---|---|
| `gen.py` | the question sets, from the surveillance agent's questions.yaml |
| `run.py` | asks each question as `agent.sh` would, and keeps the transcript, tool calls, cost and time |
| `score.q` | the truth through qsp, and the replay scoring |
| `converse-gen.py`, `converse.py`, `judge.py` | the conversations, asking them a session at a time, and grading each turn as the surveillance eval did: every check, and an LLM judge against its truth |
| `agent/CLAUDE.md` | the agent example's instructions without the example's dates and users, so the agent can be asked about any database |
| `results.md` | each run's score, refusals and cost, and what changed between them |
