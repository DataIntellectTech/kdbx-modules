/ built-in framework defaults for the compression process type. A one-shot batch job: it
/ compresses the hdb once at startup and exits. See di/torq/proc/compression/compression.md.

csvpath:`:appconfig/compressionconfig.csv   / compression config csv (table/column -> algo, block, level)
hdbpath:`:hdb                               / hdb root to compress, under TORQXDATAHOME
maxage:365                                  / only scan partitions this many days old or newer
exitonfinish:1b                             / exit when the pass completes
