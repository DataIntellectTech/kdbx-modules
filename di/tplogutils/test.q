/ =============================================================================
/ TEST HELPERS
/ =============================================================================

upd:{[t;x] t upsert x};
trade:([] time:`timestamp$(); sym:`symbol$(); price:`float$(); size:`long$());

/ @function createValidLog
/ @description Create a valid tickerplant log file for testing
/ @param filepath {symbol} Path where to create the log file
/ @param msgcount {long} Number of messages to write
createvalidlog: {[filepath;msgcount]
  / Create test table
  trade:([] time:.z.p + til msgcount; sym:msgcount?`AAPL`GOOGL`MSFT`AMZN`TSLA; price:100+msgcount?100.0; size:100+msgcount?1000);
  / Create log file and write messages
  h:hopen filepath set ();
  {[h;i;t] h enlist (`upd;`trade;value t[i])} [h;;trade] each til msgcount;
  hclose h;
 };

/ @function createCorruptLog
/ @description Create a log file with valid messages followed by corruption
/ @param filepath {symbol} Path where to create the log file
/ @param msgcount {long} Number of messages in log file
/ @param corruptpos {long} Message position where to insert corruption
createcorruptlog: {[filepath;msgcount;corruptpos]
  / Create test table
  trade:([] time:.z.p + til msgcount; sym:msgcount?`AAPL`GOOGL`MSFT`AMZN`TSLA; price:100+msgcount?100.0; size:100+msgcount?1000);
  / Create log file and write messages
  h:hopen filepath set ();
  {[h;i;t;corruptpos] 
    if[=[i;corruptpos]; 
      data:enlist (`upd;`trade;value t[i]);
      data_bytes:-18!data;
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
cleanup: {[filepaths]
  {[fp] @[hdel;fp;{}]} each filepaths;
 };

/ =============================================================================
/ BASIC FUNCTIONALITY TESTS
/ =============================================================================

/ @test Valid log file tplogsutil.check returns original filepath
testcheckvalidlog: {
  testfile:`:test_valid.log;
  msgcount:10;
  
  / Setup
  createValidLog[testfile;msgcount];
  
  / Test
  result:tplogsutil.check[testfile;msgcount-1];
  
  / Assert
  passes:result~testfile;
  
  / Cleanup
  cleanup enlist testfile;
  
  / Return
  passes
 };

/ @test tplogsutil.check returns original when enough good messages exist
testcheckcorruptsufficientmessages: {
  testfile:`:test_corrupt_sufficient.log;
  validmsgcount:20;
  lastmsgtoreplay:10j;
    
  / Setup: corrupt after position where we have enough good messages
  createCorruptLog[testfile;validmsgcount;500];
  
  / Test
  result:tplogsutil.check[testfile;lastmsgtoreplay];
  
  / Assert - should return original since we have enough good messages
  goodmsgcount:first -11!(-2;testfile);
  passes:(result~testfile) and (goodmsgcount > lastmsgtoreplay);
  
  / Cleanup
  cleanup enlist testfile;
  
  passes
 };

/ @test tplogsutil.repair creates .good file with correct name
testrepaircreatesgoodfile: {
  testfile:`:test_tplogsutil.repair.log;
  expectedgoodfile:`$string[testfile],".good";
    
  / Setup
  createCorruptLog[testfile;15;150];
    
  / Test
  result:tplogsutil.repair[testfile];
  
  / Assert
  nameCorrect:result~expectedgoodfile;
  fileExists:not ()~key expectedgoodfile;
  passes:nameCorrect and fileExists;
    
  / Cleanup  
  cleanup (testfile;expectedgoodfile);
  
  passes
 };

/ @test tplogsutil.repair recovers valid messages from corrupt log
testrepairrecoversmessages: {
  testfile:`:test_recover.log;
  goodfile:`$string[testfile],".good";
  validmsgcount:20;
    
  / Setup
  createCorruptLog[testfile;validmsgcount;250];
    
  / Test
  tplogsutil.repair[testfile];
    
  / Count messages in good file
  recoveredcount:countLogMessages[goodfile];
    
  / Assert - should recover at least some messages
  passes:(recoveredcount>0) and (recoveredcount<=validmsgcount);
    
  / Cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

/ @test tplogsutil.check triggers tplogsutil.repair when insufficient good messages
testchecktriggersrepair: {
  testfile:`:test_tplogsutil.check_tplogsutil.repair.log;
  goodfile:`$string[testfile],".good";
  validmsgcount:10;
  lastmsgtoreplay:15j;  / Need more messages than available good ones
    
  / Setup - corrupt early so not enough good messages
  createCorruptLog[testfile;validmsgcount;100];
    
  / Test
  result:tplogsutil.check[testfile;lastmsgtoreplay];
    
  / Assert
  triggerstplogsutil.repair:result~goodfile;
  fileCreated:not ()~key goodfile;
  passes:triggerstplogsutil.repair and fileCreated;
    
  / Cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

/ =============================================================================
/ EDGE CASE TESTS
/ =============================================================================

/ @test tplogsutil.repair handles garbage at end of file
testrepairgarbageatend: {
  testfile:`:test_garbage_end.log;
  goodfile:`$string[testfile],".good";
    
  / Setup - create log and append garbage at end
  createValidLog[testfile;10];
  bytes:read1 testfile;
  testfile set bytes,100#0x00;
    
  / Test
  result:tplogsutil.repair[testfile];
    
  / Assert
  nameCorrect:result~goodfile;
  hasMessages:countLogMessages[goodfile]>0;
  passes:nameCorrect and hasMessages;
    
  / Cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

/ @test Handles multiple corruption points
testmultiplecorruptsections: {
  testfile:`:test_multi_corrupt.log;
  goodfile:`$string[testfile],".good";
    
  / Setup - create log with corruption in middle
  createValidLog[testfile;30];
  bytes:read1 testfile;
    
  / Insert corruption at position (should have valid messages before and after)
  if[200 < count bytes;
    corrupted:bytes[til 200],10#0xFF,bytes[210+til count[bytes]-210];
    testfile set corrupted;
  ];
    
  / Test
  result:tplogsutil.repair[testfile];
    
  / Assert - should create file and recover something
  fileCorrect:result~goodfile;
  fileExists:not ()~key goodfile;
  passes:fileCorrect and fileExists;
    
  / Cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

/ @test Completely corrupt log creates empty .good file
testcompletelycorruptlog: {
  testfile:`:test_all_corrupt.log;
  goodfile:`$string[testfile],".good";
    
  / Setup - create completely corrupt file
  testfile set 1000#0x00;
    
  / Test
  result:tplogsutil.repair[testfile];
    
  / Assert - should create .good file even if empty/minimal
  nameCorrect:result~goodfile;
  fileExists:not ()~key goodfile;
  passes:nameCorrect and fileExists;
    
  / Cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

/ @test Empty log file handling
testemptylog: {
  testfile:`:test_empty.log;
   
  / Setup - create empty file
  testfile set 0#0x00;
    
  / Test - should not crash
  result:tplogsutil.check[testfile;0j];
  passes:1b;  / If we got here without error, test passes
    
  / Cleanup
  cleanup enlist testfile;
    
  passes
 };

/ =============================================================================
/ CONFIGURATION TESTS
/ =============================================================================

/ @test Verify module constants are set correctly
testconstantsset: {
  chunkOk:CHUNK=10*1024*1024;
  maxchunkOk:MAXCHUNK=8*CHUNK;
  updmsgOk:10=count UPDMSG;
  headerOk:8=count HEADER;
    
  chunkOk and maxchunkOk and updmsgOk and headerOk
 };

/ @test Module metadata is present
test_module_info: {
  hasName:`name in key info;
  hasVersion:`version in key info;
  hasDesc:`description in key info;
    
  hasName and hasVersion and hasDesc
 };

/ =============================================================================
/ INTEGRATION TESTS
/ =============================================================================

/ @test tplogsutil.repair then replay workflow
testrepairandreplay: {
  testfile:`:test_replay.log;
  goodfile:`$string[testfile],".good";
    
  / Setup
  createCorruptLog[testfile;20;200];
    
  / Test - tplogsutil.repair and try to replay
  tplogsutil.repair[testfile];
    
  / This should not throw an error if the .good file is valid
  replayOk:@[{-11!(1;x);1b};goodfile;{0b}];
    
  / Cleanup
  cleanup (testfile;goodfile);
    
  replayOk
 };

/ @test Large file handling (performance test)
testlargefilehandling: {
  testfile:`:test_large.log;
  goodfile:`$string[testfile],".good";
  msgcount:500;  / Reasonable size for testing
    
  / Setup
  createCorruptLog[testfile;msgcount;5000];
    
  / Test - measure time
  start:.z.p;
  result:tplogsutil.repair[testfile];
  elapsed:`second$.z.p-start;
    
  / Assert - should complete and create file
  completed:result~goodfile;
  reasonable:elapsed<30;  / Should complete in under 30 seconds
  passes:completed and reasonable;
    
  / Cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

/ @test Sequential tplogsutil.check and tplogsutil.repair calls
testsequentialoperations: {
  testfile:`:test_sequential.log;
  goodfile:`$string[testfile],".good";
    
  / Setup
  createCorruptLog[testfile;15;150];
    
  / Test - tplogsutil.check then tplogsutil.repair
  tplogsutil.checkResult:tplogsutil.check[testfile;20j];
    
  / If tplogsutil.check triggered tplogsutil.repair, goodfile should exist
  / If not, manually tplogsutil.repair
  if[not tplogsutil.checkResult~goodfile;
     tplogsutil.repair[testfile];
    ];
    
  / Assert - .good file should exist in either case
  passes:not ()~key goodfile;
    
  / Cleanup
  cleanup (testfile;goodfile);
    
  passes
 };

