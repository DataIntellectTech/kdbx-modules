/ load core dataloader functions
\l ::dataloader.q               
/ load util submodule
util:use`di.dataloader.util
/ expose public function
export:([loadallfiles:loadallfiles;addsortparams:addsortparams;sortparams:sortparams])
