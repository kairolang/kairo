// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// `t[i]` on a bounded `T` is the bound's `op []` requirement, as `t + u` is
// the bound's `op +`: MemberTyping reads OperatorTyping's bound interfaces.
// It used to look `op []` up on the bare parameter, which has no members, so
// every subscript through a bound was SC103E "'T' has no subscript
// operator" -- a generic requirement and a plain one alike. A bound without
// `op []`, and an unbounded T, still have none; the requirement's parameter
// and result types are checked as any call's are.

pub interface Idx { fn op [](const self, k: i32) -> i32 }
pub interface GIdx { fn <K> op [](const self, k: K) -> bool }
pub interface Other { fn size(const self) -> i32 }
pub class Q { fn Q(self) { } }

fn <T impl Idx> at(t: T) -> i32 { return t[3] }
fn <T impl GIdx> gat(t: T) -> bool { return t[1] && t[true] }
fn <T> both(t: T) -> i32 requires T impl Idx && T impl Other { return t[t.size()] }

fn <T impl Other> none(t: T) -> i32 { return t[0] }
// CHECK: bounds_subscript.k:[[@LINE-1]]:46: error [SC103E]: 'T' has no subscript operator
fn <T> unbounded(t: T) -> i32 { return t[0] }
// CHECK: bounds_subscript.k:[[@LINE-1]]:40: error [SC103E]: 'T' has no subscript operator
fn <T impl Idx> wrong_arg(t: T) -> i32 { return t[true] }
// CHECK: bounds_subscript.k:[[@LINE-1]]:49: error [SC063E]: no matching overload for call to 'op []'
fn <T impl Idx> wrong_result(t: T) -> Q { var q: Q = t[3]; return q }
// CHECK: bounds_subscript.k:[[@LINE-1]]:54: error [SC028E]: cannot convert 'i32' to 'Q'
// CHECK-NOT: error

fn main() -> i32 { return 0 }
