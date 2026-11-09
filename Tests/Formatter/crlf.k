// RUN: %kfmt --stdout %S/Inputs/crlf.k | diff -u %S/Expected/crlf.k -
// RUN: %kfmt --check %S/Expected/crlf.k
//
// Rule 3.5 (proposed): CRLF input becomes LF.
