/ hard module dependencies and their minimum versions, validated by di.depcheck
/ di.merge has no hard dependencies - its only runtime dependency (log) is injected via
/ init as a dictionary of functions, and the parted column(s) needed for a merge are
/ passed in by the caller (see di.sort) rather than read from sort config
deps:(`$())!();
