#!/usr/bin/env python3
"""Pathological patterns stay linear: times them on growing inputs.

Builds tools/linearity.goose natively and times, with each matcher
(Go's choice, the Pike VM, the backtracker), patterns that take a
backtracking engine exponential time:

  star     (a*)*b on a^n           no match; a backtracker tries 2^n splits
  nested   (a|aa)*c on a^n         no match; Fibonacci(n) ways to split
  alt      (x+x+)+y on x^n         no match
  findall  a*b|a, all matches in (aaab)^(n/4)
  quest    a?^n a^n on a^n         the program grows with n as well: O(n^2)

Each size is 4 times the one before, so a linear matcher's time grows about
4 times a step (quest's about 16 times: its program is n long too). The
script fails if a step grows more than twice what linear (quadratic for
quest) allows, at sizes where timing is not noise.

    python3 scripts/linearity.py [--goose PATH]
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))

CASES = {
    "star": [4000, 16000, 64000, 256000, 1024000, 4096000],
    "nested": [4000, 16000, 64000, 256000, 1024000, 4096000],
    "alt": [4000, 16000, 64000, 256000, 1024000, 4096000],
    "findall": [4000, 16000, 64000, 256000, 1024000, 4096000],
    "quest": [25, 50, 100, 200, 400],
}
ENGINES = [("Go's choice", 0), ("Pike VM", 1), ("backtracker", 2)]


def find_goose(arg):
    for cand in [arg, os.environ.get("GOOSE"), shutil.which("goose"),
                 os.path.join(ROOT, "..", "goose.git", "build", "goose")]:
        if cand and os.path.isfile(cand):
            return cand
    sys.exit("no goose compiler found: pass --goose or set GOOSE")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--goose")
    args = ap.parse_args()
    goose = find_goose(args.goose)
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        exe = os.path.join(tmp, "linearity")
        p = subprocess.run([goose, "build", "-o", exe, "linearity.goose"], cwd=os.path.join(ROOT, "tools"),
                           capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit("build failed:\n" + p.stdout + p.stderr)
        for kind, sizes in CASES.items():
            for label, engine in ENGINES:
                if kind == "findall" and engine == 2:
                    continue
                out = subprocess.run([exe, kind, "E=%d" % engine] + [str(n) for n in sizes],
                                     capture_output=True, text=True, check=True).stdout.split("\n")
                rows = [l.split() for l in out if l]
                times = [float(r[1]) for r in rows]
                line = "%-8s %-12s" % (kind, label)
                factor = 16 if kind == "quest" else 4
                for i, (n, t) in enumerate(zip(sizes, times)):
                    line += "  n=%-8d %8.4fs" % (n, t)
                    if i > 0 and times[i - 1] > 0.002 and t > 2 * factor * times[i - 1]:
                        line += " (!)"
                        bad += 1
                print(line)
    print("OK: every step grew within twice linear (quadratic for quest)" if not bad else "%d steps grew too fast" % bad)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
