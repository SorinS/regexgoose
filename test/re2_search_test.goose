// Go's TestRE2Search: RE2's re2-search.txt ($GOROOT/src/regexp/testdata,
// copied by scripts/gen_go_vectors.py), run as Go runs it.

import std;
import regexp from "..";
import lib.check;
import lib.re2;

fn main() {
    let cases, skipped = run_re2("re2-search.txt", embed_file("vectors/re2-search.txt"));
    print("re2-search.txt: ", cases, " cases, ", skipped, " skipped as Go skips them (\\B on non-ASCII text)");
    summary("re2-search");
}
