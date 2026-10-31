// bench times this package on the cases of Go's own benchmarks
// (exec_test.go's BenchmarkMatch, all_test.go's micro-benchmarks and
// BenchmarkCompile), with the same loop as tools/regexpbench (Go), for
// scripts/bench.py: one line a case, "name ns/op".
//
//   goose build tools/bench.goose && tools/bench

import std;
import os;
import regexp from "..";

var min_time = 0.2;
var sink = 0;

// Go's makeText.
fn make_text(n: i64) -> u8[>..] {
    var text: u8[>..] = [];
    var x: u32 = 0xFFFFFFFF;
    for i in n {
        x += x;
        x ^= 1;
        if (x as! i32) < 0 { x ^= 0x88888eef; }
        if x % 31 == 0 { text.push('\n'); } else { text.push((x % (0x7E + 1 - 0x20) + 0x20) as u8); }
    }
    return text;
}

fn bench<F>(name: const u8[:]) {
    var n = 1;
    loop {
        let t0 = clock();
        for i in n { F(); }
        let d = clock() - t0;
        if d >= min_time {
            print(name, " ", d * 1e9 / n as f64);
            return;
        }
        if d < min_time / 100.0 { n *= 10; } else { n = (n as f64 * min_time / d * 1.2) as i64 + 1; }
    }
}

fn b(v: bool) -> i64 { if v { 1 } else { 0 } }

fn main() {
    let names = ["Easy0", "Easy0i", "Easy1", "Medium", "Hard", "Hard1"];
    let pats = ["ABCDEFGHIJKLMNOPQRSTUVWXYZ$", "(?i)ABCDEFGHIJklmnopqrstuvwxyz$",
                "A[AB]B[BC]C[CD]D[DE]E[EF]F[FG]G[GH]H[HI]I[IJ]J$", "[XYZ]ABCDEFGHIJKLMNOPQRSTUVWXYZ$",
                "[ -~]*ABCDEFGHIJKLMNOPQRSTUVWXYZ$", "ABCD|CDEF|EFGH|GHIJ|IJKL|KLMN|MNOP|OPQR|QRST|STUV|UVWX|WXYZ"];
    let size_names = ["32", "1K", "32K", "1M"];
    let sizes = [32, 1024, 32 * 1024, 1024 * 1024];
    for d in names.len {
        let re = regexp::must_compile(pats[d]);
        for k in sizes.len {
            let t = make_text(sizes[k]);
            bench(str("Match/", names[d], "/", size_names[k])) {
                if re.matches(t) {
                    print("match!");
                    exit(1);
                }
            };
        }
    }
    let op = regexp::must_compile("(?s)\\A.*\\z");
    for k in sizes.len {
        let t = make_text(sizes[k]);
        bench(str("Match_onepass_regex/", size_names[k])) { if !op.matches(t) { exit(1); } };
    }
    let ab = regexp::must_compile("a+b+");
    let s1 = "acbbaaabbdd";
    bench("Find") {
        let f, ok = ab.find(s1);
        sink += f.len;
    };
    bench("FindAllNoMatches") { sink += ab.find_all("acddee", -1).len; };
    var s3: u8[>..] = [];
    for i in 10 { s3.append("acddeeabbax"); }
    bench("FindAllTenMatches") { sink += ab.find_all(s3, -1).len; };
    let sub = regexp::must_compile("a(a+b+)b");
    bench("FindSubmatch") { sink += sub.find_submatch(s1).len; };
    var x: u8[>..] = [];
    x.push_n('x', 50);
    x.push('y');
    let lit = regexp::must_compile("y");
    bench("Literal") { sink += b(lit.match_string(x)); };
    let nlit = regexp::must_compile(".y");
    bench("NotLiteral") { sink += b(nlit.match_string(x)); };
    let cls = regexp::must_compile("[abcdw]");
    var xc: u8[>..] = [];
    for i in 20 { xc.append("xxxx"); }
    xc.push('w');
    bench("MatchClass") { sink += b(cls.match_string(xc)); };
    let cls2 = regexp::must_compile("[ac]");
    var xc2: u8[>..] = [];
    for i in 20 { xc2.append("bbbb"); }
    xc2.push('c');
    bench("MatchClass_InRange") { sink += b(cls2.match_string(xc2)); };
    let rep = regexp::must_compile("[cjrw]");
    bench("ReplaceAll") { sink += rep.replace_all_string("abcdefghijklmnopqrstuvwxyz", "").len; };
    let az = "abcdefghijklmnopqrstuvwxyz";
    var long: u8[>..] = [];
    for i in 32768 { long.append(az); }
    let anc = regexp::must_compile("^zbc(d|e)");
    bench("AnchoredLiteralShortNonMatch") { sink += b(anc.matches(az)); };
    bench("AnchoredLiteralLongNonMatch") { sink += b(anc.matches(long)); };
    let anc2 = regexp::must_compile("^.bc(d|e)");
    bench("AnchoredShortMatch") { sink += b(anc2.matches(az)); };
    bench("AnchoredLongMatch") { sink += b(anc2.matches(long)); };
    let sh = "abcddddddeeeededd";
    let opa = regexp::must_compile("^.bc(d|e)*$");
    bench("OnePassShortA") { sink += b(opa.matches(sh)); };
    let nopa = regexp::must_compile(".bc(d|e)*$");
    bench("NotOnePassShortA") { sink += b(nopa.matches(sh)); };
    let opb = regexp::must_compile("^.bc(?:d|e)*$");
    bench("OnePassShortB") { sink += b(opb.matches(sh)); };
    let nopb = regexp::must_compile(".bc(?:d|e)*$");
    bench("NotOnePassShortB") { sink += b(nopb.matches(sh)); };
    let lp = regexp::must_compile("^abcdefghijklmnopqrstuvwxyz.*$");
    bench("OnePassLongPrefix") { sink += b(lp.matches(az)); };
    let lnp = regexp::must_compile("^.bcdefghijklmnopqrstuvwxyz.*$");
    bench("OnePassLongNotPrefix") { sink += b(lnp.matches(az)); };
    let par = regexp::must_compile("foo (ba+r)? baz");
    bench("MatchShared") { sink += b(par.matches("this is a long line that contains foo bar baz")); };
    bench("QuoteMetaAll") { sink += regexp::quote_meta("\\.+*?()|[]{}^$").len; };
    bench("QuoteMetaNone") { sink += regexp::quote_meta("abcdefghijklmnopqrstuvwxyz").len; };
    var hard: u8[>..] = [];
    for i in 50 { hard.append("((abc)*|"); }
    for i in 50 { hard.push(')'); }
    bench("Compile/Onepass") {
        let r = regexp::must_compile("^a.[l-nA-Cg-j]?e$");
        sink += r.num_subexp();
    };
    bench("Compile/Medium") {
        let r = regexp::must_compile("^((a|b|[d-z0-9])*(日){4,5}.)+$");
        sink += r.num_subexp();
    };
    bench("Compile/Hard") {
        let r = regexp::must_compile(hard);
        sink += r.num_subexp();
    };
    let big = make_text(1024 * 1024);
    let words = regexp::must_compile("[a-z]+ing");
    bench("FindAll/words/1M") { sink += words.find_all_index(big, -1).len; };
    let email = regexp::must_compile("(\\w+)@(\\w+)\\.com");
    bench("FindAllSubmatch/email/1M") { sink += email.find_all_submatch_index(big, -1).len; };
}
