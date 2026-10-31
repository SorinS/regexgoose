#!/usr/bin/env python3
"""This package against Go's regexp, on generated patterns and inputs.

Generates cases (a pattern, an input, a replacement template, and a mode:
Compile, CompilePOSIX, or Compile then Longest), runs them through
tools/regexporacle (Go) and tools/regexpverdict.goose (this package, built
natively), and compares, case by case: the compile error (code and
expression), NumSubexp, SubexpNames, LiteralPrefix, the String() of the
parse and of its simplification, the program listing, MatchString,
FindStringIndex, FindStringSubmatchIndex, FindAllStringSubmatchIndex,
FindAllStringIndex with n = 2, ReplaceAllString, ReplaceAllLiteralString,
and Split with n = -1 and 2.

The patterns come from a grammar over RE2's syntax: literals (ASCII,
multi-byte, case-folding pairs like k/K/U+212A), escapes (\\x41, \\x{263a},
octal, \\Q...\\E), classes (ranges, negation, POSIX [[:alpha:]], Perl \\d\\w\\s,
Unicode \\pL \\p{Greek} \\P{Lu} \\p{^N}), ., anchors (^ $ \\A \\z \\b \\B),
groups (capturing, (?:), (?P<name>), (?<name>), flags (?i) (?s) (?m) (?U)
and their negations, scoped and not), alternation, every repetition form
(greedy and lazy, counted), and mutations that make errors (unbalanced
parentheses and brackets, bad escapes and ranges, nested and too-large
repetitions, invalid UTF-8, \\C). Inputs mix the pattern's own characters
with newlines, multi-byte runes, case variants and invalid UTF-8 (stray
continuation bytes, truncated sequences, overlong forms, surrogates); some
are made long (past the backtracker's limit) so that the Pike VM runs, and
some patterns are made large for the same reason.

With --engines the cases are also run with each matcher forced
(regexp::debug_engine: the Pike VM, the backtracker, the one-pass
matcher) and compared with Go, which checks each matcher against Go's
choice of matcher.

    python3 scripts/regexp_differential.py [--seed N] [--count N] [--engines] [-v]

Exit status 1 if any case differs.
"""

import argparse
import os
import random
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))

FIELDS = ["status", "NumSubexp", "SubexpNames", "LiteralPrefix", "prefix complete", "String", "Simplify().String",
          "Prog.String", "MatchString", "FindStringIndex", "FindStringSubmatchIndex", "FindAllStringSubmatchIndex",
          "FindAllStringIndex(2)", "ReplaceAllString", "ReplaceAllLiteralString", "Split(-1)", "Split(2)"]

LITERALS = ["a", "b", "c", "x", "y", "z", "A", "B", "0", "1", "_", " ", "-", ",", "é", "É", "ß", "k", "K", "\u212a",
            "s", "S", "\u017f", "☺", "日", "本", "\U0001F600", "Σ", "σ", "ς", "\n", "\t", ".", "\\.", "\\*", "\\(",
            "\\)", "\\[", "\\]", "\\{", "\\}", "\\|", "\\\\", "\\^", "\\$", "\\+", "\\?", "\\-", "\\_", "\\!",
            "\\x41", "\\x{263a}", "\\x{1F600}", "\\x{10FFFF}", "\\x{FFFD}", "\\101", "\\0", "\\a", "\\f", "\\n",
            "\\r", "\\t", "\\v", "{", "}", "]", "\\Qa.b\\E", "\\Q\\E", "\\Q*\\E"]
CLASSES = ["[abc]", "[^abc]", "[a-c]", "[^a-c]", "[a-zA-Z]", "[0-9]", "[^\\n]", "[\\d]", "[\\w-]", "[a-]", "[]a]",
           "[^]a]", "[-a]", "[[:alpha:]]", "[[:^alpha:]]", "[[:digit:][:space:]]", "[[:upper:]]", "[[:lower:]]",
           "[[:word:]]", "[[:punct:]]", "[\\pL]", "[\\p{Greek}a]", "[^\\PL]", "[é-ü]", "[☺-☻]", "[\\x00-\\x{10FFFF}]",
           "[^\\x00-\\x{10FFFF}]", "[kK]", "[Kk\u212a]", "[ſs]", "\\d", "\\D", "\\w", "\\W", "\\s", "\\S", "\\pL", "\\PL",
           "\\pN", "\\p{Lu}", "\\p{Ll}", "\\p{Greek}", "\\p{greek}", "\\p{^Greek}", "\\P{^Greek}", "\\p{Han}",
           "\\pZ", "\\p{Any}", "\\p{Assigned}", "\\p{ASCII}", "\\p{Letter}", "\\p{Cased_Letter}", "\\p{Lc}",
           "\\p{Latin}", "\\p{Common}", ".", "[.]", "[\\Q]\\E]"]
ANCHORS = ["^", "$", "\\A", "\\z", "\\b", "\\B"]
FLAGS = ["i", "s", "m", "U", "is", "im", "-i", "-s", "-m", "i-s", "s-i", "imsU", "-imsU"]
REPEATS = ["*", "+", "?", "*?", "+?", "??", "{2}", "{0}", "{1}", "{0,}", "{1,}", "{2,}", "{0,1}", "{1,2}",
           "{2,3}", "{0,2}?", "{2,}?", "{3}", "{1,3}", "{,2}", "{2", "{x}"]
NAMES = ["n", "name", "x1", "_", "a_b"]
ERRORS = ["(", ")", "[", "]", "*", "+", "?", "{2,1}", "{1001}", "{1000,}", "**", "*+", "\\", "\\C", "\\8",
          "\\xZ", "\\x{110000}", "\\x{}", "\\p{Bogus}", "\\pX", "[z-a]", "[[:bogus:]]", "(?P<>x)", "(?P<x y>x)",
          "(?P<n", "(?<n", "(?x)", "(?i", "(?-)", "(?i-)", "\xff", "\xc3", "\xed\xa0\x80", "[\xff]", "\\\xff",
          "(?P<\xff>x)", "\\p{\xff}", "x{2}{3}", "(?:", "a|*", "[a", "[^", "\\Q\xff\\E"]
INPUT_EXTRA = ["a", "b", "c", "x", "\n", " ", "é", "É", "k", "K", "\u212a", "ſ", "s", "S", "☺", "日", "Σ", "σ", "ς",
               "0", "1", "_", "-", ".", "\U0001F600"]
INPUT_BYTES = [b"\xff", b"\x80", b"\xc3", b"\xe2\x98", b"\xc0\x80", b"\xed\xa0\x80", b"\xf4\x90\x80\x80",
               b"\xef\xbf\xbd", b"\x00", b"\xf0\x9f\x98"]
REPLS = ["", "x", "$0", "$1", "${1}", "$2", "${name}", "$name", "<$1>", "$$", "$", "$1x", "${1}x", "$x", "${",
         "${}", "$01", "$10", "$9", "${n}${x1}", "[$0]", "é$1é", "$\xff"]


def gen_pattern(r, depth=0, posix=False):
    """A random pattern, as bytes; in POSIX's syntax if posix."""
    if depth > 3 or r.random() < 0.3:
        return gen_atom(r, depth, posix).encode("utf-8", "surrogateescape")
    k = r.random()
    if k < 0.35:
        return b"".join(gen_pattern(r, depth + 1, posix) for _ in range(r.randint(2, 4)))
    if k < 0.55:
        return b"|".join(gen_pattern(r, depth + 1, posix) for _ in range(r.randint(2, 4)))
    if k < 0.75:
        return group(r, gen_pattern(r, depth + 1, posix), posix)
    sub = gen_pattern(r, depth + 1, posix)
    if (len(sub) > 1 and r.random() < 0.6) or (sub[-1:] in (b"*", b"+", b"?", b"}") and r.random() < 0.9):
        sub = group(r, sub, posix)
    rep = r.choice(REPEATS)
    if posix:
        rep = rep.rstrip("?") or "?"
    return sub + rep.encode()


POSIX_LITERALS = [l for l in LITERALS if not l.startswith("\\Q") and l not in ("\\_", "\\x{263a}", "\\x{1F600}",
                                                                             "\\x{10FFFF}", "\\x{FFFD}")]
POSIX_CLASSES = [c for c in CLASSES if "\\p" not in c and "\\P" not in c and "\\d" not in c and "\\w" not in c
                 and "\\D" not in c and "\\W" not in c and "\\s" not in c and "\\S" not in c and "\\Q" not in c
                 and c not in ("[\\x00-\\x{10FFFF}]", "[^\\x00-\\x{10FFFF}]", "[a-]", "[-a]")]


def group(r, inner, posix=False):
    if posix:
        return b"(" + inner + b")"
    k = r.random()
    if k < 0.4:
        return b"(" + inner + b")"
    if k < 0.6:
        return b"(?:" + inner + b")"
    if k < 0.7:
        return b"(?P<" + r.choice(NAMES).encode() + b">" + inner + b")"
    if k < 0.75:
        return b"(?<" + r.choice(NAMES).encode() + b">" + inner + b")"
    if k < 0.9:
        return b"(?" + r.choice(FLAGS).encode() + b":" + inner + b")"
    return b"(?" + r.choice(FLAGS).encode() + b")" + inner


def gen_atom(r, depth, posix=False):
    k = r.random()
    if k < 0.5:
        return r.choice(POSIX_LITERALS if posix else LITERALS)
    if k < 0.8:
        return r.choice(POSIX_CLASSES if posix else CLASSES)
    return r.choice(ANCHORS[:2] if posix else ANCHORS)


def mutate(r, p):
    """Sometimes, make an error or an oddity somewhere in the pattern."""
    if r.random() < 0.12:
        e = r.choice(ERRORS).encode("latin-1")
        i = r.randint(0, len(p))
        return p[:i] + e + p[i:]
    if r.random() < 0.03 and len(p) > 0:
        i = r.randint(0, len(p) - 1)
        return p[:i] + p[i + 1:]
    return p


def literal_chars(p):
    """Characters of the pattern that could appear in an input."""
    s = p.decode("utf-8", "replace")
    return [c for c in s if c not in "\\()[]{}|*+?^$" and c != "\ufffd"]


def gen_input(r, p, long):
    chars = literal_chars(p) or ["a"]
    parts = []
    n = r.randint(0, 12)
    for _ in range(n):
        k = r.random()
        if k < 0.55:
            parts.append(r.choice(chars).encode("utf-8"))
        elif k < 0.9:
            parts.append(r.choice(INPUT_EXTRA).encode("utf-8"))
        else:
            parts.append(r.choice(INPUT_BYTES))
    s = b"".join(parts)
    if long:
        # Past the backtracker's limit (256K bits / the program's length).
        while len(s) < 20000:
            s += s + r.choice(INPUT_EXTRA).encode("utf-8")
    return s


def big_pattern(r, posix):
    """A pattern whose program is over 500 instructions, for the Pike VM."""
    if posix:
        return b"(" + gen_pattern(r, 0, True) + b"){60}|" + gen_pattern(r, 0, True) + b"x{200}"
    return b"(?:" + gen_pattern(r) + b"){60}|" + gen_pattern(r) + b"x{200}"


def hx(b):
    return b.hex() if b else "="


def gen_cases(r, count):
    lines = []
    for _ in range(count):
        mode = r.choices(["perl", "posix", "longest"], [6, 2, 2])[0]
        posix = mode == "posix"
        if r.random() < 0.05:
            p = big_pattern(r, posix)
        else:
            p = mutate(r, gen_pattern(r, 0, posix))
        long = r.random() < 0.05
        inp = gen_input(r, p, long)
        repl = r.choice(REPLS).encode("utf-8", "surrogateescape")
        lines.append("%s %s %s %s" % (mode, hx(p), hx(inp), hx(repl)))
    return lines


def find_goose(arg):
    for cand in [arg, os.environ.get("GOOSE"), shutil.which("goose"),
                 os.path.join(ROOT, "..", "goose.git", "build", "goose")]:
        if cand and os.path.isfile(cand):
            return cand
    sys.exit("no goose compiler found: pass --goose or set GOOSE")


def unhex(f):
    return b"" if f == "=" else bytes.fromhex(f)


def describe(case, field, got, want):
    mode, p, inp, repl = case.split(" ")
    return "%s /%r/ on %r (repl %r): %s: goose %s, go %s" % (
        mode, unhex(p)[:80], unhex(inp)[:60], unhex(repl), field, got[:120], want[:120])


def split_fields(line):
    """The output line's fields, the string lists kept together."""
    f = line.split(" ")
    if f[0] == "err":
        return f
    out = [f[0], f[1]]
    i = 2
    n = int(f[i])
    out.append(" ".join(f[i:i + 1 + n]))
    i += 1 + n
    out.extend(f[i:i + 13])
    i += 13
    for _ in range(2):
        n = int(f[i])
        out.append(" ".join(f[i:i + 1 + n]))
        i += 1 + n
    return out


def compare(cases, mine, theirs, label, verbose, classes):
    diffs = 0
    for case, a, b in zip(cases, mine, theirs):
        if a == b:
            continue
        diffs += 1
        fa, fb = split_fields(a), split_fields(b)
        field = "status"
        if fa[0] == fb[0] == "ok":
            for name, x, y in zip(FIELDS, fa, fb):
                if x != y:
                    field = name
                    break
        elif fa[0] == fb[0] == "err":
            field = "error code" if fa[1] != fb[1] else "error expr"
        classes[(label, field)] = classes.get((label, field), 0) + 1
        if verbose or classes[(label, field)] <= 3:
            print("DIFF [%s] %s" % (label, describe(case, field, a, b)))
    return diffs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--goose")
    ap.add_argument("--go", default=shutil.which("go") or "go")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=20000)
    ap.add_argument("--engines", action="store_true", help="also run each matcher forced")
    ap.add_argument("-v", action="store_true")
    args = ap.parse_args()
    goose = find_goose(args.goose)
    r = random.Random(args.seed)
    cases = gen_cases(r, args.count)
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "cases.txt")
        with open(path, "w") as f:
            f.write("\n".join(cases) + "\n")
        oracle = os.path.join(tmp, "regexporacle")
        subprocess.run([args.go, "build", "-o", oracle, "."], cwd=os.path.join(ROOT, "tools", "regexporacle"),
                       check=True, env=dict(os.environ, GOPROXY="off"))
        verdict = os.path.join(tmp, "regexpverdict")
        p = subprocess.run([goose, "build", "-o", verdict, "regexpverdict.goose"], cwd=os.path.join(ROOT, "tools"),
                           capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit("goose build failed:\n" + p.stdout + p.stderr)
        theirs = subprocess.run([oracle, "-cases", path], capture_output=True, check=True).stdout.decode().splitlines()
        runs = [("go's choice", "0")]
        if args.engines:
            runs += [("Pike VM", "1"), ("backtracker", "2"), ("one-pass", "3")]
        classes = {}
        total = 0
        for label, engine in runs:
            out = subprocess.run([verdict, path, engine], capture_output=True)
            if out.returncode != 0:
                sys.exit("regexpverdict failed (%s):\n%s" % (label, out.stderr.decode(errors="replace")))
            mine = out.stdout.decode().splitlines()
            if len(mine) != len(cases) or len(theirs) != len(cases):
                sys.exit("output lengths differ: %d cases, %d from goose, %d from go" % (len(cases), len(mine), len(theirs)))
            d = compare(cases, mine, theirs, label, args.v, classes)
            print("%s: %d cases, %d differ" % (label, len(cases), d))
            total += d
        errs = sum(1 for t in theirs if t.startswith("err"))
        print("(%d of the cases are expressions Go refuses)" % errs)
        for (label, field), n in sorted(classes.items()):
            print("  %s / %s: %d" % (label, field, n))
        sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
