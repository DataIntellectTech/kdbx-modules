/ api module - registration and metadata for a process's public API functions.
/ registry-only (no live namespace scan); di.torq collects each module's getapimeta and registers here.
\l ::api.q
export:([init;add;getapi;find;f;p;getapimeta])
