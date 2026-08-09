// `eval fn` is a compile-time function wherever a decl is legal. `eval` only
// falls through to the binding/eval-block productions when no `fn` follows.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
eval fn at_top() -> bool = false

module m {
    eval fn in_module() -> bool = false
    eval fn <T> generic() -> bool = false
    eval LIMIT: u8 = 0x02
}

class C {
    eval fn member(self) -> bool = false
}
