// A decl head may wrap, putting `requires` on its own line. The newline in
// front of it must not terminate the head.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
eval fn <P> is_ptr() -> bool = false

struct <T> NS { var v: T }

struct <P> NS<*P>
  requires is_ptr<P>() {
    var p: unsafe P
}

extend <P> NS<*P>
  requires is_ptr<P>() {
    fn get(self) -> unsafe P = self.p
}
