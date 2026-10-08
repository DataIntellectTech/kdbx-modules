// module for sending html emails via the system sendmail utility
// ported from torq code/common/email.q and code/processes/reporter.q
// html construction and sendmail transport ported from qmail (github.com/BestiaPL/qmail)
// no c library or smtp server required

// ============================================================
// sendmail utilities (ported from qmail)
// ============================================================

utilityexists:{@[system;"which ",x," 2>/dev/null";0b]};

hsym2str:{[x] $[":"=first s:string x;1_s;s]};

checkfile:{if[not x~key x:hsym x;'"file not found: ",hsym2str x]};

encodefile:{[x]
  checkfile x;
  system "base64 \"",hsym2str[x],"\""
  };

mimetype:{[a]
  if[0b~utilityexists "file"; :"application/octet-stream"];
  r:@[system;"file --mime-type ",hsym2str a;{[e]enlist ": application/octet-stream"}];
  if[not count r; :"application/octet-stream"];
  mt:trim last ":" vs first r;
  $[10h=type mt;mt;"application/octet-stream"]};

mailheader:{[]
  ("<html>";"<body style=\"width:100%; margin:0; padding:0; font-size:15px;\">")
  };

mailfooter:("</body>";"</html>");

template0:{[frm;to;sub;body]
  enlist["From: ",frm],
  enlist["To: ",to],
  enlist["Subject: ",sub],
  enlist["MIME-Version: 1.0"],
  enlist["Content-Type: text/html; charset=UTF-8"],
  enlist[""],
  mailheader[],
  body,
  mailfooter
  };

mailtemplate:{[frm;to;sub;body;att]
  if[not count att where not null att,:();:template0[frm;to;sub;body]];
  boundary:"====",string[rand 0Ng],"====";
  enlist["From: ",frm],
  enlist["To: ",to],
  enlist["Subject: ",sub],
  enlist["Content-Type: multipart/mixed; boundary=\"",boundary,"\""],
  enlist["MIME-Version: 1.0"],
  enlist[""],
  enlist["--",boundary],
  enlist["Content-Type: text/html; charset=UTF-8"],
  enlist[""],
  mailheader[],
  body,
  mailfooter,
  (raze {[a;boundary]
    fn:last "/"vs hsym2str a;
    enlist[""],
    enlist["--",boundary],
    enlist["Content-Transfer-Encoding: base64"],
    enlist["Content-Type: ",mimetype[a],"; name=\"",fn,"\""],
    enlist["Content-Disposition: attachment; filename=\"",fn,"\""],
    enlist[""],
    encodefile[a],
    enlist[""]
  }[;boundary] each att),
  enlist["--",boundary,"--"]
  };

mailsend:{[frm;to;sub;body;att]
  // send an html email via the system sendmail utility
  // frm  - string from address
  // to   - string, comma-delimited recipient addresses
  // sub  - string subject
  // body - list of strings (html content)
  // att  - "" for no attachment, or list of hsym file paths
  if[0b~utilityexists "sendmail";'"sendmail not found on this system"];
  if[not att~"";if[10h=type att;att:enlist att]];
  fn:hsym`$first system"mktemp /tmp/qmail.XXXXXXXXXX";
  fn 0: mailtemplate[frm;to;sub;body;att];
  @[system;"sendmail -t < ",1_string fn;{[fn;e]hdel fn;'"sendmail error: ",e}[fn]];
  hdel fn;
  };

// ============================================================
// html construction helpers (ported from qmail)
// ============================================================

mailstring:{$[10h=abs type x;x;(type[x] in 0 98 99h) or (100h<type x) or 0h<type x;.Q.s1 x;string x]};

dict2css:{";"sv":"sv'flip(string@key@;value)@\:x};

cssbody:{(!) . flip 2 cut(
  `$"font-family";"Verdana, Geneva, Sans-Serif";
  `$"color";"#2f4a5c")};

csstableall:{cssbody[],(!) . flip 2 cut(
  `$"font-family";"Verdana, Geneva, Sans-Serif";
  `$"font-size";"15px";
  `margin;"0 ";
  `padding;"3px";
  `$"line-height";"100%";
  `$"text-align";"left";
  `color;"#069";
  `$"border-width";"2px";
  `$"border-collapse";"collapse";
  `$"background-color";"#ffffff";
  `$"border-color";"#ffffff")};

csstableheader:{csstableall[],(!) . flip 2 cut(
  `$"border-style";"solid";
  `$"background-color";"#5473bf";
  `color;"#ffffff";
  `$"border-color";"#ffffff";
  `$"border-width";"2px")};

csstablerowall:{csstableall[],(!) . flip 2 cut(
  `$"border-style";"solid";
  `$"border-width";"2px";
  `$"border-color";"#ffffff")};

csstablerowodd:{csstablerowall[],enlist[`$"background-color"]!enlist "#e6e6ff"};

csstableroweven:{csstablerowall[],enlist[`$"background-color"]!enlist "#ffffff"};

getstyle:{[x]
  k:(),x;
  $[k~enlist `body; cssbody[];
    k~`table`all; csstableall[];
    k~`table`header; csstableheader[];
    k~`table`row`all; csstablerowall[];
    k~`table`row`odd; csstablerowodd[];
    csstableroweven[]]
  };

addstyle:{x," style=\"",(dict2css getstyle[y]),"\""};

mailwrap:{"<",x,">",y,"</",(first " "vs (),x),">"};
mailewrap:{enlist["<",x,">"],y,enlist"</",(first " "vs (),x),">"};

addtext:{mailwrap[addstyle["p";`body];x]};
mailheading:{mailwrap[addstyle["h",x;`body];y]};
mailbold:{mailwrap[addstyle["b";`body];mailstring x]};
mailitalic:{mailwrap[addstyle["i";`body];mailstring x]};

mailcolors:{[color;bg;sz;text]
  styledict:(`$("color";"background-color";"font-size";"display"))!(color;bg;$[count sz;sz,"px";""];"inline");
  styledict:#[;styledict]where not ""~/:styledict;
  mailwrap["p style=\"",(dict2css cssbody[],styledict),"\"";mailstring[text]]};

addcolor:{mailcolors[x;"";"";y]};
mailsize:{mailcolors["";"";x;y]};
mailbgcolor:{mailcolors["";x;"";y]};

mailurl:{[u;txt]mailwrap[addstyle["a href=\"",u,"\"";`body];txt]};
setbookmark:{[id]"<a name=\"",id,"\"></a>"};
getbookmark:{[id;txt]mailurl["#",id;txt]};

mailrow:{mailewrap["tr";mailwrap[x]each mailstring each y]};

table0:{[t;alt]
  h:mailrow[addstyle["th";`table`header];cols t];
  b:raze mailrow'[addstyle["td"] each`table`row,/:$[alt;?[1=til[count t]mod 2;`odd;`even];count[t]#`even];flip value flip 0!t];
  mailewrap[addstyle["table";`table`all];h,b]
  };

mailtable:{table0[x;0b]};
ztable:{table0[x;1b]};

dict0:{[d;alt]
  b:raze mailrow'[addstyle["td"] each`table`row,/:$[alt;?[1=til[count d]mod 2;`odd;`even];count[d]#`even];flip(key;value)@\:d];
  mailewrap["table";b]
  };

maildict:{dict0[x;0b]};
zdict:{dict0[x;1b]};

colornormalize:{[low;high;x]0f | 1f & (x - low)%(high - low)};
colorhex2html:{"#",raze string x};

colorhsv2rgb:{[h;s;v]
  C:v*s;
  H:(h mod 360f)%60f;
  X:C * 1 - abs -1f + H mod 2;
  m:v-C;
  D:`s#0 1 2 3 4 5 6f!(1 2 0;2 1 0;0 1 2;0 2 1;2 0 1;1 0 2;0 0 0);
  `byte$255*m + (0f;C;X)D H
  };

colorhuemap:(!). flip (
  (`red;0);(`orange;30);(`yellow;60);(`lime;90);(`green;120);
  (`turquoise;150);(`cyan;180);(`blue;240);(`purple;270);
  (`pink;300);(`violet;330));

colorizemono:{[color;min_val;max_val;x]
  s_values:colornormalize[min_val;max_val;x];
  colorhsv2rgb[$[-11h=type color;colorhuemap[color];color];;1f]each s_values
  };

colorizestereo:{[color_min;color_max;min_val;max_val;pivot_val;x]
  low:x<pivot_val;
  low_colors:colorizemono[color_min;pivot_val;min_val;x where low];
  high_colors:colorizemono[color_max;pivot_val;max_val;x where not low];
  @[;where not low;:;high_colors] @[;where low;:;low_colors] count[x]#enlist 0x000000
  };

// ============================================================
// module state and defaults
// ============================================================

// from address used in all outgoing emails - overwritten by init
mailfrom:"torq@localhost";

// email gate - overwritten by init
enabled:0b;

// controls whether senddefault appends rows to history - overwritten by init
historyenabled:1b;

// append-only table recording every send attempt
history:([]time:`timestamp$();recipients:`symbol$();subject:();status:`symbol$();bytes:`long$());

send:mailsend;

// smtp config - set by init when smtpurl is provided; used by smtpsend_
smtpurl:"";
smtpuser:"";
smtppassword:"";
smtpssl:1b;

// ============================================================
// internal helpers
// ============================================================

smtpsend_:{[frm;to;sub;body;att]
  // send via curl smtp transport using module smtp config (smtpurl/smtpuser/smtppassword/smtpssl)
  // signature matches mailsend: frm to sub body att
  if[0b~utilityexists "curl";'"curl not found on this system"];
  if[not att~"";if[10h=type att;att:enlist att]];
  // keep tmpfile as a plain string to avoid type issues when building cmd
  tmpfile:first system"mktemp /tmp/qmail.XXXXXXXXXX";
  fn:hsym`$tmpfile;
  .[{[a;b]a 0: b};(fn;mailtemplate[frm;to;sub;body;att]);{[fn;e]hdel fn;'"smtp write error: ",e}[fn]];
  rcpts:" " sv {[r]"--mail-rcpt '",r,"'"}each ","vs to;
  sslopt:$[smtpssl;"--ssl-reqd ";""];
  cmd:"curl --url '",smtpurl,"' ",sslopt,"--crlf --mail-from '",frm,"' ",rcpts," --user '",smtpuser,":",smtppassword,"' --upload-file ",tmpfile," 2>&1";
  @[{system x};cmd;{[fn;e]hdel fn;'"curl smtp error: ",e}[fn]];
  hdel fn;
  };


// ============================================================
// public api
// ============================================================

senddefault:{[msgdict]
  // send an html email via the system sendmail utility
  // msgdict keys: to (symbol or symbol list), subject (string), body (list of strings)
  //               optionally: attachments (hsym or list of hsyms)
  // returns 1b on success, 0b on send failure, -1 if disabled
  if[not enabled;
    .z.m.logerr[`email;"email sending is not enabled"];
    if[historyenabled;.z.m.loghistory[msgdict`to;msgdict`subject;`disabled;-1]];
    :-1;
  ];
  to:","sv string$[-11h=type msgdict`to;enlist msgdict`to;msgdict`to];
  htmlbody:{$[10h=type x;$[count x;$["<"=first x;x;addtext x];""];x]}'[msgdict[`body],enlist "email generated at ",(string .z.p)];
  att:$[`attachments in key msgdict;$[-11h=type msgdict`attachments;enlist msgdict`attachments;msgdict`attachments];""];
  res:.[send;(mailfrom;to;msgdict`subject;htmlbody;att);{[e].z.m.logerr[`email;"send failed: ",e];0b}];
  ok:not res~0b;
  if[historyenabled;loghistory[msgdict`to;msgdict`subject;`failed`sent ok;$[ok;0j;-1j]]];
  $[ok;
    .z.m.loginfo[`email;"email sent"];
    .z.m.logerr[`email;"failed to send email"]];
  :ok;
  };

test:{[to]
  // send a test email to verify sendmail connectivity
  // to - symbol e.g. `$"user@example.com"
  // returns 1b on success, 0b on failure
  :senddefault`to`subject`body!(to;"test email";enlist"this is a test email to verify sendmail is configured correctly");
  };

getstatus:{[]
  // return the full send history table
  :history;
  };

clearhistory:{[]
  // truncate the history table; schema is preserved
  // to clear on a schedule via di.timer:
  //   timer.addjob[`emailhistoryclear;email.clearhistory;();0D01:00:00:00;`repeat;()!()]
  .z.m.history:0#.z.m.history;
  };

init:{[config;deps]
  // initialise module with email config and injected log dependency
  // config - dict with any of:
  //   mailfrom        (string or symbol) - from address
  //   enabled         (boolean)          - gate for sending
  //   historyenabled  (boolean)          - whether to record sends in history table (default 1b)
  //   smtpurl         (string or symbol) - e.g. "smtp://smtp.gmail.com:587"; when set, curl is used
  //   smtpuser        (string or symbol) - smtp username
  //   smtppassword    (string)           - smtp password
  //   smtpssl         (boolean)          - require tls (default 1b)
  // pass (::) for config to use defaults (email disabled, sendmail transport)
  // deps - (enlist`log)!enlist logdict
  //   `log: `info`warn`error!({[c;m]};{[c;m]};{[c;m]}) - required; init throws if absent
  .z.m.mailfrom:"torq@localhost";
  .z.m.enabled:0b;
  .z.m.historyenabled:1b;
  // initialise history only once; subsequent init calls preserve existing rows
  if[98h<>type@[{.z.m.history};::;{""}];
    .z.m.history:([]time:`timestamp$();recipients:`symbol$();subject:();status:`symbol$();bytes:`long$())];
  // loghistory stored in .z.m so it executes with module context and can write to .z.m.history
  .z.m.loghistory:{[recipients;subject;status;bytes]
    .z.m.history:.z.m.history,enlist `time`recipients`subject`status`bytes!(.z.p;recipients;subject;status;`long$bytes);
    };
  .z.m.smtpurl:"";
  .z.m.smtpuser:"";
  .z.m.smtppassword:"";
  .z.m.smtpssl:1b;
  logdict:$[99h=type deps;$[(`log in key deps) and not (::)~deps`log;deps`log;()!()];()!()];
  if[not count logdict;'"di.email: log dependency is required; pass (enlist`log)!enlist logdep - see di.log"];
  .z.m.loginfo:logdict`info;
  .z.m.logwarn:logdict`warn;
  .z.m.logerr:logdict`error;
  if[99h=type config;
    if[`mailfrom in key config;.z.m.mailfrom:$[10h=type config`mailfrom;config`mailfrom;string config`mailfrom]];
    if[`enabled in key config;.z.m.enabled:config`enabled];
    if[`historyenabled in key config;.z.m.historyenabled:config`historyenabled];
    if[`smtpurl in key config;.z.m.smtpurl:$[10h=type config`smtpurl;config`smtpurl;string config`smtpurl]];
    if[`smtpuser in key config;.z.m.smtpuser:$[10h=type config`smtpuser;config`smtpuser;string config`smtpuser]];
    if[`smtppassword in key config;.z.m.smtppassword:$[10h=type config`smtppassword;config`smtppassword;string config`smtppassword]];
    if[`smtpssl in key config;.z.m.smtpssl:config`smtpssl];
  ];
  // select transport: curl smtp if smtpurl is set, otherwise sendmail
  .z.m.send:$[count smtpurl;smtpsend_;mailsend];
  };
