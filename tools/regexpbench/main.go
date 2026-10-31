// regexpbench times Go's regexp on the cases of Go's own benchmarks
// (exec_test.go's BenchmarkMatch, all_test.go's micro-benchmarks and
// BenchmarkCompile), with the same loop as tools/bench.goose, for
// scripts/bench.py: one line a case, "name ns/op".
//
//	regexpbench [-min SECONDS]
package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"
)

const version = "regexpbench 1"

var minTime = 0.2
var sink int

func makeText(n int) []byte {
	text := make([]byte, n)
	x := ^uint32(0)
	for i := range text {
		x += x
		x ^= 1
		if int32(x) < 0 {
			x ^= 0x88888eef
		}
		if x%31 == 0 {
			text[i] = '\n'
		} else {
			text[i] = byte(x%(0x7E+1-0x20) + 0x20)
		}
	}
	return text
}

func bench(name string, f func()) {
	n := 1
	for {
		t0 := time.Now()
		for i := 0; i < n; i++ {
			f()
		}
		d := time.Since(t0).Seconds()
		if d >= minTime {
			fmt.Printf("%s %.1f\n", name, d*1e9/float64(n))
			return
		}
		if d < minTime/100 {
			n *= 10
		} else {
			n = int(float64(n)*minTime/d*1.2) + 1
		}
	}
}

func main() {
	flag.Float64Var(&minTime, "min", 0.2, "seconds each case runs at least")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	data := []struct{ name, re string }{
		{"Easy0", "ABCDEFGHIJKLMNOPQRSTUVWXYZ$"},
		{"Easy0i", "(?i)ABCDEFGHIJklmnopqrstuvwxyz$"},
		{"Easy1", "A[AB]B[BC]C[CD]D[DE]E[EF]F[FG]G[GH]H[HI]I[IJ]J$"},
		{"Medium", "[XYZ]ABCDEFGHIJKLMNOPQRSTUVWXYZ$"},
		{"Hard", "[ -~]*ABCDEFGHIJKLMNOPQRSTUVWXYZ$"},
		{"Hard1", "ABCD|CDEF|EFGH|GHIJ|IJKL|KLMN|MNOP|OPQR|QRST|STUV|UVWX|WXYZ"},
	}
	sizes := []struct {
		name string
		n    int
	}{{"32", 32}, {"1K", 1 << 10}, {"32K", 32 << 10}, {"1M", 1 << 20}}
	for _, d := range data {
		re := regexp.MustCompile(d.re)
		for _, s := range sizes {
			t := makeText(s.n)
			bench("Match/"+d.name+"/"+s.name, func() {
				if re.Match(t) {
					fmt.Fprintln(os.Stderr, "match!")
					os.Exit(1)
				}
			})
		}
	}
	op := regexp.MustCompile(`(?s)\A.*\z`)
	for _, s := range sizes {
		t := makeText(s.n)
		bench("Match_onepass_regex/"+s.name, func() {
			if !op.Match(t) {
				os.Exit(1)
			}
		})
	}
	ab := regexp.MustCompile("a+b+")
	s1 := []byte("acbbaaabbdd")
	bench("Find", func() { sink += len(ab.Find(s1)) })
	s2 := []byte("acddee")
	bench("FindAllNoMatches", func() { sink += len(ab.FindAll(s2, -1)) })
	s3 := bytes.Repeat([]byte("acddeeabbax"), 10)
	bench("FindAllTenMatches", func() { sink += len(ab.FindAll(s3, -1)) })
	sub := regexp.MustCompile("a(a+b+)b")
	bench("FindSubmatch", func() { sink += len(sub.FindSubmatch(s1)) })
	x := strings.Repeat("x", 50) + "y"
	lit := regexp.MustCompile("y")
	bench("Literal", func() { sink += b(lit.MatchString(x)) })
	nlit := regexp.MustCompile(".y")
	bench("NotLiteral", func() { sink += b(nlit.MatchString(x)) })
	cls := regexp.MustCompile("[abcdw]")
	xc := strings.Repeat("xxxx", 20) + "w"
	bench("MatchClass", func() { sink += b(cls.MatchString(xc)) })
	cls2 := regexp.MustCompile("[ac]")
	xc2 := strings.Repeat("bbbb", 20) + "c"
	bench("MatchClass_InRange", func() { sink += b(cls2.MatchString(xc2)) })
	rep := regexp.MustCompile("[cjrw]")
	bench("ReplaceAll", func() { sink += len(rep.ReplaceAllString("abcdefghijklmnopqrstuvwxyz", "")) })
	az := []byte("abcdefghijklmnopqrstuvwxyz")
	long := az
	for i := 0; i < 15; i++ {
		long = append(long, long...)
	}
	anc := regexp.MustCompile("^zbc(d|e)")
	bench("AnchoredLiteralShortNonMatch", func() { sink += b(anc.Match(az)) })
	bench("AnchoredLiteralLongNonMatch", func() { sink += b(anc.Match(long)) })
	anc2 := regexp.MustCompile("^.bc(d|e)")
	bench("AnchoredShortMatch", func() { sink += b(anc2.Match(az)) })
	bench("AnchoredLongMatch", func() { sink += b(anc2.Match(long)) })
	sh := []byte("abcddddddeeeededd")
	for _, c := range []struct{ name, re string }{
		{"OnePassShortA", "^.bc(d|e)*$"}, {"NotOnePassShortA", ".bc(d|e)*$"},
		{"OnePassShortB", "^.bc(?:d|e)*$"}, {"NotOnePassShortB", ".bc(?:d|e)*$"},
	} {
		re := regexp.MustCompile(c.re)
		bench(c.name, func() { sink += b(re.Match(sh)) })
	}
	lp := regexp.MustCompile("^abcdefghijklmnopqrstuvwxyz.*$")
	bench("OnePassLongPrefix", func() { sink += b(lp.Match(az)) })
	lnp := regexp.MustCompile("^.bcdefghijklmnopqrstuvwxyz.*$")
	bench("OnePassLongNotPrefix", func() { sink += b(lnp.Match(az)) })
	par := regexp.MustCompile("foo (ba+r)? baz")
	px := []byte("this is a long line that contains foo bar baz")
	bench("MatchShared", func() { sink += b(par.Match(px)) })
	bench("QuoteMetaAll", func() { sink += len(regexp.QuoteMeta(`\.+*?()|[]{}^$`)) })
	bench("QuoteMetaNone", func() { sink += len(regexp.QuoteMeta("abcdefghijklmnopqrstuvwxyz")) })
	for _, c := range []struct{ name, re string }{
		{"Onepass", `^a.[l-nA-Cg-j]?e$`},
		{"Medium", `^((a|b|[d-z0-9])*(日){4,5}.)+$`},
		{"Hard", strings.Repeat(`((abc)*|`, 50) + strings.Repeat(`)`, 50)},
	} {
		bench("Compile/"+c.name, func() {
			re, err := regexp.Compile(c.re)
			if err != nil {
				os.Exit(1)
			}
			sink += re.NumSubexp()
		})
	}
	// Beyond Go's benchmarks: a common search over a large text.
	big := makeText(1 << 20)
	words := regexp.MustCompile(`[a-z]+ing`)
	bench("FindAll/words/1M", func() { sink += len(words.FindAllIndex(big, -1)) })
	email := regexp.MustCompile(`(\w+)@(\w+)\.com`)
	bench("FindAllSubmatch/email/1M", func() { sink += len(email.FindAllSubmatchIndex(big, -1)) })
}

func b(v bool) int {
	if v {
		return 1
	}
	return 0
}
