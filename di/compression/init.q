/ Load core functionality into root module namespace
\l ::compression.q

/ Load KX log module
.logger:use`kx.log
.log:.logger.createLog[]
.log.addfmt[`custom;"$l: $p PID[$i] $m\n"]; / Simplified logging - DELETE
.log.setfmt[`custom]

export:([
        checkcsv:checkcsv;
        loadcsv:loadcsv;
        hdbstructure:hdbstructure;
        showcomp:showcomp;
        compressfromtable:compressfromtable;
        statstabupdate:statstabupdate;
        singlethreadcompress:singlethreadcompress;
        multithreadcompress:multithreadcompress;
        compressmaxage:compressmaxage;
        docompression:docompression;
        summarystats:summarystats;
        compress:compress;
        cleancompressed:cleancompressed;
        hashfilecheck:hashfilecheck
        ])
