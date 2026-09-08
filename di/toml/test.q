/ di.toml test fixtures (loaded by test.csv). di.toml is pure - no mocks needed; the TOML text is
/ defined here as q string literals (far cleaner than CSV-escaping all the quotes inline) plus a
/ small temp .toml file fixture for parsefile.

fflat:"a = 1\nb = 2.5\nc = true\nd = false\ns = \"hello\"";
fqkey:"\"my key\" = 42";
fcomments:"# whole line\na = 1  # trailing\ns = \"a # b\"  # real comment";
fsection:"top = 1\n[sec]\nk = 10\nname = \"rdb\"";
farrays:"nums = [1, 2, 3]\nstrs = [\"xx\", \"yy\"]\nempty = []";
fescapes:"s = \"a\\nb\\tc\\\"d\"";
fblank:"\n  \n# only a comment\n";
fqdotkey:"\"a.b\" = 1";                     / a QUOTED key with a dot - a literal key, allowed
expesc:"a\nb\tc\"d";                        / expected unescaped value of fescapes' s
fbs:"p = \"a\\\\nb\"";                      / TOML  p = "a\\nb"  (escaped backslash then n)
expbs:"a\\nb";                              / expected: a, backslash, n, b (4 chars) - NOT a newline
femptystr:"k = \"\"";                       / TOML  k = ""  (a legitimate empty string)
finvesc:"s = \"a\\xb\"";                    / TOML  s = "a\xb"  (\x is not a valid escape)
fescq:"d = \"a\\\"b\" # c";                 / TOML  d = "a\"b" # c  (escaped quote in value + comment)
expescq:"a\"b";                             / expected value of d: a, ", b  (comment stripped)
fescarr:"a = [\"x\\\"y\", \"zz\"]";         / TOML  a = ["x\"y", "zz"]  (escaped quote in an array elem)
expescarr:("x\"y";"zz");                    / expected: two elements x"y and zz (comma not mis-split)
fqsec:"[\"a.b\"]\nx = 1";                   / TOML  ["a.b"]  -  a QUOTED section name (dot is literal)
ftab:"s = \"x\ty\"";                        / TOML  s = "x<tab>y"  (a literal tab inside the string)
exptab:"x\ty";                              / expected: x, tab, y - the tab preserved, not spaced
fdeps:"# peer deps\n[dependencies]\n\"di.servers\" = \"0.3.0\"  # injected\n\"di.dbwrite\" = \"0.1.0\"";  / a di.depcheck deps.toml
expdeps:`di.servers`di.dbwrite!("0.3.0";"0.1.0");   / di.depcheck's readdeps expects [dependencies] -> symbol!version-string

TDIR:"/tmp/ditomltest";
setuptoml:{[] system "mkdir -p ",TDIR; (`$":",TDIR,"/x.toml") 0: ("dir = \":appdb\"";"rows = 100");};
teardowntoml:{[] system "rm -rf ",TDIR;};
