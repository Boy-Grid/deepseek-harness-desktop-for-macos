// A dsh stand-in that fails on startup, to exercise the launcher's early-exit
// path: it must report the failure with the log tail immediately instead of
// waiting out the readiness timeout.
console.error('fake-dsh: cannot bind, exiting 3 on purpose');
process.exit(3);
