/ hard module dependencies and their minimum versions, validated by di.depcheck.
/ these are the modules di.tickerplant `use`s in init.q. the injected log and timer are not declared
/ here - di.depcheck validates them through its core-contract check.
deps:`di.pubsub`di.eodtime`di.tplog!("0.1.0";"0.1.0";"0.1.0");
