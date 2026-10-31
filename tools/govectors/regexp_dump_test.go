// This file is copied by scripts/gen_go_vectors.py into a temporary copy of
// Go's regexp package, where it can read the package's unexported test
// tables, and writes them to $VECTORS_OUT, one case a line, strings
// hex-encoded ("=" for the empty string), lists as a count (-1 for nil)
// and their items. It is not built on its own.

package regexp

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

func zints(x []int) string {
	if x == nil {
		return "-"
	}
	parts := make([]string, len(x))
	for i, v := range x {
		parts[i] = fmt.Sprint(v)
	}
	if len(parts) == 0 {
		return "="
	}
	return strings.Join(parts, ",")
}

func zstrs(x []string) string {
	if x == nil {
		return "-1"
	}
	s := fmt.Sprint(len(x))
	for _, v := range x {
		s += " " + zh(v)
	}
	return s
}

func zbool(v bool) int {
	if v {
		return 1
	}
	return 0
}

func TestZZDump(t *testing.T) {
	path := os.Getenv("VECTORS_OUT")
	if path == "" {
		t.Skip("VECTORS_OUT not set")
	}
	var b strings.Builder
	out := func(format string, args ...any) { fmt.Fprintf(&b, format+"\n", args...) }
	for _, ft := range findTests {
		n := -1
		if ft.matches != nil {
			n = len(ft.matches)
		}
		line := fmt.Sprintf("find %s %s %d %d", zh(ft.pat), zh(ft.text), ft.max, n)
		for _, m := range ft.matches {
			line += " " + zints(m)
		}
		out("%s", line)
	}
	for _, s := range goodRe {
		out("good %s", zh(s))
	}
	for _, e := range badRe {
		out("bad %s %s", zh(e.re), zh(e.err))
	}
	for _, tc := range replaceTests {
		out("replace %s %s %s %s", zh(tc.pattern), zh(tc.replacement), zh(tc.input), zh(tc.output))
	}
	for _, tc := range replaceLiteralTests {
		out("replaceliteral %s %s %s %s", zh(tc.pattern), zh(tc.replacement), zh(tc.input), zh(tc.output))
	}
	for _, tc := range replaceFuncTests {
		// Every replacement function of the table is "x" + s + "y"; check.
		if tc.replacement("s") != "xsy" {
			t.Fatalf("replaceFuncTests has a new function: %q", tc.pattern)
		}
		out("replacefunc %s %s %s", zh(tc.pattern), zh(tc.input), zh(tc.output))
	}
	for _, tc := range metaTests {
		out("meta %s %s %s %d", zh(tc.pattern), zh(tc.output), zh(tc.literal), zbool(tc.isLiteral))
	}
	for _, tc := range literalPrefixTests {
		out("prefix %s %s %s %d", zh(tc.pattern), zh(tc.output), zh(tc.literal), zbool(tc.isLiteral))
	}
	for _, c := range subexpCases {
		line := fmt.Sprintf("subexp %s %d %s %d", zh(c.input), c.num, zstrs(c.names), len(c.indices))
		for _, ix := range c.indices {
			line += fmt.Sprintf(" %s %d", zh(ix.name), ix.index)
		}
		out("%s", line)
	}
	for _, tc := range splitTests {
		out("split %s %s %d %s", zh(tc.s), zh(tc.r), tc.n, zstrs(tc.out))
	}
	for _, tc := range onePassTests {
		out("onepass %s %d", zh(tc.re), zbool(tc.isOnePass))
	}
	for _, tc := range onePassTests1 {
		out("onepassmatch %s %s", zh(tc.re), zh(tc.match))
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}
