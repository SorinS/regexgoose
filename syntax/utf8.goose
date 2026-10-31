// regexp.syntax: UTF-8 as Go's unicode/utf8 and strconv read and write it.
// The matchers decode their input with these, so an invalid byte, an
// overlong form, a surrogate or a sequence cut short reads as U+FFFD of
// width 1 exactly where Go's utf8.DecodeRune says so.

namespace syntax;

let RUNE_ERROR = 0xFFFD;
let MAX_RUNE = 0x10FFFF;
let RUNE_SELF = 0x80;

// Go's utf8 "first" table: for each leading byte, its sequence length
// (low 3 bits) and the accepted range of the second byte (high bits:
// 0 [80,BF], 1 [A0,BF], 2 [80,9F], 3 [90,BF], 4 [80,8F]); 0xF1 for ASCII,
// 0x00 for a byte that cannot start a sequence.
fn first_info(b: u8) -> u8 {
    if b < 0x80 { return 0xF1; }
    if b < 0xC2 { return 0; }
    if b < 0xE0 { return 0x02; }
    if b == 0xE0 { return 0x13; }
    if b < 0xED { return 0x03; }
    if b == 0xED { return 0x23; }
    if b < 0xF0 { return 0x03; }
    if b == 0xF0 { return 0x34; }
    if b < 0xF4 { return 0x04; }
    if b == 0xF4 { return 0x44; }
    return 0;
}

// The rune at s[pos] and its width: utf8.DecodeRune(s[pos:]). Past the end
// it gives (RUNE_ERROR, 0).
inline fn decode_rune(s: const u8[:], pos: i64) -> i32, i64 {
    let n = s.len - pos;
    if n < 1 { return RUNE_ERROR, 0; }
    let p0 = s[pos];
    if p0 < 0x80 { return p0, 1; }
    return decode_multi(s, pos, n, p0);
}

fn decode_multi(s: const u8[:], pos: i64, n: i64, p0: u8) -> i32, i64 {
    let x = first_info(p0);
    if x == 0 { return RUNE_ERROR, 1; }
    let sz = (x & 7) as i64;
    var lo: u8 = 0x80;
    var hi: u8 = 0xBF;
    let acc = x >> 4;
    if acc == 1 { lo = 0xA0; } else if acc == 2 { hi = 0x9F; } else if acc == 3 { lo = 0x90; } else if acc == 4 { hi = 0x8F; }
    if n < sz { return RUNE_ERROR, 1; }
    let b1 = s[pos + 1];
    if b1 < lo || hi < b1 { return RUNE_ERROR, 1; }
    if sz <= 2 { return (((p0 as i32) & 0x1F) << 6) | ((b1 as i32) & 0x3F), 2; }
    let b2 = s[pos + 2];
    if b2 < 0x80 || 0xBF < b2 { return RUNE_ERROR, 1; }
    if sz <= 3 { return (((p0 as i32) & 0x0F) << 12) | (((b1 as i32) & 0x3F) << 6) | ((b2 as i32) & 0x3F), 3; }
    let b3 = s[pos + 3];
    if b3 < 0x80 || 0xBF < b3 { return RUNE_ERROR, 1; }
    return (((p0 as i32) & 0x07) << 18) | (((b1 as i32) & 0x3F) << 12) | (((b2 as i32) & 0x3F) << 6) | ((b3 as i32) & 0x3F), 4;
}

// The rune that ends at s[end]: utf8.DecodeLastRune(s[:end]). At 0 it
// gives (RUNE_ERROR, 0).
fn decode_last_rune(s: const u8[:], end: i64) -> i32, i64 {
    if end <= 0 { return RUNE_ERROR, 0; }
    var start = end - 1;
    let r = s[start];
    if r < 0x80 { return r, 1; }
    let lim = max(end - 4, 0);
    start--;
    while start >= lim {
        if s[start] & 0xC0 != 0x80 { break; }
        start--;
    }
    if start < 0 { start = 0; }
    let d, size = decode_rune(s[..end], start);
    if start + size != end { return RUNE_ERROR, 1; }
    return d, size;
}

// utf8.ValidRune.
fn valid_rune(r: i64) -> bool {
    (0 <= r && r < 0xD800) || (0xDFFF < r && r <= MAX_RUNE)
}

// utf8.RuneLen: -1 for a rune that cannot be encoded.
fn rune_len(r: i64) -> i64 {
    if r < 0 { return -1; }
    if r < 0x80 { return 1; }
    if r < 0x800 { return 2; }
    if 0xD800 <= r && r <= 0xDFFF { return -1; }
    if r < 0x10000 { return 3; }
    if r <= MAX_RUNE { return 4; }
    return -1;
}

// Appends r in UTF-8, as utf8.AppendRune does: U+FFFD for a rune that
// cannot be encoded.
fn append_rune(out: u8[>..]&, r0: i64) {
    var r = r0;
    if !valid_rune(r) { r = RUNE_ERROR; }
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

let LOWER_HEX = "0123456789abcdef";

fn append_hex_digits(out: u8[>..]&, r: i64, digits: i64) {
    var s = (digits - 1) * 4;
    while s >= 0 {
        out.push(LOWER_HEX[(r >> s) & 0xF]);
        s -= 4;
    }
}

// strconv's appendEscapedRune.
fn append_escaped_rune(out: u8[>..]&, r0: i64, quote: u8, ascii_only: bool) {
    var r = r0;
    if r == quote || r == '\\' {
        out.push('\\');
        append_rune(out, r);
        return;
    }
    if ascii_only {
        if r < RUNE_SELF && r >= 0x20 && r < 0x7F {
            out.push(r as u8);
            return;
        }
    } else if is_print(r) {
        append_rune(out, r);
        return;
    }
    if r == 7 { out.append("\\a"); return; }
    if r == 8 { out.append("\\b"); return; }
    if r == 12 { out.append("\\f"); return; }
    if r == '\n' { out.append("\\n"); return; }
    if r == '\r' { out.append("\\r"); return; }
    if r == '\t' { out.append("\\t"); return; }
    if r == 11 { out.append("\\v"); return; }
    if r < ' ' || r == 0x7F {
        out.append("\\x");
        append_hex_digits(out, r, 2);
        return;
    }
    if !valid_rune(r) { r = RUNE_ERROR; }
    if r < 0x10000 {
        out.append("\\u");
        append_hex_digits(out, r, 4);
    } else {
        out.append("\\U");
        append_hex_digits(out, r, 8);
    }
}

// strconv.Quote (ascii_only false) or strconv.QuoteToASCII (true) of s,
// appended to out.
fn append_quoted(out: u8[>..]&, s: const u8[:], ascii_only: bool) {
    out.push('"');
    var pos = 0;
    while pos < s.len {
        let r, width = decode_rune(s, pos);
        if width == 1 && r == RUNE_ERROR {
            out.append("\\x");
            append_hex_digits(out, s[pos], 2);
            pos += 1;
            continue;
        }
        append_escaped_rune(out, r, '"', ascii_only);
        pos += width;
    }
    out.push('"');
}

// strconv.CanBackquote.
fn can_backquote(s: const u8[:]) -> bool {
    var pos = 0;
    while pos < s.len {
        let r, wid = decode_rune(s, pos);
        pos += wid;
        if wid > 1 {
            if r == 0xFEFF { return false; }
            continue;
        }
        if r == RUNE_ERROR { return false; }
        if (r < ' ' && r != '\t') || r == '`' || r == 0x7F { return false; }
    }
    return true;
}
