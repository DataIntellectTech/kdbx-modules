//Load core functionality into root module namespace
\l ::usage.q

export:([
    init:init; 
    getusage:getusage; 
    readlog:readlog; 
    flushusage:flushusage;
    setextension:setextension;
    clearextension:clearextension
    ])
