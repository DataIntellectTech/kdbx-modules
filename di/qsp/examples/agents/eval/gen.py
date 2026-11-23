"""The held-out questions, as the eval asks them.

    python3 -I gen.py QUESTIONS.YAML surveillance > questions-surveillance.json
    python3 -I gen.py QUESTIONS.YAML example      > questions-example.json

QUESTIONS.YAML is the surveillance agent's question set (qsp/semantic/eval/questions.yaml in the
original qsp repository). Only its 22 held-out questions (h-1 to h-22) are taken.

  surveillance  as the surveillance agent was asked them: its dates (2026.10.02 to 2026.10.08), as
                llmu2, for its database under policylargeequitiesdb
  example       on the equities example's dates (2026.10.05 to 2026.10.09) as quant1 (compliance1
                for h-11, which reads orders). The example holds far fewer rows, so three windows
                are widened to leave a truth that is not empty, and h-17's sessions end at 16:00,
                because the example has fills after the close
"""
import json, sys, yaml

SETS = {
    "surveillance": {"dates": {"d1": "2026.10.02", "d5": "2026.10.08"}, "persona": lambda i: "llmu2", "override": {}},
    "example": {
        "dates": {"d1": "2026.10.05", "d5": "2026.10.09"},
        "persona": lambda i: "compliance1" if i == "h-11" else "quant1",
        "override": {
            "h-4": [("more than two standard deviations", "more than one and a half standard deviations"), (">2*(dev", ">1.5*(dev")],
            "h-12": [("between 10:00 and 10:02", "between 10:00 and 10:30"), ("D10:02)", "D10:30)")],
            "h-14": [("first five minutes", "first thirty minutes"), ("D09:35)", "D10:00)")],
            "h-17": [("bin time from trades where date=2026.10.05,sym=`MSFT", "bin time from trades where date=2026.10.05,sym=`MSFT,time within (2026.10.05D09:30;2026.10.05D16:00)")],
        },
    },
}


def main():
    src, which = sys.argv[1], sys.argv[2]
    cfg = SETS[which]
    out = []
    for q in yaml.safe_load(open(src))["questions"]:
        if not q["id"].startswith("h-"):
            continue
        text, query = q["question"], q["q"].strip()
        for k, v in cfg["dates"].items():
            text, query = text.replace("{{%s}}" % k, v), query.replace("{{%s}}" % k, v)
        assert "{{" not in text + query, q["id"]
        for a, b in cfg["override"].get(q["id"], []):
            text, query = text.replace(a, b), query.replace(a, b)
        out.append({"id": q["id"], "question": text, "q": query, "kind": q["kind"],
                    "tolerance": q.get("tolerance"), "persona": cfg["persona"](q["id"]),
                    "changed": q["id"] in cfg["override"]})
    json.dump(out, sys.stdout, indent=1)


if __name__ == "__main__":
    main()
