#!/usr/bin/env python3
"""This package's speed against Go's regexp, on Go's own benchmarks.

Builds tools/bench.goose natively and tools/regexpbench (Go), which time
the same cases with the same loop: exec_test.go's BenchmarkMatch (Easy0,
Easy0i, Easy1, Medium, Hard, Hard1 on Go's makeText, 32 B to 1 MB), the
one-pass match, all_test.go's micro-benchmarks and BenchmarkCompile, and
two FindAll searches over 1 MB. Prints ns/op for each and the ratio
(goose / go: below 1 is faster).

    python3 scripts/bench.py [--goose PATH] [--min SECONDS]
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

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
    ap.add_argument("--min", default="0.2")
    args = ap.parse_args()
    goose = find_goose(args.goose)
    with tempfile.TemporaryDirectory() as tmp:
        gob = os.path.join(tmp, "regexpbench")
        subprocess.run([args.go, "build", "-o", gob, "."], cwd=os.path.join(ROOT, "tools", "regexpbench"), check=True,
                       env=dict(os.environ, GOPROXY="off"))
        mine = os.path.join(tmp, "bench")
        p = subprocess.run([goose, "build", "-o", mine, "bench.goose"], cwd=os.path.join(ROOT, "tools"),
                           capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit("build failed:\n" + p.stdout + p.stderr)
        go = dict(l.split() for l in subprocess.run([gob, "-min", args.min], capture_output=True, text=True,
                                                     check=True).stdout.splitlines() if l.strip())
        gs = dict(l.split() for l in subprocess.run([mine], capture_output=True, text=True,
                                                     check=True).stdout.splitlines() if l.strip())
    print("%-34s %14s %14s %7s" % ("case", "go ns/op", "goose ns/op", "ratio"))
    for k, v in go.items():
        a, b = float(v), float(gs.get(k, "nan"))
        print("%-34s %14.1f %14.1f %7.2f" % (k, a, b, b / a))


if __name__ == "__main__":
    main()
