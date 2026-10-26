/ end-of-day time management - date resolution, roll scheduling and data timestamp adjustment

tz:use`di.tz

\l ::eodtime.q

/ module version from the VERSION file, checked by di.torq.depcheck
version:first read0`:::VERSION

export:([init;getd;getnextroll;getdailyadj;getrolltimezone;getdatatimezone;getrolltimeoffset;getroll;getdailyadjustment;setnextroll;setdailyadj;setd;version])
