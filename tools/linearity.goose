// linearity times a pathological pattern on inputs of growing length, for
// scripts/linearity.py: one line per size, "n seconds".
//
//   goose build tools/linearity.goose && tools/linearity CASE N1 N2 ...
//
// CASE is star (/(a*)*b/ on a^n), nested (/(a|aa)*c/ on a^n), alt
// (/(x+x+)+y/ on x^n), quest (/a?^n a^n/ on a^n: the program grows with n
// too), or findall (/a*b|a/ found all over (aaab)^(n/4)); the Pike VM,
// the backtracker and the one-pass matcher are each timed by forcing
// (engine argument E before the sizes: "E=1").

import std;
import os;
import regexp from "..";

fn main() {
    var kind: u8[>..] = [];
    arg(1, kind);
    var engine = 0;
    var first = 2;
    var a2: u8[>..] = [];
    arg(2, a2);
    if starts_with(a2, "E=") {
        let v, ok = parse_int(a2[2..]);
        engine = v;
        first = 3;
    }
    regexp::debug_engine = engine;
    for k in first..arg_count() {
        var a: u8[>..] = [];
        arg(k, a);
        let n, ok = parse_int(a);
        var pat: u8[>..] = [];
        var text: u8[>..] = [];
        if kind == "star" {
            pat.append("(a*)*b");
            text.push_n('a', n);
        } else if kind == "nested" {
            pat.append("(a|aa)*c");
            text.push_n('a', n);
        } else if kind == "alt" {
            pat.append("(x+x+)+y");
            text.push_n('x', n);
        } else if kind == "quest" {
            for i in n { pat.append("a?"); }
            for i in n { pat.push('a'); }
            text.push_n('a', n);
        } else {
            pat.append("a*b|a");
            for i in n / 4 { text.append("aaab"); }
        }
        let re = regexp::must_compile(pat);
        let t0 = clock();
        var found = 0;
        if kind == "findall" {
            found = re.find_all_index(text, -1).len / 2;
        } else {
            let m = re.find_submatch_index(text);
            found = if m.len > 0 { 1 } else { 0 };
        }
        let t = clock() - t0;
        print(n, " ", t, " ", found);
    }
}
