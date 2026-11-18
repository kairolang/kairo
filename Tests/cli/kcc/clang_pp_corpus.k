// clang's own preprocessor tests, through kcc: `kcc -E -P` and the bundled
// clang's `-E -P`, on the same target and sysroot, must exit alike and
// print the same text (clang_corpus/pp.txt). Regenerate: clang_corpus/README.

fn main() -> i32 { return 0 }

// REQUIRES: kcc, clang-corpus
// RUN: python3 %S/clang_corpus/clang_corpus.py run --mode pp --kcc '%kcc' --clang %bundled_clang --sysroot %musl_sysroot --root %clang_tests --list %S/clang_corpus/pp.txt
