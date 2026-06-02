/ load core dataloader functions
\l ::dataloader.q               
/ load util submodule
util:use`.util
/ expose public function
export:([loadallfiles;addsortparams;sortparams])
