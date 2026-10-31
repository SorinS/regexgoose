// regexp.syntax against Go's own tests: the tables of
// $GOROOT/src/regexp/syntax/{parse,simplify,prog}_test.go
// (test/vectors/go_syntax.txt, from scripts/gen_go_vectors.py), run as Go
// runs them, and more: every parse's String() against Go's, and every
// invalid expression's error code and text in both Perl and POSIX mode.
// Then the Unicode lookups against tools/gentables's vectors.

import std;
import regexp from "..";
import regexp.syntax;
import lib.check;

let TEST_FLAGS = 4 | 8 | 64 | 128;     // MatchNL | PerlX | UnicodeGroups

let DUMP_NAMES = ["", "no", "emp", "lit", "cc", "dnl", "dot", "bol", "eol", "bot", "eot", "wb", "nwb", "cap", "star",
                  "plus", "que", "rep", "cat", "alt"];

fn hex_lower(b: u8[>..]&, v: i64) {
    b.append("0x");
    var digits = 1;
    while digits < 16 && (v >> (digits * 4)) != 0 { digits++; }
    var s = (digits - 1) * 4;
    while s >= 0 {
        b.push("0123456789abcdef"[(v >> s) & 15]);
        s -= 4;
    }
}

// parse_test.go's dumpRegexp.
recursive fn dump_node(b: u8[>..]&, v: syntax::View, n: i64) {
    let nd = v.nodes[n];
    let op = nd.op as i64;
    if op >= DUMP_NAMES.len || DUMP_NAMES[op] == "" {
        format(b, "op", op);
    } else if op == syntax::OP_STAR || op == syntax::OP_PLUS || op == syntax::OP_QUEST || op == syntax::OP_REPEAT {
        if nd.flags & syntax::NON_GREEDY != 0 { b.push('n'); }
        b.append(DUMP_NAMES[op]);
    } else if op == syntax::OP_LITERAL {
        if nd.nrune > 1 { b.append("str"); } else { b.append("lit"); }
        if nd.flags & syntax::FOLD_CASE != 0 {
            for r in syntax::runes(v, n) {
                if syntax::simple_fold(r) != r {
                    b.append("fold");
                    break;
                }
            }
        }
    } else {
        b.append(DUMP_NAMES[op]);
    }
    b.push('{');
    if op == syntax::OP_END_TEXT {
        if nd.flags & syntax::WAS_DOLLAR == 0 { b.append("\\z"); }
    } else if op == syntax::OP_LITERAL {
        for r in syntax::runes(v, n) { syntax::append_rune(b, r); }
    } else if op == syntax::OP_CONCAT || op == syntax::OP_ALTERNATE {
        for i in nd.nsub as i64 { dump_node(b, v, syntax::sub(v, n, i)); }
    } else if op == syntax::OP_STAR || op == syntax::OP_PLUS || op == syntax::OP_QUEST {
        dump_node(b, v, syntax::sub(v, n, 0));
    } else if op == syntax::OP_REPEAT {
        format(b, nd.min, ",", nd.max, " ");
        dump_node(b, v, syntax::sub(v, n, 0));
    } else if op == syntax::OP_CAPTURE {
        if nd.name_len > 0 {
            b.append(syntax::name(v, n));
            b.push(':');
        }
        dump_node(b, v, syntax::sub(v, n, 0));
    } else if op == syntax::OP_CHAR_CLASS {
        let rs = syntax::runes(v, n);
        var i = 0;
        while i + 1 < rs.len {
            if i > 0 { b.push(' '); }
            hex_lower(b, rs[i]);
            if rs[i] != rs[i + 1] {
                b.push('-');
                hex_lower(b, rs[i + 1]);
            }
            i += 2;
        }
    }
    b.push('}');
}

fn dump(re: syntax::Regexp&) -> u8[>..] {
    var b: u8[>..] = [];
    dump_node(b, syntax::view(re), re.root);
    return b;
}

// parse lines: the table, flags, expression, Go's dump ("" to check only
// that it parses) and Go's String() of the parse.
fn parse_case(table: const u8[:], flags: i64, s: const u8[:], want_dump: const u8[:], want_string: const u8[:]) {
    let what = str(table, " ", s);
    let re, err = syntax::parse(s, flags);
    if err.code != 0 {
        fail_msg(what, str("parse error: ", err));
        return;
    }
    checks++;
    let d = dump(re);
    if want_dump.len > 0 { check_str(str(what, " dump"), d, want_dump); }
    let st = syntax::string(re);
    check_str(str(what, " String"), st, want_string);
    // TestToStringEquivalentParse: a String() that is not the expression
    // must parse to the same tree and print the same again.
    if table == "parseTests" && want_dump.len > 0 && st != s {
        let nre, nerr = syntax::parse(st, flags);
        if nerr.code != 0 {
            fail_msg(what, str("reparse of ", st, ": ", nerr));
            return;
        }
        check_str(str(what, " reparse dump"), dump(nre), d);
        check_str(str(what, " reparse String"), syntax::string(nre), st);
    }
}

fn error_case(what: const u8[:], s: const u8[:], flags: i64, ok: const u8[:], code: const u8[:], expr: const u8[:]) {
    let re, err = syntax::parse(s, flags);
    if ok == "ok" {
        if err.code != 0 { fail_msg(what, str("got ", err, ", want success")); } else { checks++; }
        return;
    }
    if err.code == 0 {
        fail_msg(what, "parsed, want an error");
        return;
    }
    check_str(str(what, " code"), syntax::error_code_string(err.code), code);
    check_str(str(what, " expr"), err.expr, expr);
}

fn go_vectors() {
    let data = embed_file("vectors/go_syntax.txt");
    var n = 0;
    each_split(data, '\n') {
        guard it.len > 0 && it[0] != '#';
        let f = split(it, ' ');
        let kind = f[0];
        n++;
        if kind == "parse" {
            parse_case(f[1], int_field(f[2]), unhex(f[3]), unhex(f[4]), unhex(f[5]));
        } else if kind == "invalid" {
            let s = unhex(f[2]);
            let pre = str(f[1], " ");
            error_case(str(pre, s, " (Perl)"), s, syntax::PERL, f[3], unhex(f[4]), unhex(f[5]));
            error_case(str(pre, s, " (POSIX)"), s, syntax::POSIX, f[6], unhex(f[7]), unhex(f[8]));
        } else if kind == "string" {
            let s = unhex(f[1]);
            let re, err = syntax::parse(s, syntax::PERL);
            if err.code != 0 { fail_msg(str("stringTests ", s), str(err)); } else {
                check_str(str("stringTests ", s), syntax::string(re), unhex(f[2]));
            }
        } else if kind == "simplify" {
            let s = unhex(f[1]);
            let re, err = syntax::parse(s, syntax::MATCH_NL | (syntax::PERL & ~syntax::ONE_LINE));
            if err.code != 0 { fail_msg(str("simplifyTests ", s), str(err)); } else {
                let simp = syntax::simplify(re);
                check_str(str("simplifyTests ", s), syntax::string(simp), unhex(f[2]));
            }
        } else if kind == "compile" {
            let s = unhex(f[1]);
            let re, err = syntax::parse(s, syntax::PERL);
            if err.code != 0 { fail_msg(str("compileTests ", s), str(err)); } else {
                let prog = syntax::compile(re);
                check_str(str("compileTests ", s), syntax::string(prog), unhex(f[2]));
            }
        } else {
            fail_msg("go_syntax.txt", str("unknown line kind ", kind));
        }
    };
    print("go_syntax.txt: ", n, " cases");
}

// tools/gentables's vectors: \p{name} membership at every table's
// boundaries, SimpleFold, IsPrint, IsLetter, IsDigit.
fn unicode_vectors() {
    let data = embed_file("vectors/unicode.txt");
    var n = 0;
    var bad = 0;
    each_split(data, '\n') {
        guard it.len > 0 && it[0] != '#';
        let f = split(it, ' ');
        n++;
        if f[0] == "N" {
            let tab, fold, sign = syntax::unicode_table(f[1]);
            let r = int_field(f[2]);
            let inside = syntax::in_pairs(r, syntax::table_pairs(tab)) == (sign > 0);
            if tab < 0 || inside != (f[3] == "1") {
                bad++;
                fail_msg(str("unicode \\p{", f[1], "}"), str("rune ", r, " in: ", inside));
            }
        } else if f[0] == "F" {
            let r = int_field(f[1]);
            if syntax::simple_fold(r) != int_field(f[2]) {
                bad++;
                fail_msg("SimpleFold", str(r, " -> ", syntax::simple_fold(r), ", want ", f[2]));
            }
        } else if f[0] == "P" {
            let r = int_field(f[1]);
            if syntax::is_print(r) != (f[2] == "1") || syntax::is_letter(r) != (f[3] == "1") ||
               syntax::is_digit(r) != (f[4] == "1") {
                bad++;
                fail_msg("IsPrint/IsLetter/IsDigit", str(r));
            }
        }
    };
    checks += n;
    print("unicode.txt: ", n, " cases, ", bad, " wrong");
}

// TestAppendRangeCollapse: append_range looks back two ranges, so that
// interlaced A-Z and a-z give two ranges.
fn append_range_collapse() {
    var r: i64[>..<] = [];
    for i in 'A'..'Z' + 1 {
        syntax::append_range(r, i, i);
        syntax::append_range(r, i + 32, i + 32);
    }
    checks++;
    if r.len != 4 || r[0] != 'A' || r[1] != 'Z' || r[2] != 'a' || r[3] != 'z' { fail_msg("appendRange", str(r)); }
}

// Errors print as Go's do.
fn error_text() {
    let re, err = syntax::parse("a(b", syntax::PERL);
    check_str("Error.Error", str(err), "error parsing regexp: missing closing ): `a(b`");
    let re2, err2 = syntax::parse("a\\", syntax::PERL);
    check_str("trailing backslash", str(err2), "error parsing regexp: trailing backslash at end of expression: ``");
}

fn main() {
    go_vectors();
    unicode_vectors();
    append_range_collapse();
    error_text();
    summary("syntax");
}
