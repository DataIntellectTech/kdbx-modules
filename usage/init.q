//Load core functionality into root module namespace
\l ::usage.q

//Return to root module namespace to simplify exposure of public functions
\d .z.m
export:([init:init; usage:getusage])