// regexpverdict prints what this package makes of each case of a cases
// file, in tools/regexporacle's format (see there), for
// scripts/regexp_differential.py.
//
//   goose tools/regexpverdict.goose -- CASES [ENGINE]
//
// ENGINE (default 0) is regexp::debug_engine: 0 chooses the matcher as Go
// does, 1 always the Pike VM, 2 the backtracker wherever the program is
// small enough, 3 the one-pass matcher wherever there is a one-pass program.

import std;
import os;
import regexp from "..";
import regexp.syntax;

fn hex_digit(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    return -1;
}

fn unh(f: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    if f == "=" { return out; }
    var i = 0;
    while i + 1 < f.len {
        out.push((hex_digit(f[i]) * 16 + hex_digit(f[i + 1])) as u8);
        i += 2;
    }
    return out;
}

fn h(out: u8[>..]&, s: const u8[:]) {
    if s.len == 0 {
        out.push('=');
        return;
    }
    for c in s {
        out.push("0123456789abcdef"[c >> 4]);
        out.push("0123456789abcdef"[c & 15]);
    }
}

// A list of integers: "-" for none (Go's nil), else comma-separated.
fn ints(out: u8[>..]&, xs: const i64[:], has: bool) {
    if !has {
        out.push('-');
        return;
    }
    if xs.len == 0 {
        out.push('=');
        return;
    }
    for x, i in xs {
        if i > 0 { out.push(','); }
        format(out, x);
    }
}

fn strs(out: u8[>..]&, xs: const u8[:][:]) {
    format(out, xs.len);
    for x in xs {
        out.push(' ');
        h(out, x);
    }
}

fn run(out: u8[>..]&, mode: const u8[:], pat: const u8[:], input: const u8[:], repl: const u8[:]) {
    let posix = mode == "posix";
    let flags = if posix { syntax::POSIX } else { syntax::PERL };
    let re, err = regexp::compile_mode(pat, flags, posix);
    if err.code != 0 {
        out.append("err ");
        h(out, syntax::error_code_string(err.code));
        out.push(' ');
        h(out, err.expr);
        return;
    }
    if mode == "longest" { re.leftmost_longest = true; }
    let tree, terr = syntax::parse(pat, flags);
    let simple = syntax::simplify(tree);
    let prog = syntax::compile(simple);
    let prefix, complete = re.literal_prefix();
    out.append("ok ");
    format(out, re.num_subexp());
    out.push(' ');
    strs(out, re.subexp_names());
    out.push(' ');
    h(out, prefix);
    out.append(if complete { " 1 " } else { " 0 " });
    h(out, syntax::string(tree));
    out.push(' ');
    h(out, syntax::string(simple));
    out.push(' ');
    h(out, syntax::string(prog));
    out.append(if re.match_string(input) { " 1 " } else { " 0 " });
    let a, b = re.find_string_index(input);
    var loc: i64[2] = [a, b];
    ints(out, loc, a >= 0);
    out.push(' ');
    let sm = re.find_string_submatch_index(input);
    ints(out, sm, sm.len > 0);
    out.push(' ');
    let all = re.find_all_string_submatch_index(input, -1);
    ints(out, all, all.len > 0);
    out.push(' ');
    let two = re.find_all_string_index(input, 2);
    ints(out, two, two.len > 0);
    out.push(' ');
    h(out, re.replace_all_string(input, repl));
    out.push(' ');
    h(out, re.replace_all_literal_string(input, repl));
    out.push(' ');
    strs(out, re.split(input, -1));
    out.push(' ');
    strs(out, re.split(input, 2));
}

fn main() {
    if arg_count() < 2 {
        print("usage: regexpverdict CASES [ENGINE]");
        exit(2);
    }
    var path: u8[>..] = [];
    arg(1, path);
    if arg_count() > 2 {
        var e: u8[>..] = [];
        arg(2, e);
        let v, ok = parse_int(e);
        regexp::debug_engine = v;
    }
    var data: u8[>..] = [];
    if !read_file(path, data) {
        print("regexpverdict: cannot read ", path);
        exit(1);
    }
    var out: u8[>..] = [];
    for line in split(data, '\n') {
        if line.len == 0 { continue; }
        let f = split(line, ' ');
        run(out, f[0], unh(f[1]), unh(f[2]), unh(f[3]));
        out.push('\n');
        if out.len > 1 << 20 {
            write_stdout(out);
            out.clear();
        }
    }
    write_stdout(out);
}
