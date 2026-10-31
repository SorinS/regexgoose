// This file is copied by scripts/gen_go_vectors.py into a temporary copy of
// Go's regexp/syntax package, where it can read the package's unexported
// test tables, and writes them to $VECTORS_OUT, one case a line, strings
// hex-encoded ("=" for the empty string). It is not built on its own.

package syntax

import (
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"testing"
)

func zh(s string) string {
	if s == "" {
		return "="
	}
	return hex.EncodeToString([]byte(s))
}

// zerr is "ok = =" or "err CODE EXPR" for s parsed under flags.
func zerr(s string, flags Flags) string {
	_, err := Parse(s, flags)
	if err == nil {
		return "ok = ="
	}
	e, ok := err.(*Error)
	if !ok {
		return "err " + zh(err.Error()) + " ="
	}
	return "err " + zh(string(e.Code)) + " " + zh(e.Expr)
}

func TestZZDump(t *testing.T) {
	path := os.Getenv("VECTORS_OUT")
	if path == "" {
		t.Skip("VECTORS_OUT not set")
	}
	var b strings.Builder
	out := func(format string, args ...any) { fmt.Fprintf(&b, format+"\n", args...) }
	tables := []struct {
		name  string
		tests []parseTest
		flags Flags
	}{
		{"parseTests", parseTests, testFlags},
		{"foldcaseTests", foldcaseTests, FoldCase},
		{"literalTests", literalTests, Literal},
		{"matchnlTests", matchnlTests, MatchNL},
		{"nomatchnlTests", nomatchnlTests, 0},
	}
	for _, tb := range tables {
		for _, tt := range tb.tests {
			// Go's own String() of the parse, which the table does not give.
			s := ""
			if re, err := Parse(tt.Regexp, tb.flags); err == nil {
				s = re.String()
			}
			out("parse %s %d %s %s %s", tb.name, tb.flags, zh(tt.Regexp), zh(tt.Dump), zh(s))
		}
	}
	for _, s := range invalidRegexps {
		out("invalid invalidRegexps %s %s %s", zh(s), zerr(s, Perl), zerr(s, POSIX))
	}
	for _, s := range onlyPerl {
		out("invalid onlyPerl %s %s %s", zh(s), zerr(s, Perl), zerr(s, POSIX))
	}
	for _, s := range onlyPOSIX {
		out("invalid onlyPOSIX %s %s %s", zh(s), zerr(s, Perl), zerr(s, POSIX))
	}
	for _, tt := range stringTests {
		out("string %s %s", zh(tt.re), zh(tt.out))
	}
	for _, tt := range simplifyTests {
		out("simplify %s %s", zh(tt.Regexp), zh(tt.Simple))
	}
	for _, tt := range compileTests {
		out("compile %s %s", zh(tt.Regexp), zh(tt.Prog))
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}
