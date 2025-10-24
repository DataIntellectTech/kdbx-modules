// load core dataloader functions
\l ::dataloader.q
// load util submodule
util:use`dataloader.util
// expose public function
export:([init:init;loadallfiles:loadallfiles])
