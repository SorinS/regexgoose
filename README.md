# regexgoose

Go's `regexp` and `regexp/syntax` for [Goose](../goose.git): regular
expressions with RE2's syntax, matched in time linear in the input, over
UTF-8, with Go's API and Go's answers. It is a port, function by function,
of Go 1.27.1's packages (the parser, simplifier and compiler of
`regexp/syntax`; the Pike VM, bit-state backtracker and one-pass matcher of
`regexp`, chosen per search as Go chooses), and it is checked against Go
on Go's own tests, RE2's logs and generated cases.

| Module | What |
|---|---|
| `regexp` | `compile`, `compile_posix`, `must_compile`, the `find` family, `matches`, `replace_all` and its forms, `expand`, `split`, `quote_meta`, subexpression names; namespace `regexp` |
| `regexp.syntax` | Go's `regexp/syntax`: `parse` into a tree, `simplify`, `string`, `equal`, `max_cap`, `cap_names`, `compile` into a program, `prefix`, `start_cond`, the program listing and `inst_string`, `match_rune_pos`, `match_empty_width`, `empty_op_context`, `is_word_char`; error codes and messages as Go's; namespace `syntax` |
| `syntax/parse.goose` | the parser: parse.go's stack machine, with its free list of nodes and its size and height caches, so `ErrLarge` and `ErrNestingDepth` trip where Go's do |
| `syntax/simplify.goose`, `syntax/prog.goose` | simplify.go; prog.go and compile.go |
| `syntax/tables.goose` | the Unicode data, generated from Go's `unicode` package (Unicode 17.0.0) by `tools/gentables`: every table a `\p{...}` reaches, `unicode.SimpleFold`, `IsPrint`, `IsLetter`, `IsDigit`, and the Perl and POSIX class groups of perl_groups.go |
| `syntax/unicode.goose`, `syntax/utf8.goose` | lookups in those tables (`\p{name}` resolved as Go's `unicodeTable` resolves it, canonical names and aliases included); UTF-8 decoded exactly as `utf8.DecodeRune` and `DecodeLastRune` decode it, `strconv.Quote` |
| `exec.goose` | the Pike VM (exec.go) and the backtracker (backtrack.go) |
| `onepass.goose` | onepass.go: the one-pass program and matcher |

```goose
import regexp from "../regexgoose.git";

fn main() {
    let re = regexp::must_compile("(?P<user>\\w+)@(?P<host>[\\w.]+)");
    let text = "mail ann@example.com or bob@go.dev";
    if re.match_string(text) {
        let m = re.find_submatch_index(text);    // [5, 20, 5, 8, 9, 20]
        print(text[m[2]..m[3]]);                 // ann
    }
    for addr in re.find_all(text, -1) { print(addr); }   // views into text
    print(re.replace_all(text, "${host}:$user"));      // mail example.com:ann or go.dev:bob
    let parts = regexp::must_compile(",\\s*").split("a, b,c", -1);   // ["a", "b", "c"]

    let bad, err = regexp::compile("a(b");
    if err.code != 0 { print(err); }   // error parsing regexp: missing closing ): `a(b`
}
```

```goose
import regexp from "../regexgoose.git";
import regexp.syntax;

let tree, err = syntax::parse("a{2,3}|b*", syntax::PERL);
let simple = syntax::simplify(tree);
print(syntax::string(simple));       // aaa?|b*, as Go's Simplify().String()
let prog = syntax::compile(simple);
print(prog);                         // the program, listed as Go's Prog.String() lists it
```

## API

Inputs are byte strings (`u8[:]`): Go's `[]byte` and `string` methods are
one function here, and each is also there under the `String` name
(`find_string`, `find_all_string_submatch_index`, ...). Results are views
into the input or positions in it; only replacements make new text. A
`Regexp` is plain data that owns its program; `copy(re)` copies it. The
functions take it by reference, so a Regexp is bound to a variable
before use (`let re = regexp::must_compile(...)`), as Goose binds no
reference to a temporary.

| Go | here |
|---|---|
| `Compile`, `CompilePOSIX` | `compile(expr) -> Regexp, syntax::Error`, `compile_posix`: `err.code` 0 on success; a failed one matches nothing |
| `MustCompile`, `MustCompilePOSIX` | `must_compile`, `must_compile_posix`: abort with Go's panic message (``regexp: Compile(`a(b`): error parsing regexp: ...``) |
| `Match`, `MatchString` (package) | `matches(pattern, s)`, `match_string(pattern, s) -> bool, syntax::Error` |
| `re.Match`, `re.MatchString` | `re.matches(s)`, `re.match_string(s)` |
| `re.Find`, `re.FindString` | `re.find(s) -> const u8[:], bool` (Go's nil is the false) |
| `re.FindIndex` | `re.find_index(s) -> i64, i64`, (-1, -1) for none |
| `re.FindSubmatchIndex` | `re.find_submatch_index(s) -> i64[>..]`: 2 × (`num_subexp` + 1) positions, -1 for a group that took no part; empty for no match |
| `re.FindSubmatch` | `re.find_submatch(s) -> const u8[:][>..]`: views; a group that took no part is an empty view (as in `FindStringSubmatch`) |
| `re.FindAll`, `FindAllIndex`, `FindAllSubmatch`, `FindAllSubmatchIndex` | `find_all(s, n)`, `find_all_index(s, n)`, `find_all_submatch(s, n)`, `find_all_submatch_index(s, n)`: flat arrays, a match after another (2, `num_subexp` + 1 or 2 × (`num_subexp` + 1) entries a match) |
| (iterators) | `each_match(re, s, n, ncap) { m => ... }`: each match's positions, nothing allocated per match |
| `re.ReplaceAll`, `ReplaceAllLiteral` | `replace_all(src, repl)` (`$1`, `${name}`, `$$`), `replace_all_literal(src, repl)` |
| `re.ReplaceAllFunc` | `re.replace_all_func(src) { m => replacement }`, the block given the match's text |
| `re.Expand` | `re.expand(dst, template, src, match)`: appends to `dst` |
| `re.Split` | `re.split(s, n) -> const u8[:][>..]` |
| `QuoteMeta` | `quote_meta(s) -> u8[>..]` |
| `re.LiteralPrefix` | `re.literal_prefix() -> const u8[:], bool` |
| `re.NumSubexp`, `SubexpNames`, `SubexpIndex` | `num_subexp()`, `subexp_names()` (views), `subexp_name(i)`, `subexp_index(name)` |
| `re.Longest` | `re.longest()` |
| `re.String` | `regexp::string(re)`; `print(re)` prints it too |
| `re.Copy` | `copy(re)` |

`regexp.syntax` keeps Go's names: `syntax::parse(s, flags)`, flags
`syntax::PERL`, `POSIX`, `FOLD_CASE`, ... ; operators `OP_LITERAL`, ...;
error codes `ERR_MISSING_PAREN`, ... with `error_code_string`;
`syntax::Error { code, expr }`, printed as Go's `Error()`. A tree is a pool
of nodes (`syntax::Regexp { root, nodes, subs, runes, names }`); a node's
subexpressions, runes and name are `syntax::sub(re, n, i)`,
`syntax::runes(re, n)`, `syntax::name(re, n)`.

## Deliberate departures from Go

- **One input type.** Go's `[]byte` and `string` forms are the same
  function on `u8[:]` (both names exist).
- **No nil.** Go's nil results are `false` (`find`), (-1, -1)
  (`find_index`) or an empty array (`find_submatch_index`,
  `find_all_*`). `find_submatch` cannot tell a group that took no part
  from an empty one, as Go's `FindStringSubmatch` cannot; the index forms
  can. `compile` returns a Regexp that matches nothing with its error.
- **Flat `FindAll` results**, not `[][]int`: one array, a fixed stride a
  match.
- **No readers.** The methods `MatchReader`, `FindReaderIndex` and
  `FindReaderSubmatchIndex` and the package's `MatchReader` are not
  provided: Goose has no `io.RuneReader`.
- **No text marshalling** (`MarshalText`, `UnmarshalText`, `AppendText`):
  Goose has no encoding interfaces; `string(re)` and `compile` are the
  same thing.
- **Unicode 17.0.0**, which is what Go 1.27.1's `unicode` package has.
- **`regexp::debug_engine`** forces one matcher, for testing; at 0 (the
  default) the choice is Go's.
- A Regexp is not shared between threads: Goose threads share no memory,
  each has its own copy.

## Tests

```bash
python3 scripts/run_tests.py [--native]      # test/*.goose at -O0, -O2, --debug (and natively)
python3 scripts/gen_go_vectors.py            # re-extract Go's test tables and testdata into test/vectors
python3 scripts/re2_exhaustive.py            # RE2's re2-exhaustive.txt (61 MB, from GOROOT), each matcher
python3 scripts/regexp_differential.py [--count N] [--seed N] [--engines] [-v]
python3 scripts/linearity.py                 # pathological patterns stay linear
python3 scripts/bench.py                     # speed against Go's regexp on Go's benchmarks
(cd tools/gentables && go run . -out ../../syntax/tables.goose -vectors ../../test/vectors/unicode.txt)
```

Every Go test the package's behaviour can be checked by is run, from data
extracted by script, never copied by hand:

| Suite | Source | Result |
|---|---|---|
| `test/syntax_test.goose` | parse_test.go, simplify_test.go, prog_test.go tables (368 cases: parse dumps, String round trips, every invalid expression's error code *and* text in Perl and POSIX mode, simplifications, program listings) and the Unicode lookups against Go (75303 vectors) | 76415 checks, 0 failures |
| `test/regexp_test.goose` | find_test.go, all_test.go, onepass_test.go tables (302 cases) through every API form, each matcher | 10396 checks, 0 failures |
| `test/re2_search_test.goose` | testdata/re2-search.txt, Go's TestRE2Search harness, each matcher | 1888 cases, 57728 checks, 0 failures |
| `scripts/re2_exhaustive.py` | testdata/re2-exhaustive.txt.bz2, the same harness, each matcher | 5716884 cases, 41623744 checks a matcher, 0 failures |
| `test/fowler_test.goose` | basic.dat, nullsubexpr.dat, repetition.dat (AT&T), Go's TestFowler, each matcher | 347 tests a matcher, 5540 checks, 0 failures |
| `test/api_test.goose` | this API's own conventions (views, no-match forms, invalid UTF-8, failed compiles, copies, each_match) and the rest of regexp.syntax's API | 59 checks, 0 failures |

Exceptions, all Go's own: the RE2 logs' cases with `\B` on non-ASCII text
are skipped (2696 exhaustive, 4 search), because RE2 sees a non-boundary
inside a UTF-8 sequence and Go (and this package) only between runes; the
Fowler lines Go skips (NIL, control and locale lines, modes other than E
and L) are skipped.

The differential (`tools/regexporacle`, Go; `tools/regexpverdict.goose`)
generates patterns from a grammar of RE2's syntax (literals, escapes,
classes, Unicode and POSIX classes, anchors, every group and flag form,
every repetition form, alternation), with mutations that make errors,
inputs with multi-byte runes, case variants and invalid UTF-8, long inputs
and large programs for the Pike VM, in Perl, POSIX and longest mode, and
compares the compile error (code and expression), NumSubexp, SubexpNames,
LiteralPrefix, the String() of the parse and of its simplification, the
program listing, MatchString, FindStringIndex, FindStringSubmatchIndex,
FindAllStringSubmatchIndex, FindAllStringIndex(n = 2), ReplaceAllString,
ReplaceAllLiteralString and Split: **50000 cases (seed 7) and 20000 more
(seed 11), 14% of them expressions Go refuses, 0 differences**, with Go's
choice of matcher and with each forced (the Pike VM, the backtracker, the
one-pass matcher).

`scripts/linearity.py` times `(a*)*b`, `(a|aa)*c` and `(x+x+)+y` on
inputs up to 4 MB, a FindAll over 4 MB, and `a?`ⁿ`a`ⁿ on `a`ⁿ: time grows
linearly (quadratically for the last, whose program grows with n) with
each matcher.

## Speed

`scripts/bench.py` runs Go's own benchmarks (BenchmarkMatch's six
expressions on makeText, 32 B to 1 MB; the one-pass match; all_test.go's
micro-benchmarks; BenchmarkCompile) and two FindAll searches over 1 MB
through both packages with the same loop (Apple M-series, native build).
Times are goose / Go (below 1 is faster):

| Case | ratio |
|---|---|
| Compile (Onepass, Medium, Hard) | 0.56 – 0.66 |
| Find, FindSubmatch, FindAll (Ten, NoMatches), ReplaceAll, Literal | 0.74 – 0.91 |
| Anchored matches, one-pass with a long prefix | 0.27 – 0.63 |
| Match/Easy0, Easy0i, Easy1 (literal prefix, folding), 32 B – 1 MB | 0.34 – 0.98 |
| Match/Hard, Hard1 | 0.80 – 1.21 |
| Match/Medium (Pike VM) | 1.04 – 1.11 |
| One-pass `(?s)\A.*\z`, OnePassShortA/B | 1.07 – 1.14 |
| FindAll over 1 MB (words; email with groups) | 1.11, 1.18 |

The full table is printed by the script.

## Requirements

A Goose compiler v2026.3-254 or later; no C. Go 1.27 for the generator,
the oracle and the scripts.

## Not done

- Reader input (`io.RuneReader`) and text marshalling, as above.
- No DFA: like Go's, the matchers are the Pike VM, the backtracker and the
  one-pass matcher, so large searches run at Go's speed, not RE2's.
- The Pike VM's scratch (a few words per instruction and capture slot) is
  made for each call; Go keeps machines in a pool. `each_match` and the
  `find_all` forms make it once per call.
