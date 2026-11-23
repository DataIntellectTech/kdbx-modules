/ Build a realistic 10-day Renewable Energy Wind Fleet HDB for qsp + agenticq demos
/   q mkhdb.q   -> builds in /tmp/windfleet-db (or pass dir as arg)
/ Highlights baked into the data:
/   - 6 wind farms across NorthSea (offshore, high wind), Scotland, Texas
/   - 30 turbines across Vestas, Siemens, GE
/   - Simpson's paradox: Vestas has the highest RAW fault rate overall because 80% of its fleet
/     sits in harsh NorthSea gale conditions, yet Vestas is the MOST reliable in BOTH calm and gale!
/   - Predictive anomaly: Turbine T07 (HORNSEA) shows rising gearbox temp (62->94C), rising vibration
/     (2->9 mm/s), and power curve sag starting 2026.10.07, culminating in a critical GEARBOX fault
/     on 2026.10.08D14:20.

.wf.mk:{[dir]
  system"rm -rf '",dir,"' && mkdir -p '",dir,"'";
  system"S 42";

  / 1. Sites (reference)
  sites:([]
    site:`DOGGER`HORNSEA`HIGHLAND`CAITHNESS`WESTTX`PANHANDLE;
    region:`NorthSea`NorthSea`Scotland`Scotland`Texas`Texas;
    env:`offshore`offshore`onshore`onshore`onshore`onshore;
    baseWind:14.2 13.8 10.6 10.2 8.4 8.8;
    targetCf:0.52 0.50 0.41 0.39 0.35 0.36);

  / 2. Turbines (30 turbines: Vestas concentrated in harsh NorthSea -> Simpson's paradox!)
  tids:`$"T",/:({$[1=count x;"0",x;x]} each string 1+til 30);
  tsite:(5#`DOGGER),(5#`HORNSEA),(5#`HIGHLAND),(5#`CAITHNESS),(5#`WESTTX),(5#`PANHANDLE);
  / NorthSea (10): 8 Vestas, 1 Siemens, 1 GE
  / Scotland (10): 2 Vestas, 5 Siemens, 3 GE
  / Texas    (10): 1 Vestas, 4 Siemens, 5 GE
  tmfg:`Vestas`Vestas`Vestas`Vestas`Siemens`Vestas`Vestas`Vestas`Vestas`GE,
       `Vestas`Siemens`Siemens`Siemens`GE`Vestas`Siemens`Siemens`GE`GE,
       `Vestas`Siemens`Siemens`GE`GE`Siemens`Siemens`GE`GE`GE;
  trated:12.0 12.0 12.0 12.0 10.0 12.0 12.0 12.0 12.0 10.0,
         8.0 8.0 8.0 8.0 8.0 8.0 8.0 8.0 8.0 8.0,
         6.0 6.0 6.0 6.0 6.0 6.0 6.0 6.0 6.0 6.0;
  tyr:2022 2023 2021 2022 2020 2023 2021 2022 2024 2021,
      2020 2021 2019 2022 2020 2021 2022 2020 2023 2021,
      2019 2020 2021 2022 2020 2021 2019 2022 2023 2020;
  twar:`$"WC-",/:string 1001+til 30;
  turbines:([]turbine:tids;site:tsite;manufacturer:tmfg;ratedMw:trated;installYear:tyr;warrantyContract:twar);

  / Power curve helper: cubic ramp from 3 m/s to 12 m/s, flat rated 12..25 m/s, cut-out >25
  pcurve:{[w;r]
    f:?[w<3f;0f;?[w<12f;((w-3f)%9f) xexp 3;?[w<=25f;1f;0f]]];
    :r*f};

  dates:2026.10.01+til 10;
  step5:0D00:05*til 288; / 288 five-minute buckets per day
  diurnal:sin 3.14159265*(til 288)%144f;
  techs:`TECH01`TECH02`TECH03`TECH04`TECH05`TECH06`TECH07`TECH08;
  fcodes:`GEARBOX`PITCH`GRID`YAW`ICING;

  / Per-day generation
  cfg:`dir`sites`turbines`pcurve`step5`diurnal`techs`fcodes!(dir;sites;turbines;pcurve;step5;diurnal;techs;fcodes);
  {[cfg;d]
    dir:cfg`dir; sites:cfg`sites; turbines:cfg`turbines; pcurve:cfg`pcurve;
    step5:cfg`step5; diurnal:cfg`diurnal; techs:cfg`techs; fcodes:cfg`fcodes;
    di:d-2026.10.01;
    / Weather front hits NorthSea harder on Oct 4-5 and Oct 8
    storm:$[di in 3 4 7;3.2;di in 1 6;1.2;-0.6];
    tel:([]time:`timestamp$();turbine:`symbol$();site:`symbol$();windMs:`float$();powerMw:`float$();
           rpm:`float$();gearboxTempC:`float$();vibrationMmS:`float$();curtailed:`boolean$());
    flt:([]time:`timestamp$();turbine:`symbol$();site:`symbol$();faultCode:`symbol$();severity:`symbol$();
           downtimeMin:`long$();technicianId:`symbol$();repairCostUsd:`float$());
    mnt:([]time:`timestamp$();turbine:`symbol$();site:`symbol$();workType:`symbol$();hours:`float$();
           technicianId:`symbol$();repairCostUsd:`float$());

    j:0;
    while[j<count turbines;
      tr:turbines j;
      srow:first select from sites where site=tr`site;
      bw:srow[`baseWind]+$[srow[`env]=`offshore;storm;0.4*storm];
      w:0.5|bw+(1.6*diurnal)+((count step5)?3.6)-1.8;
      pw:0f|pcurve[w;tr`ratedMw]+((count step5)?0.35)-0.175;
      pw:pw&tr`ratedMw;
      rpm:0f|((pw%tr`ratedMw)*14.5)+((count step5)?0.4)-0.2;
      gtemp:52f+(14f*pw%tr`ratedMw)+((count step5)?2.4)-1.2;
      vib:1.4f+(1.8f*w%15f)+((count step5)?0.45)-0.22;
      curt:(w>20f)&0=(count step5)?8;
      pw:?[curt;pw*0.35;pw];

      / Inject progressive T07 gearbox failure on Oct 7 & Oct 8
      if[(tr[`turbine]=`T07)and di=6;
        ramp:(til count step5)%count step5;
        gtemp+:16f*ramp;
        vib+:3.2f*ramp;
        pw*:1f-0.18*ramp];
      if[(tr[`turbine]=`T07)and di=7;
        / 14:20 is bucket 172
        pre:til 172;
        ramp:(pre%172f);
        gtemp[pre]+:16f+18f*ramp;
        vib[pre]+:3.2f+4.4f*ramp;
        pw[pre]*:0.82-0.22*ramp;
        / Down after 14:20 fault for 4 hours (buckets 172..219)
        down:172+til 48;
        pw[down]:0f; rpm[down]:0f; gtemp[down]:48f; vib[down]:0.3f;
        flt,:enlist (d+0D14:20:00;`T07;tr`site;`GEARBOX;`critical;240;`TECH02;48500f);
        mnt,:enlist (d+0D15:00:00;`T07;tr`site;`corrective;6.5;`TECH02;48500f)];

      / Fault generation with Simpson's paradox:
      / Gale regime (avg wind >= 14) has ~4x fault probability vs calm (<14)
      / Within EACH regime: Vestas < Siemens < GE (Vestas is BEST!)
      mfgMult:$[tr[`manufacturer]=`Vestas;0.70;tr[`manufacturer]=`Siemens;1.00;1.35];
      isGale:(avg w)>=13.8;
      / Expected faults per turbine-day
      pFault:mfgMult*$[isGale;0.75;0.14];
      nf:$[(first 1?1f)<pFault;1;0]+$[(first 1?1f)<0.35*pFault;1;0];
      if[nf>0;
        k:0;
        while[k<nf;
          ft:d+0D00:05*(first 1?280);
          fc:first 1?fcodes;
          sev:$[isGale and 0=first 1?3;`critical;0=first 1?2;`med;`low];
          dm:$[sev=`critical;120+first 1?180;sev=`med;45+first 1?75;15+first 1?30];
          cost:`float$$[sev=`critical;18000+first 1?22000;sev=`med;4500+first 1?5500;800+first 1?1400];
          tc:first 1?techs;
          flt,:enlist (ft;tr`turbine;tr`site;fc;sev;dm;tc;cost);
          if[sev in `med`critical;
            mnt,:enlist (ft+0D00:30;tr`turbine;tr`site;`corrective;`float$(dm%60f);tc;cost)];
          k+:1]];

      / Scheduled preventive maintenance occasionally
      if[0=(j+di) mod 13;
        mnt,:enlist (d+0D09:00:00;tr`turbine;tr`site;`preventive;2.5;first 1?techs;1250f)];

      tel,:([]time:d+step5;turbine:(count step5)#tr`turbine;site:(count step5)#tr`site;
              windMs:0.01*floor 0.5+100*w;powerMw:0.01*floor 0.5+100*pw;
              rpm:0.01*floor 0.5+100*rpm;gearboxTempC:0.01*floor 0.5+100*gtemp;
              vibrationMmS:0.01*floor 0.5+100*vib;curtailed:curt);
      j+:1];

    tel:`turbine`time xasc tel;
    flt:`turbine`time xasc flt;
    mnt:`turbine`time xasc mnt;
    / Partitioned tables splayed with `p# on turbine
    pdir:dir,"/",string[d],"/";
    (`$":",pdir,"telemetry/") set .Q.en[hsym`$dir;update `p#turbine from tel];
    (`$":",pdir,"faults/") set .Q.en[hsym`$dir;update `p#turbine from flt];
    (`$":",pdir,"maintenance/") set .Q.en[hsym`$dir;update `p#turbine from mnt];
    }[cfg] each dates;

  (`$":",dir,"/sites") set sites;
  (`$":",dir,"/turbines") set turbines;
  -1"Built windfleet HDB in ",dir," (",string[count dates]," days, 30 turbines, 6 sites)";
  };

if[count .z.x;.wf.mk first .z.x;exit 0];
