/ di.permissions - role-based access control and authentication for a KDB-X process
/ consolidates TorQ's permissions.q (.pm), writeaccess.q (.readonly), ldap.q (.ldap) and common/execas.q
/ owns the exec phase of the message-handling .z.* events via the injected di.handlers dependency

\l ::permissions.q

/ Module version
version:first read0`:::VERSION

/ NB: export:([...]) EVALUATES each name, so it can only list names that already exist - the export
/ list and the implementation therefore cannot drift apart in this direction.
/ init and getapimeta are framework plumbing di.torq calls by convention; every other name here has a
/ getapimeta row, which the test suite asserts
export:([init;teardown;version;getapimeta;status;
         allowed;requ;val;valp;execas;
         admin;loadpermissions;unblock])
