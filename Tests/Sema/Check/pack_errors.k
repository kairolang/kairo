class <...T> Holder {
    var xs: T
}
fn <...T> ret(...xs: T) -> T { return 0 }
fn <...T> param(x: T) { }
fn <...T> value(...xs: T) {
    var y = xs
}
fn <...T> loose(...xs: T) -> i32 {
    var z = (xs...)
    return 0
}
fn <...T> count(...xs: T) -> i32 { return 0 }
fn <T, ...U> notpack(x: T, ...ys: U) -> i32 { return count(x...) }
fn <...T> forward(...xs: T) -> i32 { return count(xs...) }
fn main() -> i32 { return count<i32>(1) + forward(1, 2) }

// --- lit wiring -----------------------------------------------------------
// A type pack is written expanded or as a pack parameter's type, and a pack
// parameter is forwarded as a call argument or iterated (PackChecking);
// its elements are deduced, not written (OverloadResolution).
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: pack_errors.k:2:13: error [SC001E]: 'T' is a type pack and stands for several types; a field cannot have it as its type
// CHECK: pack_errors.k:4:28: error [SC001E]: 'T' is a type pack and stands for several types; a return value cannot have it as its type
// CHECK: pack_errors.k:5:20: error [SC001E]: 'T' is a type pack and stands for several types; a parameter that is not a pack parameter cannot have it as its type
// CHECK: pack_errors.k:7:13: error [SC001E]: 'xs' is a pack of values with different types; pass it on expanded as an argument, or iterate it with a for loop
// CHECK-NEXT: pack_errors.k:6:17: note [I900N]: declared as a pack here
// CHECK: pack_errors.k:10:14: error [SC001E]: a pack expansion is written only as a call argument, where it passes each element as its own argument
// CHECK: pack_errors.k:14:60: error [SC001E]: only a pack parameter can be expanded
// CHECK: pack_errors.k:16:27: error [SC063E]: no matching overload for call to 'count'
// CHECK-NEXT: pack_errors.k:13:1: note [I900N]: candidate not viable: 'T' is a type pack, deduced from the arguments; it cannot be written as a generic argument yet
