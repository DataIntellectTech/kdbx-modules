/ library for viewing the approximate memory size of individual kdb objects
/ and viewing the approximate memory usage statistics of a kdb session

/ functionality to return approximate memory size of kdb+ objects

attrsize:{
  / `u#2 4 5 unique 32*u
  $[`u=a:attr x;32*count distinct x;
  / `p#2 2 1 parted (8*u;32*u;8*u+1)
  `p=a;8+48*count distinct x;
  0]
  };

/ (16 bytes + attribute overheads + raw size) to the nearest power of 2
calcsize:{[c;s;a] `long$2 xexp ceiling 2 xlog 16+a+s*c};

vectorsize:{.z.m.calcsize[count x;.z.m.typesize x;.z.m.attrsize x]};

/ raw size of atoms according to type, type 20h->76h have 4 bytes pointer size
typesize:{4^0N 1 16 0N 1 2 4 8 4 8 1 8 8 4 4 8 8 4 4 4 abs type x};

sampling:{[f;x]
  / pick samples randomly accoding to threshold and apply function
  threshold:100000;
  $[threshold<c:count x;f@threshold?x;f x]
  };

scalesampling:{[f;x]
  / scale sampling result back to total population
  threshold:100000;
  .z.m.sampling[f;x]*max(1;count[x]%threshold)
  };

objsize:{
  / calculate the size of a kdb object
  / count 0 exit early
  if[not count x;:0];
  / set the pointer size to 8 for 64 bit machines
  ptrsize:8;
  / flatten table/dict into list of objects
  x:$[.Q.qt x;(key x;value x:flip 0!x);
    99h=type x;(key x;value x);
	x];
  / special case to handle `g# attr
  / raw list + hash
  if[`g=attr x;x:(`#x;group x)];
  / atom is fixed at 16 bytes, GUID is 32 bytes
  $[0h>t:type x;$[-2h=t;32;16];
    / list & enum list
    t within 1 76h;.z.m.vectorsize x;
	/ exit early for anything above 76h
	76h<t;0;
	/ complex = complex type in list, pointers + size of each objects
	0h in t:.z.m.sampling[type each;x];.z.m.calcsize[count x;ptrsize;0]+"j"$.z.m.scalesampling[{[f;x]sum f each x}[.z.s];x];
	/ complex = if only 1 type and simple list, pointers + sum count each*first type
	/ assume count>1000 has no attrbutes (i.e. table unlikely to have 1000 columns, list of strings unlikely to have attr for some objects only
	(d[0] within 1 76h)&1=count d:distinct t;.z.m.calcsize[count x;ptrsize;0]+"j"$.z.m.scalesampling[{sum .z.m.calcsize[count each x;.z.m.typesize x 0;$[1000<count x;0;.z.m.attrsize each x]]};x];
	/ other complex, pointers + size of each objects
	.z.m.calcsize[count x;ptrsize;0]+"j"$.z.m.scalesampling[{[f;x]sum f each x}[.z.s];x]]
  };


/ functionality for viewing the approximate memory usage statistics of a kdb session

/ get all the namespaces in . form
allns:{`$".",/:string key `};

varnames:{[ns;vartype;shortpath]
  / get the full var names for a given namespace
  vars:system vartype," ",string ns;
  / create the full path to the variable.  If it's in . or .q it doesn't have a suffix
  `$$[shortpath and ns in `.`.q;"";(string ns),"."],/:string vars
  };

memusage:{
  / create a table of memory usage statistics containing all objects in a session
  / cross each namespace with "v" (varaibles) and "b" (views)
  namespaces:.z.m.allns[] cross $[x;"vb";enlist"v"];
  / get the full var names for a given namespace
  vars:([]variable:raze .z.m.varnames[;;0b] .' namespaces);
  / get the value of each var using -22!
  vars: update size:{-22! value x}each variable from vars;
  / calculate the size in mb
  `size xdesc update sizeMB:`int$size%2 xexp 20 from vars
  };

memusageall:{.z.m.memusage[1b]}; / returns memory usage table with variables and views

memusagevars:{.z.m.memusage[0b]}; / returns memory usage table with just variables
