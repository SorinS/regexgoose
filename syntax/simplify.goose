// regexp.syntax: Simplify, a port of Go's simplify.go. Counted repetitions
// become their simpler equivalents (x{1,3} is xx?x? as x(x(x)?)?), and
// repeated operators collapse (a** is a*). The nodes simplify makes are
// added to the pools; untouched subtrees are shared with the tree simplified.

namespace syntax;

import std;

struct Simplifier {
    nodes: Node[>..]&,
    subs: i32[>..]&,
    work: i64[>..<]&,
}

// The simplified form of the tree under root, built in the same pools.
fn simplify_into(pl: Pools&, root: i64) -> i64 {
    var work: i64[>..<] = [];
    var s = Simplifier { nodes: pl.nodes, subs: pl.subs, work: work };
    return simplify_node(s, root);
}

// Simplify: a new tree, equivalent to re, with counted repetitions
// expanded and other simplifications made.
fn simplify(re: const Regexp&) -> Regexp {
    var nodes: Node[>..] = [];
    var subs: i32[>..] = [];
    var runes: i32[>..] = [];
    var names: u8[>..] = [];
    nodes.append(re.nodes);
    subs.append(re.subs);
    runes.append(re.runes);
    names.append(re.names);
    var pl = Pools { nodes: nodes, subs: subs, runes: runes, names: names };
    let root = simplify_into(pl, re.root);
    return freeze(pl, root);
}

fn add_node(s: Simplifier&, nd: Node) -> i64 {
    s.nodes.push(nd);
    return s.nodes.len - 1;
}

// A node of operator o and flags with the subexpressions
// work[base..base + count].
fn node_with_subs(s: Simplifier&, o: i64, flags: i64, base: i64, count: i64) -> i64 {
    var nd = new_node(o);
    nd.flags = flags as i32;
    nd.sub = s.subs.len as i32;
    nd.nsub = count as i32;
    for k in count { s.subs.push(s.work[base + k] as i32); }
    return add_node(s, nd);
}

fn node_with_sub(s: Simplifier&, o: i64, flags: i64, a: i64) -> i64 {
    var nd = new_node(o);
    nd.flags = flags as i32;
    nd.sub = s.subs.len as i32;
    nd.nsub = 1;
    s.subs.push(a as i32);
    return add_node(s, nd);
}

recursive fn simplify_node(s: Simplifier&, n: i64) -> i64 {
    let nd = s.nodes[n];
    let o = nd.op as i64;
    if o == OP_CAPTURE || o == OP_CONCAT || o == OP_ALTERNATE {
        // Simplify the subexpressions; a node with any of them changed
        // becomes a copy with the new ones.
        let mark = s.work.len;
        var changed = false;
        for i in nd.nsub as i64 {
            let old = s.subs[nd.sub + i] as i64;
            let ns = simplify_node(s, old);
            if ns != old { changed = true; }
            s.work.push(ns);
        }
        var r = n;
        if changed {
            var c = nd;
            c.rune = 0;
            c.nrune = 0;
            c.sub = s.subs.len as i32;
            for k in nd.nsub as i64 { s.subs.push(s.work[mark + k] as i32); }
            r = add_node(s, c);
        }
        s.work.resize(mark);
        return r;
    }
    if o == OP_STAR || o == OP_PLUS || o == OP_QUEST {
        let sub = simplify_node(s, s.subs[nd.sub]);
        return simplify1(s, o, nd.flags, sub, n);
    }
    if o == OP_REPEAT {
        // Special special case: x{0} matches the empty string and doesn't
        // even need to consider x.
        if nd.min == 0 && nd.max == 0 { return add_node(s, new_node(OP_EMPTY_MATCH)); }

        // The fun begins.
        let sub = simplify_node(s, s.subs[nd.sub]);

        // x{n,} means at least n matches of x.
        if nd.max == -1 {
            // Special case: x{0,} is x*.
            if nd.min == 0 { return simplify1(s, OP_STAR, nd.flags, sub, -1); }
            // Special case: x{1,} is x+.
            if nd.min == 1 { return simplify1(s, OP_PLUS, nd.flags, sub, -1); }
            // General case: x{4,} is xxxx+.
            let mark = s.work.len;
            for i in nd.min as i64 - 1 { s.work.push(sub); }
            let plus = simplify1(s, OP_PLUS, nd.flags, sub, -1);
            s.work.push(plus);
            let r = node_with_subs(s, OP_CONCAT, 0, mark, s.work.len - mark);
            s.work.resize(mark);
            return r;
        }

        // Special case x{0} handled above.

        // Special case: x{1} is just x.
        if nd.min == 1 && nd.max == 1 { return sub; }

        // General case: x{n,m} means n copies of x and m copies of x?.
        // The machine will do less work if we nest the final m copies,
        // so that x{2,5} = xx(x(x(x)?)?)?

        // Build leading prefix: xx.
        let mark = s.work.len;
        let has_prefix = nd.min > 0;
        for i in nd.min as i64 { s.work.push(sub); }

        // Build and attach suffix: (x(x(x)?)?)?
        if nd.max > nd.min {
            var suffix = simplify1(s, OP_QUEST, nd.flags, sub, -1);
            for i in nd.min as i64 + 1..nd.max as i64 {
                let mark2 = s.work.len;
                s.work.push(sub);
                s.work.push(suffix);
                let nre2 = node_with_subs(s, OP_CONCAT, 0, mark2, 2);
                s.work.resize(mark2);
                suffix = simplify1(s, OP_QUEST, nd.flags, nre2, -1);
            }
            if !has_prefix {
                s.work.resize(mark);
                return suffix;
            }
            s.work.push(suffix);
        }
        if has_prefix {
            let r = node_with_subs(s, OP_CONCAT, 0, mark, s.work.len - mark);
            s.work.resize(mark);
            return r;
        }

        // Some degenerate case like min > max or min < max < 0. This
        // shouldn't happen, because the parser rejects such regexps.
        s.work.resize(mark);
        return add_node(s, new_node(OP_NO_MATCH));
    }
    return n;
}

// The simplest node for operator o (STAR, PLUS or QUEST) with flags over
// sub, given that node re (-1 for none) is o(sub) already: the empty
// match itself, sub where it is o already (a** is a*), re where it is
// exactly that, and a new node otherwise.
fn simplify1(s: Simplifier&, o: i64, flags: i64, sub: i64, re: i64) -> i64 {
    // Special case: repeat the empty string as much as you want, but it's
    // going to match only once.
    if s.nodes[sub].op == OP_EMPTY_MATCH { return sub; }
    // The operators are idempotent if the flags match.
    if o == s.nodes[sub].op && flags & NON_GREEDY == s.nodes[sub].flags & NON_GREEDY { return sub; }
    if re >= 0 && s.nodes[re].op == o && s.nodes[re].flags & NON_GREEDY == flags & NON_GREEDY &&
       sub == s.subs[s.nodes[re].sub] {
        return re;
    }
    return node_with_sub(s, o, flags, sub);
}
