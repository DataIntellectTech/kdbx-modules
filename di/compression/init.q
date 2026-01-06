/ Load core functionality into root module namespace
\l ::compression.q

/ Load KX log module - needed for .log.info and .log.error
.logger:use`kx.log
.log:.logger.createLog[]
.log.addfmt[`custom;"$l: $p PID[$i] $m\n"];
.log.setfmt[`custom]

export:([
        showcomp:showcomp;
        getcompressioncsv:getcompressioncsv;
        compressmaxage:compressmaxage;
        docompression:docompression;
        getstatstab:getstatstab
        ])
