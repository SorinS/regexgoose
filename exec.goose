// regexp: the matchers, ports of Go's exec.go (the Pike VM, a simulation
// of the NFA in time linear in the input) and backtrack.go (a bounded
// backtracker that never visits an (instruction, position) pair twice, for
// small programs on small inputs). The one-pass matcher is in onepass.goose.
//
// Every matcher fills a capture array of ncap slots (0: a yes or no is
// enough; 2: where the match is; more: the groups too), -1 for a slot not
// set, and reports whether there was a match.

namespace regexp;

import std;
import syntax;

let END_OF_TEXT = -1;

// --- input -------------------------------------------------------------------------

// The rune at pos and its width; END_OF_TEXT and 0 at the end.
inline fn step_at(s: const u8[:], pos: i64) -> i64, i64 {
    if pos < s.len {
        let c = s[pos];
        if c < 0x80 { return c, 1; }
        let r, w = syntax::decode_rune(s, pos);
        return r, w;
    }
    return END_OF_TEXT, 0;
}

// The runes before and at pos, as input.context gives them.
fn context_at(s: const u8[:], pos: i64) -> i64, i64 {
    var r1 = END_OF_TEXT;
    var r2 = END_OF_TEXT;
    if pos - 1 >= 0 && pos - 1 < s.len {
        let r, w = syntax::decode_last_rune(s, pos);
        r1 = r;
    }
    if pos >= 0 && pos < s.len {
        let r, w = syntax::decode_rune(s, pos);
        r2 = r;
    }
    return r1, r2;
}

// Whether the empty-width conditions op hold between runes r1 and r2
// (Go's lazyFlag.match).
fn flag_match(r1: i64, r2: i64, op0: i64) -> bool {
    var op = op0;
    if op == 0 { return true; }
    if op & syntax::EMPTY_BEGIN_LINE != 0 {
        if r1 != '\n' && r1 >= 0 { return false; }
        op &= ~syntax::EMPTY_BEGIN_LINE;
    }
    if op & syntax::EMPTY_BEGIN_TEXT != 0 {
        if r1 >= 0 { return false; }
        op &= ~syntax::EMPTY_BEGIN_TEXT;
    }
    if op == 0 { return true; }
    if op & syntax::EMPTY_END_LINE != 0 {
        if r2 != '\n' && r2 >= 0 { return false; }
        op &= ~syntax::EMPTY_END_LINE;
    }
    if op & syntax::EMPTY_END_TEXT != 0 {
        if r2 >= 0 { return false; }
        op &= ~syntax::EMPTY_END_TEXT;
    }
    if op == 0 { return true; }
    if syntax::is_word_char(r1) != syntax::is_word_char(r2) {
        op &= ~syntax::EMPTY_WORD_BOUNDARY;
    } else {
        op &= ~syntax::EMPTY_NO_WORD_BOUNDARY;
    }
    return op == 0;
}

// --- the Pike VM ---------------------------------------------------------------

// The NFA simulation's state. Its arrays are regions of one workspace `w`
// of nfa_space(n, ncap) slots, for a program of n instructions:
//
//   sparse[q][pc]   where pc is in queue q's dense list (a sparse set)
//   pc[q][j]        the instruction of queue q's j-th entry
//   has[q][j]       1 if that entry holds a thread (a rune or match instruction)
//   cap[q][j][k]    that thread's capture slots
//   matchcap[k]     the captures of the match found
//   stack           add's explicit stack, two slots an entry
struct Nfa {
    n: i64,
    ncap: i64,
    cap_at: i64,        // where cap[0] starts in w
    match_at: i64,      // where matchcap starts
    stack_at: i64,
    len0: i64,          // the queues' lengths
    len1: i64,
    matched: bool,
    longest: bool,
}

fn nfa_space(n: i64, ncap: i64) -> i64 { 6 * n + 2 * n * ncap + ncap + 2 * n + 4 }

fn new_nfa(n: i64, ncap: i64, longest: bool) -> Nfa {
    Nfa {
        n: n, ncap: ncap, cap_at: 6 * n, match_at: 6 * n + 2 * n * ncap, stack_at: 6 * n + 2 * n * ncap + ncap,
        len0: 0, len1: 0, matched: false, longest: longest,
    }
}

inline fn qlen(m: const Nfa&, q: i64) -> i64 { if q == 0 { m.len0 } else { m.len1 } }

inline fn set_qlen(m: Nfa&, q: i64, v: i64) {
    if q == 0 { m.len0 = v; } else { m.len1 = v; }
}

// Adds the thread for pc to queue q: the instructions it reaches without
// consuming a rune, in priority order, each once. The thread's captures
// are the ncap slots of w at cap_off, which the capture instructions on
// the way change for what they reach and restore after; r1, r2 are the
// runes around pos, for the empty-width conditions. (Go's machine.add,
// with its recursion on an explicit stack: the first branch of an
// alternation is followed to the end before the second.)
fn nfa_add(m: Nfa&, w: i64[:], insts: const syntax::Inst[:], q: i64, pc0: i64, pos: i64, cap_off: i64, r1: i64, r2: i64) {
    let n = m.n;
    let ncap = m.ncap;
    let sparse = q * n;
    let dpc = 2 * n + q * n;
    let dhas = 4 * n + q * n;
    let caps = m.cap_at + q * n * ncap;
    var sp = m.stack_at;
    w[sp] = pc0;
    w[sp + 1] = -1;
    sp += 2;
    var len = qlen(m, q);
    while sp > m.stack_at {
        sp -= 2;
        var pc = w[sp];
        if pc < 0 {
            // a capture slot to restore: (-1 - slot, old value)
            w[cap_off - 1 - pc] = w[sp + 1];
            continue;
        }
        loop {
            if pc == 0 { break; }
            let j0 = w[sparse + pc];
            if j0 < len && w[dpc + j0] == pc { break; }
            let j = len;
            len++;
            w[dpc + j] = pc;
            w[dhas + j] = 0;
            w[sparse + pc] = j;
            let i = insts[pc];
            let op = i.op as i64;
            if op == syntax::INST_ALT || op == syntax::INST_ALT_MATCH {
                w[sp] = i.arg;
                w[sp + 1] = -1;
                sp += 2;
                pc = i.out;
            } else if op == syntax::INST_EMPTY_WIDTH {
                if !flag_match(r1, r2, i.arg) { break; }
                pc = i.out;
            } else if op == syntax::INST_NOP {
                pc = i.out;
            } else if op == syntax::INST_CAPTURE {
                let slot = i.arg as i64;
                if slot < ncap {
                    w[sp] = -1 - slot;
                    w[sp + 1] = w[cap_off + slot];
                    sp += 2;
                    w[cap_off + slot] = pos;
                }
                pc = i.out;
            } else if op == syntax::INST_FAIL {
                break;
            } else {
                // a match or rune instruction: a thread, with a copy of the captures
                w[dhas + j] = 1;
                let row = caps + j * ncap;
                for k in ncap { w[row + k] = w[cap_off + k]; }
                break;
            }
        }
    }
    set_qlen(m, q, len);
}

// Runs the threads of runq on the rune c between pos and next_pos,
// adding what they lead to to nextq; (n1, n2) are the runes around
// next_pos. (Go's machine.step.)
fn nfa_step(m: Nfa&, w: i64[:], insts: const syntax::Inst[:], runes: const i32[:], runq: i64, nextq: i64, pos: i64,
            next_pos: i64, c: i64, n1: i64, n2: i64) {
    let n = m.n;
    let ncap = m.ncap;
    let dpc = 2 * n + runq * n;
    let dhas = 4 * n + runq * n;
    let caps = m.cap_at + runq * n * ncap;
    let mc = m.match_at;
    var j = 0;
    while j < qlen(m, runq) {
        if w[dhas + j] == 0 {
            j++;
            continue;
        }
        let tcap = caps + j * ncap;
        if m.longest && m.matched && ncap > 0 && w[mc] < w[tcap] {
            j++;
            continue;
        }
        let i = insts[w[dpc + j]];
        let op = i.op as i64;
        var add = false;
        if op == syntax::INST_MATCH {
            if ncap > 0 && (!m.longest || !m.matched || w[mc + 1] < pos) {
                w[tcap + 1] = pos;
                for k in ncap { w[mc + k] = w[tcap + k]; }
            }
            if !m.longest {
                // First-match mode: cut off all lower-priority threads.
                set_qlen(m, runq, 0);
            }
            m.matched = true;
        } else if op == syntax::INST_RUNE {
            add = syntax::match_rune(i, runes, c);
        } else if op == syntax::INST_RUNE1 {
            add = c == runes[i.rune];
        } else if op == syntax::INST_RUNE_ANY {
            add = true;
        } else if op == syntax::INST_RUNE_ANY_NOT_NL {
            add = c != '\n';
        } else {
            abort("bad inst");
        }
        if add { nfa_add(m, w, insts, nextq, i.out, next_pos, tcap, n1, n2); }
        j++;
    }
    set_qlen(m, runq, 0);
}

// The leftmost match at or after pos (Go's machine.match); its captures
// are then the ncap slots at m.match_at.
// prefix is the program's literal prefix (Go's re.prefix where there is no
// one-pass program; empty where there is, its program being anchored).
fn nfa_match(re: const Regexp&, m: Nfa&, w: i64[:], s: const u8[:], pos0: i64, prefix: const u8[:]) -> bool {
    let start_cond = re.cond;
    if start_cond == syntax::EMPTY_ALL { return false; }     // impossible
    let insts = re.insts;
    let runes = re.runes;
    let ncap = m.ncap;
    let mc = m.match_at;
    m.matched = false;
    for k in ncap { w[mc + k] = -1; }
    m.len0 = 0;
    m.len1 = 0;
    var runq = 0;
    var nextq = 1;
    var pos = pos0;
    var r1 = END_OF_TEXT;
    var width1 = 0;
    var r, width = step_at(s, pos);
    if r != END_OF_TEXT { r1, width1 = step_at(s, pos + width); }
    var f1 = END_OF_TEXT;
    var f2 = r;
    if pos != 0 { f1, f2 = context_at(s, pos); }
    loop {
        if qlen(m, runq) == 0 {
            if start_cond & syntax::EMPTY_BEGIN_TEXT != 0 && pos != 0 {
                // Anchored match, past beginning of text.
                break;
            }
            if m.matched {
                // Have match; finished exploring alternatives.
                break;
            }
            if prefix.len > 0 && r1 != re.prefix_rune {
                // Match requires literal prefix; fast search for it.
                let advance = ::find(s[pos..], prefix);
                if advance < 0 { break; }
                pos += advance;
                r, width = step_at(s, pos);
                r1, width1 = step_at(s, pos + width);
            }
        }
        if !m.matched {
            if ncap > 0 { w[mc] = pos; }
            nfa_add(m, w, insts, runq, re.start, pos, mc, f1, f2);
        }
        f1 = r;
        f2 = r1;
        nfa_step(m, w, insts, runes, runq, nextq, pos, pos + width, r, f1, f2);
        if width == 0 { break; }
        if ncap == 0 && m.matched {
            // Found a match and not paying attention to where it is, so
            // any match will do.
            break;
        }
        pos += width;
        r = r1;
        width = width1;
        if r != END_OF_TEXT { r1, width1 = step_at(s, pos + width); }
        let t = runq;
        runq = nextq;
        nextq = t;
    }
    set_qlen(m, nextq, 0);
    return m.matched;
}

// --- the backtracker ---------------------------------------------------------

let VISITED_BITS = 32;
let MAX_BACKTRACK_PROG = 500;           // len(prog.Inst) <= max
let MAX_BACKTRACK_VECTOR = 262144;      // bit vector size <= max (bits)

// The longest input the backtracker takes for a program of n
// instructions, 0 if it takes none (maxBitStateLen).
fn max_bit_state_len(n: i64) -> i64 {
    if n > MAX_BACKTRACK_PROG { return 0; }
    return MAX_BACKTRACK_VECTOR / n;
}

struct BitState {
    end: i64,
    n: i64,
    ncap: i64,
    longest: bool,
    visited: u32[>..]&,
    jobs: i64[>..<]&,       // three slots a job: pc, arg (0 or 1), pos
    cap: i64[>..]&,
    matchcap: i64[>..]&,
}

fn should_visit(b: BitState&, pc: i64, pos: i64) -> bool {
    let k = pc * (b.end + 1) + pos;
    let word = k / VISITED_BITS;
    let bit: u32 = (1 as u32) << ((k % VISITED_BITS) as u32);
    if b.visited[word] & bit != 0 { return false; }
    b.visited[word] |= bit;
    return true;
}

fn bt_push(b: BitState&, insts: const syntax::Inst[:], pc: i64, pos: i64, arg: bool) {
    // Only check should_visit when arg is false: when arg is true, the
    // instruction is being revisited to try its other branch.
    if insts[pc].op != syntax::INST_FAIL && (arg || should_visit(b, pc, pos)) {
        b.jobs.push(pc);
        b.jobs.push(if arg { 1 } else { 0 });
        b.jobs.push(pos);
    }
}

// Runs a backtracking search of the program from pc at pos (Go's
// tryBacktrack).
fn try_backtrack(re: const Regexp&, b: BitState&, s: const u8[:], pc0: i64, pos0: i64) -> bool {
    let insts = re.insts;
    let runes = re.runes;
    let longest = b.longest;
    bt_push(b, insts, pc0, pos0, false);
    while b.jobs.len > 0 {
        let l = b.jobs.len - 3;
        var pc = b.jobs[l];
        var arg = b.jobs[l + 1] != 0;
        var pos = b.jobs[l + 2];
        b.jobs.resize(l);
        var check = false;      // the first instruction is not checked: it was when pushed
        loop {
            if check && !should_visit(b, pc, pos) { break; }
            check = true;
            let i = insts[pc];
            let op = i.op as i64;
            if op == syntax::INST_ALT {
                // Cannot just
                //   b.push(re, inst.Out, pos, false)
                //   b.push(re, inst.Arg, pos, false)
                // If during the processing of inst.Out, we encounter
                // inst.Arg via another path, we want to process it then.
                // Pushing it here will inhibit that. Instead, re-push
                // inst with arg==true as a reminder to push inst.Arg out
                // later.
                if arg {
                    // Finished inst.Out; try inst.Arg.
                    arg = false;
                    pc = i.arg;
                } else {
                    bt_push(b, insts, pc, pos, true);
                    pc = i.out;
                }
            } else if op == syntax::INST_ALT_MATCH {
                // One opcode consumes runes; the other leads to match.
                let o = insts[i.out].op as i64;
                if o == syntax::INST_RUNE || o == syntax::INST_RUNE1 || o == syntax::INST_RUNE_ANY ||
                   o == syntax::INST_RUNE_ANY_NOT_NL {
                    // inst.Arg is the match.
                    bt_push(b, insts, i.arg, pos, false);
                    pc = i.arg;
                    pos = b.end;
                } else {
                    // inst.Out is the match - non-greedy
                    bt_push(b, insts, i.out, b.end, false);
                    pc = i.out;
                }
            } else if op == syntax::INST_RUNE {
                let r, width = step_at(s, pos);
                if !syntax::match_rune(i, runes, r) { break; }
                pos += width;
                pc = i.out;
            } else if op == syntax::INST_RUNE1 {
                let r, width = step_at(s, pos);
                if r != runes[i.rune] { break; }
                pos += width;
                pc = i.out;
            } else if op == syntax::INST_RUNE_ANY_NOT_NL {
                let r, width = step_at(s, pos);
                if r == '\n' || r == END_OF_TEXT { break; }
                pos += width;
                pc = i.out;
            } else if op == syntax::INST_RUNE_ANY {
                let r, width = step_at(s, pos);
                if r == END_OF_TEXT { break; }
                pos += width;
                pc = i.out;
            } else if op == syntax::INST_CAPTURE {
                if arg {
                    // Finished inst.Out; restore the old value.
                    b.cap[i.arg] = pos;
                    break;
                }
                if (i.arg as i64) < b.ncap {
                    // Capture pos to register, but save old value.
                    bt_push(b, insts, pc, b.cap[i.arg], true);     // come back when we're done.
                    b.cap[i.arg] = pos;
                }
                pc = i.out;
            } else if op == syntax::INST_EMPTY_WIDTH {
                let f1, f2 = context_at(s, pos);
                if !flag_match(f1, f2, i.arg) { break; }
                pc = i.out;
            } else if op == syntax::INST_NOP {
                pc = i.out;
            } else if op == syntax::INST_MATCH {
                // We found a match. If the caller doesn't care where the
                // match is, no point going further.
                if b.ncap == 0 { return true; }
                // Record best match so far. Only need to check end point,
                // because this entire call is only considering one start
                // position.
                if b.ncap > 1 { b.cap[1] = pos; }
                let old = b.matchcap[1];
                if old == -1 || (longest && pos > 0 && pos > old) {
                    for k in b.ncap { b.matchcap[k] = b.cap[k]; }
                }
                // If going for first match, we're done.
                if !longest { return true; }
                // If we used the entire text, no longer match is possible.
                if pos == b.end { return true; }
                // Otherwise, continue on in hope of a longer match.
                break;
            } else if op == syntax::INST_FAIL {
                abort("unexpected InstFail");
            } else {
                abort("bad inst");
            }
        }
    }
    return longest && b.ncap > 1 && b.matchcap[1] >= 0;
}

// The leftmost match at or after pos by backtracking (Go's
// Regexp.backtrack); its ncap captures go to out. prefix is as for
// nfa_match.
fn backtrack(re: const Regexp&, s: const u8[:], pos0: i64, ncap: i64, out: i64[:], prefix: const u8[:]) -> bool {
    let start_cond = re.cond;
    if start_cond == syntax::EMPTY_ALL { return false; }     // impossible
    if start_cond & syntax::EMPTY_BEGIN_TEXT != 0 && pos0 != 0 {
        // Anchored match, past beginning of text.
        return false;
    }
    let n = re.insts.len;
    let end = s.len;
    var visited: u32[>..] = [];
    visited.push_n(0, (n * (end + 1) + VISITED_BITS - 1) / VISITED_BITS);
    var jobs: i64[>..<] = [];
    var cap: i64[>..] = [];
    cap.push_n(-1, ncap);
    var matchcap: i64[>..] = [];
    matchcap.push_n(-1, ncap);
    var b = BitState { end: end, n: n, ncap: ncap, longest: re.leftmost_longest, visited: visited, jobs: jobs, cap: cap,
                       matchcap: matchcap };
    var pos = pos0;
    var found = false;
    if start_cond & syntax::EMPTY_BEGIN_TEXT != 0 {
        // Anchored search must start at the beginning of the input.
        if ncap > 0 { b.cap[0] = pos; }
        found = try_backtrack(re, b, s, re.start, pos);
    } else {
        // Unanchored search, starting from each possible text position.
        // Notice that we have to try the empty string at the end of the
        // text, so the loop condition is pos <= end, not pos < end. This
        // looks like it's quadratic in the size of the text, but we are
        // not clearing visited between calls to try_backtrack, so no
        // work is duplicated and it ends up still being linear.
        var width = -1;
        while pos <= end && width != 0 {
            if prefix.len > 0 {
                // Match requires literal prefix; fast search for it.
                let advance = ::find(s[pos..], prefix);
                if advance < 0 { return false; }
                pos += advance;
            }
            if ncap > 0 { b.cap[0] = pos; }
            if try_backtrack(re, b, s, re.start, pos) {
                found = true;
                break;
            }
            let r, w = step_at(s, pos);
            width = w;
            pos += width;
        }
    }
    if !found { return false; }
    for k in ncap { out[k] = matchcap[k]; }
    return true;
}
