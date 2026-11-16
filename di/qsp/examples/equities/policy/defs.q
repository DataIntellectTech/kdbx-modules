/ the q that this policy names: its lookups and its clock. It lives in the policy directory so a
/ change to it is reviewed with the grants that call it. qsp.fromfiles does not load it - loading q
/ is the process's decision - so load it first: hdb.q does, with the database, and CI does with
/ -init, to check the policy without the data:
/   q di/qsp/bin/policy.q -dir di/qsp/examples/equities/policy -init di/qsp/examples/equities/policy/defs.q
/ To load it with the HDB instead, copy it into the database root, which q loads .q files from -
/ but copy it from here, the reviewed copy, as part of deploying: anyone who can write to the
/ database could otherwise change what every filter returns
/ The filters call these by name, with the user, on every query. They are ordinary q over
/ ordinary tables: change a row and that user's next query sees it, with no reload. Nothing here
/ is granted, so no user can read these tables

/ which regions each salesperson covers - and so which accounts
coverage:([]user:`sales_na`sales_emea`sales_emea;region:`NA`EMEA`APAC);
coveredaccounts:{[u] :exec account from accounts where region in exec region from coverage where user=u;};

/ which desk each desk head runs - and so which traders
deskheads:([]user:`cash_head`etf_head;desk:`CASH`ETF);
deskof:{[u] :exec desk from deskheads where user=u;};
desktraders:{[u] :exec trader from traders where desk in deskof u;};

/ the policy clock, which qsp.aged and qsp.NOW measure from. The example's data is fixed in
/ October 2026, so its clock is fixed at the morning after the last day; against the real clock
/ every row would be old and the research embargo would hold nothing back. DEMO ONLY: a real
/ policy leaves the clock alone. It changes nothing outside qsp - only config.csv's clock row
/ points qsp at it - but delete both before reusing this policy
exampleclock:{[] :2026.10.10D00:00;};
