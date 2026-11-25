/ is anyone changing this process while it runs?
/ a timer checks what changed since its last look and logs it: functions redefined over IPC,
/ settings changed, globals left behind. Data tables change all the time, so they are ignored.
/ Each look is saved as a fingerprint, so the monitor holds no references to old values
/   q examples/04_changemonitor.q -q

st:use`di.state;

/ the service: a data table that grows, and an API
trade:([]time:`timestamp$();sym:`symbol$();price:`float$());
.api.lastprice:{[s] :exec last price from trade where sym=s;};

/ things to leave out: the data, and the monitor's own namespace
st.ignore`trade`.mon;

.mon.ticks:0;
.mon.log:([]time:`timestamp$();name:`symbol$();kind:`symbol$();change:`symbol$());

.mon.check:{[]
  / log what changed since the last look, then look again
  r:select time:.z.p,name,kind,change from st.collapse st.sincelast[];
  if[count r;.mon.log,:r;-1 string[.z.t]," ",", "sv{[n;c] :string[n]," ",string c;}'[r`name;r`change]];
  st.setfingerprint`mon;
  };

/ what happens to the process each tick: new data always, and now and then a change
.mon.simulate:{[n]
  / feed data, and make one change on some ticks, as a user on a q prompt or over IPC might
  `trade insert(.z.p;rand`a`b`c;rand 100f);
  if[n=2;.api.lastprice:{[s] :exec last price from trade where sym=s,price>0;}];
  if[n=3;system"P 4"];
  if[n=4;tmp::42];
  if[n=5;delete tmp from`.];
  };

/ the timer drives everything, and is set up before the first look
.z.ts:{[x]
  .mon.ticks+:1;
  .mon.simulate .mon.ticks;
  .mon.check[];
  if[.mon.ticks=6;-1"\n== change log";show .mon.log;-1"\ntrade has ",string[count trade]," rows - none of them reported";exit 0];
  };
system"t 200";
st.setfingerprint`mon;
