/ why does this process behave differently from that one?
/ fingerprint a process once its config is loaded, save it to disk, then compare another process
/ (or the same one after a restart or an upgrade) against it. A fingerprint holds no values, only
/ (type;count;attributes;size;md5), so it is small and safe to keep
/   q examples/03_configdrift.q -save /tmp/prod.fp -q                 on the reference process
/   q examples/03_configdrift.q -compare /tmp/prod.fp -env uat -q     on the one to check

st:use`di.state;
.ex.here:{[p] :$[count i:where p="/";(1+last i)#p;"./"];}string .z.f;
.ex.opt:.Q.opt .z.x;

/ this script's own names and the module handle differ between runs, so leave them out
st.ignore`.ex`st;

system"l ",.ex.here,"fixtures/app.q";

if[`save in key .ex.opt;
  .ex.f:hsym`$first .ex.opt`save;
  .ex.f set st.fingerprint st.getstate[];
  -1"saved a fingerprint of the ",string[.cfg.env]," process to ",1_string .ex.f;
  exit 0];

if[`compare in key .ex.opt;
  st.addstate[`reference;get hsym`$first .ex.opt`compare];
  st.setfingerprint`here;
  r:st.comparestate[`reference;`here];
  -1"== differences from the reference process";
  show select ns,name,kind,change from r;
  / system settings are kept as values; variables only as fingerprints, so a report says that
  / they changed, not what to
  -1"\n== system settings, reference and here";
  show select name,reference:before,here:after from r where kind=`sys;
  exit 0];

-2"usage: q 03_configdrift.q [-save file | -compare file] [-env prod|uat]";
exit 1;
