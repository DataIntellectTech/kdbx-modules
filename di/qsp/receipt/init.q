/ di.qsp.receipt - a signed receipt for a result
/ A gateway that runs a query for a person - an agent's tooling, a reporting service - can ask for
/ a receipt with the result: who it ran as, what was asked and what actually ran, the row filter,
/ the partitions read, and a hash of the result, signed with a key only this process holds. Any
/ number later quoted from the result can then be traced to an audited query the user was
/ entitled to run, under the policy that was served when it ran.
/   issue[d]            a receipt for the fields in d, signed with the newest key
/   verify[r]           is r's signature valid, under the key it names?
/   keep[cfg;r;v]       store receipt r, and result v when it is small enough to keep
/   fetch[id;caller]    a stored receipt and its kept values, to its user or its gateway only
/   loadkeys[dir]       read the key ring: every <kid>.key file in dir
/   newkey[dir]         write a new key to dir, from the operating system's random source
/ Signing is HMAC-SHA1 (RFC 2104) over q's own SHA-1, -33!. HMAC's security does not rest on
/ SHA-1's collision resistance, and it is checked against RFC 2202's test vectors. The bytes
/ signed are -8! of the receipt without its signature: q reads them back the same in any process

tree:use`..core.tree;

/ ------------------------------------------------------------------ HMAC-SHA1

sha1:{[x] :-33!x;};

/ the bytes of x exclusive-or those of y, which are as long
xorbytes:{[x;y] :0b sv' 8 cut (raze 0b vs' x)<>raze 0b vs' y;};

hmac:{[k;m]
  / HMAC-SHA1 of message m under key k, both bytes or strings
  if[10h=type k;k:`byte$k];
  if[10h=type m;m:`byte$m];
  if[64<count k;k:sha1 k];
  k:64#k,64#0x00;
  :sha1 xorbytes[k;64#0x5c],sha1 xorbytes[k;64#0x36],m;
  };

hex:{[x] :raze string x;};

/ ------------------------------------------------------------------ the key ring
/ a directory of keys, one file each, <kid>.key holding 32 bytes. The newest - the greatest kid,
/ which newkey makes from the time - signs; every one verifies. Rotate by adding a key; retire one
/ by deleting its file once the receipts it signed are past keeping

ring:(`symbol$())!();

loadkeys:{[dir]
  / read every key in directory dir, replacing the ring; a null dir empties it
  .z.m.ring:(`symbol$())!();
  if[null dir;:0];
  d:hsym dir;
  tree.chk[not ()~key d;"receipt key directory not found: ",1_string d];
  fs:{x where x like "*.key"} key d;
  ks:{[d;f] read1 ` sv d,f}[d] each fs;
  tree.chk[all 32=count each ks;"a receipt key must be 32 bytes: ",", " sv string fs where not 32=count each ks];
  .z.m.ring:(`$-4_'string fs)!ks;
  :count ring;
  };

/ the kid that signs, or ` when there are no keys
signer:{[] :$[count ring;last asc key ring;`];};

/ 32 bytes from the operating system's random source - q's own generator is seeded, and a key
/ must not be guessable from when the process started
randombytes:{[n]
  h:raze system"od -An -tx1 -N",string[n]," /dev/urandom";
  b:"X"$2 cut h except " ";
  tree.chk[n=count b;"could not read ",string[n]," random bytes from /dev/urandom"];
  :b;
  };

newkey:{[dir]
  / write a new key into directory dir, and return its kid. It signs once the ring is reloaded
  kid:`$"k",{x where x in .Q.n} string .z.p;
  f:` sv (hsym dir),`$string[kid],".key";
  f 1: randombytes 32;
  system"chmod 600 ",1_string f;
  :kid;
  };

/ ------------------------------------------------------------------ receipts

/ every field of a receipt, in the order it is signed. sig is last, and not signed
fields:`id`time`user`gateway`session`turn`original`fixes`policy`query`rewritten`filter`partitions`rows`columns`resulthash`kid`sig;
signed:-1_fields;

mac:{[r] :hex hmac[ring r`kid;-8!signed#r];};

issue:{[d]
  / a receipt for the fields given in d - every field but id, time, kid and sig - signed with
  / the newest key, or unsigned, with kid and sig empty, when there is none
  r:fields!(count fields)#enlist (::);
  r[key d]:value d;
  r[`id]:first -1?0Ng;
  r[`time]:.z.p;
  r[`kid]:signer[];
  r[`sig]:$[null r`kid;"";mac r];
  :r;
  };

verify:{[r]
  / is receipt r signed, by a key in the ring, and unchanged since?
  if[not 99h=type r;:0b];
  if[not all fields in key r;:0b];
  if[null k:r`kid;:0b];
  if[not k in key ring;:0b];
  :(r`sig)~mac r;
  };

/ ------------------------------------------------------------------ the store

kept:([]id:`guid$();user:`symbol$();gateway:`symbol$();receipt:();vals:());

/ how many cells result v has: rows times columns for a table, items for anything else
cells:{[v]
  t:type v;
  if[t=98h;:(count v)*count cols v];
  if[t=99h;:$[98h=type key v;(count v)*count cols 0!v;sum count each value v]];
  if[t<0;:1];
  :count raze v;
  };

keep:{[cfg;r;v]
  / store receipt r, and result v when it has at most receiptcells cells, keeping receiptmax
  small:cells[v]<=cfg`receiptcells;
  .z.m.kept:kept,([]id:enlist r`id;user:enlist r`user;gateway:enlist r`gateway;
    receipt:enlist r;vals:enlist $[small;v;(::)]);
  if[cfg[`receiptmax]<count kept;.z.m.kept:neg[cfg`receiptmax] sublist kept];
  };

fetch:{[id;caller]
  / the receipt with id and its kept values - (::) when not kept - for the user it ran as or the
  / gateway that asked for it. Anyone else is told only that there is no such receipt they may
  / read, so a receipt's existence is not disclosed
  i:kept[`id]?id;
  ok:$[i<count kept;caller in kept[i;`user`gateway];0b];
  tree.chk[ok;"no receipt ",string[id]," that this login may read"];
  :`receipt`values!kept[i;`receipt`vals];
  };

clear:{[] .z.m.kept:0#kept;};

isstored:{[id] :id in kept`id;};

export:([hmac;hex;loadkeys;signer;newkey;issue;verify;keep;fetch;clear;isstored;cells;fields]);
