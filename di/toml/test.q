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

TDIR:"/tmp/ditomltest";
setuptoml:{[] system "mkdir -p ",TDIR; (`$":",TDIR,"/x.toml") 0: ("dir = \":appdb\"";"rows = 100");};
teardowntoml:{[] system "rm -rf ",TDIR;};
