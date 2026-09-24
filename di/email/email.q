/ module for sending html emails via the system sendmail utility
/ ported from torq code/common/email.q and code/processes/reporter.q
/ html construction and sendmail transport ported from qmail (github.com/BestiaPL/qmail)
/ no c library or smtp server required

/ ============================================================
/ sendmail utilities (ported from qmail)
/ ============================================================

utilityexists:{not 0b~@[system;"which ",x," 2>/dev/null";{0b}]};

hsym2str:{[x] $[":"=first s:string x;1_s;s]};

checkfile:{if[not x~key x:hsym x;'"file not found: ",hsym2str x]};

base64encode:$[.z.K >= 3.6;76 cut .Q.btoa@;{
  c:count[x]mod 3;
  pc:count p:(0x;0x0000;0x00)c;
  b:.Q.b6 2 sv/: 6 cut raze 0b vs/: x,p;
  76 cut(neg[pc] _ b),pc#"="}];

encodefile:{
  checkfile x;
  base64encode read1 x;
  };

mimetype:{[a]
  if[not utilityexists "file"; :"text/plain"];
  checkfile a;
  trim last ":" vs first @[system;"file --mime-type ",hsym2str a;{enlist ": text/plain"}];
  };

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
  enlist["Content-Type: text/html"],
  enlist[""],
  mailheader[],
  body,
  mailfooter,
  (raze {[a;boundary]
    fn:last "/"vs hsym2str a;
    enlist[""],
    enlist["--",boundary],
    enlist["Content-Transfer-Encoding: base64"],
    enlist["Content-Type: ",mimetype[a],"; name=",fn],
    enlist["Content-Disposition: attachment; filename=",fn],
    enlist[""],
    encodefile[a]
  }[;boundary] each att),
  enlist["--",boundary,"--"]
  };

mailsend:{[frm;to;sub;body;att]
  / send an html email via the system sendmail utility
  / frm  - string from address
  / to   - string, comma-delimited recipient addresses
  / sub  - string subject
  / body - list of strings (html content)
  / att  - "" for no attachment, or list of hsym file paths
  if[not utilityexists "sendmail";'"sendmail not found on this system"];
  if[not att~"";if[10h=type att;att:enlist att]];
  fn:hsym`$first system"mktemp /tmp/qmail.XXXXXXXXXX";
  fn 0: mailtemplate[frm;to;sub;body;att];
  @[system;"sendmail -t < ",1_string fn;{[fn;e]hdel fn;'"sendmail error: ",e}[fn]];
  hdel fn;
  };

/ ============================================================
/ html construction helpers (ported from qmail)
/ ============================================================

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

/ ============================================================
/ module state and defaults
/ ============================================================

/ from address used in all outgoing emails - overwritten by init
mailfrom:"torq@localhost";

/ email gate - overwritten by init
enabled:0b;

/ append-only table recording every send attempt
history:([]time:`timestamp$();recipients:`symbol$();subject:();status:`symbol$();bytes:`long$());

/ keyed table tracking last alert send time per procname+alertname pair (for cooldown)
alertstats:([procname:`symbol$();alertname:`symbol$()] lastsent:`timestamp$());

/ default send wraps mailsend - can be overridden in deps for testing
defaultsend:{[frm;to;sub;body;att]mailsend[frm;to;sub;body;att]};
send:defaultsend;

/ smtp config - set by init when smtpurl is provided; used by smtpsend_
smtpurl:"";
smtpuser:"";
smtppassword:"";
smtpssl:1b;

/ ============================================================
/ internal helpers
/ ============================================================

smtpsend_:{[frm;to;sub;body;att]
  / send via curl smtp transport using module smtp config (smtpurl/smtpuser/smtppassword/smtpssl)
  / signature matches mailsend: frm to sub body att
  if[not utilityexists "curl";'"curl not found on this system"];
  if[not att~"";if[10h=type att;att:enlist att]];
  / keep tmpfile as a plain string to avoid type issues when building cmd
  tmpfile:first system"mktemp /tmp/qmail.XXXXXXXXXX";
  fn:hsym`$tmpfile;
  .[{[a;b]a 0: b};(fn;mailtemplate[frm;to;sub;body;att]);{[fn;e]hdel fn;'"smtp write error: ",e}[fn]];
  rcpts:" " sv {[r]"--mail-rcpt '",r,"'"}each ","vs to;
  sslopt:$[smtpssl;"--ssl-reqd ";""];
  cmd:"curl --url '",smtpurl,"' ",sslopt,"--crlf --mail-from '",frm,"' ",rcpts," --user '",smtpuser,":",smtppassword,"' --upload-file ",tmpfile," 2>&1";
  @[{system x};cmd;{[fn;e]hdel fn;'"curl smtp error: ",e}[fn]];
  hdel fn;
  };

stringnestedlists:{[res]
  / convert any nested int/float list columns to space-delimited strings for serialisation
  / ported from torq reporter.q stringnestedlists
  nestedtypes:upper .Q.t except " c";
  $[count select from meta[res] where t in nestedtypes;
    {[t;c] ![t;();0b;(enlist c)!enlist((';{" " sv string x});c)]}/[res;exec c from meta[res] where t in nestedtypes];
    res];
  };

writetofile:{[temppath;reportname;filetype;data]
  / write data`result to disk as csv or txt and return the file path hsym
  / ported from torq reporter.q writetofile
  ty:`$filetype;
  if[not ty in key .h.tx;
    .z.m.logerr[`email;"writetofile: filetype not supported: ",filetype];
    'filetype," is not a supported file type";
  ];
  res:stringnestedlists[data`result];
  filepath:`$temppath,"/",reportname,".",filetype;
  .[{hsym[x] 0:.h.tx[y;z]};(filepath;ty;res);{[e].z.m.logerr[`email;"writetofile: ",e]}];
  :hsym filepath;
  };

loghistory:{[recipients;subject;status;bytes]
  / append one row to the persistent send history table
  .z.M.history insert (.z.p;recipients;subject;status;`long$bytes);
  };

/ ============================================================
/ public api
/ ============================================================

senddefault:{[msgdict]
  / send an html email via the system sendmail utility
  / msgdict keys: to (symbol or symbol list), subject (string), body (list of strings)
  /               optionally: attachment (file path hsym)
  / returns 1b on success, 0b on send failure, -1 if disabled
  if[not enabled;
    .z.m.logerr[`email;"email sending is not enabled"];
    loghistory[msgdict`to;msgdict`subject;`disabled;-1];
    :-1;
  ];
  to:","sv string$[-11h=type msgdict`to;enlist msgdict`to;msgdict`to];
  htmlbody:{$[10h=type x;$[count x;$["<"=first x;x;addtext x];""];x]}'[msgdict[`body],enlist "email generated at ",(string .z.p)];
  att:$[`attachment in key msgdict;enlist msgdict`attachment;""];
  res:.[send;(mailfrom;to;msgdict`subject;htmlbody;att);{[e].z.m.logerr[`email;"send failed: ",e];0b}];
  ok:not res~0b;
  loghistory[msgdict`to;msgdict`subject;`failed`sent ok;$[ok;0j;-1j]];
  $[ok;
    .z.m.loginfo[`email;"email sent"];
    .z.m.logerr[`email;"failed to send email"]];
  :ok;
  };

test:{[to]
  / send a test email to verify sendmail connectivity
  / to - symbol e.g. `$"user@example.com"
  / returns 1b on success, 0b on failure
  :senddefault`to`subject`body!(to;"test email";enlist"this is a test email to verify sendmail is configured correctly");
  };

alerthandler:{[period;recipients;data]
  / result handler for the torq reporter alert - invoked via the alert[] projection
  / ported from torq reporter.q emailalert
  / period     - timespan cooldown e.g. 00:02:00
  / recipients - string or list of strings (email addresses)
  / data       - reporter data dict: result (table with messages col), name, procname, queryid
  lasttime:0p^exec first lastsent from alertstats where procname=(data`procname),alertname=(data`name);
  result:data`result;
  if[not count result;
    .z.m.loginfo[`email;"emailalert: nothing to email"];
    :();
  ];
  if[period > .z.p - lasttime;
    .z.m.loginfo[`email;"emailalert: suppressed, previous email was too recent"];
    :();
  ];
  .z.M.alertstats upsert (data`procname;data`name;.z.p);
  subject:"Process [",(string data`procname),"] has triggered an alert [",(string data`name),"]";
  .z.m.loginfo[`email;"emailalert: sending warning email"];
  res:senddefault[`to`subject`body!(`$recipients;subject;(),result`messages)];
  $[res>0;
    .z.m.loginfo[`email;"emailalert: sent alert for: ",string data`name];
    .z.m.logerr[`email;"emailalert: failed to send alert for: ",string data`name]];
  };

alert:{[period;recipients]
  / create a reporter result handler that sends an alert email with cooldown
  / period     - timespan cooldown between successive alerts e.g. 00:02:00
  / recipients - string or list of strings (email addresses)
  / returns a projection {[data]} compatible with the torq reporter resulthandler column
  :alerthandler[period;recipients;];
  };

reporthandler:{[temppath;recipients;filename;filetype;data]
  / result handler for the torq reporter report - invoked via the report[] projection
  / ported from torq reporter.q emailreport
  / temppath   - string path for temporary report files e.g. getenv[`TORQHOME]
  / recipients - string or list of strings (email addresses)
  / filename   - string output filename stem and email subject label
  / filetype   - string file format e.g. "csv" or "txt"
  / data       - reporter data dict: result (table), name, queryid
  filepath:writetofile[temppath;filename;filetype;data];
  subject:"Report '",(string data`name),"' has been generated [",(string .z.d),"]";
  body:"A report has been generated. Please see the attached file for the results.";
  .z.m.loginfo[`email;"emailreport: sending email with attached report"];
  res:senddefault[`to`subject`body`attachment!(`$recipients;subject;enlist body;filepath)];
  if[res<1;.z.m.logerr[`email;"emailreport: failed to send email"]];
  .z.m.loginfo[`email;"emailreport: removing temporary file: ",string filepath];
  @[hdel;filepath;{[e].z.m.logerr[`email;"emailreport: failed to delete temp file: ",e]}];
  };

report:{[temppath;recipients;filename;filetype]
  / create a reporter result handler that writes the result to file and emails it as an attachment
  / temppath   - string path for temporary report files e.g. getenv[`TORQHOME]
  / recipients - string or list of strings (email addresses)
  / filename   - string output filename stem and email subject label
  / filetype   - string file format e.g. "csv" or "txt"
  / returns a projection {[data]} compatible with the torq reporter resulthandler column
  :reporthandler[temppath;recipients;filename;filetype;];
  };

getstatus:{[]
  / return the full send history table
  :history;
  };

init:{[config;deps]
  / initialise module with email config and optional injected dependencies
  / config - dict with any of:
  /   mailfrom (string or symbol) - from address
  /   enabled  (boolean)          - gate for sending
  /   smtpurl  (string or symbol) - e.g. "smtp://smtp.gmail.com:587"
  /   smtpuser (string or symbol) - smtp username
  /   smtppassword (string)       - smtp password
  /   smtpssl  (boolean)          - require tls (default 1b)
  / pass (::) for config to use defaults (email disabled, sendmail transport)
  / deps - `log`send!(logdict;sendfunc)
  /   `log:  `info`warn`error!({[c;m]};{[c;m]};{[c;m]}) - required; init throws if absent
  /   `send: {[frm;to;sub;body;att]}                    - optional, (::) = use smtp or sendmail
  / examples:
  /   email.init[config; `log`send!(logdep; ::)]     / inject log, default send
  /   email.init[config; `log`send!(logdep; mysend)] / inject both
  .z.m.mailfrom:"torq@localhost";
  .z.m.enabled:0b;
  .z.m.smtpurl:"";
  .z.m.smtpuser:"";
  .z.m.smtppassword:"";
  .z.m.smtpssl:1b;
  logdict:$[99h=type deps;$[(`log in key deps) and not (::)~deps`log;deps`log;()!()];()!()];
  if[not count logdict;'"di.email: log dependency is required; pass `log`send!(logdep;::) - see di.log"];
  .z.m.loginfo:logdict`info;
  .z.m.logwarn:logdict`warn;
  .z.m.logerr:logdict`error;
  sendinjected:$[99h=type deps;(`send in key deps) and not (::)~deps`send;0b];
  .z.m.send:$[sendinjected;deps`send;defaultsend];
  if[99h=type config;
    if[`mailfrom in key config;.z.m.mailfrom:$[10h=type config`mailfrom;config`mailfrom;string config`mailfrom]];
    if[`enabled in key config;.z.m.enabled:config`enabled];
    if[`smtpurl in key config;.z.m.smtpurl:$[10h=type config`smtpurl;config`smtpurl;string config`smtpurl]];
    if[`smtpuser in key config;.z.m.smtpuser:$[10h=type config`smtpuser;config`smtpuser;string config`smtpuser]];
    if[`smtppassword in key config;.z.m.smtppassword:$[10h=type config`smtppassword;config`smtppassword;string config`smtppassword]];
    if[`smtpssl in key config;.z.m.smtpssl:config`smtpssl];
  ];
  / if smtp url is configured and send was not explicitly injected, use curl smtp transport
  if[count smtpurl;if[not sendinjected;.z.m.send:smtpsend_]];
  };
