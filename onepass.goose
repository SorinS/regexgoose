// regexp: the one-pass matcher, a port of Go's onepass.go. A one-pass
// program is one in which every alternation can be decided by the next
// rune of the input alone, so a match is a single walk with no threads
// and no backtracking. Only anchored expressions (\A, or ^ outside
// multi-line mode) can be one-pass. Go derives the one-pass program from
// the ordinary one, giving each alternation the rune ranges that lead into
// each of its branches; this does the same, in pools: an instruction's
// runes in op_runes and its next instructions, one a range, in op_next.

namespace regexp;

import std;
import syntax;

// An instruction of a one-pass program (Go's onePassInst): an ordinary
// instruction whose runes are in the one-pass pool, and its `nnext`
// next instructions at `next` in op_next.
struct OnePassInst {
    op: u8,
    out: u32,
    arg: u32,
    rune: i32,
    nrune: i32,
    next: i32,
    nnext: i32,
}

let MERGE_FAILED: u32 = 0xffffffff;

fn as_inst(i: OnePassInst) -> syntax::Inst { syntax::Inst { op: i.op, out: i.out, arg: i.arg, rune: i.rune, nrune: i.nrune } }

inline fn iop(op: i64) -> i64 {
    if op == syntax::INST_RUNE1 || op == syntax::INST_RUNE_ANY || op == syntax::INST_RUNE_ANY_NOT_NL { return syntax::INST_RUNE; }
    return op;
}

// The literal prefix of an anchored program: the prefix, whether it is
// the whole match (followed by $ and the end), and the instruction after
// it (onePassPrefix).
fn onepass_prefix(insts: const syntax::Inst[:], runes: const i32[:], start: i64) -> u8[>..], bool, i64 {
    var buf: u8[>..] = [];
    var i = insts[start];
    if i.op != syntax::INST_EMPTY_WIDTH || i.arg & syntax::EMPTY_BEGIN_TEXT == 0 {
        return buf, i.op == syntax::INST_MATCH, start;
    }
    var pc = i.out as i64;
    i = insts[pc];
    while i.op == syntax::INST_NOP {
        pc = i.out;
        i = insts[pc];
    }
    // Avoid allocation of buffer if prefix is empty.
    if iop(i.op) != syntax::INST_RUNE || i.nrune != 1 { return buf, i.op == syntax::INST_MATCH, start; }
    // Have prefix; gather characters.
    while iop(i.op) == syntax::INST_RUNE && i.nrune == 1 && i.arg & syntax::FOLD_CASE == 0 &&
          runes[i.rune] != syntax::RUNE_ERROR {
        syntax::append_rune(buf, runes[i.rune]);
        pc = i.out;
        i = insts[i.out];
    }
    var complete = false;
    if i.op == syntax::INST_EMPTY_WIDTH && i.arg & syntax::EMPTY_END_TEXT != 0 && insts[i.out].op == syntax::INST_MATCH {
        complete = true;
    }
    return buf, complete, pc;
}

// The instruction an alternation of the one-pass program leads to on r
// (onePassNext); 0 for none.
fn onepass_next(re: const Regexp&, i: OnePassInst, r: i64) -> i64 {
    let next = syntax::match_rune_pos(as_inst(i), re.op_runes, r);
    if next >= 0 { return re.op_next[i.next + next]; }
    if i.op == syntax::INST_ALT_MATCH { return i.out; }
    return 0;
}

// --- compiling ---------------------------------------------------------------------

// The state of makeOnePass's check: the program being made, the rune
// sets of its instructions (onePassRunes: n_runes runes at at_runes in
// pool), the queues, and whether each instruction leads to a match
// without consuming input (m).
struct OnePass {
    insts: OnePassInst[>..]&,
    pool: i32[>..]&,
    next: u32[>..]&,
    at_runes: i64[>..]&,
    n_runes: i64[>..]&,
    m: u8[>..]&,
    // queueOnePass: sparse sets of instructions; the dense list of the
    // instruction queue is consumed from inst_next on.
    sparse: i64[>..]&,      // 2 * n: inst queue, then visit queue
    dense: i64[>..]&,
    inst_size: i64,
    inst_next: i64,
    visit_size: i64,
    n: i64,
}

fn q_contains(o: const OnePass&, q: i64, u: i64) -> bool {
    if u >= o.n { return false; }
    let size = if q == 0 { o.inst_size } else { o.visit_size };
    let s = o.sparse[q * o.n + u];
    return s < size && o.dense[q * o.n + s] == u;
}

fn q_insert(o: OnePass&, q: i64, u: i64) {
    if q_contains(o, q, u) || u >= o.n { return; }
    if q == 0 {
        o.sparse[u] = o.inst_size;
        o.dense[o.inst_size] = u;
        o.inst_size++;
    } else {
        o.sparse[o.n + u] = o.visit_size;
        o.dense[o.n + o.visit_size] = u;
        o.visit_size++;
    }
}

// pc's rune set becomes the runes pushed onto the pool from mark on.
fn set_runes_from(o: OnePass&, pc: i64, mark: i64) {
    o.at_runes[pc] = mark;
    o.n_runes[pc] = o.pool.len - mark;
}

// pc's rune set becomes a copy of that of src.
fn copy_runes(o: OnePass&, pc: i64, src: i64) {
    let mark = o.pool.len;
    let at = o.at_runes[src];
    for k in o.n_runes[src] { o.pool.push(o.pool[at + k]); }
    set_runes_from(o, pc, mark);
}

// pc's next list becomes count copies of v.
fn fill_next(o: OnePass&, pc: i64, count: i64, v: i64) {
    o.insts[pc].next = o.next.len as i32;
    o.insts[pc].nnext = count as i32;
    for k in count { o.next.push(v as u32); }
}

// mergeRuneSets: the union of the rune sets of the instructions left and
// right (each a sorted list of ranges), as pc's rune set, with pc's next
// list saying which of the two each range came from; false where they
// overlap.
fn merge_rune_sets(o: OnePass&, pc: i64, left: i64, right: i64, left_pc: i64, right_pc: i64) -> bool {
    let left_len = o.n_runes[left];
    let right_len = o.n_runes[right];
    if left_len & 1 != 0 || right_len & 1 != 0 { abort("mergeRuneSets odd length []rune"); }
    let la = o.at_runes[left];
    let ra = o.at_runes[right];
    let mark = o.pool.len;
    let next_mark = o.next.len;
    var lx = 0;
    var rx = 0;
    var ix = -1;
    var ok = true;
    while lx < left_len || rx < right_len {
        // extend: take the range at lx of left or at rx of right
        var take_left = false;
        if rx >= right_len {
            take_left = true;
        } else if lx >= left_len {
            take_left = false;
        } else if o.pool[ra + rx] < o.pool[la + lx] {
            take_left = false;
        } else {
            take_left = true;
        }
        let at = if take_left { la + lx } else { ra + rx };
        if ix > 0 && o.pool[at] <= o.pool[mark + ix] {
            ok = false;
            break;
        }
        o.pool.push(o.pool[at]);
        o.pool.push(o.pool[at + 1]);
        ix += 2;
        if take_left {
            lx += 2;
            o.next.push(left_pc as u32);
        } else {
            rx += 2;
            o.next.push(right_pc as u32);
        }
    }
    if !ok {
        // noRune, noNext
        o.at_runes[pc] = o.pool.len;
        o.n_runes[pc] = 0;
        o.insts[pc].next = o.next.len as i32;
        o.insts[pc].nnext = 1;
        o.next.push(MERGE_FAILED);
        return false;
    }
    set_runes_from(o, pc, mark);
    o.insts[pc].next = next_mark as i32;
    o.insts[pc].nnext = (o.next.len - next_mark) as i32;
    return true;
}

// A rune set of the single rune r0 and the runes it folds to, sorted.
fn push_folded(o: OnePass&, r0: i64) {
    let mark = o.pool.len;
    o.pool.push(r0 as i32);
    o.pool.push(r0 as i32);
    var r1 = syntax::simple_fold(r0);
    while r1 != r0 {
        o.pool.push(r1 as i32);
        o.pool.push(r1 as i32);
        r1 = syntax::simple_fold(r1);
    }
    // slices.Sort of the flat list: insertion sort, the list is short.
    for i in mark + 1..o.pool.len {
        let v = o.pool[i];
        var j = i;
        while j > mark && o.pool[j - 1] > v {
            o.pool[j] = o.pool[j - 1];
            j--;
        }
        o.pool[j] = v;
    }
}

// makeOnePass's check: whether the instructions reached from pc are
// one-pass, recording their rune sets and next lists on the way.
recursive fn check(o: OnePass&, runes: const i32[:], pc: i64) -> bool {
    var ok = true;
    if q_contains(o, 1, pc) { return ok; }
    q_insert(o, 1, pc);
    let op = o.insts[pc].op as i64;
    if op == syntax::INST_ALT || op == syntax::INST_ALT_MATCH {
        ok = check(o, runes, o.insts[pc].out) && check(o, runes, o.insts[pc].arg);
        // check no-input paths to InstMatch
        var match_out = o.m[o.insts[pc].out] != 0;
        var match_arg = o.m[o.insts[pc].arg] != 0;
        if match_out && match_arg { return false; }
        // Match on empty goes in inst.Out
        if match_arg {
            let t = o.insts[pc].out;
            o.insts[pc].out = o.insts[pc].arg;
            o.insts[pc].arg = t;
            match_out = true;
            match_arg = false;
        }
        if match_out {
            o.m[pc] = 1;
            o.insts[pc].op = syntax::INST_ALT_MATCH;
        }
        // build a dispatch operator from the two legs
        let out = o.insts[pc].out as i64;
        let arg = o.insts[pc].arg as i64;
        if !merge_rune_sets(o, pc, out, arg, out, arg) { return false; }
    } else if op == syntax::INST_CAPTURE || op == syntax::INST_NOP || op == syntax::INST_EMPTY_WIDTH {
        let out = o.insts[pc].out as i64;
        ok = check(o, runes, out);
        o.m[pc] = o.m[out];
        // pass matching runes back through these no-ops.
        copy_runes(o, pc, out);
        fill_next(o, pc, o.n_runes[pc] / 2 + 1, out);
    } else if op == syntax::INST_MATCH || op == syntax::INST_FAIL {
        o.m[pc] = if op == syntax::INST_MATCH { 1 } else { 0 };
    } else if op == syntax::INST_RUNE {
        o.m[pc] = 0;
        if o.insts[pc].nnext > 0 { return ok; }
        let out = o.insts[pc].out as i64;
        q_insert(o, 0, out);
        let i = o.insts[pc];
        if i.nrune == 0 {
            set_runes_from(o, pc, o.pool.len);
            fill_next(o, pc, 1, out);
            return ok;
        }
        let mark = o.pool.len;
        if i.nrune == 1 && i.arg & syntax::FOLD_CASE != 0 {
            push_folded(o, runes[i.rune]);
        } else {
            for k in i.nrune as i64 { o.pool.push(runes[i.rune + k]); }
        }
        set_runes_from(o, pc, mark);
        fill_next(o, pc, o.n_runes[pc] / 2 + 1, out);
        o.insts[pc].op = syntax::INST_RUNE;
    } else if op == syntax::INST_RUNE1 {
        o.m[pc] = 0;
        if o.insts[pc].nnext > 0 { return ok; }
        let out = o.insts[pc].out as i64;
        q_insert(o, 0, out);
        let i = o.insts[pc];
        let mark = o.pool.len;
        // expand case-folded runes
        if i.arg & syntax::FOLD_CASE != 0 {
            push_folded(o, runes[i.rune]);
        } else {
            o.pool.push(runes[i.rune]);
            o.pool.push(runes[i.rune]);
        }
        set_runes_from(o, pc, mark);
        fill_next(o, pc, o.n_runes[pc] / 2 + 1, out);
        o.insts[pc].op = syntax::INST_RUNE;
    } else if op == syntax::INST_RUNE_ANY {
        o.m[pc] = 0;
        if o.insts[pc].nnext > 0 { return ok; }
        let out = o.insts[pc].out as i64;
        q_insert(o, 0, out);
        let mark = o.pool.len;
        o.pool.push(0);
        o.pool.push(syntax::MAX_RUNE);
        set_runes_from(o, pc, mark);
        fill_next(o, pc, 1, out);
    } else if op == syntax::INST_RUNE_ANY_NOT_NL {
        o.m[pc] = 0;
        if o.insts[pc].nnext > 0 { return ok; }
        let out = o.insts[pc].out as i64;
        q_insert(o, 0, out);
        let mark = o.pool.len;
        o.pool.push(0);
        o.pool.push('\n' - 1);
        o.pool.push('\n' + 1);
        o.pool.push(syntax::MAX_RUNE);
        set_runes_from(o, pc, mark);
        fill_next(o, pc, o.n_runes[pc] / 2 + 1, out);
    }
    return ok;
}

// The one-pass program of the program (compileOnePass), built in
// op_insts, op_runes and op_next: its start, or -1 if the program is not
// one-pass.
fn compile_onepass(insts: const syntax::Inst[:], runes: const i32[:], start: i64, num_cap: i64,
                   op_insts: OnePassInst[>..]&, op_runes: i32[>..]&, op_next: u32[>..]&) -> i64 {
    if start == 0 { return -1; }
    // onepass regexp is anchored
    if insts[start].op != syntax::INST_EMPTY_WIDTH ||
       insts[start].arg & syntax::EMPTY_BEGIN_TEXT != syntax::EMPTY_BEGIN_TEXT {
        return -1;
    }
    var has_alt = false;
    for i in insts {
        if i.op == syntax::INST_ALT || i.op == syntax::INST_ALT_MATCH {
            has_alt = true;
            break;
        }
    }
    // every instruction leading to InstMatch must be EmptyEndText
    for i in insts {
        let op_out = insts[i.out].op as i64;
        let op = i.op as i64;
        if op == syntax::INST_ALT || op == syntax::INST_ALT_MATCH {
            if op_out == syntax::INST_MATCH || insts[i.arg].op == syntax::INST_MATCH { return -1; }
        } else if op == syntax::INST_EMPTY_WIDTH {
            if op_out == syntax::INST_MATCH {
                if i.arg & syntax::EMPTY_END_TEXT == syntax::EMPTY_END_TEXT { continue; }
                return -1;
            }
        } else if op_out == syntax::INST_MATCH && has_alt {
            return -1;
        }
    }
    // Creates a slightly optimized copy of the original Prog that cleans
    // up some Prog idioms that block valid onepass programs.
    let n = insts.len;
    var p: OnePassInst[>..] = [];
    for i in insts {
        p.push(OnePassInst { op: i.op, out: i.out, arg: i.arg, rune: i.rune, nrune: i.nrune, next: 0, nnext: 0 });
    }
    onepass_copy(p);

    // makeOnePass
    if n >= 1000 { return -1; }
    var pool: i32[>..] = [];
    var next: u32[>..] = [];
    var at_runes: i64[>..] = [];
    var n_runes: i64[>..] = [];
    var m: u8[>..] = [];
    var sparse: i64[>..] = [];
    var dense: i64[>..] = [];
    at_runes.push_n(0, n);
    n_runes.push_n(0, n);
    m.push_n(0, n);
    sparse.push_n(0, 2 * n);
    dense.push_n(0, 2 * n);
    var o = OnePass {
        insts: p, pool: pool, next: next, at_runes: at_runes, n_runes: n_runes, m: m, sparse: sparse, dense: dense,
        inst_size: 0, inst_next: 0, visit_size: 0, n: n,
    };
    q_insert(o, 0, start);
    while o.inst_next < o.inst_size {
        o.visit_size = 0;
        let pc = o.dense[o.inst_next];
        o.inst_next++;
        if !check(o, runes, pc) { return -1; }
    }

    // The one-pass program: each instruction's rune set; then
    // cleanupOnePass, which puts back the instructions that do not need
    // a dispatch.
    for i in n {
        let op = insts[i].op as i64;
        if op == syntax::INST_RUNE1 || op == syntax::INST_RUNE_ANY || op == syntax::INST_RUNE_ANY_NOT_NL {
            let orig = insts[i];
            let at = op_runes.len;
            for k in orig.nrune as i64 { op_runes.push(runes[orig.rune + k]); }
            op_insts.push(OnePassInst { op: orig.op, out: orig.out, arg: orig.arg, rune: at as i32, nrune: orig.nrune, next: 0, nnext: 0 });
            continue;
        }
        var oi = p[i];
        let at = op_runes.len;
        for k in n_runes[i] { op_runes.push(pool[at_runes[i] + k]); }
        oi.rune = at as i32;
        oi.nrune = n_runes[i] as i32;
        if op == syntax::INST_ALT || op == syntax::INST_ALT_MATCH || op == syntax::INST_RUNE {
            let nat = op_next.len;
            for k in oi.nnext as i64 { op_next.push(next[oi.next + k]); }
            oi.next = nat as i32;
        } else {
            oi.next = 0;
            oi.nnext = 0;
        }
        op_insts.push(oi);
    }
    return start;
}

// onePassCopy's rewriting of the alternations: an alternation looping
// back to itself through another (a loop of (a|b)*) is changed so that
// the loop does not pass through the inner alternation twice.
fn onepass_copy(p: OnePassInst[>..]&) {
    for pc in p.len {
        let op = p[pc].op as i64;
        if op != syntax::INST_ALT && op != syntax::INST_ALT_MATCH { continue; }
        // A: the instruction at pc; its "other" and "alt" exits. alt_is_out
        // says which of A's fields is the "alt" one.
        var alt_is_out = false;     // p_A_Alt is &Arg, p_A_Other is &Out
        var a_alt = p[pc].arg as i64;
        var a_other = p[pc].out as i64;
        var inst_alt = p[a_alt];
        if !(inst_alt.op == syntax::INST_ALT || inst_alt.op == syntax::INST_ALT_MATCH) {
            alt_is_out = true;
            a_alt = p[pc].out;
            a_other = p[pc].arg;
            inst_alt = p[a_alt];
            if !(inst_alt.op == syntax::INST_ALT || inst_alt.op == syntax::INST_ALT_MATCH) { continue; }
        }
        let inst_other = p[a_other];
        // Analyzing both legs pointing to Alts is for another day
        if inst_other.op == syntax::INST_ALT || inst_other.op == syntax::INST_ALT_MATCH {
            // too complicated
            continue;
        }
        // simple empty transition loop
        // A:BC + B:DA => A:BC + B:DC
        var b_alt_is_out = true;     // p_B_Alt is &B.Out, p_B_Other is &B.Arg
        var patch = false;
        if inst_alt.out == pc {
            patch = true;
        } else if inst_alt.arg == pc {
            patch = true;
            b_alt_is_out = false;
        }
        if patch {
            // *p_B_Alt = *p_A_Other
            if b_alt_is_out { p[a_alt].out = a_other as u32; } else { p[a_alt].arg = a_other as u32; }
        }
        // empty transition to common target
        // A:BC + B:DC => A:DC + B:DC
        let b_alt = if b_alt_is_out { p[a_alt].out as i64 } else { p[a_alt].arg as i64 };
        let b_other = if b_alt_is_out { p[a_alt].arg as i64 } else { p[a_alt].out as i64 };
        // A's "other" exit, read again: it may be the field just patched
        let a_other_now = if alt_is_out { p[pc].arg as i64 } else { p[pc].out as i64 };
        if a_other_now == b_alt {
            // *p_A_Alt = *p_B_Other
            if alt_is_out { p[pc].out = b_other as u32; } else { p[pc].arg = b_other as u32; }
        }
    }
}

// --- matching ------------------------------------------------------------------------

// The match of the one-pass program at pos (Go's doOnePass): it can only
// begin at the start of the text.
fn onepass_match(re: const Regexp&, s: const u8[:], pos0: i64, ncap: i64, out: i64[:]) -> bool {
    let start_cond = re.cond;
    if start_cond == syntax::EMPTY_ALL { return false; }     // impossible
    var matchcap: i64[>..] = [];
    matchcap.push_n(-1, ncap);
    var matched = false;
    var pos = pos0;
    var r1 = END_OF_TEXT;
    var width1 = 0;
    var r, width = step_at(s, pos);
    if r != END_OF_TEXT { r1, width1 = step_at(s, pos + width); }
    var f1 = END_OF_TEXT;
    var f2 = r;
    if pos != 0 { f1, f2 = context_at(s, pos); }
    let insts = re.op_insts;
    let runes = re.op_runes;
    var pc = re.onepass_start;
    var inst = insts[pc];
    // If there is a simple literal prefix, skip over it.
    let prefix = re.prefix;
    block {
        if pos == 0 && flag_match(f1, f2, inst.arg) && prefix.len > 0 {
            // Match requires literal prefix; fast search for it.
            if !starts_with(s, prefix) { break; }
            pos += prefix.len;
            r, width = step_at(s, pos);
            r1, width1 = step_at(s, pos + width);
            f1, f2 = context_at(s, pos);
            pc = re.prefix_end;
        }
        loop {
            inst = insts[pc];
            pc = inst.out;
            let op = inst.op as i64;
            if op == syntax::INST_MATCH {
                matched = true;
                if ncap > 0 {
                    matchcap[0] = 0;
                    matchcap[1] = pos;
                }
                break;
            } else if op == syntax::INST_RUNE {
                if !syntax::match_rune(as_inst(inst), runes, r) { break; }
            } else if op == syntax::INST_RUNE1 {
                if r != runes[inst.rune] { break; }
            } else if op == syntax::INST_RUNE_ANY {
                // Always matches.
            } else if op == syntax::INST_RUNE_ANY_NOT_NL {
                if r == '\n' { break; }
            } else if op == syntax::INST_ALT || op == syntax::INST_ALT_MATCH {
                // peek at the input rune to see which branch of the Alt to take
                pc = onepass_next(re, inst, r);
                continue;
            } else if op == syntax::INST_FAIL {
                break;
            } else if op == syntax::INST_NOP {
                continue;
            } else if op == syntax::INST_EMPTY_WIDTH {
                if !flag_match(f1, f2, inst.arg) { break; }
                continue;
            } else if op == syntax::INST_CAPTURE {
                if inst.arg < ncap { matchcap[inst.arg] = pos; }
                continue;
            } else {
                abort("bad inst");
            }
            if width == 0 { break; }
            f1 = r;
            f2 = r1;
            pos += width;
            r = r1;
            width = width1;
            if r != END_OF_TEXT { r1, width1 = step_at(s, pos + width); }
        }
    };
    if !matched { return false; }
    for k in ncap { out[k] = matchcap[k]; }
    return true;
}
