// gentables writes syntax/tables.goose, the Unicode data regexp/syntax
// uses, from Go's own unicode package and regexp/syntax/perl_groups.go:
//
//   - every table a \p{...} name can reach (unicode.Categories,
//     unicode.Scripts, unicode.CategoryAliases, the fold tables
//     unicode.FoldCategory and unicode.FoldScript, and parse.go's Any,
//     ASCII and its fold table), as (lo, hi) pairs with strides expanded,
//     in Go's order, so appending them range by range gives what
//     parse.go's appendTable gives;
//   - the lookup parse.go's unicodeTable makes: canonical name -> table,
//     fold table, sign;
//   - unicode.SimpleFold as a sorted table of (r, SimpleFold(r)) for every
//     r it moves;
//   - unicode.IsPrint, unicode.IsLetter and unicode.IsDigit as tables;
//   - the Perl (\d \s \w) and POSIX ([:alpha:]) groups of perl_groups.go.
//
// With -vectors it also writes test vectors for the Goose lookups:
// membership at every table's boundaries and SimpleFold of every rune
// that folds.
//
//	go run . -out ../../syntax/tables.goose -vectors ../../test/vectors/unicode.txt
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

const version = "gentables 1"

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "gentables: "+format+"\n", args...)
	os.Exit(1)
}

// parse.go's own tables.
var anyTable = &unicode.RangeTable{
	R16: []unicode.Range16{{Lo: 0, Hi: 1<<16 - 1, Stride: 1}},
	R32: []unicode.Range32{{Lo: 1 << 16, Hi: unicode.MaxRune, Stride: 1}},
}

var asciiTable = &unicode.RangeTable{
	R16: []unicode.Range16{{Lo: 0, Hi: 0x7F, Stride: 1}},
}

var asciiFoldTable = &unicode.RangeTable{
	R16: []unicode.Range16{
		{Lo: 0, Hi: 0x7F, Stride: 1},
		{Lo: 0x017F, Hi: 0x017F, Stride: 1},
		{Lo: 0x212A, Hi: 0x212A, Stride: 1},
	},
}

// canonicalName is parse.go's.
func canonicalName(name string) string {
	var b []byte
	first := true
	for i := range len(name) {
		c := name[i]
		switch {
		case c == '_' || c == '-' || c == ' ':
			c = ' '
		case first:
			if 'a' <= c && c <= 'z' {
				c -= 'a' - 'A'
			}
			first = false
		default:
			if 'A' <= c && c <= 'Z' {
				c += 'a' - 'A'
			}
		}
		if b == nil {
			if c == name[i] && c != ' ' {
				continue
			}
			b = make([]byte, i, len(name))
			copy(b, name[:i])
		}
		if c == ' ' {
			continue
		}
		b = append(b, c)
	}
	if b == nil {
		return name
	}
	return string(b)
}

// pairs gives a table's ranges with strides expanded, in table order.
func pairs(t *unicode.RangeTable) []rune {
	var out []rune
	add := func(lo, hi, stride rune) {
		if stride == 1 {
			out = append(out, lo, hi)
			return
		}
		for c := lo; c <= hi; c += stride {
			out = append(out, c, c)
		}
	}
	for _, r := range t.R16 {
		add(rune(r.Lo), rune(r.Hi), rune(r.Stride))
	}
	for _, r := range t.R32 {
		add(rune(r.Lo), rune(r.Hi), rune(r.Stride))
	}
	return out
}

// runsOf gives the ranges of runes for which f holds, merged.
func runsOf(f func(rune) bool) []rune {
	var out []rune
	in := false
	for r := rune(0); r <= unicode.MaxRune+1; r++ {
		v := r <= unicode.MaxRune && f(r)
		if v && !in {
			out = append(out, r)
			in = true
		} else if !v && in {
			out = append(out, r-1)
			in = false
		}
	}
	return out
}

type tables struct {
	data  []rune // all pairs, flat
	start []int  // table i is data[2*start[i] : 2*start[i+1]]
	names []string
	index map[*unicode.RangeTable]int
}

func (t *tables) add(name string, r []rune) int {
	t.start = append(t.start, len(t.data)/2)
	t.data = append(t.data, r...)
	t.names = append(t.names, name)
	return len(t.names) - 1
}

func (t *tables) table(name string, rt *unicode.RangeTable) int {
	if rt == nil {
		return -1
	}
	if i, ok := t.index[rt]; ok {
		return i
	}
	i := t.add(name, pairs(rt))
	t.index[rt] = i
	return i
}

type entry struct {
	tab, fold, sign int
}

type group struct {
	name  string
	sign  int
	class string // code variable name
}

// perlGroups reads perl_groups.go: its code tables and its two maps.
func perlGroups(path string) (codes map[string][]rune, perl, posix []group) {
	src, err := os.ReadFile(path)
	if err != nil {
		fail("%v", err)
	}
	codes = map[string][]rune{}
	codeRe := regexp.MustCompile(`(?s)var (code\d+) = \[\]rune\{[^\n]*\n(.*?)\n\}`)
	for _, m := range codeRe.FindAllStringSubmatch(string(src), -1) {
		var rs []rune
		for _, f := range strings.FieldsFunc(m[2], func(c rune) bool { return c == ',' || c == ' ' || c == '\n' || c == '\t' }) {
			v, err := strconv.ParseInt(f, 0, 32)
			if err != nil {
				fail("%s: %s: %v", path, m[1], err)
			}
			rs = append(rs, rune(v))
		}
		codes[m[1]] = rs
	}
	mapRe := regexp.MustCompile(`(?s)var (perlGroup|posixGroup) = map\[string\]charGroup\{(.*?)\n\}`)
	entryRe := regexp.MustCompile("`([^`]+)`:\\s*\\{([+-]1), (code\\d+)\\}")
	for _, m := range mapRe.FindAllStringSubmatch(string(src), -1) {
		var gs []group
		for _, e := range entryRe.FindAllStringSubmatch(m[2], -1) {
			sign, _ := strconv.Atoi(e[2])
			if codes[e[3]] == nil {
				fail("%s: %s names unknown %s", path, e[1], e[3])
			}
			gs = append(gs, group{e[1], sign, e[3]})
		}
		sort.Slice(gs, func(i, j int) bool { return gs[i].name < gs[j].name })
		if m[1] == "perlGroup" {
			perl = gs
		} else {
			posix = gs
		}
	}
	if len(perl) != 6 || len(posix) != 28 {
		fail("%s: found %d Perl and %d POSIX groups, expected 6 and 28", path, len(perl), len(posix))
	}
	return
}

func goString(s string) string {
	return strconv.Quote(s)
}

func writeInts(b *strings.Builder, name, typ string, vals []int, perLine int) {
	fmt.Fprintf(b, "let %s: %s[%d] = [\n", name, typ, len(vals))
	for i := 0; i < len(vals); i += perLine {
		end := min(i+perLine, len(vals))
		b.WriteString("   ")
		for _, v := range vals[i:end] {
			fmt.Fprintf(b, " %d,", v)
		}
		b.WriteString("\n")
	}
	b.WriteString("];\n\n")
}

func runesToInts(rs []rune) []int {
	out := make([]int, len(rs))
	for i, r := range rs {
		out[i] = int(r)
	}
	return out
}

func main() {
	out := flag.String("out", "", "the Goose file to write")
	vectors := flag.String("vectors", "", "also write test vectors to this file")
	goroot := flag.String("goroot", runtime.GOROOT(), "the Go tree whose regexp/syntax/perl_groups.go to read")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	if *out == "" {
		fail("-out is required")
	}

	t := &tables{index: map[*unicode.RangeTable]int{}}
	resolve := map[string]entry{}
	set := func(key, tname string, tab, fold *unicode.RangeTable, sign int) {
		resolve[key] = entry{t.table(tname, tab), t.table(tname+" fold", fold), sign}
	}

	// unicodeTable's lookups, lowest precedence first so that later ones
	// override: alias scripts, alias categories, scripts, categories, then
	// the special cases.
	var names []string
	for name := range unicode.Scripts {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		set(canonicalName(name), name, unicode.Scripts[name], unicode.FoldScript[name], +1)
	}
	names = names[:0]
	for name := range unicode.CategoryAliases {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		actual := unicode.CategoryAliases[name]
		set(canonicalName(name), actual, unicode.Categories[actual], unicode.FoldCategory[actual], +1)
	}
	names = names[:0]
	for name := range unicode.Scripts {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if canonicalName(name) == name {
			set(name, name, unicode.Scripts[name], unicode.FoldScript[name], +1)
		}
	}
	names = names[:0]
	for name := range unicode.Categories {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if canonicalName(name) == name {
			set(name, name, unicode.Categories[name], unicode.FoldCategory[name], +1)
		}
	}
	set("Any", "Any", anyTable, anyTable, +1)
	set("Assigned", "Cn", unicode.Cn, unicode.Cn, -1)
	set("Ascii", "ASCII", asciiTable, asciiFoldTable, +1)
	set("Lc", "LC", unicode.Categories["LC"], unicode.FoldCategory["LC"], +1)

	keys := make([]string, 0, len(resolve))
	for k := range resolve {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	printTab := t.add("IsPrint", runsOf(unicode.IsPrint))
	letterTab := t.table("L", unicode.L)
	digitTab := t.table("Nd", unicode.Nd)

	codes, perl, posix := perlGroups(filepath.Join(*goroot, "src", "regexp", "syntax", "perl_groups.go"))
	codeNames := make([]string, 0, len(codes))
	for c := range codes {
		codeNames = append(codeNames, c)
	}
	sort.Strings(codeNames)
	codeTab := map[string]int{}
	for _, c := range codeNames {
		codeTab[c] = t.add(c, codes[c])
	}

	// SimpleFold, and the extent of folding.
	var foldFrom, foldTo []int
	minFold, maxFold := rune(-1), rune(-1)
	for r := rune(0); r <= unicode.MaxRune; r++ {
		if f := unicode.SimpleFold(r); f != r {
			foldFrom = append(foldFrom, int(r))
			foldTo = append(foldTo, int(f))
			if minFold < 0 {
				minFold = r
			}
			maxFold = r
		}
	}

	var b strings.Builder
	fmt.Fprintf(&b, "// regexp.syntax's Unicode data. Generated by tools/gentables from %s's\n", runtime.Version())
	fmt.Fprintf(&b, "// unicode package (Unicode %s) and regexp/syntax/perl_groups.go; do not edit.\n", unicode.Version)
	b.WriteString("\nnamespace syntax;\n\n")
	fmt.Fprintf(&b, "let UNICODE_VERSION = %s;\n\n", goString(unicode.Version))
	b.WriteString("// The least and greatest runes unicode.SimpleFold moves.\n")
	fmt.Fprintf(&b, "let MIN_FOLD = 0x%04x;\nlet MAX_FOLD = 0x%04x;\n\n", minFold, maxFold)

	b.WriteString("// Every table, as (lo, hi) pairs: table i is pairs TABLE_START[i] to\n// TABLE_START[i + 1] of TABLE_PAIRS. Their names, for reference:\n")
	for i, n := range t.names {
		fmt.Fprintf(&b, "//   %d %s\n", i, n)
	}
	writeInts(&b, "TABLE_PAIRS", "i32", runesToInts(t.data), 12)
	starts := append(append([]int{}, t.start...), len(t.data)/2)
	writeInts(&b, "TABLE_START", "i32", starts, 12)

	fmt.Fprintf(&b, "let TABLE_PRINT = %d;     // unicode.IsPrint\n", printTab)
	fmt.Fprintf(&b, "let TABLE_LETTER = %d;    // unicode.IsLetter\n", letterTab)
	fmt.Fprintf(&b, "let TABLE_DIGIT = %d;     // unicode.IsDigit\n\n", digitTab)

	b.WriteString("// unicodeTable's names, canonical and sorted, and what each gives:\n// a table, its fold table (-1 for none) and a sign (-1: negate).\n")
	fmt.Fprintf(&b, "let UNICODE_NAMES: const u8[:][%d] = [\n", len(keys))
	for _, k := range keys {
		fmt.Fprintf(&b, "    %s,\n", goString(k))
	}
	b.WriteString("];\n\n")
	var tabs, folds, signs []int
	for _, k := range keys {
		e := resolve[k]
		tabs = append(tabs, e.tab)
		folds = append(folds, e.fold)
		signs = append(signs, e.sign)
	}
	writeInts(&b, "UNICODE_TABLE", "i32", tabs, 16)
	writeInts(&b, "UNICODE_FOLD", "i32", folds, 16)
	writeInts(&b, "UNICODE_SIGN", "i8", signs, 24)

	var asciiFold []int
	for r := rune(0); r < 128; r++ {
		asciiFold = append(asciiFold, int(unicode.SimpleFold(r)))
	}
	b.WriteString("// unicode.SimpleFold of the ASCII runes.\n")
	writeInts(&b, "ASCII_FOLD", "i32", asciiFold, 16)
	b.WriteString("// unicode.SimpleFold: FOLD_TO[i] for FOLD_FROM[i], sorted; any other\n// rune folds to itself.\n")
	writeInts(&b, "FOLD_FROM", "i32", foldFrom, 12)
	writeInts(&b, "FOLD_TO", "i32", foldTo, 12)

	writeGroups := func(label, prefix string, gs []group) {
		fmt.Fprintf(&b, "// perl_groups.go's %s: name, sign, table.\n", label)
		fmt.Fprintf(&b, "let %s_NAMES: const u8[:][%d] = [", prefix, len(gs))
		for i, g := range gs {
			if i > 0 {
				b.WriteString(", ")
			}
			b.WriteString(goString(g.name))
		}
		b.WriteString("];\n")
		var s, tb []int
		for _, g := range gs {
			s = append(s, g.sign)
			tb = append(tb, codeTab[g.class])
		}
		writeInts(&b, prefix+"_SIGN", "i8", s, 32)
		writeInts(&b, prefix+"_TABLE", "i32", tb, 32)
	}
	writeGroups("perlGroup", "PERL_GROUP", perl)
	writeGroups("posixGroup", "POSIX_GROUP", posix)

	if err := os.WriteFile(*out, []byte(b.String()), 0o644); err != nil {
		fail("%v", err)
	}

	if *vectors != "" {
		writeVectors(*vectors, keys)
	}
}

// writeVectors writes, for every name, "N name r in" lines at its table's
// boundaries (in: 1 if r is in the class \p{name} matches, 0 if not), and
// "F r f" lines, f = unicode.SimpleFold(r), for each rune that folds and
// some that do not.
func writeVectors(path string, keys []string) {
	var b strings.Builder
	fmt.Fprintf(&b, "# Generated by tools/gentables from %s's unicode (Unicode %s); do not edit.\n", runtime.Version(), unicode.Version)
	b.WriteString("# N name rune in: whether \\p{name} holds rune; F rune fold: unicode.SimpleFold\n")
	b.WriteString("# P rune print letter digit: unicode.IsPrint, IsLetter, IsDigit\n")
	for _, k := range keys {
		var tab *unicode.RangeTable
		sign := 1
		switch k {
		case "Any":
			tab = anyTable
		case "Assigned":
			tab, sign = unicode.Cn, -1
		case "Ascii":
			tab = asciiTable
		case "Lc":
			tab = unicode.Categories["LC"]
		default:
			if tab = unicode.Categories[k]; tab == nil {
				if tab = unicode.Scripts[k]; tab == nil {
					for a, actual := range unicode.CategoryAliases {
						if canonicalName(a) == k {
							tab = unicode.Categories[actual]
						}
					}
					if tab == nil {
						for s := range unicode.Scripts {
							if canonicalName(s) == k {
								tab = unicode.Scripts[s]
							}
						}
					}
				}
			}
		}
		seen := map[rune]bool{}
		ps := pairs(tab)
		for i := 0; i < len(ps); i += 2 {
			for _, r := range []rune{ps[i] - 1, ps[i], ps[i+1], ps[i+1] + 1} {
				if r < 0 || r > unicode.MaxRune || seen[r] {
					continue
				}
				seen[r] = true
				in := unicode.Is(tab, r) == (sign > 0)
				v := 0
				if in {
					v = 1
				}
				fmt.Fprintf(&b, "N %s %d %d\n", k, r, v)
			}
		}
	}
	for r := rune(0); r <= unicode.MaxRune; r++ {
		f := unicode.SimpleFold(r)
		if f != r || r%977 == 0 {
			fmt.Fprintf(&b, "F %d %d\n", r, f)
		}
	}
	bit := func(v bool) int {
		if v {
			return 1
		}
		return 0
	}
	for r := rune(0); r <= unicode.MaxRune; r += 61 {
		fmt.Fprintf(&b, "P %d %d %d %d\n", r, bit(unicode.IsPrint(r)), bit(unicode.IsLetter(r)), bit(unicode.IsDigit(r)))
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		fail("%v", err)
	}
}
