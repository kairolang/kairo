// A pattern over the head's own type variables IS partial, and functions do
// not take partial specializations - same rule as C++. Structs do.
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// ERR: error [S049E]: partial specialization is not allowed on functions
fn <T> p() -> bool = false
fn <T> p<*T>() -> bool = true
