/*
Programmed by: Jonathan W. Duggins
Programmed on: 2026-10-20
Programmed to: version 1.00
               1. Create first version for public release.

*/

%let dir=%str(/*path-to-your-program-directory*/);
%let out=%str(/*path-for-storing-your-results*/);
%let Assignment = /*your-program-name-prefix*/;
%let SasExeDir = %str(%sysget(sasroot));

options noxwait nomprint nomlogic nosymbolgen;
ods trace off;

/*Create batch to move all student programs to a single folder*/
data _null_;
  attrib txt   length = $ 200;

  file "&out.\Flatten.bat";
  
  put "set dSource=&dir";
  put "set dTarget=&out.";
  put "set fType=&Assignment.*.sas";
  txt = cat('for /f "delims=" %%f in (', "'dir /a-d /b /s ", '"%dSource%\%fType%"',"') do (");
  put txt;
  txt = 'copy "%%f" "%dTarget%\" 2>nul';
  put txt;
  put ")";
  put 'exit';
run;

*Locate and execute the batch file;
x "cd &out.";
x "Flatten.bat";

/*Find all downloaded student programs*/
data StudentPrograms(keep = fname
                     where = (index(fname,'.sas') gt 0));
  length fref $25 fname $200;
  nameDID = filename(fref,"&out.");
  openDID = dopen(fref);
  if openDID gt 0 then do i = 1 to dnum(openDID);
    fname = dread(openDID,i);
    output;
  end;
  closeDID = dclose(openDID);
  remDID = filename(fref);
run;

*Place all file names into a single 
 pipe-delimited macro variable;
proc sql noprint;
  select fname
  into :prgmz separated by "|"
  from studentprograms
  ;
quit;
options ls = 120;
%put &prgmz;

/*Modify paths to student work*/
%macro FixDriveMapping;
  options dlcreatedir;
  libname fixd "&out.\FixedMapping";
  options nodlcreatedir;

  %let iter = 1;
  %let fname = %scan(&prgmz,&iter,'|');

  %do %until(%bquote(&fname) = );
    data _null_;
      infile "&out.\&fname." truncover length = reclen;
      input _line $varying32767. reclen;

      retain _str kcFLag;

      *Delete blank lines before parsing;
      if missing(_line) then delete;

      *Remove all inline kernel comments;
      kc=prxparse("s/\/\*.*?\*\///");
      _line=compbl(prxchange(kc,-1,_line));

      *Detect multiline kernel comments;
      kcstartpos = index(_line,'/*');
      kcendpos = index(_line,'*/');

      *If multiline comment starts in the first column, then
       the whole line can be discarded.;
      if kcstartpos eq 1 and kcendpos eq 0 then kcflag=1;
       *If there's code first, extract code before comment begins;
        else if kcstartpos gt 1 and kcendpos eq 0 then do;
            _str = substr(_line,1,kcstartpos-1);
            kcFlag = 1;
          end;
        *Find end of multilne comment and extract text
         after comment ends;
        else if kcstartpos eq 0 and kcendpos gt 0 then do;
            kcFlag = 0;
            _line = cat(trim(_str),substr(_line,kcendpos+2));
            call missing(_str);
          end;

      *delete any lines 1 through n-1 on the multiline comment;
      if kcFlag eq 1 then delete;

      *delete ODS TRACE statements;
      if index(lowcase(_line),'ods trace') ge 1 then delete;
      
        *Check if long enough for X or not;
        else if lengthn(compress(_line)) ge 7 then 
            do;
              *if TRUE, check if actually an X with S/B/C drive mapping;
              if substr(compress(lowcase(_line)),1,6) in ('x"cds:' 'x''cds:' 'x"cdb:' 'x''cdb:' 'x"cdc:' 'x''cdc:') then 
                  do;
                    *if TRUE, then remap to out path, update length, write the record;
                    _line = cat('x "cd ', "&out.\FixedMapping", '";');
                    len = reclen+lengthn("&out.\FixedMapping");
                    file "&out.\FixedMapping\&fname.";
                    put _line $varying32767. len;
                  end;
                *if not an X with S/B/C mapping, write the record as is;
                else 
                  do;
                    file "&out.\FixedMapping\&fname.";
                    put _line $varying32767. reclen;
                  end;
            end;
          *if length not ge 7, then write the record as is;
          else 
            do;
              file "&out.\FixedMapping\&fname.";
              put _line $varying32767. reclen;
            end;
    run;

    %let iter = %eval(&iter+1);
    %let fname = %scan(&prgmz,&iter,'|');
  %end;
%mend FixDriveMapping;

%FixDriveMapping

/*Create batch to run all student programs*/
data _null_;
  attrib txt   length = $ 200;
  set StudentPrograms end=eof;

  file "&out.\FixedMapping\RunStudentPrograms.bat";

  if _n_=1 then do;
      put "set SASLOC=&SasExeDir.";
      txt='set PRJLOC='||strip("&out.")||"\FixedMapping";
      put txt;
      txt=scan("&dir.",1,"\");
      put txt;
      put 'CD %PRJLOC%';
      put 'DEL /Q *.LOG';
      put 'DEL /Q *.LST';
    end;

  txt='"%SASLOC%\sas.exe" -rsasuser -noicon -nosplash -nosyntaxcheck '||'-nostatuswin -nologo -SYSIN "%PRJLOC%\'||strip(fname)||'"';
  put txt;

  if eof then put 'EXIT';
run;

*Locate and execute the batch file;
x "cd &out.\FixedMapping";
x "RunStudentPrograms.bat";

*Find all the student logs;
data StudentLogs(keep = fname
                     where = (index(fname,'.log') gt 0));
  length fref $8 fname $200;
  did = filename(fref,"&out.\FixedMapping");
  did = dopen(fref);
  if did gt 0 then do i = 1 to dnum(did);
    fname = dread(did,i);
    output;
  end;
  did = dclose(did);
  did = filename(fref);
run;

*Put all log file names into a 
 pipe-delimited macro variable;
proc sql noprint;
  select fname
  into :logz separated by "|"
  from studentlogs
  ;
quit;

*Scan through all student logs
  - DEBUG controls whether intermediate variables useful for 
    debugging are deleted
    + NO drops the intermediate variables. This is the default
    + YES does _not_ drop the intermediate variables
  - FULLREPORT controls whether the entire log for a student
    is preserved or not
    + NO drops all but the last line of the student log
    + YES preserves all lines of a student's log
;
%macro StudentLogScan(debug=no,fullreport=no);
  %let iter = 1;
  %let fname = %scan(&logz.,&iter.,'|');

  *Check if assignment already has a Logscan file. If so, delete it.;
  %if %sysfunc(exist(&Assignment.StudentLogScans)) %then %do;
      proc datasets;
        delete &Assignment.StudentLogScans / memtype = data;
        run;
      quit;
    %end;

  %do %until(%bquote(&fname) = );
    data LogScanTemp;
      infile "&out.\FixedMapping\&fname." truncover length = reclen;
      input _line $varying32767. reclen;
      
      _line = lowcase(_line);
      if index(_line,'the sas system') eq 0 and lengthn(_line) gt 0;
    run;

    /*Split so END= is available to grab last record*/
    data LogScan %if (&debug = no) %then (drop = _: OpOnMissFlag ImpConvFlag QuitCount RunCount StepStart);;
      attrib Student  length = $ 50 
             _col1to5 length = $ 5
             GlobalStrings length = $ 32767
      ;
      Student = scan("&fname.",1,'.');
      set LogScanTemp end = last;
      retain UninitCount ImpConvCount LostCardCount OpOnMissCount 0
             ImpConvFlag OpOnMissFlag 0
             UnrecovSyntaxErrCount RecovSyntaxErrCount 0
             TrueWarnCount 0
             StepStart GlobalStatementCount 0
/*             TraceStart 0*/
             GlobalStrings
      ;

      array SingleNoteCountz[2] UninitCount LostCardCount;
      array SingleBadNotez[2] $ 50 _temporary_ ('is uninitialized' 
                                                'lost card');

      array MultiNoteCountz[2] ImpConvCount OpOnMissCount;
      array MultiBadNotez[2] $ 50 _temporary_ ('have been converted' 
                                               'missing values were generated');
      array MultiFlagz[2] ImpConvFlag OpOnMissFlag;

      array BadErrz[3] $ 50 _temporary_ ('syntax error' 
                                         'unrecognized sas option' 
                                         'was misspelled');
         
      *Check all Note messages;
      _notePattern = prxparse("/note:/");
      _noteMatch = prxmatch(_notePattern,_line);

      *Multi-note pattern;
      _multiPattern = prxparse("/\d+:\d+/");
      _multiMatch = prxmatch(_multiPattern,_line);

      *Check bad notes that print one NOTE for each instance;
      do _i = 1 to dim(SingleBadNotez);
        if (_noteMatch gt 0) and (index(_line,strip(SingleBadNotez[_i])) gt 0) then SingleNoteCountz[_i] + 1;
      end;

      *Check bad notes that print one NOTE for multiple instances;
      do _i = 1 to dim(MultiBadNotez);
        *check if the bad note has already tripped our Flag
         AND
         if line actually contains locations of issues;
        if (MultiFlagz[_i] eq 1) and (_multiMatch gt 0) then do;
            *If so, count how many issues occured;
            MultiNoteCountz[_i] + countc(_line,":");
            *Then reset the flag;
            MultiFlagz[_i] = 0;
          end;
        *check if the bad note is on the current line and then trip the Flag;
        if (_noteMatch gt 0) and (index(_line,strip(MultiBadNotez[_i])) gt 0) then MultiFlagz[_i] = 1;
      end;

      *Determine total number of tracked notes;
      BadNoteCount = sum(UninitCount, ImpConvCount, OpOnMissCount, LostCardCount);

      *Check all error and warning messages;
      _errPattern = prxparse("/error\s\d+-\d+:/");
      _warnPatternLong = prxparse("/warning\s\d+-\d+:/");
      _warnPatternShort = prxparse("/warning:/");

      _errMatch = prxmatch(_errPattern,_line);
      _warnMatchLong = prxmatch(_warnPatternLong,_line);
      _warnMatchShort = prxmatch(_warnPatternShort,_line);

      *Check error notes;
      if (_errMatch gt 0) and 
         ((index(_line,strip(BadErrz[1])) gt 0) or (index(_line,strip(BadErrz[2])) gt 0)) then UnrecovSyntaxErrCount + 1; 
        else if (_warnMatchLong gt 0) and 
                (index(_line,strip(BadErrz[3])) gt 0) then RecovSyntaxErrCount + 1;
          else if _warnMatchShort gt 0 then TrueWarnCount + 1;

      *Count PROC/DATA steps vs boundaries;
      *if (lengthn(compress(_line,' ','d')) ge 4) and /*line is long enough*/
         (substr(compress(_line),1,8) ne 'dataname') /*line is not from ODS TRACE*/
            then _col1to5 = substr(compress(_line,' ','d'),1,4);
      if (lengthn(compress(_line,' ','d')) ge 4) and /*line is long enough*/
         (substr(left(_line),1,8) ne 'dataname') /*line is not from ODS TRACE*/
            then _col1to5 = substr(compbl(left(compress(_line,,'d'))),1,5);
      select(_col1to5);
        when('proc') procCount+1;
        when('data') dataCount+1;
        when('run;','run ;') runCount+1;
        when('quit;', 'quit') quitCount+1;
        otherwise;
      end;

      BoundDiff = abs(procCount+dataCount - runCount) + abs(quitCount - 1);

      *Count number of global statements inside a step;
      cond1 = compress(lowcase(scan(_line,2,' ')),' ;');
      cond2 = compress(cond1,,'d');

      if _col1to5 in ('data' 'proc') then StepStart = 1;
        else if cond1 in ('run' 'quit') then StepStart = 0;

      if StepStart eq 1 and 
          (cond2 in ('title' 'footnote') or
           cond1 in ('ods' 'options' '%let' 'x' 'filename' 'libname' 'dm'))
        then do;
            GlobalStatementCount + 1;
            _str=substr(compbl(_line),1,min(lengthn(compbl(_line)),25));
            globalStrings = catx("200A20"x,globalStrings,_Str);
          end;

      %if (&fullreport = no) %then %do;
        if last eq 1;
      %end;
    run;

    proc append base = &Assignment.StudentLogScans
                data = LogScan;
    run;

    %let iter = %eval(&iter+1);
    %let fname = %scan(&logz,&iter,'|');
  %end;

  proc datasets;
    modify &Assignment.StudentLogScans;
    attrib UninitCount label = "# of Distinct Uninitialized Variables"
           ImpConvCount label = "# of Distinct Implicit Conversions"
           LostCardCount label = "# of Distinct Lost Card Notes"
           OpOnMissCount label = "# of Distinct Operation on Missing Value Issues"
           BadNoteCount label = "# of Problematic Notes"
           UnrecovSyntaxErrCount label = "# of Unrecoverable Syntax Errors"
           RecovSyntaxErrCount label = "# of Recoverable Syntax Errors"
           TrueWarnCount label = "# of Warnings not Related to Syntax Errors"
           BoundDiff label = "# of Missing/Extra Step Boundaries"
           dataCount label = "# of DATA Steps"
           procCount label = "# of PROC Steps"
           GlobalStatementCount label = "# of Global Statements Inside Steps"
           GlobalStrings label = "Concatenation of all Global Statements"
    ;
    run;
  quit;

  ods _all_ close;
  ods excel file = "&out\FixedMapping\&Assignment.Results.xlsx";

  proc report data = &Assignment.StudentLogScans split ='0A'x;
    column Student
           UnrecovSyntaxErrCount RecovSyntaxErrCount TrueWarnCount 
           BadNoteCount OpOnMissCount ImpConvCount UninitCount LostCardCount
           BoundDiff dataCount procCount GlobalStatementCount GlobalStrings;
    define Student / display style(column) = [width=2in];
    define UnrecovSyntaxErrCount / display style(header) = [backgroundcolor = cx700000 color = cxFFFFFF];
    define RecovSyntaxErrCount / display style(header) = [backgroundcolor = cx700000 color = cxFFFFFF];
    define TrueWarnCount / display style(header) = [backgroundcolor = cx2A8307 color = cxFFFFFF];
    define BadNoteCount / display style(header) = [backgroundcolor = cx0000FF color = cxFFFFFF];
    define OpOnMissCount / display style(header) = [backgroundcolor = cx3883A8 color = cxFFFFFF];
    define ImpConvCount / display style(header) = [backgroundcolor = cx3883A8 color = cxFFFFFF];
    define UninitCount / display style(header) = [backgroundcolor = cx3883A8 color = cxFFFFFF];
    define LostCardCount / display style(header) = [backgroundcolor = cx3883A8 color = cxFFFFFF];
    define BoundDiff / display style(header) = [backgroundcolor = cxB090D0 color = cxFFFFFF];
    define dataCount / display style(header) = [backgroundcolor = cxB090D0 color = cxFFFFFF];
    define procCount / display style(header) = [backgroundcolor = cxB090D0 color = cxFFFFFF];
    define GlobalStatementCount / display style(header) = [backgroundcolor = cxFDC086 color = cxFFFFFF];
    define GlobalStrings / display style(header) = [backgroundcolor = cxFDC086 color = cxFFFFFF width=4in];
  run;

  ods excel close;

%mend StudentLogScan;

options nosymbolgen nomlogic;
%StudentLogScan(debug=no,fullreport=no)

quit;
