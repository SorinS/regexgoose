// regexp.syntax: lookups in the generated Unicode tables (syntax/tables.goose):
// unicode.SimpleFold, unicode.IsPrint, IsLetter and IsDigit, and the
// tables a \p{name} names, found as parse.go's unicodeTable finds them.

namespace syntax;

import std;
import syntax.tables;

// Table i's (lo, hi) pairs.
fn table_pairs(i: i64) -> const i32[:] {
    let lo = TABLE_START[i] as i64 * 2;
    let hi = TABLE_START[i + 1] as i64 * 2;
    return TABLE_PAIRS[lo..hi];
}

// Whether r lies in a sorted class of (lo, hi) pairs.
fn in_pairs(r: i64, class: const i32[:]) -> bool {
    var lo = 0;
    var hi = class.len / 2;
    while lo < hi {
        let m = (lo + hi) / 2;
        if r < class[2 * m] {
            hi = m;
        } else if r > class[2 * m + 1] {
            lo = m + 1;
        } else {
            return true;
        }
    }
    return false;
}

// unicode.SimpleFold: the next rune of r's fold orbit, r itself for a
// rune that folds to nothing else (and for one out of range).
fn simple_fold(r: i64) -> i64 {
    if r >= 0 && r < 128 { return ASCII_FOLD[r]; }
    if r < MIN_FOLD || r > MAX_FOLD { return r; }
    var lo = 0;
    var hi = FOLD_FROM.len;
    while lo < hi {
        let m = (lo + hi) / 2;
        let f = FOLD_FROM[m] as i64;
        if f < r { lo = m + 1; } else if f > r { hi = m; } else { return FOLD_TO[m]; }
    }
    return r;
}

fn is_print(r: i64) -> bool { in_pairs(r, table_pairs(TABLE_PRINT)) }
fn is_letter(r: i64) -> bool { in_pairs(r, table_pairs(TABLE_LETTER)) }
fn is_digit(r: i64) -> bool { in_pairs(r, table_pairs(TABLE_DIGIT)) }

// parse.go's canonicalName: a leading capital, the rest lower case, and
// no underscores, hyphens or spaces.
fn canonical_name(name: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    var first = true;
    for c0 in name {
        var c = c0;
        if c == '_' || c == '-' || c == ' ' {
            continue;
        }
        if first {
            if 'a' <= c && c <= 'z' { c -= 32; }
            first = false;
        } else if 'A' <= c && c <= 'Z' {
            c += 32;
        }
        out.push(c);
    }
    return out;
}

// The table, fold table (-1: none) and sign \p{name} gives, as
// unicodeTable does; table -1 for an unknown name.
fn unicode_table(name: const u8[:]) -> i64, i64, i64 {
    let key = canonical_name(name);
    var lo = 0;
    var hi = UNICODE_NAMES.len;
    while lo < hi {
        let m = (lo + hi) / 2;
        let c = compare(UNICODE_NAMES[m], key);
        if c < 0 { lo = m + 1; } else if c > 0 { hi = m; } else {
            return UNICODE_TABLE[m], UNICODE_FOLD[m], UNICODE_SIGN[m];
        }
    }
    return -1, -1, 0;
}

// perl_groups.go's perlGroup (posix false) or posixGroup (true): the sign
// and table of the group called name, sign 0 if there is none.
fn char_group(name: const u8[:], posix: bool) -> i64, i64 {
    if posix {
        for n, i in POSIX_GROUP_NAMES {
            if n == name { return POSIX_GROUP_SIGN[i], POSIX_GROUP_TABLE[i]; }
        }
    } else {
        for n, i in PERL_GROUP_NAMES {
            if n == name { return PERL_GROUP_SIGN[i], PERL_GROUP_TABLE[i]; }
        }
    }
    return 0, -1;
}
