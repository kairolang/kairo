// RUN: cp %S/inputs/syntax_error.k %t.k
// RUN: not %kfmt --write %t.k 2>&1 | grep "syntax errors, not formatting" > /dev/null
// RUN: diff %S/inputs/syntax_error.k %t.k
//
// Rules 1.1 / 16.5: a file that does not parse is refused and left
// untouched.
