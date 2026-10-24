// clang's own -verify tests, through kcc. Each listed file
// (ClangCorpus/verify.txt: Sema, SemaCXX, SemaTemplate, Parser, Lexer, CXX,
// C, SemaObjC, SemaObjCXX) has every expected-error/warning/note checked
// against what kcc's clang reports; one mismatch fails the file. The list
// holds the files the bundled `clang -cc1` and kcc both pass, so a failure
// here is kcc diverging from clang. Regenerate: ClangCorpus/README.

fn main() -> i32 { return 0 }

// REQUIRES: kcc, clang-corpus
// RUN: python3 %S/ClangCorpus/clang_corpus.py run --mode verify --kcc '%kcc' --clang %bundled_clang --root %clang_tests --list %S/ClangCorpus/verify.txt
