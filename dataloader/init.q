//Load core functionality into root module namespace
\l ::dataloader.q
//Create secondary namespace level and load relevant script into it
util:use`dataloader.util
//Return to root module namespace to simplify exposure of public functions
export:([init:init;loadallfiles:loadallfiles])
