// RUN: cp %S/Inputs/syntax_error.k %t.k
// RUN: not %kfmt --write %t.k 2>&1 | grep -q "syntax errors, not formatting"
// RUN: diff %S/Inputs/syntax_error.k %t.k
//
// Rules 1.1 / 16.5: a file that does not parse is refused and left
// untouched.
