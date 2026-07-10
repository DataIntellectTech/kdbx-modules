/ configuration loading and cascade resolution for the modular torq world.
/ note: `get` is a q reserved word, so it cannot be a top-level name; the query
/ function is defined as `getcfg` in config.q and exported under the `get` key.
\l ::config.q
export:([init;loadcascade;overrideconfig;getmodule]),(enlist`get)!enlist getcfg
