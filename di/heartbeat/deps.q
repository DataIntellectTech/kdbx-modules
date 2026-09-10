/ hard module dependencies and their minimum versions, validated by di.depcheck
/ di.heartbeat has no hard dependencies - all runtime dependencies (log, timer,
/ pubsub, servers) are injected via init as dictionaries of functions. a handlers
/ dict is accepted and ignored, for di.torq's uniform wiring - see depkeys
deps:(`$())!();
