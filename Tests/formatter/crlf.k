// RUN: %kfmt --stdout %S/inputs/crlf.k | diff -u %S/expected/crlf.k -
// RUN: %kfmt --check %S/expected/crlf.k
//
// Rule 3.5 (proposed): CRLF input becomes LF.
