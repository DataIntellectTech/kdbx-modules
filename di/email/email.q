/ send html emails through the system sendmail utility or curl smtp

/ ============================================================
/ sendmail utilities
/ ============================================================

utilityexists:{@[system;"which ",x," 2>/dev/null";0b]};

hsym2str:{[x] $[":"=first s:string x;1_s;s]};

/ a new temp file, or a directory with flags "-d ", under TMPDIR or /tmp
tmppath:{[flags]first system"mktemp ",flags,"\"${TMPDIR:-/tmp}/qmail.XXXXXXXXXX\""};

/ quote a string for use as a single shell argument
shquote:{[x]"'",(ssr[x;"'";"'\\''"]),"'"};

/ escape a value for a double-quoted entry in a curl --config file
curlquote:{[x]"\"",(ssr[ssr[x;"\\";"\\\\"];"\"";"\\\""]),"\""};

checkfile:{if[not x~key x:hsym x;'"file not found: ",hsym2str x]};

encodefile:{[x]
  checkfile x;
  system "base64 ",(shquote hsym2str x)
  };

mimetype:{[a]
  if[0b~utilityexists "file"; :"application/octet-stream"];
  r:@[system;"file --mime-type ",(shquote hsym2str a);{[e]enlist ": application/octet-stream"}];
  if[not count r; :"application/octet-stream"];
  mt:trim last ":" vs first r;
  $[10h=type mt;mt;"application/octet-stream"]};

mailheader:{[]
  ("<html>";"<body style=\"width:100%; margin:0; padding:0; font-size:15px;\">")
  };

mailfooter:("</body>";"</html>");

headersafe:{[nm;x]
  / signal if a header value holds CR or LF, showing them escaped; else return the value
  if[any x in "\r\n";
    '"di.email: ",(string nm)," contains a newline, which would inject a header: ",
      ssr[ssr[x;"\r";"\\r"];"\n";"\\n"]];
  x
  };

/ the Cc header, omitted when there is no cc
ccheader:{[cc] $[count cc;enlist["Cc: ",cc];()]};

template0:{[frm;to;cc;sub;body]
  enlist["From: ",frm],
  enlist["To: ",to],
  (ccheader cc),
  enlist["Subject: ",sub],
  enlist["MIME-Version: 1.0"],
  enlist["Content-Type: text/html; charset=UTF-8"],
  enlist[""],
  mailheader[],
  body,
  mailfooter
  };

attachpart:{[a]
  / one attachment's mime part, without its boundary line
  fn:last "/"vs hsym2str a;
  enlist["Content-Transfer-Encoding: base64"],
  enlist["Content-Type: ",mimetype[a],"; name=\"",fn,"\""],
  enlist["Content-Disposition: attachment; filename=\"",fn,"\""],
  enlist[""],
  encodefile[a]
  };

imagepart:{[a;cid]
  / the image's mime part with its content id
  fn:last "/"vs hsym2str a;
  enlist["Content-Transfer-Encoding: base64"],
  enlist["Content-Type: ",mimetype[a],"; name=\"",fn,"\""],
  enlist["Content-ID: <",cid,">"],
  enlist["Content-Disposition: inline; filename=\"",fn,"\""],
  enlist[""],
  encodefile[a]
  };

htmlpart:{[body;cid;img]
  / the html body, in a multipart/related with the image if there is one
  h:enlist["Content-Type: text/html; charset=UTF-8"],
    enlist[""],
    mailheader[],
    body,
    $[null img;();enlist "<p><img src=\"cid:",cid,"\"></p>"],
    mailfooter;
  if[null img;:h];
  rb:"====rel",string[rand 0Ng],"====";
  enlist["Content-Type: multipart/related; type=\"text/html\"; boundary=\"",rb,"\""],
  enlist[""],
  enlist["--",rb],
  h,
  enlist[""],
  enlist["--",rb],
  imagepart[img;cid],
  enlist[""],
  enlist["--",rb,"--"]
  };

mailtemplate:{[frm;to;cc;sub;body;att]
  / an image makes the message multipart
  img:.z.m.img;
  hasimg:not null img;
  if[(not count att where not null att,:()) and not hasimg;:template0[frm;to;cc;sub;body]];
  boundary:"====",string[rand 0Ng],"====";
  / a content id in addr-spec form
  cid:$[hasimg;"img",(string rand 0Ng),"@kdbx.local";""];
  enlist["From: ",frm],
  enlist["To: ",to],
  (ccheader cc),
  enlist["Subject: ",sub],
  enlist["Content-Type: multipart/mixed; boundary=\"",boundary,"\""],
  enlist["MIME-Version: 1.0"],
  enlist[""],
  enlist["--",boundary],
  htmlpart[body;cid;img],
  (raze {[a;boundary] enlist[""],enlist["--",boundary],attachpart a}[;boundary] each att),
  enlist[""],
  enlist["--",boundary,"--"]
  };

mailsend:{[frm;to;cc;sub;body;att]
  / send an html email via the system sendmail utility
  / frm  - string from address
  / to   - string, comma-delimited recipient addresses
  / sub  - string subject
  / body - list of strings (html content)
  / cc   - "" for none, or a comma-delimited string of addresses (sendmail -t reads the header)
  / att  - "" for no attachment, or list of hsym file paths
  if[0b~utilityexists "sendmail";'"sendmail not found on this system"];
  if[not att~"";if[10h=type att;att:enlist att]];
  / build the message before creating the temp file
  msg:mailtemplate[frm;to;cc;sub;body;att];
  fn:hsym`$tmppath"";
  .[{[a;b]a 0: b};(fn;msg);{[fn;e]hdel fn;'"sendmail write error: ",e}[fn]];
  @[system;"sendmail -t -f ",(shquote frm)," < ",(shquote 1_string fn);{[fn;e]hdel fn;'"sendmail error: ",e}[fn]];
  hdel fn;
  };

/ ============================================================
/ html body helpers
/ ============================================================

dict2css:{";"sv":"sv'flip(string@key@;value)@\:x};

cssbody:{(!) . flip 2 cut(
  `$"font-family";"Verdana, Geneva, Sans-Serif";
  `$"color";"#2f4a5c")};

addstyle:{x," style=\"",(dict2css cssbody[]),"\""};

mailwrap:{"<",x,">",y,"</",(first " "vs (),x),">"};

/ escape html special characters, & first
htmlescape:{[x] ssr[ssr[ssr[x;"&";"&amp;"];"<";"&lt;"];">";"&gt;"]};

bodylines:{[x]
  / one body element as lines of text: strings as they are, a symbol's name, anything else its text form
  $[10h=abs type x;enlist $[10h=type x;x;enlist x];
    (0h=type x) and (0<count x) and all 10h=type each x;x;
    -11h=type x;enlist string x;
    enlist .Q.s1 x]
  };

addtext:{mailwrap[addstyle "p";x]};

/ ============================================================
/ module state and defaults
/ ============================================================

/ from address used in all outgoing emails - overwritten by init
mailfrom:"kdbx@localhost";

/ email gate - overwritten by init
enabled:0b;

/ controls whether senddefault appends rows to history - overwritten by init
historyenabled:1b;

/ append-only table recording every send attempt
history:([]time:`timestamp$();recipients:`symbol$();subject:();status:`symbol$();bytes:`long$());

send:mailsend;

/ image embedded at the foot of every message - overwritten by init, null for none
img:`;

/ smtp config - set by init when smtpurl is provided; used by smtpsend
smtpurl:"";
smtpuser:"";
smtppassword:"";
smtpssl:1b;

/ ============================================================
/ internal helpers
/ ============================================================

cleansmtptmp:{[cf;fn]
  / remove the smtp temp files, tolerating one already gone
  @[hdel;cf;::];
  @[hdel;fn;::];
  };

smtpsend:{[frm;to;cc;sub;body;att]
  / send via curl smtp transport using module smtp config (smtpurl/smtpuser/smtppassword/smtpssl)
  / signature matches mailsend: frm to cc sub body att
  if[0b~utilityexists "curl";'"curl not found on this system"];
  if[not att~"";if[10h=type att;att:enlist att]];
  / build the message before creating the temp files
  msg:mailtemplate[frm;to;cc;sub;body;att];
  tmpfile:tmppath"";
  / curl config file for the credentials, 0600 from mktemp
  cfgfile:tmppath"";
  fn:hsym`$tmpfile;
  cf:hsym`$cfgfile;
  onwritefail:{[cf;fn;e]cleansmtptmp[cf;fn];'"smtp write error: ",e}[cf;fn];
  .[{[a;b]a 0: b};(fn;msg);onwritefail];
  if[count smtpuser;.[{[a;b]a 0: b};(cf;enlist("user = ",curlquote[smtpuser,":",smtppassword]));onwritefail]];
  rcpts:" " sv {[r]"--mail-rcpt ",(shquote r)}each ","vs $[count cc;to,",",cc;to];
  sslopt:$[smtpssl;"--ssl-reqd ";""];
  cmd:"(curl --config ",(shquote cfgfile)," --url ",(shquote smtpurl)," -sS ",sslopt;
  cmd,:"--crlf --mail-from ",(shquote frm)," ",rcpts," --upload-file ",(shquote tmpfile)," 2>&1; echo $?)";
  r:@[{system x};cmd;{[cf;fn;e]cleansmtptmp[cf;fn];'"curl smtp error: ",e}[cf;fn]];
  cleansmtptmp[cf;fn];
  / the last line is curl's exit code, anything before it is curl's error text
  if[not (enlist"0")~last r;'"curl smtp error: "," " sv -1_r];
  };

dataaslines:{[x]
  / a q object as file lines: a table as csv, strings as text, anything else its text form
  $[.Q.qt x;csv 0: x;
    10h=type x;enlist x;
    (0h=type x) and all 10h=type each x;x;
    enlist -3!x]
  };

cleantmpdir:{[dir]
  / remove a temp attachment directory and everything in it
  @[hdel;;::]each .Q.dd[dir]each key dir;
  @[hdel;dir;::];
  };

/ whether x is a symbol or list of symbols
issyms:{[x]type[x] in -11 11h};

msgerror:{[m]
  / what is wrong with a message's to, cc, subject or attachments, "" if nothing
  if[not 99h=type m;:"param should be a dictionary with possible keys to, subject, cc, body, attachments"];
  k:key m;
  $[(`to in k) and not issyms m`to;"to field should be a symbol or symbol list";
    (`cc in k) and not issyms m`cc;"cc field should be a symbol or symbol list";
    (`subject in k) and not 10h=type m`subject;"subject field should be a char array";
    (`attachments in k) and not issyms m`attachments;"attachments field should be a symbol or symbol list";
    not (`to in k) and 0<count m`to;"to field must be specified";
    not `subject in k;"subject field must be specified";
    ""]
  };

dataerror:{[m]
  / what is wrong with senddata's attachments, "" if nothing
  if[not 99h=type m;:"needs a dictionary"];
  if[not `attachments in key m;:"needs an attachments dict of filename!qobject"];
  if[not 99h=type d:m`attachments;:"attachments must be a dict of filename!qobject"];
  if[not 11h=type key d;:"attachment names must be symbols"];
  if[any any each (string key d) in\: "/\"\r\n";:"attachment names must be plain filenames"];
  ""
  };

/ recipients as one symbol, comma separated when there are several
recipsym:{[x]@[{$[10h=abs type x;`$(),x;`$","sv string(),x]};x;`]};

/ ============================================================
/ public api
/ ============================================================

senddefault:{[msgdict]
  / send an html email via the system sendmail utility
  / msgdict keys: to (symbol or symbol list), subject (string), body (list of strings)
  /               optionally: cc (symbol or symbol list), attachments (hsym or list of hsyms)
  / body lines are html: a line starting with "<" is passed through, anything else is
  / escaped and wrapped in <p>. nested lists are flattened, non-strings become text
  / returns 1b once the transport accepts the message, 0b on send failure, -1 if disabled
  / signals if an enabled send has a missing field, or a to, cc, subject or attachments of the wrong type
  if[not enabled;
    .z.m.logerr[`email;"email sending is not enabled"];
    if[historyenabled and 99h=type msgdict;.z.m.loghistory[msgdict`to;msgdict`subject;`disabled;-1]];
    :-1;
  ];
  if[count err:msgerror msgdict;.z.m.logerr[`email;err:"di.email: ",err];'err];
  to:","sv string$[-11h=type msgdict`to;enlist msgdict`to;msgdict`to];
  cc:$[`cc in key msgdict;","sv string$[-11h=type msgdict`cc;enlist msgdict`cc;msgdict`cc];""];
  / check every value that reaches a header
  hdrs:.[{headersafe'[`to`cc`subject;(x;y;z)];1b};(to;cc;msgdict`subject);
    {[e].z.m.logerr[`email;"send refused: ",e];0b}];
  if[not hdrs;
    if[historyenabled;.z.m.loghistory[msgdict`to;msgdict`subject;`failed;-1]];
    :0b];
  b:msgdict`body;
  lines:raze bodylines each $[10h=abs type b;enlist(),b;b],enlist "email generated at ",(string .z.p);
  / a line starting with "<" is passed through, the rest escaped
  htmlbody:{$[count x;$["<"=first x;x;addtext htmlescape x];""]} each lines;
  / warn when only the singular attachment key is given
  if[(`attachment in key msgdict) and not `attachments in key msgdict;
    .z.m.logwarn[`email;"msgdict has an `attachment key - this module uses `attachments (plural), so nothing was attached"]];
  att:$[`attachments in key msgdict;$[-11h=type msgdict`attachments;enlist msgdict`attachments;msgdict`attachments];""];
  res:.[send;(mailfrom;to;cc;msgdict`subject;htmlbody;att);{[e].z.m.logerr[`email;"send failed: ",e];0b}];
  ok:not res~0b;
  if[historyenabled;.z.m.loghistory[msgdict`to;msgdict`subject;`failed`sent ok;$[ok;0j;-1j]]];
  $[ok;
    .z.m.loginfo[`email;"email sent"];
    .z.m.logerr[`email;"failed to send email"]];
  :ok;
  };

senddata:{[msgdict]
  / send an html email whose attachments are q objects rather than files on disk
  / msgdict is as senddefault, except attachments maps filename to a q object:
  /   `attachments!enlist `trades.csv`notes.txt!(tradetable;"a line of text")
  / a table is written as csv, a string or list of strings as text, anything else as its text form
  / the objects are written to a private temp directory which is removed again after the send
  if[not enabled;:senddefault msgdict];
  if[count err:dataerror msgdict;.z.m.logerr[`email;err:"di.email: senddata ",err];'err];
  data:msgdict`attachments;
  dir:hsym`$tmppath"-d ";
  paths:.Q.dd[dir]each key data;
  .[{[fs;vals]{x 0: dataaslines y}'[fs;vals];};(paths;value data);{[dir;e]cleantmpdir dir;'"senddata write error: ",e}[dir]];
  res:.[senddefault;enlist @[msgdict;`attachments;:;paths];{[dir;e]cleantmpdir dir;'e}[dir]];
  cleantmpdir dir;
  :res;
  };

test:{[to]
  / send a test email to verify sendmail connectivity
  / to - symbol e.g. `$"user@example.com"
  / returns 1b on success, 0b on failure
  :senddefault`to`subject`body!(to;"test email";enlist"this is a test email to verify sendmail is configured correctly");
  };

getstatus:{[]
  / return the full send history table
  :history;
  };

clearhistory:{[]
  / truncate the history table; schema is preserved
  / to clear on a schedule via di.timer:
  /   timer.addjob.simple[`emailhistoryclear;email.clearhistory;1D]
  .z.m.history:0#.z.m.history;
  };

init:{[config;deps]
  / initialise module with email config and injected log dependency
  / config - dict with any of:
  /   mailfrom        (string or symbol) - from address
  /   enabled         (boolean)          - gate for sending
  /   historyenabled  (boolean)          - whether to record sends in history table (default 1b)
  /   smtpurl         (string or symbol) - e.g. "smtp://smtp.gmail.com:587"; when set, curl is used
  /   smtpuser        (string or symbol) - smtp username
  /   smtppassword    (string)           - smtp password
  /   smtpssl         (boolean)          - require tls (default 1b)
  /   img             (hsym or string)   - image embedded at the foot of every message
  / pass (::) for config to use defaults (email disabled, sendmail transport)
  / deps - (enlist`log)!enlist logdict
  /   `log: `info`warn`error!({[c;m]};{[c;m]};{[c;m]}) - required; init throws if absent
  logdict:$[99h=type deps;$[(`log in key deps) and not (::)~deps`log;deps`log;()!()];()!()];
  if[not count logdict;'"di.email: log dependency is required; pass (enlist`log)!enlist logdep - see di.util.log"];
  if[not 99h=type logdict;'"di.email: log value must be a dict of `info`warn`error functions"];
  if[not all `info`warn`error in key logdict;'"di.email: log dict must have `info`warn`error keys; got: ",", " sv string key logdict];
  .z.m.mailfrom:"kdbx@localhost";
  .z.m.enabled:0b;
  .z.m.historyenabled:1b;
  / initialise history only once; subsequent init calls preserve existing rows
  if[98h<>type@[{.z.m.history};::;{""}];
    .z.m.history:([]time:`timestamp$();recipients:`symbol$();subject:();status:`symbol$();bytes:`long$())];
  / append a row to the history table
  .z.m.loghistory:{[recipients;subject;status;bytes]
    .z.m.history:.z.m.history,enlist `time`recipients`subject`status`bytes!(.z.p;recipsym recipients;subject;status;`long$bytes);
    };
  .z.m.img:`;
  .z.m.smtpurl:"";
  .z.m.smtpuser:"";
  .z.m.smtppassword:"";
  .z.m.smtpssl:1b;
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
    if[`img in key config;
      .z.m.img:$[-11h=type config`img;hsym config`img;hsym`$config`img];
      / warn if the image is missing or empty
      if[0=@[hcount;.z.m.img;0];
        .z.m.logwarn[`email;"img ",(hsym2str .z.m.img)," is missing or empty - messages will carry a broken image"]]];
  ];
  / select transport: curl smtp if smtpurl is set, otherwise sendmail
  .z.m.send:$[count smtpurl;smtpsend;mailsend];
  };
