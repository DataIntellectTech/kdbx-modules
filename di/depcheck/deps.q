/ hard module dependencies and their minimum versions, validated by di.depcheck
/ di.depcheck has no hard dependencies - its only runtime dependency (log) is injected via init as a dictionary of
/ functions, following the same convention di.depcheck itself checks other modules against
deps:(`$())!();
