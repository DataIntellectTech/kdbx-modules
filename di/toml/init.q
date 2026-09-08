/ a small scoped-down TOML parser for the modular torq world - reads settings .toml files into
/ q dicts. pure module (no init, no injected deps); di.config lazily loads it to parse .toml tiers.
\l ::toml.q
export:([parsetoml;parsefile;getapimeta])
