// Go's TestFowler: Glenn Fowler's AT&T POSIX tests (basic.dat,
// nullsubexpr.dat, repetition.dat from $GOROOT/src/regexp/testdata,
// copied by scripts/gen_go_vectors.py), run exactly as exec_test.go runs
// them: E (extended) and L (literal) tests in POSIX mode with ClassNL and
// leftmost-longest matching, i for case folding; NIL lines, control lines
// and the other modes (B, A, S, K) skipped as Go skips them.

import std;
import regexp from "..";
import regexp.syntax;
import lib.check;

// parseFowlerResult: ok, whether the expression compiles, whether it
// matches, and the positions expected (-1 for ?).
fn parse_fowler_result(s0: const u8[:], pos: i64[>..]&) -> bool, bool, bool {
    if s0.len == 0 { return true, true, true; }             // match with no position information
    if s0 == "NOMATCH" { return true, true, false; }       // match failure
    if s0[0] >= 'A' && s0[0] <= 'Z' { return true, false, false; }   // the other codes are compile errors
    var s = s0;
    while s.len > 0 {
        var end: u8 = ')';
        if pos.len % 2 == 0 {
            if s[0] != '(' { return false, true, false; }
            s = s[1..];
            end = ',';
        }
        var i = 0;
        while i < s.len && s[i] != end { i++; }
        if i == 0 || i == s.len { return false, true, false; }
        var v = -1;
        if s[..i] != "?" {
            let n, ok = parse_int(s[..i]);
            if !ok { return false, true, false; }
            v = n;
        }
        pos.push(v);
        s = s[i + 1..];
    }
    if pos.len % 2 != 0 { return false, true, false; }
    return true, true, true;
}

fn run_case(file: const u8[:], lineno: i64, flag: const u8[:], pattern0: const u8[:], text: const u8[:],
            should_compile: bool, should_match: bool, pos: const i64[:], ran: i64[:]) {
    for c in flag {
        if c != 'E' && c != 'L' { continue; }
        var pattern: u8[>..] = [];
        if c == 'L' { pattern.append(regexp::quote_meta(pattern0)); } else { pattern.append(pattern0); }
        var syn = syntax::POSIX | syntax::CLASS_NL;
        for c2 in flag { if c2 == 'i' { syn |= syntax::FOLD_CASE; } }
        let what = str(file, ":", lineno, ": /", pattern, "/ on \"", text, "\"");
        let re, err = regexp::compile_mode(pattern, syn, true);
        ran[0]++;
        checks++;
        if err.code != 0 {
            if should_compile { fail_msg(what, str("did not compile: ", err)); }
            continue;
        }
        if !should_compile {
            fail_msg(what, "should not compile");
            continue;
        }
        let m = re.match_string(text);
        checks++;
        if m != should_match {
            fail_msg(what, str("Match = ", m, ", want ", should_match));
            continue;
        }
        let have = re.find_string_submatch_index(text);
        checks++;
        if (have.len > 0) != m {
            fail_msg(what, str("Match = ", m, " but FindSubmatchIndex = ", have));
            continue;
        }
        let cut = have[..min(have.len, pos.len)];
        checks++;
        if cut != pos { fail_msg(what, str("FindSubmatchIndex = ", cut, ", want ", pos)); }
    }
}

fn run_file(file: const u8[:], data: const u8[:]) -> i64, i64 {
    let notab = regexp::must_compile_posix("[^\t]+");
    var last_regexp: u8[>..] = [];
    var lineno = 0;
    var skipped = 0;
    var ran: i64[1] = [0];
    for line in split(data, '\n') {
        lineno++;
        if line.len == 0 || line[0] == '#' { continue; }
        let fields0 = notab.find_all_string(line, -1);
        if fields0.len == 0 { continue; }
        var nil_field = false;
        for f in fields0 { if f == "NIL" { nil_field = true; } }
        if nil_field {
            skipped++;
            continue;
        }
        var flag = fields0[0];
        let c0 = flag[0];
        if c0 == '?' || c0 == '&' || c0 == '|' || c0 == ';' || c0 == '{' || c0 == '}' {
            // Ignore all the control operators. Just run everything.
            flag = flag[1..];
            if flag.len == 0 { continue; }
        } else if c0 == ':' {
            let k = find(flag[1..], ":");
            if k < 0 {
                skipped++;
                continue;
            }
            flag = flag[1 + k + 1..];
        } else if c0 == 'C' || c0 == 'N' || c0 == 'T' || (c0 >= '0' && c0 <= '9') {
            skipped++;
            continue;
        }
        if fields0.len < 4 {
            fail_msg(str(file, ":", lineno), "too few fields");
            continue;
        }
        var f1: u8[>..] = [];
        var f2: u8[>..] = [];
        f1.append(if fields0[1] == "NULL" { "" } else { fields0[1] });
        f2.append(if fields0[2] == "NULL" { "" } else { fields0[2] });
        let f3 = if fields0[3] == "NULL" { "" } else { fields0[3] };
        // Expand C escapes (a.k.a. Go escapes).
        if find(flag, "$") >= 0 {
            let u1, ok1 = go_unquote(str("\"", f1, "\""));
            let u2, ok2 = go_unquote(str("\"", f2, "\""));
            if !ok1 || !ok2 { fail_msg(str(file, ":", lineno), "cannot unquote"); }
            f1.clear();
            f1.append(u1);
            f2.clear();
            f2.append(u2);
        }
        // Field 2: the regular expression pattern; SAME uses the pattern
        // from the previous specification.
        if f1 == "SAME" {
            f1.clear();
            f1.append(last_regexp);
        }
        last_regexp.clear();
        last_regexp.append(f1);
        var pos: i64[>..] = [];
        let ok, should_compile, should_match = parse_fowler_result(f3, pos);
        if !ok {
            fail_msg(str(file, ":", lineno), str("cannot parse result ", f3));
            continue;
        }
        run_case(file, lineno, flag, f1, f2, should_compile, should_match, pos, ran);
    }
    return ran[0], skipped;
}

fn main() {
    var total = 0;
    for name in ["basic.dat", "nullsubexpr.dat", "repetition.dat"] {
        let data = if name == "basic.dat" { embed_file("vectors/basic.dat") }
                   else if name == "nullsubexpr.dat" { embed_file("vectors/nullsubexpr.dat") }
                   else { embed_file("vectors/repetition.dat") };
        let ran, skipped = run_file(name, data);
        print(name, ": ", ran, " tests run, ", skipped, " lines skipped as Go skips them");
        total += ran;
    }
    summary("fowler");
}
