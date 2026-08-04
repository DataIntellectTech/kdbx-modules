/ minimal stub logging provider - satisfies the `info`warn`error DI contract documented
/ in kdbx-modules/consistency.md. Real di.util.log (plan Sprint 1) wraps kx.log; swap later.

fmt:{[level;ctx;msg] (string .z.p)," ",(upper string level)," ",(string ctx)," ",msg}

info:{[ctx;msg] -1 fmt[`info;ctx;msg]; }
warn:{[ctx;msg] -1 fmt[`warn;ctx;msg]; }
error:{[ctx;msg] -2 fmt[`error;ctx;msg]; }
