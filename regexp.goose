// regexp: Go's regexp package for Goose. Regular expressions with RE2's
// syntax (regexp.syntax), matched in time linear in the input, over UTF-8
// text, with Go's API and Go's answers.
//
//   let re = regexp::must_compile("(\\w+)@(\\w+)\\.com");
//   if re.match_string("mail ann@example.com") { ... }
//   let m = re.find_submatch_index(text);       // [start, end, g1 start, g1 end, ...], empty for none
//   let all = re.find_all(text, -1);            // views into text
//   let out = re.replace_all(text, "$2:$1");
//
// Inputs are byte strings (u8[:]): Go's []byte and string methods are the
// same function here, under both names. Results are views into the input
// or positions in it; nothing is copied unless the result is new text.
// Matching is leftmost-first, as Perl's, unless the expression is
// compiled with compile_posix or `longest` is called on it, which give
// the leftmost-longest match. A match is found by one of Go's three
// matchers, chosen as Go chooses: the one-pass matcher for an anchored
// expression without ambiguity, the backtracker for a small program on a
// small input, and otherwise the Pike VM.

namespace regexp;

import std;
import syntax;
import exec;
import onepass;

// A compiled regular expression (Go's Regexp). A failed compile gives
// one that matches nothing.
struct Regexp {
    nsubexp: i64,          // the number of parenthesized subexpressions
    max_bitstate_len: i64,
    prefix_rune: i64,       // first rune of prefix
    prefix_end: i64,        // the one-pass program's instruction after the prefix
    matchcap: i64,          // size of recorded match lengths
    cond: i64,              // empty-width conditions required at start of match
    min_input_len: i64,     // minimum length of the input in bytes
    start: i64,             // the program's start instruction
    num_cap: i64,           // the program's capture slots
    onepass_start: i64,     // the one-pass program's start, -1 if there is none
    prefix_first: ByteSet,  // the first byte of prefix, for finding it
    prefix_complete: bool,  // prefix is the entire regexp
    leftmost_longest: bool, // whether regexp prefers leftmost-longest match
    expr: u8[],             // as passed to compile
    prefix: u8[],           // required prefix in unanchored matches
    names: u8[],            // the subexpression names, back to back
    name_ends: i32[],       // name i ends at name_ends[i] of names (i from 0 to num_subexp)
    insts: syntax::Inst[],  // the program
    runes: i32[],
    op_insts: OnePassInst[],    // the one-pass program, if any
    op_runes: i32[],
    op_next: u32[],
}

// --- compiling ---------------------------------------------------------------------

// Parses a regular expression and returns, if successful, a Regexp that
// can be used to match against text (Compile). The error's code is 0 on
// success; otherwise the Regexp matches nothing.
//
// When matching against text, the regexp returns a match that begins as
// early as possible in the input (leftmost), and among those it chooses
// the one that a backtracking implementation would have chosen first.
// This so-called leftmost-first matching is the same semantics that Perl,
// Python, and other implementations use.
fn compile(expr: const u8[:]) -> Regexp, syntax::Error { return compile_mode(expr, syntax::PERL, false); }

// Like compile, but restricts the expression to POSIX ERE (egrep) syntax
// and changes the match semantics to leftmost-longest (CompilePOSIX).
fn compile_posix(expr: const u8[:]) -> Regexp, syntax::Error { return compile_mode(expr, syntax::POSIX, true); }

// Like compile, but aborts the program if the expression cannot be parsed
// (MustCompile), with Go's message.
fn must_compile(expr: const u8[:]) -> Regexp {
    var re, err = compile(expr);
    if err.code != 0 { abort(str("regexp: Compile(", quote(expr), "): ", err)); }
    return re;
}

// Like compile_posix, but aborts the program if the expression cannot be
// parsed (MustCompilePOSIX).
fn must_compile_posix(expr: const u8[:]) -> Regexp {
    var re, err = compile_posix(expr);
    if err.code != 0 { abort(str("regexp: CompilePOSIX(", quote(expr), "): ", err)); }
    return re;
}

// Go's quote: the expression between backquotes where it can be, quoted
// with escapes otherwise.
fn quote(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    if syntax::can_backquote(s) {
        out.push('`');
        out.append(s);
        out.push('`');
    } else {
        syntax::append_quoted(out, s, false);
    }
    return out;
}

fn no_match(expr: const u8[:]) -> Regexp {
    Regexp {
        nsubexp: 0, max_bitstate_len: 0, prefix_rune: 0, prefix_end: 0, matchcap: 2, cond: syntax::EMPTY_ALL,
        min_input_len: 0, start: 0, num_cap: 2, onepass_start: -1, prefix_first: byte_set(""), prefix_complete: false,
        leftmost_longest: false,
        expr: expr, prefix: [], names: [], name_ends: [0],
        insts: [syntax::Inst { op: syntax::INST_FAIL, out: 0, arg: 0, rune: 0, nrune: 0 }],
        runes: [], op_insts: [], op_runes: [], op_next: [],
    }
}

fn compile_mode(expr: const u8[:], mode: i64, longest: bool) -> Regexp, syntax::Error {
    var nodes: syntax::Node[>..] = [];
    var subs: i32[>..] = [];
    var trunes: i32[>..] = [];
    var tnames: u8[>..] = [];
    var pl = syntax::Pools { nodes: nodes, subs: subs, runes: trunes, names: tnames };
    let root, err = syntax::parse_into(pl, expr, mode);
    if err.code != 0 { return no_match(expr), err; }
    let max_cap = syntax::max_cap(syntax::view(pl), root);
    var names: u8[>..] = [];
    var name_ends: i32[>..] = [];
    for nm in syntax::cap_names(syntax::view(pl), root) {
        names.append(nm);
        name_ends.push(names.len as i32);
    }

    let sroot = syntax::simplify_into(pl, root);
    var insts: syntax::Inst[>..] = [];
    var runes: i32[>..] = [];
    let start, num_cap = syntax::compile_into(insts, runes, syntax::view(pl), sroot);
    let matchcap = max(num_cap, 2);
    let cond = syntax::start_cond_of(insts, start);
    let min_len = min_input_len(syntax::view(pl), sroot);

    var op_insts: OnePassInst[>..] = [];
    var op_runes: i32[>..] = [];
    var op_next: u32[>..] = [];
    let op_start = compile_onepass(insts, runes, start, num_cap, op_insts, op_runes, op_next);

    var max_bits = 0;
    var prefix_end = 0;
    var prefix: u8[>..] = [];
    var complete = false;
    if op_start < 0 {
        prefix, complete = syntax::prefix_of(insts, runes, start);
        max_bits = max_bit_state_len(insts.len);
    } else {
        prefix, complete, prefix_end = onepass_prefix(insts, runes, start);
    }
    var prefix_rune = 0;
    if prefix.len > 0 {
        let r, w = syntax::decode_rune(prefix, 0);
        prefix_rune = r;
    }
    return Regexp {
        nsubexp: max_cap, max_bitstate_len: max_bits, prefix_rune: prefix_rune, prefix_end: prefix_end,
        matchcap: matchcap, cond: cond, min_input_len: min_len, start: start, num_cap: num_cap,
        onepass_start: op_start, prefix_first: byte_set(prefix[..min(1, prefix.len)]), prefix_complete: complete,
        leftmost_longest: longest,
        expr: expr, prefix: prefix, names: names, name_ends: name_ends, insts: insts, runes: runes,
        op_insts: op_insts, op_runes: op_runes, op_next: op_next,
    }, err;
}

// The minimum length of the input in bytes a match of node n needs
// (minInputLen).
recursive fn min_input_len(v: syntax::View, n: i64) -> i64 {
    let nd = v.nodes[n];
    let op = nd.op as i64;
    if op == syntax::OP_ANY_CHAR || op == syntax::OP_ANY_CHAR_NOT_NL || op == syntax::OP_CHAR_CLASS { return 1; }
    if op == syntax::OP_LITERAL {
        var l = 0;
        for r in syntax::runes(v, n) {
            if r == syntax::RUNE_ERROR { l++; } else { l += syntax::rune_len(r); }
        }
        return l;
    }
    if op == syntax::OP_CAPTURE || op == syntax::OP_PLUS { return min_input_len(v, syntax::sub(v, n, 0)); }
    if op == syntax::OP_REPEAT { return nd.min * min_input_len(v, syntax::sub(v, n, 0)); }
    if op == syntax::OP_CONCAT {
        var l = 0;
        for i in nd.nsub as i64 { l += min_input_len(v, syntax::sub(v, n, i)); }
        return l;
    }
    if op == syntax::OP_ALTERNATE {
        var l = min_input_len(v, syntax::sub(v, n, 0));
        for i in 1..nd.nsub as i64 {
            let lnext = min_input_len(v, syntax::sub(v, n, i));
            if lnext < l { l = lnext; }
        }
        return l;
    }
    return 0;
}

// Makes future searches prefer leftmost-longest matches (Longest).
fn longest(re: Regexp&) { re.leftmost_longest = true; }

// The source text used to compile the regular expression (String).
fn string(re: const Regexp&) -> const u8[:] { re.expr }

fn format(out: u8[>..]&, re: const Regexp&) { out.append(re.expr); }

// The number of parenthesized subexpressions (NumSubexp).
fn num_subexp(re: const Regexp&) -> i64 { re.nsubexp }

// The name of parenthesized subexpression i, "" for an unnamed one and
// for 0, the whole match.
fn subexp_name(re: const Regexp&, i: i64) -> const u8[:] {
    let lo = if i == 0 { 0 } else { re.name_ends[i - 1] as i64 };
    return re.names[lo..re.name_ends[i] as i64];
}

// The names of the parenthesized subexpressions, indexed by their number,
// "" for an unnamed one and for 0, the whole match (SubexpNames).
fn subexp_names(re: const Regexp&) -> const u8[:][>..] {
    var out: const u8[:][>..] = [];
    for i in re.nsubexp + 1 { out.push(subexp_name(re, i)); }
    return out;
}

// The index of the first subexpression with the given name, -1 if there
// is none (SubexpIndex). Several subexpressions can share a name.
fn subexp_index(re: const Regexp&, name: const u8[:]) -> i64 {
    if name.len > 0 {
        for i in re.nsubexp + 1 {
            if subexp_name(re, i) == name { return i; }
        }
    }
    return -1;
}

// The literal string every match must begin with, and whether it is the
// whole of the expression (LiteralPrefix).
fn literal_prefix(re: const Regexp&) -> const u8[:], bool { return re.prefix, re.prefix_complete; }

// --- finding -------------------------------------------------------------------------

// For testing: which matcher find_at uses. 0 (the default) chooses as Go
// does; ENGINE_NFA always runs the Pike VM, ENGINE_BACKTRACK the
// backtracker wherever the program is small enough for it (whatever the
// input's length), ENGINE_ONEPASS the one-pass matcher wherever there is
// a one-pass program; the Pike VM otherwise.
var debug_engine: i64 = 0;
let ENGINE_NFA = 1;
let ENGINE_BACKTRACK = 2;
let ENGINE_ONEPASS = 3;

// The leftmost match at or after pos, as Go's find: its first ncap capture
// slots in out (which has at least ncap), -1 for those not set. w is
// scratch for the Pike VM, kept between calls.
fn find_at(re: const Regexp&, s: const u8[:], pos: i64, ncap: i64, out: i64[:], w: i64[>..]&) -> bool {
    if s.len < re.min_input_len { return false; }
    // Go's prefix is the one-pass program's where there is one; the
    // ordinary program's prefix is then empty (it begins with \A).
    let prefix = if re.onepass_start >= 0 { re.prefix[..0] } else { re.prefix[..] };
    if debug_engine == 0 {
        if re.onepass_start >= 0 { return onepass_match(re, s, pos, ncap, out); }
        if s.len < re.max_bitstate_len { return backtrack(re, s, pos, ncap, out, prefix); }
    } else if debug_engine == ENGINE_BACKTRACK && re.insts.len <= MAX_BACKTRACK_PROG {
        return backtrack(re, s, pos, ncap, out, prefix);
    } else if debug_engine == ENGINE_ONEPASS && re.onepass_start >= 0 {
        return onepass_match(re, s, pos, ncap, out);
    }
    let n = re.insts.len;
    let need = nfa_space(n, ncap);
    if w.len < need { w.push_n(0, need - w.len); }
    var m = new_nfa(n, ncap, re.leftmost_longest);
    if !nfa_match(re, m, w, s, pos, prefix) { return false; }
    for k in ncap { out[k] = w[m.match_at + k]; }
    return true;
}

// Whether s contains any match of the regular expression (Match).
fn matches(re: const Regexp&, s: const u8[:]) -> bool {
    var w: i64[>..] = [];
    var cap: i64[2] = [-1, -1];
    return find_at(re, s, 0, 0, cap, w);
}

// MatchString: matches, for a string.
fn match_string(re: const Regexp&, s: const u8[:]) -> bool { matches(re, s) }

// Whether s contains any match of the expression pattern (the package's
// Match and MatchString); an error if pattern does not compile.
fn matches(pattern: const u8[:], s: const u8[:]) -> bool, syntax::Error {
    let re, err = compile(pattern);
    if err.code != 0 { return false, err; }
    return matches(re, s), err;
}

fn match_string(pattern: const u8[:], s: const u8[:]) -> bool, syntax::Error { return matches(pattern, s); }

// The leftmost match: its start and end, (-1, -1) if there is none
// (FindIndex).
fn find_index(re: const Regexp&, s: const u8[:]) -> i64, i64 {
    var w: i64[>..] = [];
    var cap: i64[2] = [-1, -1];
    if !find_at(re, s, 0, 2, cap, w) { return -1, -1; }
    return cap[0], cap[1];
}

fn find_string_index(re: const Regexp&, s: const u8[:]) -> i64, i64 { return find_index(re, s); }

// The text of the leftmost match, and whether there is one (Find; Go's
// nil for none is the false).
fn find(re: const Regexp&, s: const u8[:]) -> const u8[:], bool {
    let a, b = find_index(re, s);
    if a < 0 { return s[0..0], false; }
    return s[a..b], true;
}

fn find_string(re: const Regexp&, s: const u8[:]) -> const u8[:], bool { return find(re, s); }

// The leftmost match and its subexpressions: 2 * (num_subexp + 1)
// positions, start and end of the match and of each subexpression, -1 for
// a subexpression that took no part; empty if there is no match
// (FindSubmatchIndex).
fn find_submatch_index(re: const Regexp&, s: const u8[:]) -> i64[>..] {
    var w: i64[>..] = [];
    var cap: i64[>..] = [];
    cap.push_n(-1, max(2 * (re.nsubexp + 1), re.num_cap));
    if !find_at(re, s, 0, re.num_cap, cap, w) {
        cap.clear();
        return cap;
    }
    cap.resize(2 * (re.nsubexp + 1));
    return cap;
}

fn find_string_submatch_index(re: const Regexp&, s: const u8[:]) -> i64[>..] { find_submatch_index(re, s) }

// The text of the leftmost match and of its subexpressions, num_subexp + 1
// views into s; empty if there is no match (FindSubmatch). A
// subexpression that took no part is an empty view, as in Go's
// FindStringSubmatch; find_submatch_index tells it from an empty match.
fn find_submatch(re: const Regexp&, s: const u8[:]) -> const u8[:][>..] {
    var out: const u8[:][>..] = [];
    let m = find_submatch_index(re, s);
    var i = 0;
    while i + 1 < m.len {
        if m[i] >= 0 { out.push(s[m[i]..m[i + 1]]); } else { out.push(s[0..0]); }
        i += 2;
    }
    return out;
}

fn find_string_submatch(re: const Regexp&, s: const u8[:]) -> const u8[:][>..] { find_submatch(re, s) }

// Calls F(m) for each successive non-overlapping match of the expression
// in s, at most n of them (all if n < 0), m being its 2 * (num_subexp + 1)
// positions as find_submatch_index gives them; with ncap 2 only the
// match's own two are set (Go's matches). An empty match right after the
// previous match is not one.
fn each_match<F>(re: const Regexp&, s: const u8[:], n: i64, ncap: i64) {
    if n == 0 { return; }
    var left = n;
    let end = s.len;
    let width_all = max(2 * (re.nsubexp + 1), re.num_cap);
    var w: i64[>..] = [];
    var cap: i64[>..] = [];
    cap.push_n(-1, width_all);
    var pos = 0;
    var prev_match_end = -1;
    while pos <= end {
        for k in width_all { cap[k] = -1; }
        if !find_at(re, s, pos, ncap, cap, w) { break; }
        var accept = true;
        if cap[1] == pos {
            // An empty match.
            if cap[0] == prev_match_end {
                // An empty match right after a previous match is not one.
                accept = false;
            }
            // Move to next matching position.
            let r, width = step_at(s, pos);
            if width > 0 { pos += width; } else { pos = end + 1; }
        } else {
            pos = cap[1];
        }
        prev_match_end = cap[1];
        if accept {
            F(cap[..2 * (re.nsubexp + 1)]);
            if left > 0 {
                left--;
                if left == 0 { return; }
            }
        }
    }
}

// All successive matches, at most n (all if n < 0), as views into s
// (FindAll).
fn find_all(re: const Regexp&, s: const u8[:], n: i64) -> const u8[:][>..] {
    var out: const u8[:][>..] = [];
    each_match(re, s, n, 2) { m => out.push(s[m[0]..m[1]]); };
    return out;
}

fn find_all_string(re: const Regexp&, s: const u8[:], n: i64) -> const u8[:][>..] { find_all(re, s, n) }

// All successive matches, at most n (all if n < 0): their start and end,
// two positions a match (FindAllIndex).
fn find_all_index(re: const Regexp&, s: const u8[:], n: i64) -> i64[>..] {
    var out: i64[>..] = [];
    each_match(re, s, n, 2) { m =>
        out.push(m[0]);
        out.push(m[1]);
    };
    return out;
}

fn find_all_string_index(re: const Regexp&, s: const u8[:], n: i64) -> i64[>..] { find_all_index(re, s, n) }

// All successive matches, at most n (all if n < 0), with their
// subexpressions: 2 * (num_subexp + 1) positions a match, as
// find_submatch_index gives them (FindAllSubmatchIndex).
fn find_all_submatch_index(re: const Regexp&, s: const u8[:], n: i64) -> i64[>..] {
    var out: i64[>..] = [];
    each_match(re, s, n, re.num_cap) { m => out.append(m); };
    return out;
}

fn find_all_string_submatch_index(re: const Regexp&, s: const u8[:], n: i64) -> i64[>..] {
    find_all_submatch_index(re, s, n)
}

// All successive matches, at most n (all if n < 0), with their
// subexpressions: num_subexp + 1 views into s a match, empty ones for
// subexpressions that took no part (FindAllSubmatch).
fn find_all_submatch(re: const Regexp&, s: const u8[:], n: i64) -> const u8[:][>..] {
    var out: const u8[:][>..] = [];
    each_match(re, s, n, re.num_cap) { m =>
        var i = 0;
        while i + 1 < m.len {
            if m[i] >= 0 { out.push(s[m[i]..m[i + 1]]); } else { out.push(s[0..0]); }
            i += 2;
        }
    };
    return out;
}

fn find_all_string_submatch(re: const Regexp&, s: const u8[:], n: i64) -> const u8[:][>..] {
    find_all_submatch(re, s, n)
}

// --- replacing -----------------------------------------------------------------------

// Go's replaceAll: src with each match replaced by what F(out, m)
// appends to out, m holding the match's first nmatch positions.
fn replace_all_with<F>(re: const Regexp&, src: const u8[:], nmatch0: i64) -> u8[>..] {
    var buf: u8[>..] = [];
    var last_match_end = 0;     // end position of the most recent match
    var search_pos = 0;         // position where we next look for a match
    let end_pos = src.len;
    let nmatch = min(nmatch0, re.num_cap);
    let width_all = max(2 * (re.nsubexp + 1), re.num_cap);
    var w: i64[>..] = [];
    var a: i64[>..] = [];
    a.push_n(-1, width_all);
    while search_pos <= end_pos {
        for k in width_all { a[k] = -1; }
        if !find_at(re, src, search_pos, nmatch, a, w) { break; }  // no more matches
        // Copy the unmatched characters before this match.
        buf.append(src[last_match_end..a[0]]);
        // Now insert a copy of the replacement string, but not for a match
        // of the empty string immediately after another match. (Otherwise,
        // we get double replacement for patterns that match both empty and
        // nonempty strings.)
        if a[1] > last_match_end || a[0] == 0 { F(buf, a[..nmatch]); }
        last_match_end = a[1];
        // Advance past this match; always advance at least one character.
        let r, width = step_at(src, search_pos);
        if search_pos + width > a[1] {
            search_pos += width;
        } else if search_pos + 1 > a[1] {
            // This clause is only needed at the end of the input string. In
            // that case, step_at returns width=0.
            search_pos++;
        } else {
            search_pos = a[1];
        }
    }
    // Copy the unmatched characters after the last match.
    buf.append(src[last_match_end..]);
    return buf;
}

// src with each match replaced by repl, in which $ signs are interpreted
// as in expand: $1 is the text of the first subexpression (ReplaceAll).
fn replace_all(re: const Regexp&, src: const u8[:], repl: const u8[:]) -> u8[>..] {
    var n = 2;
    if ::find(repl, "$") >= 0 { n = 2 * (re.nsubexp + 1); }
    return replace_all_with(re, src, n) { out: u8[>..]&, m: const i64[:] => expand_into(re, out, repl, src, m); };
}

fn replace_all_string(re: const Regexp&, src: const u8[:], repl: const u8[:]) -> u8[>..] { replace_all(re, src, repl) }

// src with each match replaced by repl, taken literally (ReplaceAllLiteral).
fn replace_all_literal(re: const Regexp&, src: const u8[:], repl: const u8[:]) -> u8[>..] {
    return replace_all_with(re, src, 2) { out: u8[>..]&, m: const i64[:] => out.append(repl); };
}

fn replace_all_literal_string(re: const Regexp&, src: const u8[:], repl: const u8[:]) -> u8[>..] {
    replace_all_literal(re, src, repl)
}

// src with each match replaced by F(match), the text of the match, taken
// literally (ReplaceAllFunc):
//
//   let out = re.replace_all_func(src) { m => str("<", m, ">") };
fn replace_all_func<F>(re: const Regexp&, src: const u8[:]) -> u8[>..] {
    return replace_all_with(re, src, 2) { out: u8[>..]&, m: const i64[:] => out.append(F(src[m[0]..m[1]])); };
}

fn replace_all_string_func<F>(re: const Regexp&, src: const u8[:]) -> u8[>..] {
    return replace_all_with(re, src, 2) { out: u8[>..]&, m: const i64[:] => out.append(F(src[m[0]..m[1]])); };
}

// Appends template to dst, with each $name or ${name} replaced by the
// text in src of the subexpression of that name or number in match (as
// find_submatch_index gives it): $1, ${1}, $name, ${name}; $$ is a $. A
// name is the longest run of letters, digits and underscores, so $1x is
// ${1x}, not ${1}x; a missing or unmatched subexpression is the empty
// string, and an invalid reference is copied as is (Expand).
fn expand(re: const Regexp&, dst: u8[>..]&, template: const u8[:], src: const u8[:], m: const i64[:]) {
    expand_into(re, dst, template, src, m);
}

fn expand_string(re: const Regexp&, dst: u8[>..]&, template: const u8[:], src: const u8[:], m: const i64[:]) {
    expand_into(re, dst, template, src, m);
}

fn expand_into(re: const Regexp&, dst: u8[>..]&, template0: const u8[:], src: const u8[:], m: const i64[:]) {
    var template = template0;
    while template.len > 0 {
        let k = ::find(template, "$");
        if k < 0 { break; }
        dst.append(template[..k]);
        template = template[k + 1..];
        if template.len > 0 && template[0] == '$' {
            // Treat $$ as $.
            dst.push('$');
            template = template[1..];
            continue;
        }
        let name_lo, name_hi, num, rest, ok = extract(template);
        if !ok {
            // Malformed; treat $ as raw text.
            dst.push('$');
            continue;
        }
        let name = template[name_lo..name_hi];
        template = template[rest..];
        if num >= 0 {
            if 2 * num + 1 < m.len && m[2 * num] >= 0 { dst.append(src[m[2 * num]..m[2 * num + 1]]); }
        } else {
            for i in re.nsubexp + 1 {
                if name == subexp_name(re, i) && 2 * i + 1 < m.len && m[2 * i] >= 0 {
                    dst.append(src[m[2 * i]..m[2 * i + 1]]);
                    break;
                }
            }
        }
    }
    dst.append(template);
}

// The name at the start of s, after a $: where it starts and ends, its
// number (-1 if it is not one), where the rest of s starts, and whether
// there is a name (Go's extract).
fn extract(s: const u8[:]) -> i64, i64, i64, i64, bool {
    if s.len == 0 { return 0, 0, -1, 0, false; }
    var brace = false;
    var start = 0;
    if s[0] == '{' {
        brace = true;
        start = 1;
    }
    var i = start;
    while i < s.len {
        let r, size = syntax::decode_rune(s, i);
        if !syntax::is_letter(r) && !syntax::is_digit(r) && r != '_' { break; }
        i += size;
    }
    if i == start {
        // empty name is not okay
        return 0, 0, -1, 0, false;
    }
    let name_hi = i;
    if brace {
        if i >= s.len || s[i] != '}' {
            // missing closing brace
            return 0, 0, -1, 0, false;
        }
        i++;
    }
    // Parse number.
    var num = 0;
    for j in start..name_hi {
        if s[j] < '0' || '9' < s[j] || num >= 100000000 {
            num = -1;
            break;
        }
        num = num * 10 + (s[j] - '0');
    }
    // Disallow leading zeros.
    if s[start] == '0' && name_hi - start > 1 { num = -1; }
    return start, name_hi, num, i, true;
}

// The text of s with every regular expression metacharacter escaped, an
// expression that matches s literally (QuoteMeta).
fn quote_meta(s: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    for c in s {
        if is_special(c) { out.push('\\'); }
        out.push(c);
    }
    return out;
}

fn is_special(c: u8) -> bool {
    c == '\\' || c == '.' || c == '+' || c == '*' || c == '?' || c == '(' || c == ')' || c == '|' || c == '[' ||
    c == ']' || c == '{' || c == '}' || c == '^' || c == '$'
}

// s cut into the pieces between the matches, at most n of them (all if
// n < 0; none if n is 0), the last the rest of s (Split):
//
//   regexp::must_compile("a*").split("abaabaccadaaae", 5)
//   // ["", "b", "b", "c", "cadaaae"]
fn split(re: const Regexp&, s: const u8[:], n: i64) -> const u8[:][>..] {
    var out: const u8[:][>..] = [];
    if n == 0 { return out; }
    if re.expr.len > 0 && s.len == 0 {
        out.push(s);
        return out;
    }
    let matches = find_all_index(re, s, n);
    var beg = 0;
    var end = 0;
    var k = 0;
    while k + 1 < matches.len {
        if n > 0 && out.len >= n - 1 { break; }
        end = matches[k];
        if matches[k + 1] != 0 { out.push(s[beg..end]); }
        beg = matches[k + 1];
        k += 2;
    }
    if end != s.len { out.push(s[beg..]); }
    return out;
}
