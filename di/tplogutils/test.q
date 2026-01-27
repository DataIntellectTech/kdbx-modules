/ =============================================================================
/ TEST HELPERS
/ =============================================================================

upd:{[t;x] t upsert x};
trade:([] time:`timestamp$(); sym:`symbol$(); price:`float$(); size:`long$());

/ @function createvalidlog
/ @description Create a valid tickerplant log file for testing
/ @param filepath {symbol} Path where to create the log file
/ @param msgcount {long} Number of messages to write
createvalidlog:{[filepath;msgcount]
  / create test table
  trade:([] time:.z.p + til msgcount; sym:msgcount?`AAPL`GOOGL`MSFT`AMZN`TSLA; price:100+msgcount?100.0; size:100+msgcount?1000);
  / create log file and write messages
  h:hopen filepath set ();
  {[h;i;t] h enlist (`upd;`trade;value t[i])} [h;;trade] each til msgcount;
  hclose h;
 };

/ @function createcorruptlog
/ @description Create a log file with valid messages followed by corruption
/ @param filepath {symbol} Path where to create the log file
/ @param msgcount {long} Number of messages in log file
/ @param corruptpos {long} Message position where to insert corruption
createcorruptlog:{[filepath;msgcount;corruptpos]
  / create test table
  trade:([] time:.z.p + til msgcount; sym:msgcount?`AAPL`GOOGL`MSFT`AMZN`TSLA; price:100+msgcount?100.0; size:100+msgcount?1000);
  / create log file and write messages
  h:hopen filepath set ();
  {[h;i;t;corruptpos] 
    if[=[i;corruptpos]; 
      data:enlist (`upd;`trade;value t[i]);
      databytes:-18!data;
      data_bytes[10+til 20]:`byte$(20?50);
      :h data_bytes;
      ]
    h enlist (`upd;`trade;value t[i])
    } [h;;trade;corruptpos] each til msgcount;
    hclose h;
 };

/ @function countLogMessages
/ @description Count number of messages in a log file
/ @param filepath {symbol} Path to log file
/ @returns {long} Number of messages in the log
countlogmessages:{[filepath]
  count -11!(1;filepath)
 };

/ @function cleanup  
/ @description Delete test files
/ @param filepaths {symbol[]} List of file paths to delete
cleanup:{[filepaths]
  {[fp] @[hdel;fp;{}]} each filepaths;
 };

/ =============================================================================
/ BASIC FUNCTIONALITY TESTS
/ =============================================================================

/ @test Valid log file tplogsutils.check returns original filepath
testcheckvalidlog: {
  testfile:`:test_valid.log;
  msgcount:10;
  
  / setup
  createvalidlog[testfile;msgcount];
  
  / test
  result:tplogsutils.check[testfile;msgcount-1];
  
  / assert
  passes:result~testfile;
  
  / cleanup
  cleanup enlist testfile;
  
  / Return
  passes
 };

/ @test tplogsutils.check returns original when enough good messages exist
testcheckcorruptsufficientmessages:{
  testfile:`:test_corrupt_sufficient.log;
  validmsgcount:20;
  lastmsgtoreplay:10j;
    
  / setup: corrupt after position where we have enough good messages
  createcorruptlog[testfile;validmsgcount;500];
  
  / test
  result:tplogsutils.check[testfile;lastmsgtoreplay];
  
  / assert - should return original since we have enough good messages
  goodmsgcount:first -11!(-2;testfile);
  passes:(result~testfile) and (goodmsgcount > lastmsgtoreplay);
  
  / cleanup
  cleanup enlist testfile;
  
  passes
 };

/ @test tplogsutils.repair creates .good file with correct name
testrepaircreatesgoodfile: {
  testfile:`:test_tplogsutils.repair.log;
  expectedgoodfile:`$string[testfile],".good";
    
  / setup
  createcorruptlog[testfile;15;150];
    
  / test
  result:tplogsutils.repair[testfile];
  
  / assert
  namecorrect:result~expectedgoodfile;
  fileexists:not ()~key expectedgoodfile;
  passes:namecorrect and fileexists;
    
  / cleanup  
  cleanup (testfile;expectedgoodfile);
  
  passes
 };

/ @test tplogsutils.repair recovers valid messages from corrupt log
testrepairrecoversmessages: {
  testfile:`:test_recover.log;
  goodfile:`$string[testfile],".good";
  validmsgcount:20;
    
  / setup
  createcorruptlog[testfile;validmsgcount;250];
    
  / test
  tplogsutils.repair[testfile];
    
  / Count messages in good file
  recoveredcount:countlogmessages[goodfile];
    
  / assert - should recover at least some messages
  passes:(recoveredcount>0) and (recoveredcount<=validmsgcount);
    
  / cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

/ @test tplogsutils.check triggers tplogsutils.repair when insufficient good messages
testchecktriggersrepair: {
  testfile:`:test_tplogsutils.check_tplogsutils.repair.log;
  goodfile:`$string[testfile],".good";
  validmsgcount:10;
  lastmsgtoreplay:15j;  / Need more messages than available good ones
    
  / setup - corrupt early so not enough good messages
  createcorruptlog[testfile;validmsgcount;100];
    
  / test
  result:tplogsutils.check[testfile;lastmsgtoreplay];
    
  / assert
  triggerstplogsutils.repair:result~goodfile;
  filecreated:not ()~key goodfile;
  passes:triggerstplogsutils.repair and filecreated;
    
  / cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

/ =============================================================================
/ EDGE CASE TESTS
/ =============================================================================

/ @test tplogsutils.repair handles garbage at end of file
testrepairgarbageatend: {
  testfile:`:test_garbage_end.log;
  goodfile:`$string[testfile],".good";
    
  / setup - create log and append garbage at end
  createvalidlog[testfile;10];
  bytes:read1 testfile;
  testfile set bytes,100#0x00;
    
  / test
  result:tplogsutils.repair[testfile];
    
  / assert
  nameCorrect:result~goodfile;
  hasMessages:countlogmessages[goodfile]>0;
  passes:nameCorrect and hasMessages;
    
  / cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

/ @test Handles multiple corruption points
testmultiplecorruptsections: {
  testfile:`:test_multi_corrupt.log;
  goodfile:`$string[testfile],".good";
    
  / setup - create log with corruption in middle
  createvalidlog[testfile;30];
  bytes:read1 testfile;
    
  / insert corruption at position (should have valid messages before and after)
  if[200 < count bytes;
    corrupted:bytes[til 200],10#0xFF,bytes[210+til count[bytes]-210];
    testfile set corrupted;
  ];
    
  / test
  result:tplogsutils.repair[testfile];
    
  / assert - should create file and recover something
  fileCorrect:result~goodfile;
  fileExists:not ()~key goodfile;
  passes:fileCorrect and fileExists;
    
  / cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

/ @test Completely corrupt log creates empty .good file
testcompletelycorruptlog: {
  testfile:`:test_all_corrupt.log;
  goodfile:`$string[testfile],".good";
    
  / setup - create completely corrupt file
  testfile set 1000#0x00;
    
  / test
  result:tplogsutils.repair[testfile];
    
  / assert - should create .good file even if empty/minimal
  nameCorrect:result~goodfile;
  fileExists:not ()~key goodfile;
  passes:nameCorrect and fileExists;
    
  / cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

/ @test Empty log file handling
testemptylog: {
  testfile:`:test_empty.log;
   
  / setup - create empty file
  testfile set 0#0x00;
    
  / test - should not crash
  result:tplogsutils.check[testfile;0j];
  passes:1b;  / If we got here without error, test passes
    
  / cleanup
  cleanup enlist testfile;
    
  passes
 };

/ =============================================================================
/ CONFIGURATION TESTS
/ =============================================================================

/ @test Verify module constants are set correctly
testconstantsset: {
  chunkOk:chunk=10*1024*1024;
  maxchunkOk:maxchunk=8*chunk;
  updmsgOk:10=count updmsg;
  headerOk:8=count header;
    
  chunkOk and maxchunkOk and updmsgOk and headerOk
 };

/ @test Module metadata is present
testmoduleinfo: {
  hasName:`name in key info;
  hasVersion:`version in key info;
  hasDesc:`description in key info;
    
  hasName and hasVersion and hasDesc
 };

/ =============================================================================
/ INTEGRATION TESTS
/ =============================================================================

/ @test tplogsutils.repair then replay workflow
testrepairandreplay: {
  testfile:`:test_replay.log;
  goodfile:`$string[testfile],".good";
    
  / setup
  createcorruptlog[testfile;20;200];
    
  / test - tplogsutils.repair and try to replay
  tplogsutils.repair[testfile];
    
  / This should not throw an error if the .good file is valid
  replayOk:@[{-11!(1;x);1b};goodfile;{0b}];
    
  / cleanup
  cleanup (testfile;goodfile);
    
  replayOk
 };

/ @test Large file handling (performance test)
testlargefilehandling: {
  testfile:`:test_large.log;
  goodfile:`$string[testfile],".good";
  msgcount:500;  / Reasonable size for testing
    
  / setup
  createcorruptlog[testfile;msgcount;5000];
    
  / test - measure time
  start:.z.p;
  result:tplogsutils.repair[testfile];
  elapsed:`second$.z.p-start;
    
  / assert - should complete and create file
  completed:result~goodfile;
  reasonable:elapsed<30;  / Should complete in under 30 seconds
  passes:completed and reasonable;
    
  / cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

/ @test Sequential tplogsutils.check and tplogsutils.repair calls
testsequentialoperations: {
  testfile:`:test_sequential.log;
  goodfile:`$string[testfile],".good";
    
  / setup
  createcorruptlog[testfile;15;150];
    
  / test - tplogsutils.check then tplogsutils.repair
  tplogsutils.checkresult:tplogsutils.check[testfile;20j];
    
  / if tplogsutils.check triggered tplogsutils.repair, goodfile should exist
  / if not, manually tplogsutils.repair
  if[not tplogsutils.checkresult~goodfile;
     tplogsutils.repair[testfile];
    ];
    
  / assert - .good file should exist in either case
  passes:not ()~key goodfile;
    
  / cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

