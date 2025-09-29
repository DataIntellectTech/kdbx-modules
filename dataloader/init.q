//Load core functionality into root module namespace
\l dataloader.q
//Create secondary namespace level and load relevant script into it
\d .z.m.util
\l ::util.q
//Return to root module namespace to simplify exposure of public functions
\d .z.m
export:([init:init;loadallfiles:loadallfiles])
