// regexp.syntax: programs (Go's prog.go) and the compiler of a tree into
// one (compile.go). A program is Go's: instructions linked by their `out`
// and `arg`, instruction 0 the failing one, `start` where a match begins.
// A rune instruction's runes are `nrune` runes at `rune` in the program's
// pool; instructions made from one class node share that node's runes.

namespace syntax;

import std;

// Instruction operators (Go's InstOp).
let INST_ALT = 0;
let INST_ALT_MATCH = 1;
let INST_CAPTURE = 2;
let INST_EMPTY_WIDTH = 3;
let INST_MATCH = 4;
let INST_FAIL = 5;
let INST_NOP = 6;
let INST_RUNE = 7;
let INST_RUNE1 = 8;
let INST_RUNE_ANY = 9;
let INST_RUNE_ANY_NOT_NL = 10;

let INST_OP_NAMES = ["InstAlt", "InstAltMatch", "InstCapture", "InstEmptyWidth", "InstMatch", "InstFail", "InstNop",
                     "InstRune", "InstRune1", "InstRuneAny", "InstRuneAnyNotNL"];

fn inst_op_string(op: i64) -> const u8[:] {
    if op >= 0 && op < INST_OP_NAMES.len { return INST_OP_NAMES[op]; }
    return "";
}

// Empty-width conditions (Go's EmptyOp), a bit mask.
let EMPTY_BEGIN_LINE = 1;
let EMPTY_END_LINE = 2;
let EMPTY_BEGIN_TEXT = 4;
let EMPTY_END_TEXT = 8;
let EMPTY_WORD_BOUNDARY = 16;
let EMPTY_NO_WORD_BOUNDARY = 32;
let EMPTY_ALL = 255;        // ^EmptyOp(0): StartCond's "impossible"

// An instruction (Go's Inst).
struct Inst {
    op: u8,
    out: u32,       // all but INST_MATCH, INST_FAIL
    arg: u32,       // INST_ALT, INST_ALT_MATCH, INST_CAPTURE, INST_EMPTY_WIDTH; a rune's flags
    rune: i32,      // its runes: nrune of the program's runes at rune
    nrune: i32,
}

// A compiled program (Go's Prog).
struct Prog {
    start: i64,         // the start instruction
    num_cap: i64,       // the number of capture slots (2 per group, group 0 the match)
    insts: Inst[],
    runes: i32[],
}

// The empty-width conditions satisfied at the position between runes r1
// and r2 (-1 for the start or end of the text): EmptyOpContext.
fn empty_op_context(r1: i64, r2: i64) -> i64 {
    var op = EMPTY_NO_WORD_BOUNDARY;
    var boundary = 0;
    if is_word_char(r1) {
        boundary = 1;
    } else if r1 == '\n' {
        op |= EMPTY_BEGIN_LINE;
    } else if r1 < 0 {
        op |= EMPTY_BEGIN_TEXT | EMPTY_BEGIN_LINE;
    }
    if is_word_char(r2) {
        boundary ^= 1;
    } else if r2 == '\n' {
        op |= EMPTY_END_LINE;
    } else if r2 < 0 {
        op |= EMPTY_END_TEXT | EMPTY_END_LINE;
    }
    if boundary != 0 { op ^= EMPTY_WORD_BOUNDARY | EMPTY_NO_WORD_BOUNDARY; }
    return op;
}

// Whether r is a word character for \b and \B: an ASCII letter, digit or
// underscore (IsWordChar).
inline fn is_word_char(r: i64) -> bool {
    ('a' <= r && r <= 'z') || ('A' <= r && r <= 'Z') || ('0' <= r && r <= '9') || r == '_'
}

// Whether instruction i's runes match r: MatchRunePos != -1.
fn match_rune(i: Inst, runes: const i32[:], r: i64) -> bool { match_rune_pos(i, runes, r) != -1 }

// The index of the range of instruction i's runes that matches r, -1 for
// none; 0 for a single rune that matches, folded if the instruction folds
// (MatchRunePos).
fn match_rune_pos(i: Inst, runes: const i32[:], r: i64) -> i64 {
    let n = i.nrune as i64;
    let off = i.rune as i64;
    if n == 0 { return -1; }
    if n == 1 {
        // Special case: single rune.
        let r0 = runes[off] as i64;
        if r == r0 { return 0; }
        if i.arg & FOLD_CASE != 0 {
            var r1 = simple_fold(r0);
            while r1 != r0 {
                if r == r1 { return 0; }
                r1 = simple_fold(r1);
            }
        }
        return -1;
    }
    if n == 2 {
        if r >= runes[off] && r <= runes[off + 1] { return 0; }
        return -1;
    }
    if n == 4 || n == 6 || n == 8 {
        // Linear search for a few pairs. Should handle ASCII well.
        var j = 0;
        while j < n {
            if r < runes[off + j] { return -1; }
            if r <= runes[off + j + 1] { return j / 2; }
            j += 2;
        }
        return -1;
    }
    // Otherwise binary search.
    var lo = 0;
    var hi = n / 2;
    while lo < hi {
        let m = (lo + hi) / 2;
        let c = runes[off + 2 * m] as i64;
        if c <= r {
            if r <= runes[off + 2 * m + 1] { return m; }
            lo = m + 1;
        } else {
            hi = m;
        }
    }
    return -1;
}

// Whether the empty-width instruction i holds between runes before and
// after (MatchEmptyWidth).
fn match_empty_width(i: Inst, before: i64, after: i64) -> bool {
    let a = i.arg as i64;
    if a == EMPTY_BEGIN_LINE { return before == '\n' || before == -1; }
    if a == EMPTY_END_LINE { return after == '\n' || after == -1; }
    if a == EMPTY_BEGIN_TEXT { return before == -1; }
    if a == EMPTY_END_TEXT { return after == -1; }
    if a == EMPTY_WORD_BOUNDARY { return is_word_char(before) != is_word_char(after); }
    if a == EMPTY_NO_WORD_BOUNDARY { return is_word_char(before) == is_word_char(after); }
    abort("unknown empty width arg");
}

// The operator of i with the rune variants as INST_RUNE.
fn inst_kind(i: Inst) -> i64 {
    let o = i.op as i64;
    if o == INST_RUNE1 || o == INST_RUNE_ANY || o == INST_RUNE_ANY_NOT_NL { return INST_RUNE; }
    return o;
}

// The first instruction from pc on that is not a no-op or capture.
fn skip_nop(insts: const Inst[:], pc0: i64) -> i64 {
    var pc = pc0;
    while insts[pc].op == INST_NOP || insts[pc].op == INST_CAPTURE { pc = insts[pc].out; }
    return pc;
}

// The literal string every match of the program must begin with, and
// whether it is the whole match (Prog.Prefix).
fn prefix(p: const Prog&) -> u8[>..], bool {
    var buf: u8[>..] = [];
    let insts = p.insts;
    var pc = skip_nop(insts, p.start);
    // Avoid allocation of buffer if prefix is empty.
    if inst_kind(insts[pc]) != INST_RUNE || insts[pc].nrune != 1 { return buf, insts[pc].op == INST_MATCH; }
    // Have prefix; gather characters.
    while inst_kind(insts[pc]) == INST_RUNE && insts[pc].nrune == 1 && insts[pc].arg & FOLD_CASE == 0 &&
          p.runes[insts[pc].rune] != RUNE_ERROR {
        append_rune(buf, p.runes[insts[pc].rune]);
        pc = skip_nop(insts, insts[pc].out);
    }
    return buf, insts[pc].op == INST_MATCH;
}

// The empty-width conditions every match must meet at its start;
// EMPTY_ALL if no match is possible (Prog.StartCond).
fn start_cond(p: const Prog&) -> i64 {
    var flag = 0;
    var pc = p.start;
    loop {
        let i = p.insts[pc];
        let o = i.op as i64;
        if o == INST_EMPTY_WIDTH {
            flag |= i.arg;
        } else if o == INST_FAIL {
            return EMPTY_ALL;
        } else if o != INST_CAPTURE && o != INST_NOP {
            break;
        }
        pc = i.out;
    }
    return flag;
}

// --- dumping ---------------------------------------------------------------------

fn append_inst(b: u8[>..]&, i: Inst, runes: const i32[:]) {
    let o = i.op as i64;
    if o == INST_ALT {
        format(b, "alt -> ", i.out, ", ", i.arg);
    } else if o == INST_ALT_MATCH {
        format(b, "altmatch -> ", i.out, ", ", i.arg);
    } else if o == INST_CAPTURE {
        format(b, "cap ", i.arg, " -> ", i.out);
    } else if o == INST_EMPTY_WIDTH {
        format(b, "empty ", i.arg, " -> ", i.out);
    } else if o == INST_MATCH {
        b.append("match");
    } else if o == INST_FAIL {
        b.append("fail");
    } else if o == INST_NOP {
        format(b, "nop -> ", i.out);
    } else if o == INST_RUNE {
        b.append("rune ");
        append_runes_quoted(b, runes[(i.rune as i64)..(i.rune as i64) + i.nrune]);
        if i.arg & FOLD_CASE != 0 { b.append("/i"); }
        format(b, " -> ", i.out);
    } else if o == INST_RUNE1 {
        b.append("rune1 ");
        append_runes_quoted(b, runes[(i.rune as i64)..(i.rune as i64) + i.nrune]);
        format(b, " -> ", i.out);
    } else if o == INST_RUNE_ANY {
        format(b, "any -> ", i.out);
    } else if o == INST_RUNE_ANY_NOT_NL {
        format(b, "anynotnl -> ", i.out);
    }
}

// strconv.QuoteToASCII(string(runes)).
fn append_runes_quoted(b: u8[>..]&, rs: const i32[:]) {
    var s: u8[>..] = [];
    for r in rs { append_rune(s, r); }
    append_quoted(b, s, true);
}

// The program's listing (Prog.String).
fn format(b: u8[>..]&, p: const Prog&) {
    for i, j in p.insts {
        var pc: u8[>..] = [];
        format(pc, j);
        if pc.len < 3 {
            for k in 3 - pc.len { b.push(' '); }
        }
        if j == p.start { pc.push('*'); }
        b.append(pc);
        b.push('\t');
        append_inst(b, i, p.runes);
        b.push('\n');
    }
}

fn string(p: const Prog&) -> u8[>..] {
    var b: u8[>..] = [];
    format(b, p);
    return b;
}

// --- the compiler ------------------------------------------------------------------

// A fragment of program: its first instruction (0 for one that cannot
// match), the list of exits still to be patched (head and tail: an exit is
// instruction << 1, | 1 for its arg rather than its out), and whether it
// can match the empty string.
struct Frag { i: i64, head: i64, tail: i64, nullable: bool }

struct Compiler {
    insts: Inst[>..]&,
    runes: i32[>..]&,
    class_at: i64[>..]&,    // per tree node: where its class's runes went, -1 if not yet
    num_cap: i64,
}

fn patch(c: Compiler&, head0: i64, val: i64) {
    var head = head0;
    while head != 0 {
        let i = head >> 1;
        if head & 1 == 0 {
            head = c.insts[i].out;
            c.insts[i].out = val as u32;
        } else {
            head = c.insts[i].arg;
            c.insts[i].arg = val as u32;
        }
    }
}

// The patch list l1 then l2: head, tail.
fn append_list(c: Compiler&, h1: i64, t1: i64, h2: i64, t2: i64) -> i64, i64 {
    if h1 == 0 { return h2, t2; }
    if h2 == 0 { return h1, t1; }
    let i = t1 >> 1;
    if t1 & 1 == 0 { c.insts[i].out = h2 as u32; } else { c.insts[i].arg = h2 as u32; }
    return h1, t2;
}

fn inst(c: Compiler&, op: i64) -> Frag {
    let f = Frag { i: c.insts.len, head: 0, tail: 0, nullable: true };
    c.insts.push(Inst { op: op as u8, out: 0, arg: 0, rune: 0, nrune: 0 });
    return f;
}

fn nop(c: Compiler&) -> Frag {
    var f = inst(c, INST_NOP);
    f.head = f.i << 1;
    f.tail = f.head;
    return f;
}

fn fail_frag() -> Frag { Frag { i: 0, head: 0, tail: 0, nullable: false } }

fn cap_frag(c: Compiler&, arg: i64) -> Frag {
    var f = inst(c, INST_CAPTURE);
    f.head = f.i << 1;
    f.tail = f.head;
    c.insts[f.i].arg = arg as u32;
    if c.num_cap < arg + 1 { c.num_cap = arg + 1; }
    return f;
}

fn cat(c: Compiler&, f1: Frag, f2: Frag) -> Frag {
    // concat of failure is failure
    if f1.i == 0 || f2.i == 0 { return fail_frag(); }
    patch(c, f1.head, f2.i);
    return Frag { i: f1.i, head: f2.head, tail: f2.tail, nullable: f1.nullable && f2.nullable };
}

fn alt(c: Compiler&, f1: Frag, f2: Frag) -> Frag {
    // alt of failure is other
    if f1.i == 0 { return f2; }
    if f2.i == 0 { return f1; }
    var f = inst(c, INST_ALT);
    c.insts[f.i].out = f1.i as u32;
    c.insts[f.i].arg = f2.i as u32;
    f.head, f.tail = append_list(c, f1.head, f1.tail, f2.head, f2.tail);
    f.nullable = f1.nullable || f2.nullable;
    return f;
}

fn quest(c: Compiler&, f1: Frag, nongreedy: bool) -> Frag {
    var f = inst(c, INST_ALT);
    if nongreedy {
        c.insts[f.i].arg = f1.i as u32;
        f.head = f.i << 1;
    } else {
        c.insts[f.i].out = f1.i as u32;
        f.head = (f.i << 1) | 1;
    }
    f.tail = f.head;
    f.head, f.tail = append_list(c, f.head, f.tail, f1.head, f1.tail);
    return f;
}

// loop returns the fragment for the main loop of a plus or star. For
// plus, it can be used after connecting f1 to f2: plus(x) = x loop.
fn loop_frag(c: Compiler&, f1: Frag, nongreedy: bool) -> Frag {
    var f = inst(c, INST_ALT);
    if nongreedy {
        c.insts[f.i].arg = f1.i as u32;
        f.head = f.i << 1;
    } else {
        c.insts[f.i].out = f1.i as u32;
        f.head = (f.i << 1) | 1;
    }
    f.tail = f.head;
    patch(c, f1.head, f.i);
    return f;
}

fn star(c: Compiler&, f1: Frag, nongreedy: bool) -> Frag {
    if f1.nullable {
        // Use (f1+)? to get priority match order correct.
        // See golang.org/issue/46123.
        return quest(c, plus(c, f1, nongreedy), nongreedy);
    }
    return loop_frag(c, f1, nongreedy);
}

fn plus(c: Compiler&, f1: Frag, nongreedy: bool) -> Frag {
    let l = loop_frag(c, f1, nongreedy);
    return Frag { i: f1.i, head: l.head, tail: l.tail, nullable: f1.nullable };
}

fn empty(c: Compiler&, op: i64) -> Frag {
    var f = inst(c, INST_EMPTY_WIDTH);
    c.insts[f.i].arg = op as u32;
    f.head = f.i << 1;
    f.tail = f.head;
    return f;
}

// A rune instruction over the nrune runes at off in the program's pool.
fn rune_frag(c: Compiler&, off: i64, nrune: i64, flags0: i64) -> Frag {
    var f = inst(c, INST_RUNE);
    f.nullable = false;
    var flags = flags0 & FOLD_CASE;     // only relevant flag is FOLD_CASE
    let r = c.runes;
    if nrune != 1 || simple_fold(r[off]) == r[off] {
        // and sometimes not even that
        flags &= ~FOLD_CASE;
    }
    c.insts[f.i].rune = off as i32;
    c.insts[f.i].nrune = nrune as i32;
    c.insts[f.i].arg = flags as u32;
    f.head = f.i << 1;
    f.tail = f.head;
    // Special cases for exec machine.
    if flags & FOLD_CASE == 0 && (nrune == 1 || (nrune == 2 && r[off] == r[off + 1])) {
        c.insts[f.i].op = INST_RUNE1;
    } else if nrune == 2 && r[off] == 0 && r[off + 1] == MAX_RUNE {
        c.insts[f.i].op = INST_RUNE_ANY;
    } else if nrune == 4 && r[off] == 0 && r[off + 1] == '\n' - 1 && r[off + 2] == '\n' + 1 && r[off + 3] == MAX_RUNE {
        c.insts[f.i].op = INST_RUNE_ANY_NOT_NL;
    }
    return f;
}

// Where the runes of anyRuneNotNL and anyRune are in every program's pool.
let ANY_RUNE_NOT_NL_AT = 0;
let ANY_RUNE_AT = 4;

recursive fn compile_node(c: Compiler&, v: View, n: i64) -> Frag {
    let nd = v.nodes[n];
    let o = nd.op as i64;
    if o == OP_NO_MATCH { return fail_frag(); }
    if o == OP_EMPTY_MATCH { return nop(c); }
    if o == OP_LITERAL {
        if nd.nrune == 0 { return nop(c); }
        var f = fail_frag();
        for j in nd.nrune as i64 {
            let at = c.runes.len;
            c.runes.push(v.runes[nd.rune + j]);
            let f1 = rune_frag(c, at, 1, nd.flags);
            if j == 0 { f = f1; } else { f = cat(c, f, f1); }
        }
        return f;
    }
    if o == OP_CHAR_CLASS {
        var at = c.class_at[n];
        if at < 0 {
            at = c.runes.len;
            c.runes.append(runes(v, n));
            c.class_at[n] = at;
        }
        return rune_frag(c, at, nd.nrune, nd.flags);
    }
    if o == OP_ANY_CHAR_NOT_NL { return rune_frag(c, ANY_RUNE_NOT_NL_AT, 4, 0); }
    if o == OP_ANY_CHAR { return rune_frag(c, ANY_RUNE_AT, 2, 0); }
    if o == OP_BEGIN_LINE { return empty(c, EMPTY_BEGIN_LINE); }
    if o == OP_END_LINE { return empty(c, EMPTY_END_LINE); }
    if o == OP_BEGIN_TEXT { return empty(c, EMPTY_BEGIN_TEXT); }
    if o == OP_END_TEXT { return empty(c, EMPTY_END_TEXT); }
    if o == OP_WORD_BOUNDARY { return empty(c, EMPTY_WORD_BOUNDARY); }
    if o == OP_NO_WORD_BOUNDARY { return empty(c, EMPTY_NO_WORD_BOUNDARY); }
    if o == OP_CAPTURE {
        let bra = cap_frag(c, (nd.cap as i64) << 1);
        let s = compile_node(c, v, sub(v, n, 0));
        let ket = cap_frag(c, ((nd.cap as i64) << 1) | 1);
        return cat(c, cat(c, bra, s), ket);
    }
    let nongreedy = nd.flags & NON_GREEDY != 0;
    if o == OP_STAR { return star(c, compile_node(c, v, sub(v, n, 0)), nongreedy); }
    if o == OP_PLUS { return plus(c, compile_node(c, v, sub(v, n, 0)), nongreedy); }
    if o == OP_QUEST { return quest(c, compile_node(c, v, sub(v, n, 0)), nongreedy); }
    if o == OP_CONCAT {
        if nd.nsub == 0 { return nop(c); }
        var f = fail_frag();
        for i in nd.nsub as i64 {
            if i == 0 { f = compile_node(c, v, sub(v, n, i)); } else { f = cat(c, f, compile_node(c, v, sub(v, n, i))); }
        }
        return f;
    }
    if o == OP_ALTERNATE {
        var f = fail_frag();
        for i in nd.nsub as i64 { f = alt(c, f, compile_node(c, v, sub(v, n, i))); }
        return f;
    }
    abort("regexp: unhandled case in compile");
}

// Compiles the tree under node n into insts and runes (empty to begin
// with): the start instruction and the number of capture slots.
fn compile_into(insts: Inst[>..]&, runes: i32[>..]&, v: View, n: i64) -> i64, i64 {
    var class_at: i64[>..] = [];
    class_at.push_n(-1, v.nodes.len);
    runes.append([0, '\n' - 1, '\n' + 1, MAX_RUNE, 0, MAX_RUNE]);
    var c = Compiler { insts: insts, runes: runes, class_at: class_at, num_cap: 2 };   // implicit ( and ) for whole match $0
    inst(c, INST_FAIL);
    let f = compile_node(c, v, n);
    patch(c, f.head, inst(c, INST_MATCH).i);
    return f.i, c.num_cap;
}

// Compile: the program for the tree re.
fn compile(re: const Regexp&) -> Prog {
    var insts: Inst[>..] = [];
    var runes: i32[>..] = [];
    let start, num_cap = compile_into(insts, runes, view(re), re.root);
    return Prog { start: start, num_cap: num_cap, insts: insts, runes: runes };
}
