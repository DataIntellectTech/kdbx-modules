/ helper script for unit tests

.test.dataloader.mockdirs:{[headers;tabs]
  / function creates temporary mock directory for test data i/o. If exsits will reset it
  if["hdb"~last vs["/";first system"pwd"];system "cd ../../.."];
  $[()~key hsym `:test/data;system"mkdir test/data";system"rm -rf test/data/*"];
  {system "mkdir test/data/",x} each ("hdb";"files");
  tabs:(),tabs;
  if[`trade in tabs;
    `:test/data/files/trade.csv 0: $[headers;csv 0: .test.dataloader.mocktrade;1_ csv 0: .test.dataloader.mocktrade];
    ];
  if[`quote in tabs;
    `:test/data/files/quote.csv 0: $[headers;csv 0: .test.dataloader.mockquote;1_ csv 0: .test.dataloader.mockquote];  
    ];
  if[`tradedaily in tabs;
    `:test/data/files/tradedaily.csv 0: $[headers;csv 0: .test.dataloader.mocktradedaily;1_ csv 0: .test.dataloader.mockquote];  
    ];
  };

.test.dataloader.mocktrade:([]
  time:2024.01.15D09:30:00.000 2024.01.15D09:30:01.250 2024.01.15D09:30:02.500 2024.01.15D09:30:03.750 2024.01.15D09:30:05.000 2024.01.15D09:30:06.125 2024.01.15D09:30:07.375 2024.01.15D09:30:08.625 2024.01.15D09:30:09.875 2024.01.15D09:30:11.000;
  sym:`AAPL`GOOGL`MSFT`AAPL`TSLA`GOOGL`MSFT`AAPL`TSLA`GOOGL;
  price:150.25 2750.80 415.60 150.30 245.75 2751.25 415.75 150.35 245.90 2750.95;
  size:100 50 200 150 75 25 300 125 100 80;
  side:`B`S`B`S`B`B`S`B`S`B;
  exchange:`NASDAQ`NASDAQ`NYSE`NASDAQ`NASDAQ`NASDAQ`NYSE`NASDAQ`NASDAQ`NASDAQ
  );

.test.dataloader.mockquote:([]
  time:2024.01.15D09:30:00.000 2024.01.15D09:30:00.500 2024.01.15D09:30:01.000 2024.01.15D09:30:01.500 2024.01.15D09:30:02.000 2024.01.15D09:30:02.500 2024.01.15D09:30:03.000 2024.01.15D09:30:03.500 2024.01.15D09:30:04.000 2024.01.15D09:30:04.500;
  sym:`AAPL`AAPL`GOOGL`GOOGL`MSFT`MSFT`TSLA`TSLA`AAPL`GOOGL;
  bid:150.20 150.25 2750.50 2750.75 415.55 415.58 245.70 245.85 150.28 2750.85;
  ask:150.25 150.30 2750.80 2751.05 415.60 415.65 245.75 245.95 150.33 2751.15;
  bsize:500 300 100 150 400 250 200 175 350 125;
  asize:400 250 125 100 350 200 150 125 300 100;
  exchange:`NASDAQ`NASDAQ`NASDAQ`NASDAQ`NYSE`NYSE`NASDAQ`NASDAQ`NASDAQ`NASDAQ
  );

.test.dataloader.mocktradedaily:([]
  date:2024.01.15 2024.01.16 2024.01.17 2024.02.15 2024.02.16 2024.02.17 2024.03.15 2024.03.16 2024.03.17 2024.04.15 2024.04.16 2024.04.17;
  time:09:30:00.000 14:25:30.500 09:35:15.250 15:45:22.750 10:15:45.125 13:20:18.375 11:05:33.625 16:00:00.000 09:45:12.875 14:30:45.000 10:30:22.125 15:15:33.250;
  sym:`AAPL`MSFT`GOOGL`TSLA`NVDA`AMD`AAPL`MSFT`GOOGL`TSLA`NVDA`AMD;
  price:150.25 415.60 2750.80 245.75 870.45 142.30 151.30 416.25 2755.90 246.50 872.10 143.85;
  size:1000 1500 500 750 900 1100 1200 800 600 900 1050 1250;
  exchange:`NASDAQ`NYSE`NASDAQ`NASDAQ`NASDAQ`NYSE`NASDAQ`NYSE`NASDAQ`NASDAQ`NASDAQ`NYSE
  );

.test.dataloader.mocksymdir:{system "mkdir test/data/symdir"};

.test.dataloader.dataprocessfunc:{[loaderparams;data]
  / testing function will calculate mid column from quote data
  update mid:avg(bid;ask) from data
  };

.test.dataloader.delimeter:",";

.test.dataloader.complete:{system"cd ../../..";system"rm -rf test/data"};
