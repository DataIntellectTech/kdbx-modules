/ what did loading that script change?
/ load an inherited script between two captures and list everything it left behind: globals,
/ namespaces, .z handlers and system settings
/   q examples/01_auditscriptload.q -q

st:use`di.state;
here:{[p] :$[count i:where p="/";(1+last i)#p;"./"];}string .z.f;

st.setstate`before;
system"l ",here,"fixtures/legacyutils.q";
st.setstate`after;

r:st.comparestate[`before;`after];

-1"== what the load changed (collapse folds new namespaces to one row)";
show select ns,name,kind,change from st.collapse r;

-1"\n== per namespace";
show st.summary r;

-1"\n== system settings and handlers, before and after";
show select name,before,after from r where(kind=`sys)|ns=`.z;

exit 0;
