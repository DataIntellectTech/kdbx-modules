validFlags:"-+ 0";
HEX:"0123456789abcdef";

typeConversions:([
    d:{$[10h~type x;"J"$x;"j"$x]};
    f:{$[10h~type x;"F"$x;"f"$x]};
    x:{{$[10h~type x;x;ltrim raze " ",'flip x]} HEX 16 vs "i"$x};
    X:{upper {$[10h~type x;x;ltrim raze " ",'flip x]} HEX 16 vs "i"$x};
    o:{{$[10h~type x;x;ltrim raze " ",'flip x]} HEX 8 vs "i"$x};
    O:{upper {$[10h~type x;x;ltrim raze " ",'flip x]} HEX 8 vs "i"$x};
    s:{$[10h~abs tx:type x;x;-11h~tx;string x;.Q.s1 x]};
    r:.Q.s1]);

typePrecisions:([
    d:{a:string x;if[y~"";:a];c:count a;if[c>=y;:a]; ((y-c)#"0"),a};
    f:{if[y~"";:{.Q.fmt[x+1+count string floor y;x;y]}[6;x]];-27!(`int$y;x)};
    x:{a:x;if[y~"";:a];c:count a;if[c>=y;:a]; ((y-c)#"0"),a};
    X:{a:x;if[y~"";:a];c:count a;if[c>=y;:a]; ((y-c)#"0"),a};
    o:{a:x;if[y~"";:a];c:count a;if[c>=y;:a]; ((y-c)#"0"),a};
    O:{a:x;if[y~"";:a];c:count a;if[c>=y;:a]; ((y-c)#"0"),a};
    s:{if[y~"";:x];y sublist x};
    r:{[x;y]x}]);

typeFlags:string key typeConversions;

fwn:{nxy:not x in y;i:first where nxy;a:i#x;b:i _x;(a;b)};

vconst:{[flags;width;precision;ty;variable]
    (fneg;fpos;fspace;fzero):validFlags in flags;
    fpres:0b;
    if[ty~"";:""]; // early exit if nothing
    a:typeConversions[`$ty][variable];
    if[not ""~precision;precision:"J"$1 _ precision;fpres:1b];
    res:typePrecisions[`$ty][a;precision];
    if[ty in "fd";if[a>=0;res:$[fpos;"+";fspace;" ";""],res]];
    if[width~"";:res];
    pad:("J"$width)-count res;
    if[pad>0;
        res:$[fneg;
            res,pad#" ";
            fzero & (not[fpres] or ty in "f") & not ty in "sr";
            $[first[res] in "+-";first[res],(pad#"0"),1 _ res;(pad#"0"),res];
            (pad#" "),res]];
    res
 };

vrep:{[str;variable]
    fmt:1 _ str;
    (flags;fmt):fwn[fmt;validFlags];
    (width;fmt):fwn[fmt;.Q.n];
    (precision;fmt):fwn[fmt;.Q.n,"."];
    ty:$[first[fmt] in typeFlags;first fmt;""];
    fmt:1 _fmt;
    parsed:vconst[flags;width;precision;ty;variable];
    (parsed;fmt)
 };

process:{[d;variable] 
    // if no % then everything is parsed
    if[not any bs:"%"=d`unparsed;
        d[`parsed],:d[`unparsed];
        d[`unparsed]:"";
        :d
    ];
    // make the parse just look from the start
    if[not first bs;
        d[`parsed],:first[where bs] # d`unparsed;
        d[`unparsed]:first[where bs] _ d`unparsed;
        :.z.s[d;variable]
    ];
    // Check if this is a literal %
    if["%%"~2 sublist d[`unparsed];
        d[`parsed],:"%";
        d[`unparsed]:2 _ d`unparsed;
        :.z.s[d;variable]
    ];
    // Handle variable replacement
    (parsed;unparsed):vrep[d`unparsed;variable];
    d[`parsed],:parsed;
    d[`unparsed]:unparsed;
    d
 };


printf:{
    if[10h~type x; // if string then check if escape characters
        $[x like "*%%*";x:(x;"");:x] // if it exists, modify x, if not return the string
    ];
    if[(not 0h~type x) or not 10h~type (x,()) 0;'`type];
    d:`parsed`unparsed!("";x 0);
    d:process/[d;1_x];
    d[`parsed],d[`unparsed]
 };

