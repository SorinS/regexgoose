// regexp.syntax: the parser, a port of Go's regexp/syntax/parse.go. It is
// the same stack machine: literals, classes and operators are pushed as
// they are read, concatenations and alternations are collapsed at `|` and
// `)`, and alternations are factored (common literal prefixes, common
// leading classes, runs of single characters merged into a class). Go's
// free list of nodes and its size and height caches are kept as Go keeps
// them, so that the limits (ErrLarge, ErrNestingDepth) trip where Go's do.

namespace syntax;

import std;
import syntax.tables;
import syntax.utf8;
import syntax.unicode;

let MAX_HEIGHT = 1000;
let MAX_SIZE = 3355443;         // 128 << 20 / instSize (5 * 8)
let MAX_RUNES = 33554432;       // 128 << 20 / runeSize (4)

struct Parser {
    nodes: Node[>..]&,
    subs: i32[>..]&,
    runes: i32[>..]&,
    names: u8[>..]&,
    stack: i64[>..<]&,      // the parse stack
    work: i64[>..<]&,       // lists of subexpressions being collapsed and factored, stacked
    cls: i64[>..<]&,        // the character class being built
    tmp: i64[>..<]&,        // parse.go's tmpClass
    keys: i64[>..<]&,       // for sorting class ranges
    size: i64[>..]&,        // calcSize's cache, per node; -1 for none
    height: i64[>..]&,      // calcHeight's cache, per node; -1 for none
    whole: const u8[:],     // the expression
    flags: i64,
    free: i64,              // the free list of nodes, -1 for empty; linked through min
    num_cap: i64,
    num_regexp: i64,        // nodes allocated (not reused)
    num_runes: i64,         // runes pushed
    repeats: i64,           // product of the repetitions seen
    has_size: bool,         // whether the size cache exists (Go's p.size != nil)
    has_height: bool,
}

// Parses s under flags into the pools (Parse): the root node, or -1 and
// the error.
fn parse_into(pl: Pools&, s: const u8[:], flags: i64) -> i64, Error {
    if flags & LITERAL != 0 {
        let bad = check_utf8(s, 0, s.len);
        if bad >= 0 { return -1, Error { code: ERR_INVALID_UTF8, expr: s[bad..] }; }
        return literal_regexp(pl, s, flags), no_error();
    }
    return parse_impl(pl, s, flags);
}

fn parse_impl(pl: Pools&, s: const u8[:], flags: i64) -> i64, Error {
    var stack: i64[>..<] = [];
    var work: i64[>..<] = [];
    var cls: i64[>..<] = [];
    var tmp: i64[>..<] = [];
    var keys: i64[>..<] = [];
    var size: i64[>..] = [];
    var height: i64[>..] = [];
    size.push_n(-1, pl.nodes.len);
    height.push_n(-1, pl.nodes.len);
    var p = Parser {
        nodes: pl.nodes, subs: pl.subs, runes: pl.runes, names: pl.names,
        stack: stack, work: work, cls: cls, tmp: tmp, keys: keys, size: size, height: height,
        whole: s, flags: flags, free: -1, num_cap: 0, num_regexp: 0, num_runes: 0, repeats: 0,
        has_size: false, has_height: false,
    };
    var pos = 0;
    var last_repeat = -1;       // where the repetition operator before this one began; -1 for none
    while pos < s.len {
        var repeat = -1;
        let c = s[pos];
        if c == '(' {
            if p.flags & PERL_X != 0 && pos + 1 < s.len && s[pos + 1] == '?' {
                // Flag changes and non-capturing groups.
                pos = parse_perl_flags(p, pos);
            } else {
                p.num_cap++;
                let n = op(p, OP_LEFT_PAREN);
                p.nodes[n].cap = p.num_cap as i32;
                pos++;
            }
        } else if c == '|' {
            parse_vertical_bar(p);
            pos++;
        } else if c == ')' {
            parse_right_paren(p);
            pos++;
        } else if c == '^' {
            if p.flags & ONE_LINE != 0 { op(p, OP_BEGIN_TEXT); } else { op(p, OP_BEGIN_LINE); }
            pos++;
        } else if c == '$' {
            if p.flags & ONE_LINE != 0 {
                let n = op(p, OP_END_TEXT);
                p.nodes[n].flags |= WAS_DOLLAR;
            } else {
                op(p, OP_END_LINE);
            }
            pos++;
        } else if c == '.' {
            if p.flags & DOT_NL != 0 { op(p, OP_ANY_CHAR); } else { op(p, OP_ANY_CHAR_NOT_NL); }
            pos++;
        } else if c == '[' {
            pos = parse_class(p, pos);
        } else if c == '*' || c == '+' || c == '?' {
            let o = if c == '*' { OP_STAR } else if c == '+' { OP_PLUS } else { OP_QUEST };
            let after = repeat_op(p, o, 0, 0, pos, pos + 1, last_repeat);
            repeat = pos;
            pos = after;
        } else if c == '{' {
            let lo, hi, after, ok = parse_repeat(s, pos);
            if !ok {
                // If the repeat cannot be parsed, { is a literal.
                literal(p, '{');
                pos++;
            } else {
                if lo < 0 || lo > 1000 || hi > 1000 || (hi >= 0 && lo > hi) {
                    // Numbers were too big, or max is present and min > max.
                    fail(p, ERR_INVALID_REPEAT_SIZE, pos, after);
                }
                let after2 = repeat_op(p, OP_REPEAT, lo, hi, pos, after, last_repeat);
                repeat = pos;
                pos = after2;
            }
        } else if c == '\\' {
            pos = parse_backslash(p, pos);
        } else {
            let r, next = next_rune(p, pos, s.len);
            literal(p, r);
            pos = next;
        }
        last_repeat = repeat;
    }

    concat(p);
    if swap_vertical_bar(p) {
        p.stack.pop();      // the vertical bar
    }
    alternate(p);
    if p.stack.len != 1 { fail(p, ERR_MISSING_PAREN, 0, s.len); }
    return p.stack[0], no_error();
}

// Ends the parse with an error whose expression is whole[lo..hi].
fn fail(p: const Parser&, code: i64, lo: i64, hi: i64) -> i64 {
    return -1, Error { code: code, expr: p.whole[lo..hi] } from parse_impl;
}

// A backslash outside a class, at pos: an anchor, \Q...\E, a class
// escape (\pN, \d) or a single character.
fn parse_backslash(p: Parser&, pos: i64) -> i64 {
    let s = p.whole;
    if p.flags & PERL_X != 0 && pos + 1 < s.len {
        let c = s[pos + 1];
        if c == 'A' { op(p, OP_BEGIN_TEXT); return pos + 2; }
        if c == 'b' { op(p, OP_WORD_BOUNDARY); return pos + 2; }
        if c == 'B' { op(p, OP_NO_WORD_BOUNDARY); return pos + 2; }
        if c == 'C' { return fail(p, ERR_INVALID_ESCAPE, pos, pos + 2); }     // any byte; not supported
        if c == 'Q' {
            // \Q ... \E: the ... is always literals.
            var lit_end = s.len;
            var rest = s.len;
            let k = find(s[pos + 2..], "\\E");
            if k >= 0 {
                lit_end = pos + 2 + k;
                rest = lit_end + 2;
            }
            var q = pos + 2;
            while q < lit_end {
                let r, next = next_rune(p, q, lit_end);
                literal(p, r);
                q = next;
            }
            return rest;
        }
        if c == 'z' { op(p, OP_END_TEXT); return pos + 2; }
    }

    let re = new_regexp(p, OP_CHAR_CLASS);
    p.nodes[re].flags = p.flags as i32;

    // A Unicode character group like \p{Han}.
    if pos + 1 < s.len && (s[pos + 1] == 'p' || s[pos + 1] == 'P') {
        p.cls.clear();
        let found, after = parse_unicode_class(p, pos);
        if found {
            store_class(p, re);
            push(p, re);
            return after;
        }
    }

    // A Perl character class escape.
    p.cls.clear();
    let found, after = parse_perl_class_escape(p, pos);
    if found {
        store_class(p, re);
        push(p, re);
        return after;
    }
    reuse(p, re);

    // An ordinary single-character escape.
    let r, next = parse_escape(p, pos);
    literal(p, r);
    return next;
}

// --- nodes -----------------------------------------------------------------------

fn new_regexp(p: Parser&, o: i64) -> i64 {
    var n = p.free;
    if n >= 0 {
        p.free = p.nodes[n].min;
        p.nodes[n] = new_node(o);
    } else {
        p.nodes.push(new_node(o));
        n = p.nodes.len - 1;
        p.num_regexp++;
        p.size.push(-1);
        p.height.push(-1);
    }
    return n;
}

fn reuse(p: Parser&, n: i64) {
    if p.has_height { p.height[n] = -1; }
    p.nodes[n].min = p.free as i32;
    p.free = n;
}

fn op_of(p: const Parser&, n: i64) -> i64 { p.nodes[n].op }
fn nrune(p: const Parser&, n: i64) -> i64 { p.nodes[n].nrune }
fn rune_at(p: const Parser&, n: i64, k: i64) -> i64 { p.runes[p.nodes[n].rune + k] }
fn sub_at(p: const Parser&, n: i64, k: i64) -> i64 { p.subs[p.nodes[n].sub + k] }

// Node n's runes become the single rune r.
fn set_one_rune(p: Parser&, n: i64, r: i64) {
    p.nodes[n].rune = p.runes.len as i32;
    p.nodes[n].nrune = 1;
    p.runes.push(r as i32);
}

// Appends r to node n's runes, moving them to the end of the pool first
// if they are not there.
fn push_rune(p: Parser&, n: i64, r: i64) {
    let off = p.nodes[n].rune as i64;
    let len = p.nodes[n].nrune as i64;
    if off + len != p.runes.len || len == 0 {
        let start = p.runes.len;
        for k in len { p.runes.push(p.runes[off + k]); }
        p.nodes[n].rune = start as i32;
    }
    p.runes.push(r as i32);
    p.nodes[n].nrune = (len + 1) as i32;
}

// Node n's runes become the class being built.
fn store_class(p: Parser&, n: i64) {
    p.nodes[n].rune = p.runes.len as i32;
    p.nodes[n].nrune = p.cls.len as i32;
    for x in p.cls { p.runes.push(x as i32); }
}

// The class being built becomes node n's runes.
fn load_class(p: Parser&, n: i64) {
    p.cls.clear();
    let off = p.nodes[n].rune as i64;
    for k in p.nodes[n].nrune as i64 { p.cls.push(p.runes[off + k]); }
}

// Node n's subexpressions become the list at work[base..base + count].
fn set_subs(p: Parser&, n: i64, base: i64, count: i64) {
    p.nodes[n].sub = p.subs.len as i32;
    p.nodes[n].nsub = count as i32;
    for k in count { p.subs.push(p.work[base + k] as i32); }
}

fn set_subs2(p: Parser&, n: i64, a: i64, b: i64) {
    p.nodes[n].sub = p.subs.len as i32;
    p.nodes[n].nsub = 2;
    p.subs.push(a as i32);
    p.subs.push(b as i32);
}

fn set_one_sub(p: Parser&, n: i64, a: i64) {
    p.nodes[n].sub = p.subs.len as i32;
    p.nodes[n].nsub = 1;
    p.subs.push(a as i32);
}

// --- limits ------------------------------------------------------------------------

fn check_limits(p: Parser&, n: i64) {
    if p.num_runes > MAX_RUNES { fail(p, ERR_LARGE, 0, p.whole.len); }
    check_size(p, n);
    check_height(p, n);
}

recursive fn check_size(p: Parser&, n: i64) {
    if !p.has_size {
        // Not tracking size yet: a cheap check of whether to start. Keep the
        // product of the repeats seen, and do not track while the number
        // of nodes times that product is in budget.
        if p.repeats == 0 { p.repeats = 1; }
        if p.nodes[n].op == OP_REPEAT {
            var k = p.nodes[n].max as i64;
            if k == -1 { k = p.nodes[n].min; }
            if k <= 0 { k = 1; }
            if k > MAX_SIZE / p.repeats { p.repeats = MAX_SIZE; } else { p.repeats *= k; }
        }
        if p.num_regexp < MAX_SIZE / p.repeats { return; }
        // Start tracking, with what has been built so far.
        p.has_size = true;
        for k in p.stack.len { check_size(p, p.stack[k]); }
    }
    if calc_size(p, n, true) > MAX_SIZE { fail(p, ERR_LARGE, 0, p.whole.len); }
}

recursive fn calc_size(p: Parser&, n: i64, force: bool) -> i64 {
    if !force && p.size[n] >= 0 { return p.size[n]; }
    var size = 0;
    let o = p.nodes[n].op as i64;
    if o == OP_LITERAL {
        size = p.nodes[n].nrune;
    } else if o == OP_CAPTURE || o == OP_STAR {
        // star can be 1+ or 2+; assume 2 pessimistically
        size = 2 + calc_size(p, sub_at(p, n, 0), false);
    } else if o == OP_PLUS || o == OP_QUEST {
        size = 1 + calc_size(p, sub_at(p, n, 0), false);
    } else if o == OP_CONCAT {
        for k in p.nodes[n].nsub as i64 { size += calc_size(p, sub_at(p, n, k), false); }
    } else if o == OP_ALTERNATE {
        let ns = p.nodes[n].nsub as i64;
        for k in ns { size += calc_size(p, sub_at(p, n, k), false); }
        if ns > 1 { size += ns - 1; }
    } else if o == OP_REPEAT {
        let sub = calc_size(p, sub_at(p, n, 0), false);
        let mx = p.nodes[n].max as i64;
        let mn = p.nodes[n].min as i64;
        if mx == -1 {
            if mn == 0 { size = 2 + sub; } else { size = 1 + mn * sub; }
        } else {
            // x{2,5} = xx(x(x(x)?)?)?
            size = mx * sub + (mx - mn);
        }
    }
    size = max(1, size);
    p.size[n] = size;
    return size;
}

recursive fn check_height(p: Parser&, n: i64) {
    if p.num_regexp < MAX_HEIGHT { return; }
    if !p.has_height {
        p.has_height = true;
        for k in p.stack.len { check_height(p, p.stack[k]); }
    }
    if calc_height(p, n, true) > MAX_HEIGHT { fail(p, ERR_NESTING_DEPTH, 0, p.whole.len); }
}

recursive fn calc_height(p: Parser&, n: i64, force: bool) -> i64 {
    if !force && p.height[n] >= 0 { return p.height[n]; }
    var h = 1;
    for k in p.nodes[n].nsub as i64 {
        let hsub = calc_height(p, sub_at(p, n, k), false);
        if h < 1 + hsub { h = 1 + hsub; }
    }
    p.height[n] = h;
    return h;
}

// --- the parse stack -----------------------------------------------------------------

// Pushes node n onto the parse stack, making a one-rune class a literal
// and gathering literals into strings; -1 when n was folded into the
// literal below it.
fn push(p: Parser&, n: i64) -> i64 {
    p.num_runes += p.nodes[n].nrune;
    let nd = p.nodes[n];
    let is_class = nd.op == OP_CHAR_CLASS;
    if is_class && nd.nrune == 2 && rune_at(p, n, 0) == rune_at(p, n, 1) {
        // Single rune.
        if maybe_concat(p, rune_at(p, n, 0), p.flags & ~FOLD_CASE) { return -1; }
        p.nodes[n].op = OP_LITERAL;
        p.nodes[n].nrune = 1;
        p.nodes[n].flags = (p.flags & ~FOLD_CASE) as i32;
    } else if is_class && ((nd.nrune == 4 && rune_at(p, n, 0) == rune_at(p, n, 1) && rune_at(p, n, 2) == rune_at(p, n, 3) &&
                             simple_fold(rune_at(p, n, 0)) == rune_at(p, n, 2) &&
                             simple_fold(rune_at(p, n, 2)) == rune_at(p, n, 0)) ||
                            (nd.nrune == 2 && rune_at(p, n, 0) + 1 == rune_at(p, n, 1) &&
                             simple_fold(rune_at(p, n, 0)) == rune_at(p, n, 1) &&
                             simple_fold(rune_at(p, n, 1)) == rune_at(p, n, 0))) {
        // Case-insensitive rune like [Aa] or [Δδ].
        if maybe_concat(p, rune_at(p, n, 0), p.flags | FOLD_CASE) { return -1; }
        // Rewrite as (case-insensitive) literal.
        p.nodes[n].op = OP_LITERAL;
        p.nodes[n].nrune = 1;
        p.nodes[n].flags = (p.flags | FOLD_CASE) as i32;
    } else {
        // Incremental concatenation.
        maybe_concat(p, -1, 0);
    }
    p.stack.push(n);
    check_limits(p, n);
    return n;
}

// Gathers the two literals on top of the stack into one, the
// incremental concatenation of literal runes into strings; then, with
// r >= 0, the top node left over becomes the literal r with the given
// flags. Whether r was pushed.
fn maybe_concat(p: Parser&, r: i64, flags: i64) -> bool {
    let n = p.stack.len;
    if n < 2 { return false; }
    let re1 = p.stack[n - 1];
    let re2 = p.stack[n - 2];
    if p.nodes[re1].op != OP_LITERAL || p.nodes[re2].op != OP_LITERAL ||
       p.nodes[re1].flags & FOLD_CASE != p.nodes[re2].flags & FOLD_CASE {
        return false;
    }
    // Push re1 into re2.
    for k in p.nodes[re1].nrune as i64 { push_rune(p, re2, rune_at(p, re1, k)); }
    // Reuse re1 if possible.
    if r >= 0 {
        set_one_rune(p, re1, r);
        p.nodes[re1].flags = flags as i32;
        return true;
    }
    p.stack.pop();
    reuse(p, re1);
    return false;
}

// Pushes the literal r.
fn literal(p: Parser&, r0: i64) {
    let n = new_regexp(p, OP_LITERAL);
    p.nodes[n].flags = p.flags as i32;
    var r = r0;
    if p.flags & FOLD_CASE != 0 { r = min_fold_rune(r); }
    set_one_rune(p, n, r);
    push(p, n);
}

// The least rune fold-equivalent to r.
fn min_fold_rune(r0: i64) -> i64 {
    if r0 < MIN_FOLD || r0 > MAX_FOLD { return r0; }
    var m = r0;
    var r = simple_fold(r0);
    while r != r0 {
        m = min(m, r);
        r = simple_fold(r);
    }
    return m;
}

// Pushes a node of operator o.
fn op(p: Parser&, o: i64) -> i64 {
    let n = new_regexp(p, o);
    p.nodes[n].flags = p.flags as i32;
    return push(p, n);
}

// Replaces the top of the stack with itself repeated (o, lo, hi). The
// operator is at whole[before..after]; last_repeat, if not -1, is where
// the repetition just before it began. Returns where the parse goes on.
fn repeat_op(p: Parser&, o: i64, lo: i64, hi: i64, before: i64, after0: i64, last_repeat: i64) -> i64 {
    var after = after0;
    var flags = p.flags;
    if p.flags & PERL_X != 0 {
        if after < p.whole.len && p.whole[after] == '?' {
            after++;
            flags ^= NON_GREEDY;
        }
        if last_repeat >= 0 {
            // In Perl it is not allowed to stack repetition operators:
            // a** is a syntax error, not a doubled star, and a++ means
            // something else entirely, which is not supported.
            fail(p, ERR_INVALID_REPEAT_OP, last_repeat, after);
        }
    }
    let n = p.stack.len;
    if n == 0 { fail(p, ERR_MISSING_REPEAT_ARGUMENT, before, after); }
    let sub = p.stack[n - 1];
    if p.nodes[sub].op >= OP_PSEUDO { fail(p, ERR_MISSING_REPEAT_ARGUMENT, before, after); }

    let re = new_regexp(p, o);
    p.nodes[re].min = lo as i32;
    p.nodes[re].max = hi as i32;
    p.nodes[re].flags = flags as i32;
    set_one_sub(p, re, sub);
    p.stack[n - 1] = re;
    check_limits(p, re);

    if o == OP_REPEAT && (lo >= 2 || hi >= 2) && !repeat_is_valid(view(p), re, 1000) {
        fail(p, ERR_INVALID_REPEAT_SIZE, before, after);
    }
    return after;
}

fn view(p: const Parser&) -> View {
    View { nodes: p.nodes, subs: p.subs, runes: p.runes, names: p.names }
}

// Whether the repetitions in node n, nested, make at most k copies of
// the innermost thing.
recursive fn repeat_is_valid(v: View, n: i64, k0: i64) -> bool {
    var k = k0;
    let nd = v.nodes[n];
    if nd.op == OP_REPEAT {
        var m = nd.max as i64;
        if m == 0 { return true; }
        if m < 0 { m = nd.min; }
        if m > k { return false; }
        if m > 0 { k /= m; }
    }
    for i in nd.nsub as i64 {
        if !repeat_is_valid(v, sub(v, n, i), k) { return false; }
    }
    return true;
}

// The start of the run of real nodes on top of the stack, above the
// topmost `|` or `(`.
fn stack_run(p: const Parser&) -> i64 {
    var i = p.stack.len;
    while i > 0 && p.nodes[p.stack[i - 1]].op < OP_PSEUDO { i--; }
    return i;
}

// Moves stack[i..] to the top of work, returning where it starts there.
fn stack_to_work(p: Parser&, i: i64) -> i64 {
    let base = p.work.len;
    for k in i..p.stack.len { p.work.push(p.stack[k]); }
    p.stack.resize(i);
    return base;
}

// Replaces the top of the stack (above the topmost `|` or `(`) with its
// concatenation.
fn concat(p: Parser&) -> i64 {
    maybe_concat(p, -1, 0);
    let i = stack_run(p);
    let n = p.stack.len - i;
    if n == 0 {
        // Empty concatenation is special case.
        return push(p, new_regexp(p, OP_EMPTY_MATCH));
    }
    let base = stack_to_work(p, i);
    let r = collapse(p, base, n, OP_CONCAT);
    p.work.resize(base);
    return push(p, r);
}

// Replaces the top of the stack (above the topmost `(`) with its
// alternation.
fn alternate(p: Parser&) -> i64 {
    // There are no | above (.
    let i = stack_run(p);
    let n = p.stack.len - i;
    // Make sure top class is clean; the others already are (see
    // swap_vertical_bar).
    if n > 0 { clean_alt(p, p.stack[p.stack.len - 1]); }
    if n == 0 {
        // Empty alternate is special case (shouldn't happen but easy to handle).
        return push(p, new_regexp(p, OP_NO_MATCH));
    }
    let base = stack_to_work(p, i);
    let r = collapse(p, base, n, OP_ALTERNATE);
    p.work.resize(base);
    return push(p, r);
}

// Cleans node n for eventual inclusion in an alternation.
fn clean_alt(p: Parser&, n: i64) {
    if p.nodes[n].op != OP_CHAR_CLASS { return; }
    load_class(p, n);
    clean_class(p.cls, p.keys);
    // Back in place: the class can only have shrunk.
    let off = p.nodes[n].rune as i64;
    for k in p.cls.len { p.runes[off + k] = p.cls[k] as i32; }
    p.nodes[n].nrune = p.cls.len as i32;
    let c = p.cls;
    if c.len == 2 && c[0] == 0 && c[1] == MAX_RUNE {
        p.nodes[n].nrune = 0;
        p.nodes[n].op = OP_ANY_CHAR;
        return;
    }
    if c.len == 4 && c[0] == 0 && c[1] == '\n' - 1 && c[2] == '\n' + 1 && c[3] == MAX_RUNE {
        p.nodes[n].nrune = 0;
        p.nodes[n].op = OP_ANY_CHAR_NOT_NL;
        return;
    }
}

// The node applying operator o (concatenation or alternation) to the
// list work[base..base + count]. Subexpressions that are themselves o are
// hoisted, so that there is never a concatenation of a concatenation or
// an alternation of an alternation, and an alternation is factored.
recursive fn collapse(p: Parser&, base: i64, count: i64, o: i64) -> i64 {
    if count == 1 { return p.work[base]; }
    var re = new_regexp(p, o);
    let mark = p.work.len;
    for k in count {
        let s = p.work[base + k];
        if p.nodes[s].op == o {
            for j in p.nodes[s].nsub as i64 { p.work.push(sub_at(p, s, j)); }
            reuse(p, s);
        } else {
            p.work.push(s);
        }
    }
    var n = p.work.len - mark;
    if o == OP_ALTERNATE { n = factor(p, mark, n); }
    set_subs(p, re, mark, n);
    p.work.resize(mark);
    if o == OP_ALTERNATE && n == 1 {
        let old = re;
        re = sub_at(p, re, 0);
        reuse(p, old);
    }
    return re;
}

// Factors common prefixes out of the alternation list
// work[base..base + count], in place, and returns its new length.
// For example,
//
//	ABC|ABD|AEF|BCX|BCY
//
// simplifies by literal prefix extraction to
//
//	A(B(C|D)|EF)|BC(X|Y)
//
// which simplifies by character class introduction to
//
//	A(B[CD]|EF)|BC[XY]
recursive fn factor(p: Parser&, base: i64, count: i64) -> i64 {
    if count < 2 { return count; }
    var len = count;

    // Round 1: factor out common literal prefixes. The current prefix is
    // str_len runes at str_off in the rune pool.
    var str_off = 0;
    var str_len = 0;
    var strflags = 0;
    var start = 0;
    var out = 0;
    for i in 0..len + 1 {
        // Invariant: work[base + start..base + i] all begin with the prefix.
        var istr_off = 0;
        var istr_len = 0;
        var iflags = 0;
        if i < len {
            istr_off, istr_len, iflags = leading_string(p, p.work[base + i]);
            if iflags == strflags {
                var same = 0;
                while same < str_len && same < istr_len && p.runes[str_off + same] == p.runes[istr_off + same] { same++; }
                if same > 0 {
                    // Matches at least one rune in current range. Keep going around.
                    str_len = same;
                    continue;
                }
            }
        }
        // The run work[start..i] all begin with the prefix, but item i does
        // not even begin with its first rune: factor it out.
        if i == start {
            // Nothing to do - run of length 0.
        } else if i == start + 1 {
            // Just one: don't bother factoring.
            p.work[base + out] = p.work[base + start];
            out++;
        } else {
            // Construct factored form: prefix(suffix1|suffix2|...)
            let prefix = new_regexp(p, OP_LITERAL);
            p.nodes[prefix].flags = strflags as i32;
            p.nodes[prefix].rune = p.runes.len as i32;
            p.nodes[prefix].nrune = str_len as i32;
            for k in str_len { p.runes.push(p.runes[str_off + k]); }
            for j in start..i {
                let r = remove_leading_string(p, p.work[base + j], str_len);
                p.work[base + j] = r;
                check_limits(p, r);
            }
            let suffix = collapse(p, base + start, i - start, OP_ALTERNATE);   // recurse
            let re = new_regexp(p, OP_CONCAT);
            set_subs2(p, re, prefix, suffix);
            p.work[base + out] = re;
            out++;
        }
        // Prepare for next iteration.
        start = i;
        str_off = istr_off;
        str_len = istr_len;
        strflags = iflags;
    }
    len = out;

    // Round 2: factor out common simple prefixes, just the first piece of
    // each concatenation. This will be good enough a lot of the time.
    //
    // Complex subexpressions (e.g. involving quantifiers) are not safe to
    // factor because that collapses their distinct paths through the
    // automaton, which affects correctness in some cases.
    start = 0;
    out = 0;
    var first = -1;
    for i in 0..len + 1 {
        // Invariant: work[start..i] all begin with first.
        var ifirst = -1;
        if i < len {
            ifirst = leading_regexp(p, p.work[base + i]);
            if first >= 0 && equal(view(p), first, view(p), ifirst) &&
               // first must be a character class OR a fixed repeat of a character class.
               (is_char_class(p, first) ||
                (p.nodes[first].op == OP_REPEAT && p.nodes[first].min == p.nodes[first].max &&
                 is_char_class(p, sub_at(p, first, 0)))) {
                continue;
            }
        }
        if i == start {
            // Nothing to do - run of length 0.
        } else if i == start + 1 {
            p.work[base + out] = p.work[base + start];
            out++;
        } else {
            let prefix = first;
            for j in start..i {
                let reuse_it = j != start;      // prefix came from item start
                let r = remove_leading_regexp(p, p.work[base + j], reuse_it);
                p.work[base + j] = r;
                check_limits(p, r);
            }
            let suffix = collapse(p, base + start, i - start, OP_ALTERNATE);   // recurse
            let re = new_regexp(p, OP_CONCAT);
            set_subs2(p, re, prefix, suffix);
            p.work[base + out] = re;
            out++;
        }
        start = i;
        first = ifirst;
    }
    len = out;

    // Round 3: collapse runs of single literals into character classes.
    start = 0;
    out = 0;
    for i in 0..len + 1 {
        // Invariant: work[start..i] are literal runes or character classes.
        if i < len && is_char_class(p, p.work[base + i]) { continue; }
        // Item i is not a char or char class; emit a class for work[start..i]...
        if i == start {
            // Nothing to do - run of length 0.
        } else if i == start + 1 {
            p.work[base + out] = p.work[base + start];
            out++;
        } else {
            // Make new char class. Start with most complex regexp in item start.
            var mx = start;
            for j in start + 1..i {
                let a = p.work[base + mx];
                let b = p.work[base + j];
                if p.nodes[a].op < p.nodes[b].op || (p.nodes[a].op == p.nodes[b].op && p.nodes[a].nrune < p.nodes[b].nrune) {
                    mx = j;
                }
            }
            let t = p.work[base + start];
            p.work[base + start] = p.work[base + mx];
            p.work[base + mx] = t;
            let dst = p.work[base + start];
            for j in start + 1..i {
                merge_char_class(p, dst, p.work[base + j]);
                reuse(p, p.work[base + j]);
            }
            clean_alt(p, dst);
            p.work[base + out] = dst;
            out++;
        }
        // ... and then emit item i.
        if i < len {
            p.work[base + out] = p.work[base + i];
            out++;
        }
        start = i + 1;
    }
    len = out;

    // Round 4: collapse runs of empty matches into a single empty match.
    out = 0;
    for i in len {
        if i + 1 < len && p.nodes[p.work[base + i]].op == OP_EMPTY_MATCH &&
           p.nodes[p.work[base + i + 1]].op == OP_EMPTY_MATCH {
            continue;
        }
        p.work[base + out] = p.work[base + i];
        out++;
    }
    return out;
}

// The leading literal string node n begins with: its runes' offset in
// the pool, their count, and the fold flag.
fn leading_string(p: const Parser&, n0: i64) -> i64, i64, i64 {
    var n = n0;
    if p.nodes[n].op == OP_CONCAT && p.nodes[n].nsub > 0 { n = sub_at(p, n, 0); }
    if p.nodes[n].op != OP_LITERAL { return 0, 0, 0; }
    return p.nodes[n].rune, p.nodes[n].nrune, p.nodes[n].flags & FOLD_CASE;
}

// Removes the first k runes from the beginning of node n; returns the
// replacement for n.
recursive fn remove_leading_string(p: Parser&, n0: i64, k: i64) -> i64 {
    var n = n0;
    if p.nodes[n].op == OP_CONCAT && p.nodes[n].nsub > 0 {
        // Removing a leading string in a concatenation might simplify the
        // concatenation.
        let s = remove_leading_string(p, sub_at(p, n, 0), k);
        p.subs[p.nodes[n].sub] = s as i32;
        if p.nodes[s].op == OP_EMPTY_MATCH {
            reuse(p, s);
            let ns = p.nodes[n].nsub as i64;
            if ns <= 1 {
                // Impossible but handle.
                p.nodes[n].op = OP_EMPTY_MATCH;
                p.nodes[n].nsub = 0;
            } else if ns == 2 {
                let old = n;
                n = sub_at(p, n, 1);
                reuse(p, old);
            } else {
                let off = p.nodes[n].sub as i64;
                for j in 0..ns - 1 { p.subs[off + j] = p.subs[off + j + 1]; }
                p.nodes[n].nsub = (ns - 1) as i32;
            }
        }
        return n;
    }
    if p.nodes[n].op == OP_LITERAL {
        let off = p.nodes[n].rune as i64;
        let len = p.nodes[n].nrune as i64;
        let keep = max(len - k, 0);
        for j in keep { p.runes[off + j] = p.runes[off + k + j]; }
        p.nodes[n].nrune = keep as i32;
        if keep == 0 { p.nodes[n].op = OP_EMPTY_MATCH; }
    }
    return n;
}

// The leading regexp node n begins with, -1 for none.
fn leading_regexp(p: const Parser&, n: i64) -> i64 {
    if p.nodes[n].op == OP_EMPTY_MATCH { return -1; }
    if p.nodes[n].op == OP_CONCAT && p.nodes[n].nsub > 0 {
        let s = sub_at(p, n, 0);
        if p.nodes[s].op == OP_EMPTY_MATCH { return -1; }
        return s;
    }
    return n;
}

// Removes the leading regexp in node n, handing it to reuse if reuse_it;
// returns the replacement for n.
fn remove_leading_regexp(p: Parser&, n: i64, reuse_it: bool) -> i64 {
    if p.nodes[n].op == OP_CONCAT && p.nodes[n].nsub > 0 {
        if reuse_it { reuse(p, sub_at(p, n, 0)); }
        let off = p.nodes[n].sub as i64;
        let ns = p.nodes[n].nsub as i64 - 1;
        for j in ns { p.subs[off + j] = p.subs[off + j + 1]; }
        p.nodes[n].nsub = ns as i32;
        if ns == 0 {
            p.nodes[n].op = OP_EMPTY_MATCH;
        } else if ns == 1 {
            let r = sub_at(p, n, 0);
            reuse(p, n);
            return r;
        }
        return n;
    }
    if reuse_it { reuse(p, n); }
    return new_regexp(p, OP_EMPTY_MATCH);
}

// A literal node of all of s (parse with LITERAL).
fn literal_regexp(pl: Pools&, s: const u8[:], flags: i64) -> i64 {
    var nd = new_node(OP_LITERAL);
    nd.flags = flags as i32;
    nd.rune = pl.runes.len as i32;
    var pos = 0;
    while pos < s.len {
        let r, w = decode_rune(s, pos);
        pl.runes.push(r);
        pos += w;
    }
    nd.nrune = (pl.runes.len - nd.rune) as i32;
    pl.nodes.push(nd);
    return pl.nodes.len - 1;
}

// --- syntax ------------------------------------------------------------------------

// Parses {min} (max = min), {min,} (max = -1) or {min,max} at s[pos]:
// min, max, where it ends, and whether it has that form. A form whose
// numbers are too big gives min -1.
fn parse_repeat(s: const u8[:], pos: i64) -> i64, i64, i64, bool {
    if pos >= s.len || s[pos] != '{' { return 0, 0, pos, false; }
    var t = pos + 1;
    var lo, t1, ok1 = parse_int(s, t);
    if !ok1 { return 0, 0, pos, false; }
    t = t1;
    if t >= s.len { return 0, 0, pos, false; }
    var hi = 0;
    if s[t] != ',' {
        hi = lo;
    } else {
        t++;
        if t >= s.len { return 0, 0, pos, false; }
        if s[t] == '}' {
            hi = -1;
        } else {
            let h, t2, ok2 = parse_int(s, t);
            if !ok2 { return 0, 0, pos, false; }
            hi = h;
            t = t2;
            if hi < 0 {
                // parse_int found too big a number
                lo = -1;
            }
        }
    }
    if t >= s.len || s[t] != '}' { return 0, 0, pos, false; }
    return lo, hi, t + 1, true;
}

// A decimal integer at s[pos], without leading zeros: its value (-1 if
// too big), where it ends, and whether there was one.
fn parse_int(s: const u8[:], pos: i64) -> i64, i64, bool {
    if pos >= s.len || s[pos] < '0' || '9' < s[pos] { return 0, pos, false; }
    // Disallow leading zeros.
    if s.len - pos >= 2 && s[pos] == '0' && '0' <= s[pos + 1] && s[pos + 1] <= '9' { return 0, pos, false; }
    var t = pos;
    while t < s.len && '0' <= s[t] && s[t] <= '9' { t++; }
    var n = 0;
    for i in pos..t {
        // Avoid overflow.
        if n >= 100000000 {
            n = -1;
            break;
        }
        n = n * 10 + (s[i] - '0');
    }
    return n, t, true;
}

// A Perl flag setting or non-capturing group or both, at whole[pos]
// ("(?"), like (?i) or (?: or (?i:, or a named group (?P<name> or
// (?<name>; returns where the parse goes on.
fn parse_perl_flags(p: Parser&, pos: i64) -> i64 {
    let s = p.whole;
    let left = s.len - pos;
    let starts_with_p = left > 4 && s[pos + 2] == 'P' && s[pos + 3] == '<';
    let starts_with_name = left > 3 && s[pos + 2] == '<';
    if starts_with_p || starts_with_name {
        let expr_start = if starts_with_name { pos + 3 } else { pos + 4 };
        // Pull out name.
        let k = find(s[pos..], ">");
        if k < 0 {
            let bad = check_utf8(s, pos, s.len);
            if bad >= 0 { fail(p, ERR_INVALID_UTF8, bad, s.len); }
            fail(p, ERR_INVALID_NAMED_CAPTURE, pos, s.len);
        }
        let end = pos + k;
        let bad = check_utf8(s, expr_start, end);
        if bad >= 0 { fail(p, ERR_INVALID_UTF8, bad, end); }
        if !is_valid_capture_name(s[expr_start..end]) { fail(p, ERR_INVALID_NAMED_CAPTURE, pos, end + 1); }
        // Like ordinary capture, but named.
        p.num_cap++;
        let re = op(p, OP_LEFT_PAREN);
        p.nodes[re].cap = p.num_cap as i32;
        p.nodes[re].name = p.names.len as i32;
        p.nodes[re].name_len = (end - expr_start) as i32;
        p.names.append(s[expr_start..end]);
        return end + 1;
    }

    // Non-capturing group. Might also twiddle Perl flags.
    var t = pos + 2;
    var flags = p.flags;
    var sign = 1;
    var saw_flag = false;
    while t < s.len {
        let c, next = next_rune(p, t, s.len);
        t = next;
        if c == 'i' {
            flags |= FOLD_CASE;
            saw_flag = true;
        } else if c == 'm' {
            flags &= ~ONE_LINE;
            saw_flag = true;
        } else if c == 's' {
            flags |= DOT_NL;
            saw_flag = true;
        } else if c == 'U' {
            flags |= NON_GREEDY;
            saw_flag = true;
        } else if c == '-' {
            // Switch to negation.
            if sign < 0 { break; }
            sign = -1;
            // Invert flags so that | above turn into &^ and vice versa.
            // They are inverted again before use below.
            flags = ~flags;
            saw_flag = false;
        } else if c == ':' || c == ')' {
            // End of flags, starting group or not.
            if sign < 0 {
                if !saw_flag { break; }
                flags = ~flags;
            }
            if c == ':' {
                // Open new group
                op(p, OP_LEFT_PAREN);
            }
            p.flags = flags;
            return t;
        } else {
            break;
        }
    }
    return fail(p, ERR_INVALID_PERL_OP, pos, t);
}

// Whether name is a valid capture name: [A-Za-z0-9_]+.
fn is_valid_capture_name(name: const u8[:]) -> bool {
    if name.len == 0 { return false; }
    for c in name {
        if c != '_' && !is_alnum(c) { return false; }
    }
    return true;
}

fn is_alnum(c: i64) -> bool { ('0' <= c && c <= '9') || ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z') }

// Whether node n can be a character class: a single-rune literal, a
// class, . or (?s).
fn is_char_class(p: const Parser&, n: i64) -> bool {
    let o = p.nodes[n].op as i64;
    return (o == OP_LITERAL && p.nodes[n].nrune == 1) || o == OP_CHAR_CLASS || o == OP_ANY_CHAR_NOT_NL || o == OP_ANY_CHAR;
}

// Whether node n matches r.
fn match_rune(p: const Parser&, n: i64, r: i64) -> bool {
    let o = p.nodes[n].op as i64;
    if o == OP_LITERAL { return p.nodes[n].nrune == 1 && rune_at(p, n, 0) == r; }
    if o == OP_CHAR_CLASS {
        var i = 0;
        let len = p.nodes[n].nrune as i64;
        while i + 1 < len {
            if rune_at(p, n, i) <= r && r <= rune_at(p, n, i + 1) { return true; }
            i += 2;
        }
        return false;
    }
    if o == OP_ANY_CHAR_NOT_NL { return r != '\n'; }
    if o == OP_ANY_CHAR { return true; }
    return false;
}

// Handles a | in the input.
fn parse_vertical_bar(p: Parser&) {
    concat(p);
    // The concatenation just parsed is on top of the stack. If it sits
    // above a `|`, swap it below (things below a `|` become an
    // alternation). Otherwise, push a new `|`.
    if !swap_vertical_bar(p) { op(p, OP_VERTICAL_BAR); }
}

// Makes dst = dst|src. The caller ensures that dst's operator is at least
// src's, to reduce the amount of copying.
fn merge_char_class(p: Parser&, dst: i64, src: i64) {
    let o = p.nodes[dst].op as i64;
    if o == OP_ANY_CHAR {
        // src doesn't add anything.
    } else if o == OP_ANY_CHAR_NOT_NL {
        // src might add \n
        if match_rune(p, src, '\n') { p.nodes[dst].op = OP_ANY_CHAR; }
    } else if o == OP_CHAR_CLASS {
        // src is simpler, so either literal or char class
        load_class(p, dst);
        if p.nodes[src].op == OP_LITERAL {
            append_literal(p.cls, rune_at(p, src, 0), p.nodes[src].flags);
        } else {
            let off = p.nodes[src].rune as i64;
            append_class(p.cls, p.runes[off..off + p.nodes[src].nrune]);
        }
        store_class(p, dst);
    } else if o == OP_LITERAL {
        // both literal
        if rune_at(p, src, 0) == rune_at(p, dst, 0) && p.nodes[src].flags == p.nodes[dst].flags { return; }
        p.nodes[dst].op = OP_CHAR_CLASS;
        p.cls.clear();
        append_literal(p.cls, rune_at(p, dst, 0), p.nodes[dst].flags);
        append_literal(p.cls, rune_at(p, src, 0), p.nodes[src].flags);
        store_class(p, dst);
    }
}

// If the top of the stack is an element followed by a `|`, swaps the
// two and returns true; otherwise false.
fn swap_vertical_bar(p: Parser&) -> bool {
    // If above and below vertical bar are literal or char class, can merge
    // into a single char class.
    let n = p.stack.len;
    if n >= 3 && p.nodes[p.stack[n - 2]].op == OP_VERTICAL_BAR && is_char_class(p, p.stack[n - 1]) &&
       is_char_class(p, p.stack[n - 3]) {
        var re1 = p.stack[n - 1];
        var re3 = p.stack[n - 3];
        // Make re3 the more complex of the two.
        if p.nodes[re1].op > p.nodes[re3].op {
            let t = re1;
            re1 = re3;
            re3 = t;
            p.stack[n - 3] = re3;
        }
        merge_char_class(p, re3, re1);
        reuse(p, re1);
        p.stack.pop();
        return true;
    }
    if n >= 2 {
        let re1 = p.stack[n - 1];
        let re2 = p.stack[n - 2];
        if p.nodes[re2].op == OP_VERTICAL_BAR {
            if n >= 3 {
                // Now out of reach. Clean opportunistically.
                clean_alt(p, p.stack[n - 3]);
            }
            p.stack[n - 2] = re1;
            p.stack[n - 1] = re2;
            return true;
        }
    }
    return false;
}

// Handles a ) in the input.
fn parse_right_paren(p: Parser&) {
    concat(p);
    if swap_vertical_bar(p) {
        p.stack.pop();      // the vertical bar
    }
    alternate(p);
    let n = p.stack.len;
    if n < 2 { fail(p, ERR_UNEXPECTED_PAREN, 0, p.whole.len); }
    let re1 = p.stack[n - 1];
    let re2 = p.stack[n - 2];
    p.stack.resize(n - 2);
    if p.nodes[re2].op != OP_LEFT_PAREN { fail(p, ERR_UNEXPECTED_PAREN, 0, p.whole.len); }
    // Restore flags at time of paren.
    p.flags = p.nodes[re2].flags;
    if p.nodes[re2].cap == 0 {
        // Just for grouping.
        push(p, re1);
    } else {
        p.nodes[re2].op = OP_CAPTURE;
        set_one_sub(p, re2, re1);
        push(p, re2);
    }
}

// The rune at whole[pos] and where the next begins, (RUNE_ERROR, end) at
// end; invalid UTF-8 ends the parse, its expression running from pos to
// end.
fn next_rune(p: const Parser&, pos: i64, end: i64) -> i64, i64 {
    if pos >= end { return RUNE_ERROR, end; }
    let c, size = decode_rune(p.whole[..end], pos);
    if c == RUNE_ERROR && size == 1 { fail(p, ERR_INVALID_UTF8, pos, end); }
    return c, pos + size;
}

// Where s[from..to] first fails to be UTF-8; -1 if it is UTF-8.
fn check_utf8(s: const u8[:], from: i64, to: i64) -> i64 {
    var pos = from;
    while pos < to {
        let r, size = decode_rune(s[..to], pos);
        if r == RUNE_ERROR && size == 1 { return pos; }
        pos += size;
    }
    return -1;
}

fn unhex(c: i64) -> i64 {
    if '0' <= c && c <= '9' { return c - '0'; }
    if 'a' <= c && c <= 'f' { return c - 'a' + 10; }
    if 'A' <= c && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

// An escape sequence at whole[pos] (a backslash): its rune and where the
// parse goes on.
fn parse_escape(p: const Parser&, pos: i64) -> i64, i64 {
    let s = p.whole;
    var t = pos + 1;
    if t >= s.len { fail(p, ERR_TRAILING_BACKSLASH, 0, 0); }
    var c, t1 = next_rune(p, t, s.len);
    t = t1;
    block {
        if c == '1' || c == '2' || c == '3' || c == '4' || c == '5' || c == '6' || c == '7' || c == '0' {
            // Octal escapes. A single non-zero digit is a backreference;
            // not supported.
            if c != '0' && (t >= s.len || s[t] < '0' || s[t] > '7') { break; }
            // Consume up to three octal digits; already have one.
            var r = c - '0';
            for i in 1..3 {
                if t >= s.len || s[t] < '0' || s[t] > '7' { break; }
                r = r * 8 + (s[t] - '0');
                t++;
            }
            return r, t;
        }
        if c == 'x' {
            // Hexadecimal escapes.
            if t >= s.len { break; }
            c, t1 = next_rune(p, t, s.len);
            t = t1;
            if c == '{' {
                // Any number of digits in braces. Perl accepts any text at
                // all; it ignores all text after the first non-hex digit.
                // Only hex digits are allowed here, and at least one.
                var nhex = 0;
                var r = 0;
                var closed = false;
                loop {
                    if t >= s.len { break; }
                    c, t1 = next_rune(p, t, s.len);
                    t = t1;
                    if c == '}' {
                        closed = true;
                        break;
                    }
                    let v = unhex(c);
                    if v < 0 { break; }
                    r = r * 16 + v;
                    if r > MAX_RUNE { break; }
                    nhex++;
                }
                if !closed || nhex == 0 { break; }
                return r, t;
            }
            // Easy case: two hex digits.
            let x = unhex(c);
            c, t1 = next_rune(p, t, s.len);
            t = t1;
            let y = unhex(c);
            if x < 0 || y < 0 { break; }
            return x * 16 + y, t;
        }
        // C escapes. There is no case 'b', to avoid misparsing the Perl
        // word-boundary \b as the C backspace \b when in POSIX mode.
        if c == 'a' { return 7, t; }
        if c == 'f' { return 12, t; }
        if c == 'n' { return '\n', t; }
        if c == 'r' { return '\r', t; }
        if c == 't' { return '\t', t; }
        if c == 'v' { return 11, t; }
        if c < RUNE_SELF && !is_alnum(c) {
            // Escaped non-word characters are always themselves.
            return c, t;
        }
    };
    return fail(p, ERR_INVALID_ESCAPE, pos, t), t;
}

// A class character at whole[pos], escape or not; class_start is where
// the whole class began, for the error a missing ] gives.
fn parse_class_char(p: const Parser&, pos: i64, class_start: i64) -> i64, i64 {
    let s = p.whole;
    if pos >= s.len { fail(p, ERR_MISSING_BRACKET, class_start, s.len); }
    // Allow regular escape sequences even though many need not be escaped
    // in this context.
    if s[pos] == '\\' { return parse_escape(p, pos); }
    return next_rune(p, pos, s.len);
}

// A Perl class escape like \d at whole[pos], appended to the class being
// built: whether there was one, and where it ends.
fn parse_perl_class_escape(p: Parser&, pos: i64) -> bool, i64 {
    let s = p.whole;
    if p.flags & PERL_X == 0 || s.len - pos < 2 || s[pos] != '\\' { return false, pos; }
    let sign, tab = char_group(s[pos..pos + 2], false);
    if sign == 0 { return false, pos; }
    append_group(p, sign, tab);
    return true, pos + 2;
}

// A POSIX class like [:alnum:] at whole[pos], appended to the class
// being built: whether there was one, and where it ends.
fn parse_named_class(p: Parser&, pos: i64) -> bool, i64 {
    let s = p.whole;
    if s.len - pos < 2 || s[pos] != '[' || s[pos + 1] != ':' { return false, pos; }
    let k = find(s[pos + 2..], ":]");
    if k < 0 { return false, pos; }
    let end = pos + 2 + k + 2;
    let sign, tab = char_group(s[pos..end], true);
    if sign == 0 { fail(p, ERR_INVALID_CHAR_RANGE, pos, end); }
    append_group(p, sign, tab);
    return true, end;
}

fn append_group(p: Parser&, sign: i64, tab: i64) {
    if p.flags & FOLD_CASE == 0 {
        if sign < 0 { append_negated_class(p.cls, table_pairs(tab)); } else { append_class(p.cls, table_pairs(tab)); }
    } else {
        p.tmp.clear();
        append_folded_class(p.tmp, table_pairs(tab));
        clean_class(p.tmp, p.keys);
        if sign < 0 { append_negated_class(p.cls, p.tmp); } else { append_class(p.cls, p.tmp); }
    }
}

// A Unicode class like \p{Han} at whole[pos], appended to the class being
// built: whether there was one, and where it ends.
fn parse_unicode_class(p: Parser&, pos: i64) -> bool, i64 {
    let s = p.whole;
    if p.flags & UNICODE_GROUPS == 0 || s.len - pos < 2 || s[pos] != '\\' || (s[pos + 1] != 'p' && s[pos + 1] != 'P') {
        return false, pos;
    }
    // Committed to parse or return error.
    var sign = if s[pos + 1] == 'P' { -1 } else { 1 };
    let c, t = next_rune(p, pos + 2, s.len);
    var seq_end = 0;
    var name_lo = 0;
    var name_hi = 0;
    var rest = 0;
    if c != '{' {
        // Single-letter name.
        seq_end = t;
        name_lo = pos + 2;
        name_hi = t;
        rest = t;
    } else {
        // Name is in braces.
        let k = find(s[pos..], "}");
        if k < 0 {
            let bad = check_utf8(s, pos, s.len);
            if bad >= 0 { fail(p, ERR_INVALID_UTF8, bad, s.len); }
            fail(p, ERR_INVALID_CHAR_RANGE, pos, s.len);
        }
        let end = pos + k;
        seq_end = end + 1;
        rest = end + 1;
        name_lo = pos + 3;
        name_hi = end;
        let bad = check_utf8(s, name_lo, name_hi);
        if bad >= 0 { fail(p, ERR_INVALID_UTF8, bad, name_hi); }
    }

    // Group can have leading negation too. \p{^Han} == \P{Han}, \P{^Han} == \p{Han}.
    if name_hi > name_lo && s[name_lo] == '^' {
        sign = -sign;
        name_lo++;
    }

    let tab, fold, tsign = unicode_table(s[name_lo..name_hi]);
    if tab < 0 { fail(p, ERR_INVALID_CHAR_RANGE, pos, seq_end); }
    if tsign < 0 { sign = -sign; }

    if p.flags & FOLD_CASE == 0 || fold < 0 {
        if sign > 0 { append_class(p.cls, table_pairs(tab)); } else { append_negated_class(p.cls, table_pairs(tab)); }
    } else {
        // Merge and clean tab and fold in a temporary buffer. This is
        // necessary for the negative case and just tidy for the positive case.
        p.tmp.clear();
        append_class(p.tmp, table_pairs(tab));
        append_class(p.tmp, table_pairs(fold));
        clean_class(p.tmp, p.keys);
        if sign > 0 { append_class(p.cls, p.tmp); } else { append_negated_class(p.cls, p.tmp); }
    }
    return true, rest;
}

// A character class at whole[pos] ('['), pushed onto the stack; returns
// where it ends.
fn parse_class(p: Parser&, pos: i64) -> i64 {
    let s = p.whole;
    var t = pos + 1;    // chop [
    let re = new_regexp(p, OP_CHAR_CLASS);
    p.nodes[re].flags = p.flags as i32;
    p.cls.clear();

    var sign = 1;
    if t < s.len && s[t] == '^' {
        sign = -1;
        t++;
        // If character class does not match \n, add it here, so that
        // negation later will do the right thing.
        if p.flags & CLASS_NL == 0 {
            p.cls.push('\n');
            p.cls.push('\n');
        }
    }

    var first = true;   // ] and - are okay as first char in class
    while t >= s.len || s[t] != ']' || first {
        // POSIX: - is only okay unescaped as first or last in class.
        // Perl: - is okay anywhere.
        if t < s.len && s[t] == '-' && p.flags & PERL_X == 0 && !first && (t + 1 == s.len || s[t + 1] != ']') {
            let r, size = decode_rune(s, t + 1);
            fail(p, ERR_INVALID_CHAR_RANGE, t, t + 1 + size);
        }
        first = false;

        // Look for POSIX [:alnum:] etc.
        if s.len - t > 2 && s[t] == '[' && s[t + 1] == ':' {
            let found, nt = parse_named_class(p, t);
            if found {
                t = nt;
                continue;
            }
        }

        // Look for Unicode character group like \p{Han}.
        let ufound, ut = parse_unicode_class(p, t);
        if ufound {
            t = ut;
            continue;
        }

        // Look for Perl character class symbols (extension).
        let pfound, pt = parse_perl_class_escape(p, t);
        if pfound {
            t = pt;
            continue;
        }

        // Single character or simple range.
        let rng = t;
        let lo, t1 = parse_class_char(p, t, pos);
        t = t1;
        var hi = lo;
        // [a-] means (a|-) so check for final ].
        if s.len - t >= 2 && s[t] == '-' && s[t + 1] != ']' {
            t++;
            let h, t2 = parse_class_char(p, t, pos);
            hi = h;
            t = t2;
            if hi < lo { fail(p, ERR_INVALID_CHAR_RANGE, rng, t); }
        }
        if p.flags & FOLD_CASE == 0 { append_range(p.cls, lo, hi); } else { append_folded_range(p.cls, lo, hi); }
    }
    t++;    // chop ]

    clean_class(p.cls, p.keys);
    if sign < 0 { negate_class(p.cls); }
    store_class(p, re);
    push(p, re);
    return t;
}

// --- classes ---------------------------------------------------------------------------

// Sorts the ranges of r (by lo, then hi decreasing), merges them, and
// eliminates duplicates.
fn clean_class(r: i64[>..<]&, keys: i64[>..<]&) {
    let n = r.len / 2;
    if n < 2 { return; }
    keys.clear();
    for i in n { keys.push((r[2 * i] << 32) | (0xFFFFFFFF - r[2 * i + 1])); }
    sort(keys);
    for i in n {
        r[2 * i] = keys[i] >> 32;
        r[2 * i + 1] = 0xFFFFFFFF - (keys[i] & 0xFFFFFFFF);
    }
    // Merge abutting, overlapping.
    var w = 2;
    var i = 2;
    while i < r.len {
        let lo = r[i];
        let hi = r[i + 1];
        if lo <= r[w - 1] + 1 {
            // merge with previous range
            if hi > r[w - 1] { r[w - 1] = hi; }
        } else {
            // new disjoint range
            r[w] = lo;
            r[w + 1] = hi;
            w += 2;
        }
        i += 2;
    }
    r.resize(w);
}

// Appends the literal x to the class r.
fn append_literal(r: i64[>..<]&, x: i64, flags: i64) {
    if flags & FOLD_CASE != 0 { append_folded_range(r, x, x); } else { append_range(r, x, x); }
}

// Appends the range lo-hi to the class r, expanding the last range or
// the one before it if it overlaps or abuts. Checking two ranges helps
// when appending case-folded alphabets, so that one range can be
// expanding A-Z and the other expanding a-z.
fn append_range(r: i64[>..<]&, lo: i64, hi: i64) {
    let n = r.len;
    var i = 2;
    while i <= 4 {
        if n >= i {
            let rlo = r[n - i];
            let rhi = r[n - i + 1];
            if lo <= rhi + 1 && rlo <= hi + 1 {
                if lo < rlo { r[n - i] = lo; }
                if hi > rhi { r[n - i + 1] = hi; }
                return;
            }
        }
        i += 2;
    }
    r.push(lo);
    r.push(hi);
}

// Appends the range lo-hi and its case-folding-equivalent runes to the
// class r.
fn append_folded_range(r: i64[>..<]&, lo0: i64, hi0: i64) {
    var lo = lo0;
    var hi = hi0;
    // Optimizations.
    if lo <= MIN_FOLD && hi >= MAX_FOLD {
        // Range is full: folding can't add more.
        append_range(r, lo, hi);
        return;
    }
    if hi < MIN_FOLD || lo > MAX_FOLD {
        // Range is outside folding possibilities.
        append_range(r, lo, hi);
        return;
    }
    if lo < MIN_FOLD {
        // [lo, MIN_FOLD-1] needs no folding.
        append_range(r, lo, MIN_FOLD - 1);
        lo = MIN_FOLD;
    }
    if hi > MAX_FOLD {
        // [MAX_FOLD+1, hi] needs no folding.
        append_range(r, MAX_FOLD + 1, hi);
        hi = MAX_FOLD;
    }
    // Brute force. Depend on append_range to coalesce ranges on the fly.
    var c = lo;
    while c <= hi {
        append_range(r, c, c);
        var f = simple_fold(c);
        while f != c {
            append_range(r, f, f);
            f = simple_fold(f);
        }
        c++;
    }
}

// Appends the class x (clean) to the class r.
fn append_class(r: i64[>..<]&, x) {
    var i = 0;
    while i + 1 < x.len {
        append_range(r, x[i], x[i + 1]);
        i += 2;
    }
}

// Appends the case folding of the class x to the class r.
fn append_folded_class(r: i64[>..<]&, x) {
    var i = 0;
    while i + 1 < x.len {
        append_folded_range(r, x[i], x[i + 1]);
        i += 2;
    }
}

// Appends the negation of the class x (clean, or a table's pairs) to the
// class r.
fn append_negated_class(r: i64[>..<]&, x) {
    var next_lo = 0;
    var i = 0;
    while i + 1 < x.len {
        let lo = x[i] as i64;
        let hi = x[i + 1] as i64;
        if next_lo <= lo - 1 { append_range(r, next_lo, lo - 1); }
        next_lo = hi + 1;
        i += 2;
    }
    if next_lo <= MAX_RUNE { append_range(r, next_lo, MAX_RUNE); }
}

// Negates the class r (clean) in place.
fn negate_class(r: i64[>..<]&) {
    var next_lo = 0;
    var w = 0;
    var i = 0;
    while i + 1 < r.len {
        let lo = r[i];
        let hi = r[i + 1];
        if next_lo <= lo - 1 {
            r[w] = next_lo;
            r[w + 1] = lo - 1;
            w += 2;
        }
        next_lo = hi + 1;
        i += 2;
    }
    r.resize(w);
    if next_lo <= MAX_RUNE {
        r.push(next_lo as i32);
        r.push(MAX_RUNE);
    }
}
