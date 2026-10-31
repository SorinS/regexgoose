#!/usr/bin/env python3
"""Go's TestRE2Exhaustive: RE2's re2-exhaustive.txt against this package.

Unpacks $GOROOT/src/regexp/testdata/re2-exhaustive.txt.bz2 (428 KB, 61 MB
unpacked, so it is not kept in this repository) into a temporary
directory, builds test/re2_exhaustive_test.goose natively, and runs it on
the file. Every regexp is run on every string four ways (full and partial
match, leftmost-first and leftmost-longest) by FindStringSubmatchIndex and
MatchString, as Go's test does; then again with each matcher forced
(regexp::debug_engine: the Pike VM, the backtracker, the one-pass matcher).

    python3 scripts/re2_exhaustive.py [--goose PATH] [--go PATH] [--engine N]
"""

import argparse
import bz2
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))


def find_goose(arg):
    for cand in [arg, os.environ.get("GOOSE"), shutil.which("goose"),
                 os.path.join(ROOT, "..", "goose.git", "build", "goose")]:
        if cand and os.path.isfile(cand):
            return cand
    sys.exit("no goose compiler found: pass --goose or set GOOSE")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--goose")
    ap.add_argument("--go", default=shutil.which("go") or "go")
    ap.add_argument("--engine", type=int, help="only this engine (0: Go's choice)")
    args = ap.parse_args()
    goose = find_goose(args.goose)
    goroot = subprocess.run([args.go, "env", "GOROOT"], capture_output=True, text=True, check=True).stdout.strip()
    src = os.path.join(goroot, "src", "regexp", "testdata", "re2-exhaustive.txt.bz2")
    with tempfile.TemporaryDirectory() as tmp:
        txt = os.path.join(tmp, "re2-exhaustive.txt")
        with bz2.open(src, "rb") as f, open(txt, "wb") as out:
            shutil.copyfileobj(f, out)
        exe = os.path.join(tmp, "re2_exhaustive")
        p = subprocess.run([goose, "build", "-o", exe, "re2_exhaustive_test.goose"], cwd=os.path.join(ROOT, "test"),
                           capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit("build failed:\n" + p.stdout + p.stderr)
        status = 0
        for engine in ([args.engine] if args.engine is not None else [0, 1, 2, 3]):
            t0 = time.time()
            p = subprocess.run([exe, txt, str(engine)])
            print("%.1f s" % (time.time() - t0))
            status = status or p.returncode
        sys.exit(status)


if __name__ == "__main__":
    main()
