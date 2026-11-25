/ di.torq.proc.filealerter defaults; see di/torq/proc/filealerter/filealerter.md
/ the csv of path,match,function,newonly,movetodirectory rows; relative paths resolve under TORQXAPPHOME
inputcsv:"appconfig/filealerter.csv"
/ how often to scan
polltime:0D00:00:10
/ the splayed table of processed files; relative paths resolve under TORQXDATAHOME
alreadyprocessed:"filealerterprocessed"
/ mark files already present at startup as processed without running anything
skipallonstart:0b
/ move a file even when one of its functions failed
moveonfail:0b
/ the tickerplant proctype processpcaps publishes to
tickerplanttype:`segmentedtp
/ compare md5 hashes as well as sizes to detect a changed file
usemd5:1b
