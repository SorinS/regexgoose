// exec_test.go's testRE2: RE2's logs of searches (re2-search.txt and
// re2-exhaustive.txt), each regexp run on each string four ways (full
// match \A(?:re)\z and partial, leftmost-first and leftmost-longest), by
// FindStringSubmatchIndex and MatchString.

import std;
import regexp;
import lib.check;

// A result field: "-" (no match, an empty list) or pairs "lo-hi" (or "-"
// for an unmatched group), space-separated.
fn parse_result(res: const u8[:], out: i64[>..]&) {
    if res == "-" { return; }
    each_split(res, ' ') {
        if it == "-" {
            out.push(-1);
            out.push(-1);
        } else {
            let dash = find(it, "-");
            out.push(int_field(it[..dash]));
            out.push(int_field(it[dash + 1..]));
        }
    };
}

fn is_single_bytes(s: const u8[:]) -> bool {
    for c in s { if c >= 0x80 { return false; } }
    return true;
}

// The regexp q and its result lines from lines[i] on, one per string
// (strings: the strs, ends[k] where string k ends in strs); returns the
// line after them. Counts cases in counts[0], skips in counts[1].
fn run_regexp(file: const u8[:], lines: const u8[:][:], i0: i64, q: const u8[:], strs: const u8[:], ends: const i64[:],
              counts: i64[:]) -> i64 {
    var i = i0;
    let re, err = regexp::compile(q);
    if err.code != 0 {
        if str(err) != "error parsing regexp: invalid escape sequence: `\\C`" {
            fail_msg(str(file, ":", i, ": compile ", q), str(err));
        }
        // We don't and likely never will support \C; skip its results.
        while i < lines.len && lines[i].len > 0 && (lines[i][0] == '-' || (lines[i][0] >= '0' && lines[i][0] <= '9')) {
            counts[0]++;
            i++;
        }
        return i;
    }
    let refull = regexp::must_compile(str("\\A(?:", q, ")\\z"));
    var k = 0;
    while i < lines.len && lines[i].len > 0 && (lines[i][0] == '-' || (lines[i][0] >= '0' && lines[i][0] <= '9')) {
        let line = lines[i];
        i++;
        counts[0]++;
        if k >= ends.len {
            fail_msg(str(file, ":", i), "out of sync: no input remaining");
            return i;
        }
        let lo = if k == 0 { 0 } else { ends[k - 1] };
        let text = strs[lo..ends[k]];
        k++;
        if !is_single_bytes(text) && find(regexp::string(re), "\\B") >= 0 {
            // RE2's \B considers every byte position, so it sees 'not word
            // boundary' in the middle of UTF-8 sequences. This package
            // only considers the positions between runes, so it disagrees.
            // Skip those cases (as Go's test does).
            counts[1]++;
            continue;
        }
        let res = split(line, ';');
        if res.len != 4 {
            fail_msg(str(file, ":", i), str("have ", res.len, " test results, want 4"));
            continue;
        }
        for r in 4 {
            let full = r == 0 || r == 2;
            let longest = r >= 2;
            var want: i64[>..] = [];
            parse_result(res[r], want);
            var have: i64[>..] = [];
            var b = false;
            if full {
                refull.leftmost_longest = longest;
                have = refull.find_string_submatch_index(text);
                b = refull.match_string(text);
            } else {
                re.leftmost_longest = longest;
                have = re.find_string_submatch_index(text);
                b = re.match_string(text);
            }
            checks++;
            if have != want {
                fail_msg(str(file, ":", i, ": /", q, "/", if full { "[full]" } else { "" }, if longest { "[longest]" } else { "" },
                             ".FindSubmatchIndex"), str(quoted(text), " = ", have, ", want ", want));
                continue;
            }
            checks++;
            if b != (want.len > 0) {
                fail_msg(str(file, ":", i, ": /", q, "/.MatchString"), str(quoted(text), " = ", b));
            }
        }
    }
    if k != ends.len { fail_msg(str(file, ":", i), str("out of sync: ", ends.len - k, " strings left")); }
    return i;
}

fn quoted(s: const u8[:]) -> u8[>..] {
    var d: u8[>..] = [];
    quote_into(d, s);
    return d;
}

// Runs a whole log: the number of cases, and of cases skipped.
fn run_re2(file: const u8[:], data: const u8[:]) -> i64, i64 {
    let lines = split(data, '\n');
    var strs: u8[>..] = [];
    var ends: i64[>..] = [];
    var in_strings = false;
    var counts: i64[2] = [0, 0];
    var i = 0;
    while i < lines.len {
        let line = lines[i];
        i++;
        if line.len == 0 {
            if i < lines.len { fail_msg(str(file, ":", i), "unexpected blank line"); }
            continue;
        }
        if line[0] == '#' { continue; }
        if line[0] >= 'A' && line[0] <= 'Z' { continue; }     // a test name
        if line == "strings" {
            strs.clear();
            ends.clear();
            in_strings = true;
            continue;
        }
        if line == "regexps" {
            in_strings = false;
            continue;
        }
        if line[0] == '"' {
            let q, ok = go_unquote(line);
            if !ok {
                fail_msg(str(file, ":", i), str("unquote ", line));
                return counts[0], counts[1];
            }
            if in_strings {
                strs.append(q);
                ends.push(strs.len);
                continue;
            }
            i = run_regexp(file, lines, i, q, strs, ends, counts);
            continue;
        }
        fail_msg(str(file, ":", i), str("out of sync: ", line));
        return counts[0], counts[1];
    }
    return counts[0], counts[1];
}
