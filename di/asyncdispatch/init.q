/ Load core functionality into root module namespace
\l ::asyncdispatch.q

export:([servers;queryqueue;clients;results;
        errorprefix;querykeeptime;clearinactivetime;synccallsallowed;
        cp;setcp;formatresponse;setformatresponse;
        setcallbacks;setavailableservers;setgetnextqueryid;
        addserver;setserverstate;availableservers;
        addclientdetails;removeclienthandle;addquery;
        addserverresult;addservererror;runnextquery;
        getnextqueryid;execquery;
        checktimeout;removequeries;removeinactive;removeserverhandle;init])
