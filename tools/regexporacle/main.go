// regexporacle prints what Go's regexp and regexp/syntax make of each case
// of a cases file, for scripts/regexp_differential.py, which compares it
// with tools/regexpverdict.goose's output for the same file.
//
// A case is a line "MODE PATTERN INPUT REPL", the three strings
// hex-encoded ("=" for the empty string), MODE one of perl (Compile),
// posix (CompilePOSIX) or longest (Compile, then Longest). The output is
// one line a case: "err CODE EXPR" if the pattern does not compile, else
// "ok" and, space-separated: NumSubexp, SubexpNames, LiteralPrefix and
// whether it is complete, the String() of the parse and of its
// simplification, the program's listing, MatchString,
// FindStringIndex, FindStringSubmatchIndex, FindAllStringSubmatchIndex,
// FindAllStringIndex(n=2), ReplaceAllString(REPL), ReplaceAllLiteralString,
// Split(-1) and Split(2). Strings are hex ("=" empty); lists of integers
// are comma-separated ("-" for nil); lists of strings are a count and
// their items.
//
//	regexporacle -cases FILE
package main

import (
	"bufio"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"regexp"
	"regexp/syntax"
	"strings"
)

const version = "regexporacle 1"

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "regexporacle: "+format+"\n", args...)
	os.Exit(1)
}

func h(s string) string {
	if s == "" {
		return "="
	}
	return hex.EncodeToString([]byte(s))
}

func unh(s string) string {
	if s == "=" {
		return ""
	}
	d, err := hex.DecodeString(s)
	if err != nil {
		fail("bad hex %q", s)
	}
	return string(d)
}

func ints(x []int) string {
	if x == nil {
		return "-"
	}
	if len(x) == 0 {
		return "="
	}
	p := make([]string, len(x))
	for i, v := range x {
		p[i] = fmt.Sprint(v)
	}
	return strings.Join(p, ",")
}

func flat(xs [][]int) string {
	if xs == nil {
		return "-"
	}
	var all []int
	for _, x := range xs {
		all = append(all, x...)
	}
	return ints(all)
}

func strs(x []string) string {
	if x == nil {
		return "-"
	}
	s := fmt.Sprint(len(x))
	for _, v := range x {
		s += " " + h(v)
	}
	return s
}

func bit(v bool) string {
	if v {
		return "1"
	}
	return "0"
}

func run(mode, pat, input, repl string) string {
	var re *regexp.Regexp
	var err error
	flags := syntax.Perl
	if mode == "posix" {
		re, err = regexp.CompilePOSIX(pat)
		flags = syntax.POSIX
	} else {
		re, err = regexp.Compile(pat)
	}
	if err != nil {
		if e, ok := err.(*syntax.Error); ok {
			return "err " + h(string(e.Code)) + " " + h(e.Expr)
		}
		return "err " + h(err.Error()) + " ="
	}
	if mode == "longest" {
		re.Longest()
	}
	tree, err := syntax.Parse(pat, flags)
	if err != nil {
		fail("Parse failed where Compile did not: %q", pat)
	}
	simple := tree.Simplify()
	prog, err := syntax.Compile(simple)
	if err != nil {
		fail("syntax.Compile failed: %q", pat)
	}
	prefix, complete := re.LiteralPrefix()
	loc := re.FindStringIndex(input)
	out := []string{
		"ok",
		fmt.Sprint(re.NumSubexp()),
		strs(re.SubexpNames()),
		h(prefix), bit(complete),
		h(tree.String()), h(simple.String()), h(prog.String()),
		bit(re.MatchString(input)),
		ints(loc),
		ints(re.FindStringSubmatchIndex(input)),
		flat(re.FindAllStringSubmatchIndex(input, -1)),
		flat(re.FindAllStringIndex(input, 2)),
		h(re.ReplaceAllString(input, repl)),
		h(re.ReplaceAllLiteralString(input, repl)),
		strs(re.Split(input, -1)),
		strs(re.Split(input, 2)),
	}
	return strings.Join(out, " ")
}

func main() {
	cases := flag.String("cases", "", "the cases file")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	if *cases == "" {
		fail("-cases is required")
	}
	f, err := os.Open(*cases)
	if err != nil {
		fail("%v", err)
	}
	defer f.Close()
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<26)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) != 4 {
			fail("bad case line %q", sc.Text())
		}
		fmt.Fprintln(w, run(f[0], unh(f[1]), unh(f[2]), unh(f[3])))
	}
	if err := sc.Err(); err != nil {
		fail("%v", err)
	}
}
