// ==========================================================
// di.email manual test script
// run in a q session after: email:use`di.email
// then call init with your smtp config before the send tests
// ==========================================================

// helpers
chk:{[label;result] -1 ($[result;"PASS: ";"FAIL: "],label);};
has:{$[10h=type x;0<count x ss y;0b]};  // has[string;substring] - only applies ss to char vectors
hasa:{any has[;y] each x};      // hasa[list;substring] - true if any element contains substring

// ==========================================================
// section 1: html text formatting
// ==========================================================
-1 "\n--- section 1: html text formatting ---";

t:.m.di.0email.addtext "hello";
chk["addtext produces <p> tag";     has[t;"<p "]];
chk["addtext contains text";        has[t;"hello"]];
chk["addtext closes <p>";           "</p>"~-4#t];

h1:.m.di.0email.mailheading["1";"title"];
chk["mailheading h1 opens";         "<h1 "~4#h1];
chk["mailheading h1 contains text"; has[h1;"title"]];
chk["mailheading h1 closes";        "</h1>"~-5#h1];

h3:.m.di.0email.mailheading["3";"small"];
chk["mailheading h3 tag";           "<h3 "~4#h3];
chk["mailheading h3 closes";        "</h3>"~-5#h3];

b:.m.di.0email.mailbold "bold text";
chk["mailbold opens <b>";           "<b "~3#b];
chk["mailbold closes </b>";         "</b>"~-4#b];

i:.m.di.0email.mailitalic "italic text";
chk["mailitalic opens <i>";         "<i "~3#i];
chk["mailitalic closes </i>";       "</i>"~-4#i];

chk["mailstring on string";         "hello"~.m.di.0email.mailstring "hello"];
chk["mailstring on int";            has[.m.di.0email.mailstring 1;"1"]];  // "1" or "1i" depending on version
chk["mailstring on float";          "1.5"~.m.di.0email.mailstring 1.5];
chk["mailstring on symbol";         "abc"~.m.di.0email.mailstring `abc];

// ==========================================================
// section 2: color and style helpers
// ==========================================================
-1 "\n--- section 2: color and style helpers ---";

ac:.m.di.0email.addcolor["red";"colored text"];
chk["addcolor contains color:red";  has[ac;"color:red"]];
chk["addcolor no font-size:px bug"; not has[ac;"font-size:px"]];

ms:.m.di.0email.mailsize["20";"sized text"];
chk["mailsize contains font-size";  has[ms;"font-size:20px"]];
chk["mailsize no spurious color";   not has[ms;"color:;"]];

bg:.m.di.0email.mailbgcolor["#ffff00";"highlighted"];
chk["mailbgcolor sets background";  has[bg;"background-color:#ffff00"]];

mc:.m.di.0email.mailcolors["blue";"#eeeeee";"14";"full"];
chk["mailcolors sets color";        has[mc;"color:blue"]];
chk["mailcolors sets background";   has[mc;"background-color:#eeeeee"]];
chk["mailcolors sets font-size";    has[mc;"font-size:14px"]];
chk["mailcolors sets display";      has[mc;"display:inline"]];

// ==========================================================
// section 3: links and bookmarks
// ==========================================================
-1 "\n--- section 3: links and bookmarks ---";

u:.m.di.0email.mailurl["https://example.com";"click here"];
chk["mailurl contains href";        has[u;"href=\"https://example.com\""]];
chk["mailurl contains link text";   has[u;"click here"]];
chk["mailurl uses <a> tag";         has[u;"<a "]];
chk["mailurl closes </a>";          "</a>"~-4#u];

bm:.m.di.0email.setbookmark "section1";
chk["setbookmark has name attr";    has[bm;"name=\"section1\""]];

gbm:.m.di.0email.getbookmark["section1";"go to section"];
chk["getbookmark links to anchor";  has[gbm;"href=\"#section1\""]];
chk["getbookmark has link text";    has[gbm;"go to section"]];

// ==========================================================
// section 4: tables and dicts
// ==========================================================
-1 "\n--- section 4: tables and dicts ---";

t:([]sym:`a`b`c;price:1.1 2.2 3.3;vol:100 200 300);

mt:.m.di.0email.mailtable[t];
chk["mailtable returns list";        0h=type mt];
chk["mailtable has <table> open";   has[first mt;"<table "]];
chk["mailtable has </table> close"; "</table>"~last mt];
chk["mailtable has header row";     hasa[mt;"<th "]];
chk["mailtable has data rows";      hasa[mt;"<td "]];
chk["mailtable all rows same bg";   not hasa[mt;"#e6e6ff"]];

zt:.m.di.0email.ztable[t];
chk["ztable has alternating colors"; hasa[zt;"#e6e6ff"]];

d:`name`age`dept!("alice";30;"eng");
md:.m.di.0email.maildict[d];
chk["maildict returns list";         0h=type md];
chk["maildict has key values";       hasa[md;"name"]];
chk["maildict has data values";      hasa[md;"alice"]];

et:([]a:`$();b:`float$());
met:.m.di.0email.mailtable[et];
chk["mailtable empty table no error"; 0h=type met];
chk["mailtable empty has header";    hasa[met;"<th "]];

st:([]name:("alice";"bob & carol");val:(1;2));
mst:.m.di.0email.mailtable[st];
chk["mailtable with string data";    hasa[mst;"alice"]];

// ==========================================================
// section 5: template construction
// ==========================================================
-1 "\n--- section 5: template construction ---";

body:(
  .m.di.0email.mailheading["1";"Report"];
  .m.di.0email.addtext "summary line");
body,:.m.di.0email.mailtable[([]a:1 2;b:3 4)];

tmpl:.m.di.0email.template0["from@example.com";"to@example.com";"test subject";body];
chk["template0 is a list";           0h=type tmpl];
chk["template0 has From header";     "From: from@example.com"~first tmpl];
chk["template0 has Subject header";  any "Subject: test subject"~/:tmpl];
chk["template0 has blank separator"; any ""~/:tmpl];
chk["template0 has <html> open";     any "<html>"~/:tmpl];
chk["template0 has </html> close";   "</html>"~last tmpl];
chk["template0 has <body> tag";      hasa[tmpl;"<body "]];

sepidx:first where ""~/:tmpl;
subidx:first where {has[x;"Subject"]} each tmpl;
htmlidx:first where "<html>"~/:tmpl;
chk["blank line after subject";      sepidx>subidx];
chk["blank line before html";        sepidx<htmlidx];

mt2:.m.di.0email.mailtemplate["frm";"to";"sub";body;""];
chk["mailtemplate no-att same as template0"; mt2~.m.di.0email.template0["frm";"to";"sub";body]];

tf:hsym`$first system"mktemp /tmp/emailtest.XXXXXXXXXX";
tf 0: enlist "test attachment content";
mt3:.m.di.0email.mailtemplate["frm";"to";"sub";body;tf];
chk["mailtemplate with att uses multipart"; hasa[mt3;"multipart/mixed"]];
chk["mailtemplate with att has boundary";   hasa[mt3;"boundary"]];
hdel tf;

// ==========================================================
// section 6: css helpers
// ==========================================================
-1 "\n--- section 6: css helpers ---";

css:.m.di.0email.dict2css[(`$"color";`$"background-color")!("red";"blue")];
chk["dict2css produces key:val";    has[css;"color:red"]];
chk["dict2css semicolon separated"; ";" in css];

cb:.m.di.0email.cssbody[];
chk["cssbody is a dict";            99h=type cb];
chk["cssbody has font-family";      any (`$"font-family")=key cb];
chk["cssbody has color";            any `color=key cb];

chk["getstyle body";                cb~.m.di.0email.getstyle[`body]];
chk["getstyle table all";           .m.di.0email.csstableall[]~.m.di.0email.getstyle[`table`all]];
chk["getstyle table header";        .m.di.0email.csstableheader[]~.m.di.0email.getstyle[`table`header]];
chk["getstyle table row odd";       .m.di.0email.csstablerowodd[]~.m.di.0email.getstyle[`table`row`odd]];
chk["getstyle table row even";      .m.di.0email.csstableroweven[]~.m.di.0email.getstyle[`table`row`even]];

as:.m.di.0email.addstyle["p";`body];
chk["addstyle adds style attr";     has[as;"style="]];
chk["addstyle keeps tag name";      "p "~2#as];

// ==========================================================
// section 7: color utilities
// ==========================================================
-1 "\n--- section 7: color utilities ---";

chk["colornormalize mid";           0.5~.m.di.0email.colornormalize[0f;10f;5f]];
chk["colornormalize clamps low";    0f~.m.di.0email.colornormalize[0f;10f;-1f]];
chk["colornormalize clamps high";   1f~.m.di.0email.colornormalize[0f;10f;11f]];

rgb:.m.di.0email.colorhsv2rgb[0f;1f;1f];
chk["colorhsv2rgb returns 3 bytes"; 3=count rgb];
chk["colorhsv2rgb red is max";      rgb[0]=max rgb];

mono:.m.di.0email.colorizemono[`red;0f;100f;0 50 100f];
chk["colorizemono returns list";    3=count mono];
chk["colorizemono each is 3 bytes"; all 3=count each mono];

// ==========================================================
// section 8: send integration tests (requires init with smtp)
// ==========================================================
-1 "\n--- section 8: send integration (runs actual sends) ---";
-1 "NOTE: these require email.init[] called with valid smtp config";
-1 "      check your inbox after each test";

sendtest:{[label;msgdict]
  res:email.senddefault[msgdict];
  chk[label," returns 1b"; 1b~res];
  chk[label," logged sent"; `sent~last exec status from email.getstatus[]];
  };

to:`$"dlee01592@gmail.com";

sendtest["plain text";
  `to`subject`body!(to;"[TEST A] plain text";enlist"this is plain text")];

body:();
body,:enlist .m.di.0email.mailheading["1";"Sales Report"];
body,:enlist .m.di.0email.addtext "daily summary";
body,:.m.di.0email.mailtable[([]sym:`AAPL`GOOG;price:150.0 120.0;vol:1000 2000)];
sendtest["heading and table";
  `to`subject`body!(to;"[TEST B] heading and table";body)];

body:();
body,:enlist .m.di.0email.addcolor["red";"WARNING: high memory usage"];
body,:enlist .m.di.0email.mailbgcolor["#ffff99";"highlighted row"];
body,:enlist .m.di.0email.mailsize["20";"large text"];
body,:enlist .m.di.0email.mailcolors["white";"#333333";"14";"inverted text"];
sendtest["color helpers";
  `to`subject`body!(to;"[TEST C] colors";body)];

body:();
body,:enlist .m.di.0email.mailheading["2";"Links"];
body,:enlist .m.di.0email.mailurl["https://example.com";"click here"];
body,:enlist .m.di.0email.mailbold "bold statement";
body,:enlist .m.di.0email.mailitalic "italic note";
sendtest["links and formatting";
  `to`subject`body!(to;"[TEST D] links and formatting";body)];

// ztable returns a list of strings - concat directly, not enlist
body:.m.di.0email.ztable[([]a:1 2 3 4;b:`x`y`z`w)];
sendtest["ztable alternating rows";
  `to`subject`body!(to;"[TEST E] ztable";body)];

// maildict returns a list of strings - concat directly, not enlist
body:.m.di.0email.maildict[`server`status`uptime!("prod01";"ok";"99.9%")];
sendtest["maildict";
  `to`subject`body!(to;"[TEST F] maildict";body)];

// single attachment
tf:hsym`$first system"mktemp /tmp/emailtest.XXXXXXXXXX";
tf 0: ("sym,price";"AAPL,182.5";"GOOG,141.3");
sendtest["single attachment";
  `to`subject`body`attachments!(to;"[TEST G] single attachment";enlist"see attached csv";tf)];
hdel tf;

// multiple attachments
tf1:hsym`$first system"mktemp /tmp/emailtest.XXXXXXXXXX";
tf2:hsym`$first system"mktemp /tmp/emailtest.XXXXXXXXXX";
tf1 0: ("sym,price";"AAPL,182.5");
tf2 0: enlist "notes: eod prices";
sendtest["multiple attachments";
  `to`subject`body`attachments!(to;"[TEST H] multiple attachments";enlist"see 2 attached files";tf1,tf2)];
hdel each tf1,tf2;

mocklog:`info`warn`error!({[c;m]};{[c;m]};{[c;m]});
email.init[(::);enlist[`log]!enlist mocklog];
chk["disabled returns -1"; -1~email.senddefault`to`subject`body!(to;"disabled";"x")];

-1 "\n--- done ---";
