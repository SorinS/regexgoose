// Helpers the tests share: reading the vector files' lines and fields
// (hex-encoded strings, "=" for the empty one), and counting failures.

import std;

var failures = 0;
var checks = 0;

fn fail_msg(what: const u8[:], detail: const u8[:]) {
    failures++;
    if failures <= 60 { print("FAIL ", what, ": ", detail); }
}

fn check_str(what: const u8[:], got: const u8[:], want: const u8[:]) {
    checks++;
    if got != want {
        var d: u8[>..] = [];
        format(d, "got ");
        quote_into(d, got);
        format(d, ", want ");
        quote_into(d, want);
        fail_msg(what, d);
    }
}

fn check_int(what: const u8[:], got: i64, want: i64) {
    checks++;
    if got != want { fail_msg(what, str("got ", got, ", want ", want)); }
}

fn check_bool(what: const u8[:], got: bool, want: bool) {
    checks++;
    if got != want { fail_msg(what, str("got ", got, ", want ", want)); }
}

// s, quoted with Go's %q rules for printable ASCII and \x escapes elsewhere,
// shortened if long.
fn quote_into(d: u8[>..]&, s: const u8[:]) {
    d.push('"');
    for c, i in s {
        if i >= 300 {
            d.append("...");
            break;
        }
        if c == '"' || c == '\\' {
            d.push('\\');
            d.push(c);
        } else if c >= 0x20 && c < 0x7f {
            d.push(c);
        } else if c == '\n' {
            d.append("\\n");
        } else {
            d.append("\\x");
            d.push("0123456789abcdef"[c >> 4]);
            d.push("0123456789abcdef"[c & 15]);
        }
    }
    d.push('"');
}

fn hex_digit(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

// A hex-encoded field ("=" is the empty string).
fn unhex(f: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    if f == "=" { return out; }
    var i = 0;
    while i + 1 < f.len {
        out.push((hex_digit(f[i]) * 16 + hex_digit(f[i + 1])) as u8);
        i += 2;
    }
    return out;
}

fn int_field(f: const u8[:]) -> i64 {
    let v, ok = parse_int(f);
    if !ok { abort(str("bad integer field ", f)); }
    return v;
}

// A comma-separated list of integers: "-" for nil (-1 entries returned
// with nil set), "=" for empty.
fn ints_field(f: const u8[:], out: i64[>..]&) -> bool {
    if f == "-" { return false; }
    if f == "=" { return true; }
    each_split(f, ',') { out.push(int_field(it)); };
    return true;
}

fn summary(name: const u8[:]) {
    print(name, ": ", checks, " checks, ", failures, " failures");
    if failures > 0 { exit(1); }
}

// strconv.Unquote of a Go double-quoted string literal (quotes included):
// the bytes, and false if it is not one.
fn go_unquote(q: const u8[:]) -> u8[>..], bool {
    var out: u8[>..] = [];
    if q.len < 2 || q[0] != '"' || q[q.len - 1] != '"' { return out, false; }
    let s = q[1..q.len - 1];
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c != '\\' {
            if c == '"' || c == '\n' { return out, false; }
            out.push(c);
            i++;
            continue;
        }
        i++;
        if i >= s.len { return out, false; }
        let e = s[i];
        i++;
        if e == 'a' { out.push(7); }
        else if e == 'b' { out.push(8); }
        else if e == 'f' { out.push(12); }
        else if e == 'n' { out.push('\n'); }
        else if e == 'r' { out.push('\r'); }
        else if e == 't' { out.push('\t'); }
        else if e == 'v' { out.push(11); }
        else if e == '\\' || e == '"' { out.push(e); }
        else if e == 'x' || e == 'u' || e == 'U' {
            let n = if e == 'x' { 2 } else if e == 'u' { 4 } else { 8 };
            if i + n > s.len { return out, false; }
            var v = 0;
            for k in n {
                let d = hex_digit(s[i + k]);
                if d < 0 { return out, false; }
                v = v * 16 + d;
            }
            i += n;
            if e == 'x' { out.push(v as u8); } else {
                if v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) { return out, false; }
                syntax_append_rune(out, v);
            }
        } else if e >= '0' && e <= '7' {
            if i + 2 > s.len { return out, false; }
            var v = e - '0';
            for k in 2 {
                let d = s[i + k];
                if d < '0' || d > '7' { return out, false; }
                v = v * 8 + (d - '0');
            }
            if v > 255 { return out, false; }
            i += 2;
            out.push(v as u8);
        } else {
            return out, false;
        }
    }
    return out, true;
}

// UTF-8 of a valid rune.
fn syntax_append_rune(out: u8[>..]&, r: i64) {
    if r < 0x80 {
        out.push(r as u8);
    } else if r < 0x800 {
        out.push((0xC0 | (r >> 6)) as u8);
        out.push((0x80 | (r & 0x3F)) as u8);
    } else if r < 0x10000 {
        out.push((0xE0 | (r >> 12)) as u8);
        out.push((0x80 | ((r >> 6) & 0x3F)) as u8);
        out.push((0x80 | (r & 0x3F)) as u8);
    } else {
        out.push((0xF0 | (r >> 18)) as u8);
        out.push((0x80 | ((r >> 12) & 0x3F)) as u8);
        out.push((0x80 | ((r >> 6) & 0x3F)) as u8);
        out.push((0x80 | (r & 0x3F)) as u8);
    }
}
