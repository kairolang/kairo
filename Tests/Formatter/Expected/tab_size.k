// RUN: %kfmt --tab-size=2 --stdout %s | diff -u %S/Expected/tab_size.k -
// RUN: %kfmt --tab-size=2 --check %S/Expected/tab_size.k
//
// Rule 2.4: --tab-size=2 makes one level two spaces.

fn f() {
  if x {
    g()
  }
}
