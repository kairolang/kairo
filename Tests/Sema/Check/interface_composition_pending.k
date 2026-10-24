// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: interface_composition_pending.k:14:21: error [SC001E]: interface composition with '-' or '&' is not compiled yet; only a union ('+' or ',') is
// CHECK: interface_composition_pending.k:15:21: error [SC001E]: interface composition with '-' or '&' is not compiled yet; only a union ('+' or ',') is
// CHECK-NOT: error
//
// Until InterfaceComposition computes requirement sets, a `derives` clause
// using `-` or `&` is rejected rather than compiled as the union its leaves
// would read as. A union, `+` or `,`, is today's inheritance and passes.
// When the pass lands this test is replaced by its real ones.

interface X { fn a(self) }
interface Y { fn b(self) }
interface U derives X + Y { }
interface D derives X - Y { }
interface I derives X & Y { }
interface C derives X, Y { }
