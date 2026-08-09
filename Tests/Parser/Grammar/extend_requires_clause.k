// `extend` takes a `requires` clause like the type productions do; before it
// was supported the clause parsed as a stray expression and took the body
// down with it.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
eval fn <P> is_ptr() -> bool = false
struct <T> NS { var v: T }

extend <P> NS<P> requires is_ptr<P>() {
    fn get(self) -> P = self.v
}
