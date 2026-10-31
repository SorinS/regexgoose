// Go's TestRE2Exhaustive: RE2's re2-exhaustive.txt, 61 MB unpacked, run as
// Go runs it. The file is not in this repository: scripts/re2_exhaustive.py
// unpacks $GOROOT/src/regexp/testdata/re2-exhaustive.txt.bz2 and runs this
// with its path; without one, this test is skipped.

import std;
import os;
import regexp from "..";
import lib.check;
import lib.re2;

fn main() {
    if arg_count() < 2 {
        print("re2-exhaustive: skipped (run scripts/re2_exhaustive.py)");
        return;
    }
    var path: u8[>..] = [];
    arg(1, path);
    var data: u8[>..] = [];
    if !read_file(path, data) {
        print("cannot read ", path);
        exit(1);
    }
    let cases, skipped = run_re2("re2-exhaustive.txt", data);
    print("re2-exhaustive.txt: ", cases, " cases, ", skipped, " skipped as Go skips them (\\B on non-ASCII text)");
    summary("re2-exhaustive");
}
