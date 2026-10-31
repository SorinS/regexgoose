// regexp against Go's own tests: the tables of $GOROOT/src/regexp's
// find_test.go, all_test.go and onepass_test.go (test/vectors/go_regexp.txt,
// from scripts/gen_go_vectors.py), run as Go's tests run them, through
// every form of the API: Find, FindIndex, FindSubmatch(Index), the
// FindAll forms with their limit, Match, the package's MatchString,
// String, Compile's errors, ReplaceAll and its Literal and Func forms,
// QuoteMeta, LiteralPrefix, NumSubexp, SubexpNames, SubexpIndex, Split,
// and whether an expression gets a one-pass program.

import std;
import regexp from "..";
import regexp.syntax;
import lib.check;

fn ints_equal(a: const i64[:], b: const i64[:]) -> bool { a == b }

fn str_of(xs: const i64[:]) -> u8[>..] { str(xs) }

// One findTests case: pat, text, max, and the matches (each with its
// submatch positions), or none (nil) for no match.
fn find_case(pat: const u8[:], text: const u8[:], max: i64, has: bool, matches: const i64[:], width: i64) {
    let what = str("find /", pat, "/ on \"", text, "\"");
    let re, err = regexp::compile(pat);
    if err.code != 0 {
        fail_msg(what, str("compile: ", err));
        return;
    }
    check_str(str(what, " String"), regexp::string(re), pat);
    let nmatch = if has && width > 0 { matches.len / width } else { 0 };

    // Match, MatchString, the package's MatchString (TestMatch,
    // TestMatchFunction), and on a copy (TestCopyMatch).
    if max != 0 {
        check_bool(str(what, " MatchString"), re.match_string(text), nmatch > 0);
        check_bool(str(what, " Match"), re.matches(text), nmatch > 0);
        let m, merr = regexp::match_string(pat, text);
        check_bool(str(what, " regexp.MatchString"), m, nmatch > 0);
        let c = copy(re);
        check_bool(str(what, " Copy().MatchString"), c.match_string(text), nmatch > 0);
    }

    // Find, FindIndex, FindSubmatch, FindSubmatchIndex.
    if max != 0 {
        let f, found = re.find(text);
        let a, b = re.find_index(text);
        let sm = re.find_submatch_index(text);
        let subs = re.find_submatch(text);
        if !has {
            check_bool(str(what, " Find"), found, false);
            check_int(str(what, " FindIndex"), a, -1);
            check_int(str(what, " FindSubmatchIndex"), sm.len, 0);
            check_int(str(what, " FindSubmatch"), subs.len, 0);
        } else {
            let want = matches[..width];
            check_bool(str(what, " Find found"), found, true);
            check_str(str(what, " Find"), f, text[want[0]..want[1]]);
            check_int(str(what, " FindIndex start"), a, want[0]);
            check_int(str(what, " FindIndex end"), b, want[1]);
            check_str(str(what, " FindSubmatchIndex"), str_of(sm), str_of(want));
            check_int(str(what, " FindSubmatch len"), subs.len, width / 2);
            for k in min(subs.len, width / 2) {
                let w = if want[2 * k] >= 0 { text[want[2 * k]..want[2 * k + 1]] } else { "" };
                check_str(str(what, " FindSubmatch ", k), subs[k], w);
            }
        }
    }

    // The FindAll forms, with the table's limit.
    let all = re.find_all(text, max);
    let all_index = re.find_all_index(text, max);
    let all_sub_index = re.find_all_submatch_index(text, max);
    let all_sub = re.find_all_submatch(text, max);
    if !has {
        check_int(str(what, " FindAll"), all.len, 0);
        check_int(str(what, " FindAllIndex"), all_index.len, 0);
        check_int(str(what, " FindAllSubmatchIndex"), all_sub_index.len, 0);
        check_int(str(what, " FindAllSubmatch"), all_sub.len, 0);
        return;
    }
    check_int(str(what, " FindAll count"), all.len, nmatch);
    check_int(str(what, " FindAllIndex count"), all_index.len, 2 * nmatch);
    check_str(str(what, " FindAllSubmatchIndex"), str_of(all_sub_index), str_of(matches));
    check_int(str(what, " FindAllSubmatch count"), all_sub.len, nmatch * (width / 2));
    for k in min(all.len, nmatch) {
        let e = matches[k * width..(k + 1) * width];
        check_str(str(what, " FindAll ", k), all[k], text[e[0]..e[1]]);
        if 2 * k + 1 < all_index.len {
            check_int(str(what, " FindAllIndex ", k), all_index[2 * k], e[0]);
            check_int(str(what, " FindAllIndex ", k), all_index[2 * k + 1], e[1]);
        }
        for g in width / 2 {
            let at = k * (width / 2) + g;
            if at < all_sub.len {
                let w = if e[2 * g] >= 0 { text[e[2 * g]..e[2 * g + 1]] } else { "" };
                check_str(str(what, " FindAllSubmatch ", k, " ", g), all_sub[at], w);
            }
        }
    }
}

fn replace_case(kind: const u8[:], pattern: const u8[:], repl: const u8[:], input: const u8[:], output: const u8[:]) {
    let what = str(kind, " /", pattern, "/ \"", repl, "\" on \"", input, "\"");
    let re, err = regexp::compile(pattern);
    if err.code != 0 {
        fail_msg(what, str("compile: ", err));
        return;
    }
    if kind == "replace" {
        check_str(str(what, " ReplaceAllString"), re.replace_all_string(input, repl), output);
        check_str(str(what, " ReplaceAll"), re.replace_all(input, repl), output);
        // TestReplaceAllLiteral runs the cases without $ literally too.
        if find(repl, "$") < 0 {
            check_str(str(what, " ReplaceAllLiteral"), re.replace_all_literal(input, repl), output);
        }
    } else {
        check_str(str(what, " ReplaceAllLiteralString"), re.replace_all_literal_string(input, repl), output);
        check_str(str(what, " ReplaceAllLiteral"), re.replace_all_literal(input, repl), output);
    }
}

fn go_vectors() {
    let data = embed_file("vectors/go_regexp.txt");
    var n = 0;
    each_split(data, '\n') {
        guard it.len > 0 && it[0] != '#';
        let f = split(it, ' ');
        let kind = f[0];
        n++;
        if kind == "find" {
            let nm = int_field(f[4]);
            var matches: i64[>..] = [];
            var width = 0;
            for k in 0..max(nm, 0) {
                let before = matches.len;
                ints_field(f[5 + k], matches);
                width = matches.len - before;
            }
            find_case(unhex(f[1]), unhex(f[2]), int_field(f[3]), nm >= 0, matches, width);
        } else if kind == "good" {
            let s = unhex(f[1]);
            let re, err = regexp::compile(s);
            checks++;
            if err.code != 0 { fail_msg(str("goodRe ", s), str(err)); }
        } else if kind == "bad" {
            let s = unhex(f[1]);
            let want = unhex(f[2]);
            let re, err = regexp::compile(s);
            checks++;
            if err.code == 0 {
                fail_msg(str("badRe ", s), "compiled");
            } else if find(str(err), want) < 0 {
                fail_msg(str("badRe ", s), str("wrong error: ", err, "; want ", want));
            }
        } else if kind == "replace" || kind == "replaceliteral" {
            replace_case(kind, unhex(f[1]), unhex(f[2]), unhex(f[3]), unhex(f[4]));
        } else if kind == "replacefunc" {
            // Every function of replaceFuncTests is "x" + s + "y".
            let pattern = unhex(f[1]);
            let input = unhex(f[2]);
            let re = regexp::must_compile(pattern);
            let got = re.replace_all_func(input) { m => str("x", m, "y") };
            check_str(str("ReplaceAllFunc /", pattern, "/"), got, unhex(f[3]));
            let got2 = re.replace_all_string_func(input) { m => str("x", m, "y") };
            check_str(str("ReplaceAllStringFunc /", pattern, "/"), got2, unhex(f[3]));
        } else if kind == "meta" || kind == "prefix" {
            let pattern = unhex(f[1]);
            let literal = unhex(f[3]);
            let is_literal = f[4] == "1";
            if kind == "meta" {
                // TestQuoteMeta
                let quoted = regexp::quote_meta(pattern);
                check_str(str("QuoteMeta ", pattern), quoted, unhex(f[2]));
                if pattern.len > 0 {
                    let re = regexp::must_compile(quoted);
                    let src = str("abc", pattern, "def");
                    check_str(str("QuoteMeta replace ", pattern), re.replace_all_string(src, "xyz"), "abcxyzdef");
                }
            }
            // TestLiteralPrefix
            let re = regexp::must_compile(pattern);
            let lp, complete = re.literal_prefix();
            check_str(str("LiteralPrefix ", pattern), lp, literal);
            check_bool(str("LiteralPrefix complete ", pattern), complete, is_literal);
        } else if kind == "subexp" {
            let input = unhex(f[1]);
            let num = int_field(f[2]);
            let re = regexp::must_compile(input);
            check_int(str("NumSubexp ", input), re.num_subexp(), num);
            let names = re.subexp_names();
            check_int(str("len(SubexpNames) ", input), names.len, num + 1);
            let nn = int_field(f[3]);
            var at = 4;
            for k in 0..max(nn, 0) {
                if k < names.len { check_str(str("SubexpNames ", input, " ", k), names[k], unhex(f[at])); }
                at++;
            }
            let ni = int_field(f[at]);
            at++;
            for k in ni {
                let name = unhex(f[at]);
                check_int(str("SubexpIndex ", input, " ", name), re.subexp_index(name), int_field(f[at + 1]));
                at += 2;
            }
        } else if kind == "split" {
            let s = unhex(f[1]);
            let r = unhex(f[2]);
            let lim = int_field(f[3]);
            let re = regexp::must_compile(r);
            let got = re.split(s, lim);
            let cnt = int_field(f[4]);
            let what = str("Split \"", s, "\" by /", r, "/ ", lim);
            check_int(str(what, " count"), got.len, max(cnt, 0));
            for k in min(got.len, max(cnt, 0)) { check_str(str(what, " ", k), got[k], unhex(f[5 + k])); }
        } else if kind == "onepass" {
            let s = unhex(f[1]);
            let re = regexp::must_compile(s);
            check_bool(str("onepass ", s), re.onepass_start >= 0, f[2] == "1");
        } else if kind == "onepassmatch" {
            let s = unhex(f[1]);
            let re = regexp::must_compile(s);
            check_bool(str("onepass program ", s), re.onepass_start >= 0, true);
            check_bool(str("onepass match ", s), re.match_string(unhex(f[2])), true);
        } else {
            fail_msg("go_regexp.txt", str("unknown line kind ", kind));
        }
    };
    print("go_regexp.txt: ", n, " cases");
}

// all_test.go's tests that are code rather than tables.
fn go_tests() {
    // TestParseAndCompile: a$ under OneLine and not, through String.
    for one_line in [true, false] {
        let flags = if one_line { syntax::PERL | syntax::ONE_LINE } else { syntax::PERL & ~syntax::ONE_LINE };
        let parsed, err = syntax::parse("a$", flags);
        let re = regexp::must_compile(syntax::string(parsed));
        check_bool(str("ParseAndCompile ", one_line), re.match_string("a\nb"), !one_line);
    }
    // TestOnePassCutoff: too many instructions for a one-pass program.
    let cut = regexp::must_compile("^x{1,1000}y{1,1000}$");
    check_bool("OnePassCutoff", cut.onepass_start >= 0, false);
    // TestSwitchBacktrack: the Pike VM, then the backtracker.
    let ab = regexp::must_compile("a|b");
    var long: u8[>..] = [];
    long.push_n(0, 256 * 1024 + 1);
    check_bool("SwitchBacktrack long", ab.matches(long), false);
    check_bool("SwitchBacktrack short", ab.matches(long[..1]), false);
    // TestLongest (exec_test.go).
    var re = regexp::must_compile("a(|b)");
    let f1, ok1 = re.find_string("ab");
    check_str("Longest before", f1, "a");
    re.longest();
    let f2, ok2 = re.find_string("ab");
    check_str("Longest after", f2, "ab");
    // MustCompile's message, by Go's quote.
    check_str("quote backquote", regexp::quote("a(b"), "`a(b`");
    check_str("quote escaped", regexp::quote("a`b\n"), "\"a`b\\n\"");
    // Expand (example_test.go's ExampleRegexp_Expand).
    let content = "\n\t# comment line\n\toption1: value1\n\toption2: value2\n\n\t# another comment line\n\toption3: value3\n";
    let pat = regexp::must_compile("(?m)(?P<key>\\w+):\\s+(?P<value>\\w+)$");
    var result: u8[>..] = [];
    let all = pat.find_all_submatch_index(content, -1);
    let w = 2 * (pat.num_subexp() + 1);
    var k = 0;
    while k < all.len {
        pat.expand(result, "$key=$value\n", content, all[k..k + w]);
        k += w;
    }
    check_str("Expand", result, "option1=value1\noption2=value2\noption3=value3\n");
}

fn main() {
    go_vectors();
    go_tests();
    summary("regexp");
}
