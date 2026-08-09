// A pack expands with either spelling; `...args` mirrors how the pack is
// introduced in the parameter list, `args...` is the postfix form.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
fn <T, ...U> postfix_form(...args: U) {
    sink<T>(mem, args...)
}
fn <T, ...U> prefix_form(...args: U) {
    sink<T>(mem, ...args)
}
