// The API's own conventions, which Go's tests cannot check: results as
// views into the input, (-1, -1) and false for no match, empty views for
// subexpressions that took no part (the index forms keep -1), invalid
// UTF-8 read as U+FFFD of width 1, a failed compile giving a Regexp that
// matches nothing, copies independent of the original, and each_match.

import std;
import regexp from "..";
import regexp.syntax;
import lib.check;

fn views() {
    let text = "say hello, hello again";
    let re = regexp::must_compile("h(el)lo");
    let all = re.find_all(text, -1);
    check_int("find_all count", all.len, 2);
    // The views are into text itself, not copies.
    check_bool("find_all view", &all[1][0] .== &text[11], true);
    let f, ok = re.find(text);
    check_bool("find found", ok, true);
    check_bool("find view", &f[0] .== &text[4], true);
    let none, nok = re.find("nothing");
    check_bool("find none", nok, false);
    check_int("find none len", none.len, 0);
    let a, b = re.find_index("nothing");
    check_int("find_index none", a, -1);
    check_int("find_index none end", b, -1);
    check_int("find_submatch_index none", re.find_submatch_index("nothing").len, 0);
    check_int("find_submatch none", re.find_submatch("nothing").len, 0);
    check_int("find_all none", re.find_all("nothing", -1).len, 0);
}

fn unmatched_groups() {
    let re = regexp::must_compile("(a)|(b)");
    let m = re.find_submatch_index("b");
    check_str("index keeps -1", str(m), "[0, 1, -1, -1, 0, 1]");
    let s = re.find_submatch("b");
    check_int("submatch count", s.len, 3);
    check_int("unmatched is empty", s[1].len, 0);
    check_str("matched", s[2], "b");
    let all = re.find_all_submatch_index("ab", -1);
    check_str("all submatch index", str(all), "[0, 1, 0, 1, -1, -1, 1, 2, -1, -1, 1, 2]");
    check_str("subexp_name", re.subexp_name(0), "");
    let named = regexp::must_compile("(?P<first>a)(?<second>b)?");
    check_str("subexp_names", str(named.subexp_names()), "[\"\", \"first\", \"second\"]");
    check_int("subexp_index", named.subexp_index("second"), 2);
    check_int("subexp_index missing", named.subexp_index("third"), -1);
}

fn utf8_input() {
    // An invalid byte is a rune of its own, U+FFFD, one byte wide.
    let dot = regexp::must_compile(".");
    check_str("dot over invalid", str(dot.find_all_index("\xffa\xc3", -1)), "[0, 1, 1, 2, 2, 3]");
    let fffd = regexp::must_compile("\\x{FFFD}");
    check_str("U+FFFD matches invalid and real", str(fffd.find_all_index("\xff\xef\xbf\xbd", -1)), "[0, 1, 1, 4]");
    // A multi-byte rune is one character.
    let one = regexp::must_compile("^.$");
    check_bool("one rune", one.match_string("☺"), true);
    check_bool("two invalid bytes", one.match_string("\xe2\x98"), false);
    // An empty match moves on a whole rune.
    let empty = regexp::must_compile("x*");
    check_str("empty matches between runes", str(empty.find_all_index("é☺", -1)), "[0, 0, 2, 2, 5, 5]");
}

fn failed_compile() {
    let re, err = regexp::compile("a(b");
    check_int("error code", err.code, syntax::ERR_MISSING_PAREN);
    check_str("error text", str(err), "error parsing regexp: missing closing ): `a(b`");
    check_bool("matches nothing", re.match_string("a(b"), false);
    check_bool("matches nothing, empty", re.match_string(""), false);
    check_str("still has its text", regexp::string(re), "a(b");
    let m, merr = regexp::match_string("a(b", "ab");
    check_bool("package match_string fails", m, false);
    check_int("package match_string error", merr.code, syntax::ERR_MISSING_PAREN);
    let ok, oerr = regexp::matches("b+", "abbc");
    check_bool("package matches", ok, true);
    check_int("package matches no error", oerr.code, 0);
    let pre, perr = regexp::compile_posix("\\d");
    check_int("POSIX has no \\d", perr.code, syntax::ERR_INVALID_ESCAPE);
}

fn copies_and_longest() {
    let re = regexp::must_compile("a(|b)");
    var c = copy(re);
    c.longest();
    let f1, ok1 = re.find("ab");
    let f2, ok2 = c.find("ab");
    check_str("original leftmost-first", f1, "a");
    check_str("copy leftmost-longest", f2, "ab");
    let posix = regexp::must_compile_posix("a|ab");
    let f3, ok3 = posix.find("ab");
    check_str("POSIX leftmost-longest", f3, "ab");
}

fn each_match_and_replace() {
    let re = regexp::must_compile("(\\w)(\\d)");
    var seen: u8[>..] = [];
    re.each_match("a1 b2 c3", 2, re.num_cap) { m => format(seen, m[2], m[4], ";"); };
    check_str("each_match with n", seen, "01;34;");
    var count = 0;
    var groups = 0;
    re.each_match("a1 b2 c3") { m =>
        count++;
        if m[4] >= 0 { groups++; }
    };
    check_int("each_match defaults: all", count, 3);
    check_int("each_match defaults: groups set", groups, 3);
    let out = re.replace_all_func("a1 b2") { m => str("<", m, ">") };
    check_str("replace_all_func", out, "<a1> <b2>");
    check_str("replace_all expand", re.replace_all("a1 b2", "$2$1"), "1a 2b");
    check_str("replace_all ${n}x", re.replace_all("a1", "${1}x"), "ax");
    check_str("replace_all $1x is ${1x}", re.replace_all("a1", "$1x"), "");
    check_str("replace_all literal", re.replace_all_literal("a1", "$1"), "$1");
    var dst: u8[>..] = [];
    dst.append("> ");
    let m = re.find_submatch_index("z9");
    re.expand(dst, "$2 then $1 and $$", "z9", m);
    check_str("expand appends", dst, "> 9 then z and $");
    check_str("quote_meta", regexp::quote_meta("1.5*[x]"), "1\\.5\\*\\[x\\]");
    let comma = regexp::must_compile(",\\s*");
    check_str("split", str(comma.split("a, b,c", -1)), "[\"a\", \"b\", \"c\"]");
    let abc = regexp::must_compile("abc+");
    let p, complete = abc.literal_prefix();
    check_str("literal_prefix", p, "abc");
    check_bool("literal_prefix incomplete", complete, false);
}

fn syntax_api() {
    let tree, err = syntax::parse("(?i)k", syntax::PERL);
    let prog = syntax::compile(tree);
    check_str("Inst.String", syntax::inst_string(prog, prog.start), "rune \"K\"/i -> 2");
    check_str("Op.String", syntax::op_string(syntax::OP_ALTERNATE), "Alternate");
    check_str("InstOp.String", syntax::inst_op_string(syntax::INST_RUNE_ANY_NOT_NL), "InstRuneAnyNotNL");
    check_int("EmptyOpContext", syntax::empty_op_context(-1, 'a'),
              syntax::EMPTY_BEGIN_TEXT | syntax::EMPTY_BEGIN_LINE | syntax::EMPTY_WORD_BOUNDARY);
    check_int("MaxCap", syntax::max_cap(tree), 0);
    let two, e2 = syntax::parse("(a)(?P<x>b)", syntax::PERL);
    check_str("CapNames", str(syntax::cap_names(two)), "[\"\", \"\", \"x\"]");
    let same, e3 = syntax::parse("(a)(?P<x>b)", syntax::PERL);
    check_bool("Equal", syntax::equal(two, same), true);
    check_bool("not Equal", syntax::equal(two, tree), false);
}

fn main() {
    syntax_api();
    views();
    unmatched_groups();
    utf8_input();
    failed_compile();
    copies_and_longest();
    each_match_and_replace();
    summary("api");
}
