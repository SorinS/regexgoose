// regexp.syntax: Go's regexp/syntax. A parser of RE2's syntax into a tree
// (parse), its simplification (simplify), its text again (string), and a
// compiler of it into a program for the matchers (compile, syntax/prog).
//
//   let re, err = syntax::parse("a(b|c)*", syntax::PERL);
//   if err.code == 0 { print(syntax::string(re)); }      // a(b|c)*
//
// A tree is a pool of nodes: `root` is the top one, and a node's
// subexpressions, runes and capture name are runs of `subs`, `runes` and
// `names`. Node indices stay valid for the tree's life; simplify gives a
// new tree whose nodes may be shared by several parents, as Go's do.

namespace syntax;

import std;
import syntax.tables;
import syntax.utf8;
import syntax.unicode;
import syntax.parse;
import syntax.simplify;
import syntax.prog;

// --- operators (Go's Op) ---------------------------------------------------

let OP_NO_MATCH = 1;            // matches no strings
let OP_EMPTY_MATCH = 2;         // matches empty string
let OP_LITERAL = 3;             // matches the runes in sequence
let OP_CHAR_CLASS = 4;          // matches a rune of the (lo, hi) pairs of runes
let OP_ANY_CHAR_NOT_NL = 5;     // matches any character except newline
let OP_ANY_CHAR = 6;            // matches any character
let OP_BEGIN_LINE = 7;          // matches empty string at beginning of line
let OP_END_LINE = 8;            // matches empty string at end of line
let OP_BEGIN_TEXT = 9;          // matches empty string at beginning of text
let OP_END_TEXT = 10;           // matches empty string at end of text
let OP_WORD_BOUNDARY = 11;      // matches word boundary `\b`
let OP_NO_WORD_BOUNDARY = 12;   // matches word non-boundary `\B`
let OP_CAPTURE = 13;            // capturing subexpression with index cap, optional name
let OP_STAR = 14;               // matches sub 0 zero or more times
let OP_PLUS = 15;               // matches sub 0 one or more times
let OP_QUEST = 16;              // matches sub 0 zero or one times
let OP_REPEAT = 17;             // matches sub 0 at least min times, at most max (-1: no limit)
let OP_CONCAT = 18;             // matches concatenation of the subs
let OP_ALTERNATE = 19;          // matches alternation of the subs
let OP_PSEUDO = 128;            // where the parser's pseudo-operators start
let OP_LEFT_PAREN = 128;
let OP_VERTICAL_BAR = 129;

let OP_NAMES = ["NoMatch", "EmptyMatch", "Literal", "CharClass", "AnyCharNotNL", "AnyChar", "BeginLine",
                "EndLine", "BeginText", "EndText", "WordBoundary", "NoWordBoundary", "Capture", "Star", "Plus",
                "Quest", "Repeat", "Concat", "Alternate"];

// Op.String.
fn op_string(op: i64) -> u8[>..] {
    if 1 <= op && op <= 19 { return str(OP_NAMES[op - 1]); }
    if op == 128 { return str("opPseudo"); }
    return str("Op(", op, ")");
}

// --- flags (Go's Flags) ----------------------------------------------------

let FOLD_CASE = 1;          // case-insensitive match
let LITERAL = 2;            // treat pattern as literal string
let CLASS_NL = 4;           // allow character classes like [^a-z] and [[:space:]] to match newline
let DOT_NL = 8;             // allow . to match newline
let ONE_LINE = 16;          // treat ^ and $ as only matching at beginning and end of text
let NON_GREEDY = 32;        // make repetition operators default to non-greedy
let PERL_X = 64;            // allow Perl extensions
let UNICODE_GROUPS = 128;   // allow \p{Han}, \P{Han} for Unicode group and negation
let WAS_DOLLAR = 256;       // regexp OP_END_TEXT was $, not \z
let SIMPLE = 512;           // regexp contains no counted repetition
let MATCH_NL = 12;          // CLASS_NL | DOT_NL
let PERL = 212;             // CLASS_NL | ONE_LINE | PERL_X | UNICODE_GROUPS: as close to Perl as possible
let POSIX = 0;              // POSIX syntax

// --- errors (Go's Error and ErrorCode) -----------------------------------------

let ERR_INTERNAL_ERROR = 1;
let ERR_INVALID_CHAR_CLASS = 2;
let ERR_INVALID_CHAR_RANGE = 3;
let ERR_INVALID_ESCAPE = 4;
let ERR_INVALID_NAMED_CAPTURE = 5;
let ERR_INVALID_PERL_OP = 6;
let ERR_INVALID_REPEAT_OP = 7;
let ERR_INVALID_REPEAT_SIZE = 8;
let ERR_INVALID_UTF8 = 9;
let ERR_MISSING_BRACKET = 10;
let ERR_MISSING_PAREN = 11;
let ERR_MISSING_REPEAT_ARGUMENT = 12;
let ERR_TRAILING_BACKSLASH = 13;
let ERR_UNEXPECTED_PAREN = 14;
let ERR_NESTING_DEPTH = 15;
let ERR_LARGE = 16;

let ERROR_TEXTS = [
    "regexp/syntax: internal error",
    "invalid character class",
    "invalid character class range",
    "invalid escape sequence",
    "invalid named capture",
    "invalid or unsupported Perl syntax",
    "invalid nested repetition operator",
    "invalid repeat count",
    "invalid UTF-8",
    "missing closing ]",
    "missing closing )",
    "missing argument to repetition operator",
    "trailing backslash at end of expression",
    "unexpected )",
    "expression nests too deeply",
    "expression too large",
];

// A failure to parse: its code (0 for none) and the offending part of
// the expression.
struct Error { code: i64, expr: u8[] }

fn no_error() -> Error { Error { code: 0, expr: [] } }

// The text of an error code (ErrorCode.String), "" for 0.
fn error_code_string(code: i64) -> const u8[:] {
    if code >= 1 && code <= ERROR_TEXTS.len { return ERROR_TEXTS[code - 1]; }
    return "";
}

// Error.Error: "error parsing regexp: <code>: `<expr>`"; nothing for no error.
fn format(out: u8[>..]&, e: Error&) {
    if e.code == 0 { return; }
    format(out, "error parsing regexp: ", error_code_string(e.code), ": `", e.expr, "`");
}

// --- the tree ------------------------------------------------------------------

// A node of a tree (Go's Regexp): its operator and flags, min and max for
// OP_REPEAT, cap for OP_CAPTURE, and runs of the tree's pools: `nsub`
// subexpressions at `sub` in `subs`, `nrune` runes at `rune` in `runes`
// (a literal's runes, or a class's (lo, hi) pairs), and a capture's name
// of `name_len` bytes at `name` in `names`.
struct Node {
    op: i32,
    flags: i32,
    min: i32,
    max: i32,
    cap: i32,
    sub: i32,
    nsub: i32,
    rune: i32,
    nrune: i32,
    name: i32,
    name_len: i32,
}

fn new_node(op: i64) -> Node {
    Node { op: op as i32, flags: 0, min: 0, max: 0, cap: 0, sub: 0, nsub: 0, rune: 0, nrune: 0, name: 0, name_len: 0 }
}

// A parsed regular expression: the tree under `root`.
struct Regexp {
    root: i32,
    nodes: Node[],
    subs: i32[],
    runes: i32[],
    names: u8[],
}

// A read-only view of a tree, finished or being built.
struct View {
    nodes: const Node[:],
    subs: const i32[:],
    runes: const i32[:],
    names: const u8[:],
}

fn view(re: const Regexp&) -> View {
    View { nodes: re.nodes, subs: re.subs, runes: re.runes, names: re.names }
}

// The growable pools a tree is built in.
struct Pools {
    nodes: Node[>..]&,
    subs: i32[>..]&,
    runes: i32[>..]&,
    names: u8[>..]&,
}

fn view(p: const Pools&) -> View {
    View { nodes: p.nodes, subs: p.subs, runes: p.runes, names: p.names }
}

// The tree under root, frozen.
fn freeze(p: const Pools&, root: i64) -> Regexp {
    Regexp { root: root as i32, nodes: copy(p.nodes), subs: copy(p.subs), runes: copy(p.runes), names: copy(p.names) }
}

// The i-th subexpression of node n.
fn sub(v: View, n: i64, i: i64) -> i64 { v.subs[v.nodes[n].sub + i] }

// Node n's runes.
fn runes(v: View, n: i64) -> const i32[:] {
    let nd = v.nodes[n];
    return v.runes[(nd.rune as i64)..(nd.rune as i64) + nd.nrune];
}

// Node n's capture name.
fn name(v: View, n: i64) -> const u8[:] {
    let nd = v.nodes[n];
    return v.names[(nd.name as i64)..(nd.name as i64) + nd.name_len];
}

fn sub(re: const Regexp&, n: i64, i: i64) -> i64 { sub(view(re), n, i) }
fn runes(re: const Regexp&, n: i64) -> const i32[:] { runes(view(re), n) }
fn name(re: const Regexp&, n: i64) -> const u8[:] { name(view(re), n) }

// --- Equal ---------------------------------------------------------------------

// Whether node a of tree x and node b of tree y have the same structure
// (Regexp.Equal); -1 is Go's nil.
recursive fn equal(x: View, a: i64, y: View, b: i64) -> bool {
    if a < 0 || b < 0 { return a < 0 && b < 0; }
    let p = x.nodes[a];
    let q = y.nodes[b];
    if p.op != q.op { return false; }
    let op = p.op as i64;
    if op == OP_END_TEXT {
        if p.flags & WAS_DOLLAR != q.flags & WAS_DOLLAR { return false; }
    } else if op == OP_LITERAL || op == OP_CHAR_CLASS {
        return p.flags & FOLD_CASE == q.flags & FOLD_CASE && runes(x, a) == runes(y, b);
    } else if op == OP_ALTERNATE || op == OP_CONCAT {
        if p.nsub != q.nsub { return false; }
        for i in p.nsub as i64 {
            if !equal(x, sub(x, a, i), y, sub(y, b, i)) { return false; }
        }
        return true;
    } else if op == OP_STAR || op == OP_PLUS || op == OP_QUEST {
        if p.flags & NON_GREEDY != q.flags & NON_GREEDY || !equal(x, sub(x, a, 0), y, sub(y, b, 0)) { return false; }
    } else if op == OP_REPEAT {
        if p.flags & NON_GREEDY != q.flags & NON_GREEDY || p.min != q.min || p.max != q.max ||
           !equal(x, sub(x, a, 0), y, sub(y, b, 0)) {
            return false;
        }
    } else if op == OP_CAPTURE {
        if p.cap != q.cap || name(x, a) != name(y, b) || !equal(x, sub(x, a, 0), y, sub(y, b, 0)) { return false; }
    }
    return true;
}

fn equal(x: const Regexp&, y: const Regexp&) -> bool { equal(view(x), x.root, view(y), y.root) }

// --- MaxCap and CapNames ---------------------------------------------------------

// The largest capture index under node n (Regexp.MaxCap).
recursive fn max_cap(v: View, n: i64) -> i64 {
    var m = 0;
    if v.nodes[n].op == OP_CAPTURE { m = v.nodes[n].cap; }
    for i in v.nodes[n].nsub as i64 {
        let k = max_cap(v, sub(v, n, i));
        if m < k { m = k; }
    }
    return m;
}

fn max_cap(re: const Regexp&) -> i64 { max_cap(view(re), re.root) }

// For each capture index under node n, the node of that capture.
recursive fn cap_nodes(v: View, n: i64, out: i64[:]) {
    if v.nodes[n].op == OP_CAPTURE { out[v.nodes[n].cap] = n; }
    for i in v.nodes[n].nsub as i64 { cap_nodes(v, sub(v, n, i), out); }
}

// The names of the capture groups under node n, indexed by capture
// index, "" for an unnamed one and for index 0 (Regexp.CapNames): views
// into the tree's names.
fn cap_names(v: View, n: i64) -> const u8[:][>..] {
    var at: i64[>..] = [];
    at.push_n(-1, max_cap(v, n) + 1);
    cap_nodes(v, n, at);
    var out: const u8[:][>..] = [];
    for k in at {
        if k < 0 { out.push(""); } else { out.push(name(v, k)); }
    }
    return out;
}

fn cap_names(re: const Regexp&) -> const u8[:][>..] { cap_names(view(re), re.root) }

// --- String ----------------------------------------------------------------------

let FLAG_I = 1;         // (?i:
let FLAG_M = 2;         // (?m:
let FLAG_S = 4;         // (?s:
let FLAG_OFF = 8;       // )
let FLAG_PREC = 16;     // (?: )
let NEG_SHIFT = 5;      // FLAG_I << NEG_SHIFT is (?-i:

// In a character class, whether r is one of its runes.
fn in_char_class(r: i64, class: const i32[:]) -> bool { in_pairs(r, class) }

fn add_span(start: i64, last: i64, f: i64, flags: i64[:]) {
    flags[start] = f;
    flags[last] |= FLAG_OFF;
}

// calcFlags: the print flags node n must and cannot be printed with,
// recording spans where they conflict in flags (indexed by node).
recursive fn calc_flags(v: View, n: i64, flags: i64[:]) -> i64, i64 {
    let nd = v.nodes[n];
    let op = nd.op as i64;
    if op == OP_LITERAL {
        for r in runes(v, n) {
            if MIN_FOLD <= r && r <= MAX_FOLD && simple_fold(r) != r {
                if nd.flags & FOLD_CASE != 0 { return FLAG_I, 0; }
                return 0, FLAG_I;
            }
        }
        return 0, 0;
    }
    if op == OP_CHAR_CLASS {
        let rs = runes(v, n);
        var i = 0;
        while i + 1 < rs.len {
            let lo = max(MIN_FOLD, rs[i] as i64);
            let hi = min(MAX_FOLD, rs[i + 1] as i64);
            var r = lo;
            while r <= hi {
                var f = simple_fold(r);
                while f != r {
                    if !(lo <= f && f <= hi) && !in_char_class(f, rs) { return 0, FLAG_I; }
                    f = simple_fold(f);
                }
                r++;
            }
            i += 2;
        }
        return 0, 0;
    }
    if op == OP_ANY_CHAR_NOT_NL { return 0, FLAG_S; }
    if op == OP_ANY_CHAR { return FLAG_S, 0; }
    if op == OP_BEGIN_LINE || op == OP_END_LINE { return FLAG_M, 0; }
    if op == OP_END_TEXT {
        if nd.flags & WAS_DOLLAR != 0 { return 0, FLAG_M; }
        return 0, 0;
    }
    if op == OP_CAPTURE || op == OP_STAR || op == OP_PLUS || op == OP_QUEST || op == OP_REPEAT {
        return calc_flags(v, sub(v, n, 0), flags);
    }
    if op == OP_CONCAT || op == OP_ALTERNATE {
        var must = 0;
        var cant = 0;
        var all_cant = 0;
        var start = 0;
        var last = 0;
        var did = false;
        for i in nd.nsub as i64 {
            let sub_must, sub_cant = calc_flags(v, sub(v, n, i), flags);
            if must & sub_cant != 0 || sub_must & cant != 0 {
                if must != 0 { add_span(sub(v, n, start), sub(v, n, last), must, flags); }
                must = 0;
                cant = 0;
                start = i;
                did = true;
            }
            must |= sub_must;
            cant |= sub_cant;
            all_cant |= sub_cant;
            if sub_must != 0 { last = i; }
            if must == 0 && start == i { start++; }
        }
        if !did { return must, cant; }
        if must != 0 { add_span(sub(v, n, start), sub(v, n, last), must, flags); }
        return 0, all_cant;
    }
    return 0, 0;
}

let META = "\\.+*?()|[]{}^$";

// syntax's escape: r as it is written in an expression.
fn escape(b: u8[>..]&, r: i64, force: bool) {
    if is_print(r) {
        if force || (r < 0x80 && contains(META, r as u8)) { b.push('\\'); }
        append_rune(b, r);
        return;
    }
    if r == 7 { b.append("\\a"); return; }
    if r == 12 { b.append("\\f"); return; }
    if r == '\n' { b.append("\\n"); return; }
    if r == '\r' { b.append("\\r"); return; }
    if r == '\t' { b.append("\\t"); return; }
    if r == 11 { b.append("\\v"); return; }
    if r >= 0 && r < 0x100 {
        b.append("\\x");
        if r < 0x10 { b.push('0'); }
        append_hex(b, r);
        return;
    }
    b.append("\\x{");
    append_hex(b, r);
    b.push('}');
}

// strconv.FormatInt(r, 16).
fn append_hex(b: u8[>..]&, r0: i64) {
    var r = r0;
    if r < 0 {
        b.push('-');
        r = -r;
    }
    var digits = 1;
    while digits < 16 && (r >> (digits * 4)) != 0 { digits++; }
    append_hex_digits(b, r, digits);
}

recursive fn write_regexp(b: u8[>..]&, v: View, n: i64, f0: i64, flags: i64[:]) {
    var f = f0 | flags[n];
    if f & FLAG_PREC != 0 && f & ~(FLAG_OFF | FLAG_PREC) != 0 && f & FLAG_OFF != 0 {
        f &= ~FLAG_PREC;
    }
    if f & ~(FLAG_OFF | FLAG_PREC) != 0 {
        b.append("(?");
        if f & FLAG_I != 0 { b.push('i'); }
        if f & FLAG_M != 0 { b.push('m'); }
        if f & FLAG_S != 0 { b.push('s'); }
        if f & ((FLAG_M | FLAG_S) << NEG_SHIFT) != 0 {
            b.push('-');
            if f & (FLAG_M << NEG_SHIFT) != 0 { b.push('m'); }
            if f & (FLAG_S << NEG_SHIFT) != 0 { b.push('s'); }
        }
        b.push(':');
    }
    var closes = 0;
    if f & FLAG_OFF != 0 { closes++; }
    if f & FLAG_PREC != 0 {
        b.append("(?:");
        closes++;
    }

    let nd = v.nodes[n];
    let op = nd.op as i64;
    if op == OP_NO_MATCH {
        b.append("[^\\x00-\\x{10FFFF}]");
    } else if op == OP_EMPTY_MATCH {
        b.append("(?:)");
    } else if op == OP_LITERAL {
        for r in runes(v, n) { escape(b, r, false); }
    } else if op == OP_CHAR_CLASS {
        let rs = runes(v, n);
        if rs.len % 2 != 0 {
            b.append("[invalid char class]");
        } else {
            b.push('[');
            if rs.len == 0 {
                b.append("^\\x00-\\x{10FFFF}");
            } else if rs[0] == 0 && rs[rs.len - 1] == MAX_RUNE && rs.len > 2 {
                // Contains 0 and MaxRune: probably a negated class. Print the gaps.
                b.push('^');
                var i = 1;
                while i < rs.len - 1 {
                    let lo = rs[i] as i64 + 1;
                    let hi = rs[i + 1] as i64 - 1;
                    escape(b, lo, lo == '-');
                    if lo != hi {
                        if hi != lo + 1 { b.push('-'); }
                        escape(b, hi, hi == '-');
                    }
                    i += 2;
                }
            } else {
                var i = 0;
                while i < rs.len {
                    let lo = rs[i] as i64;
                    let hi = rs[i + 1] as i64;
                    escape(b, lo, lo == '-');
                    if lo != hi {
                        if hi != lo + 1 { b.push('-'); }
                        escape(b, hi, hi == '-');
                    }
                    i += 2;
                }
            }
            b.push(']');
        }
    } else if op == OP_ANY_CHAR_NOT_NL || op == OP_ANY_CHAR {
        b.push('.');
    } else if op == OP_BEGIN_LINE {
        b.push('^');
    } else if op == OP_END_LINE {
        b.push('$');
    } else if op == OP_BEGIN_TEXT {
        b.append("\\A");
    } else if op == OP_END_TEXT {
        if nd.flags & WAS_DOLLAR != 0 { b.push('$'); } else { b.append("\\z"); }
    } else if op == OP_WORD_BOUNDARY {
        b.append("\\b");
    } else if op == OP_NO_WORD_BOUNDARY {
        b.append("\\B");
    } else if op == OP_CAPTURE {
        if nd.name_len > 0 {
            b.append("(?P<");
            b.append(name(v, n));
            b.push('>');
        } else {
            b.push('(');
        }
        let s = sub(v, n, 0);
        if v.nodes[s].op != OP_EMPTY_MATCH { write_regexp(b, v, s, flags[s], flags); }
        b.push(')');
    } else if op == OP_STAR || op == OP_PLUS || op == OP_QUEST || op == OP_REPEAT {
        var p = 0;
        let s = sub(v, n, 0);
        let sop = v.nodes[s].op as i64;
        if sop > OP_CAPTURE || (sop == OP_LITERAL && v.nodes[s].nrune > 1) { p = FLAG_PREC; }
        write_regexp(b, v, s, p, flags);
        if op == OP_STAR {
            b.push('*');
        } else if op == OP_PLUS {
            b.push('+');
        } else if op == OP_QUEST {
            b.push('?');
        } else {
            b.push('{');
            format(b, nd.min);
            if nd.max != nd.min {
                b.push(',');
                if nd.max >= 0 { format(b, nd.max); }
            }
            b.push('}');
        }
        if nd.flags & NON_GREEDY != 0 { b.push('?'); }
    } else if op == OP_CONCAT {
        for i in nd.nsub as i64 {
            let s = sub(v, n, i);
            let p = if v.nodes[s].op == OP_ALTERNATE { FLAG_PREC } else { 0 };
            write_regexp(b, v, s, p, flags);
        }
    } else if op == OP_ALTERNATE {
        for i in nd.nsub as i64 {
            if i > 0 { b.push('|'); }
            write_regexp(b, v, sub(v, n, i), 0, flags);
        }
    } else {
        format(b, "<invalid op", op, ">");
    }
    for k in closes { b.push(')'); }
}

// The expression node n stands for, in a form that parses back to it
// (Regexp.String), appended to b.
fn append_string(b: u8[>..]&, v: View, n: i64) {
    var flags: i64[>..] = [];
    flags.push_n(0, v.nodes.len);
    var must, cant = calc_flags(v, n, flags);
    must |= (cant & ~FLAG_I) << NEG_SHIFT;
    if must != 0 { must |= FLAG_OFF; }
    write_regexp(b, v, n, must, flags);
}

fn string(re: const Regexp&) -> u8[>..] {
    var b: u8[>..] = [];
    append_string(b, view(re), re.root);
    return b;
}

fn format(out: u8[>..]&, re: const Regexp&) { append_string(out, view(re), re.root); }

// --- Parse -------------------------------------------------------------------------

// Parses s under flags (Parse): the tree, and an error whose code is not
// 0 if s is not a valid expression (then the tree is empty).
fn parse(s: const u8[:], flags: i64) -> Regexp, Error {
    var nodes: Node[>..] = [];
    var subs: i32[>..] = [];
    var runes: i32[>..] = [];
    var names: u8[>..] = [];
    var pl = Pools { nodes: nodes, subs: subs, runes: runes, names: names };
    let root, err = parse_into(pl, s, flags);
    if err.code != 0 { return Regexp { root: -1, nodes: [], subs: [], runes: [], names: [] }, err; }
    return freeze(pl, root), err;
}
