#!/usr/bin/env python3
"""Run a command, capture its streams to files, print "STATUS NANOSECONDS".

The clock brackets the subprocess only, from inside one already-started Python
process, so interpreter startup is not part of any sample. Nothing is piped, so
no exit status can be hidden.

Usage: time_run.py OUT ERR CMD [ARG ...]
"""

import subprocess
import sys
import time


def main():
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    out_path, err_path = sys.argv[1], sys.argv[2]
    cmd = sys.argv[3:]
    with open(out_path, "wb") as out, open(err_path, "wb") as err:
        t0 = time.monotonic_ns()
        proc = subprocess.run(cmd, stdout=out, stderr=err)
        elapsed = time.monotonic_ns() - t0
    # subprocess reports a signal death as a negative code; report it the way the
    # shell does, so a signal stays distinguishable from a wrong answer.
    status = proc.returncode
    if status < 0:
        status = 128 - status
    print("%d %d" % (status, elapsed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
