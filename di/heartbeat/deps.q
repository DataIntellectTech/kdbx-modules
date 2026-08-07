/ hard module dependencies and their minimum versions, validated by di.depcheck
/ di.heartbeat has no hard dependencies - all runtime dependencies (log, timer,
/ handlers, pubsub, servers) are injected via init as dictionaries of functions
deps:(`$())!();
