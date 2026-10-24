// clang's own preprocessor tests, through kcc: `kcc -E -P` and the bundled
// clang's `-E -P`, on the same target and sysroot, must exit alike and
// print the same text (ClangCorpus/pp.txt). Regenerate: ClangCorpus/README.

fn main() -> i32 { return 0 }

// REQUIRES: kcc, clang-corpus
// RUN: python3 %S/ClangCorpus/clang_corpus.py run --mode pp --kcc '%kcc' --clang %bundled_clang --sysroot %musl_sysroot --root %clang_tests --list %S/ClangCorpus/pp.txt
