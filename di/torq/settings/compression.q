/ framework defaults for the compression process type - a one-shot batch job

csvpath:`:appconfig/compressionconfig.csv   / compression config csv (table/column -> algo, block, level)
hdbpath:`:hdb                               / hdb root to compress, under TORQXDATAHOME
maxage:30                                   / only scan partitions this many days old or newer
exitonfinish:1b                             / exit when the pass completes
