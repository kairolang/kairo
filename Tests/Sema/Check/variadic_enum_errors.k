enum <T, ...E> NoPayload { Ok { v: T }, Err... }
enum <T, ...E> NoPack { Ok { v: T }, Err { e: T }... }
enum <T, ...E> Twice { A { a: E }..., B { b: E }... }
enum <T, ...E> NotLast { Err { e: E }..., Ok { v: T } }
enum <T, ...E> Unexpanded { Ok { v: T }, Err { e: E } }
enum <T, ...E> Shaped { Ok { v: T }, Err { e: *E }... }
enum <T, ...E> Good { Ok { v: T }, Err { e: E }... }

fn build() {
    var a: Good<i32, i64, f64> = .Err { e: true }
    var b: Good<i32, i64, f64> = .Err { e: 1 }
    var c: Good<i32> = .Err { e: 1 }
}

fn read(g: Good<i32, i64, f64>) -> i32 = match g {
    case .Ok(var v) => v
    case .Err(var e) => 1
    case .Err(var e: bool) => 2
}

fn <T, ...E> gen(g: Good<T, E...>) -> i32 = match g {
    case .Err(var e) => 1
    default => 0
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// The rules of a pack-expanded variant `V { e: E }...` (PackChecking), and
// picking one of its elements by payload type in a construction
// (ControlTyping) and a pattern (PatternTyping).
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: variadic_enum_errors.k:1:44: error [SC001E]: variant 'Err' is followed by ... but has no payload, so there is nothing to expand
// CHECK-NEXT: fix-it:{{.*}}:{1:44-1:47}:""
// CHECK: variadic_enum_errors.k:2:50: error [SC001E]: variant 'Err' is followed by ..., but its payload names no type pack of 'NoPack'
// CHECK: variadic_enum_errors.k:3:24: error [SC001E]: pack-expanded variant 'A' must be the last variant of 'Twice'
// CHECK: variadic_enum_errors.k:3:49: error [SC001E]: 'Twice' already has a pack-expanded variant, 'A'; an enum expands its pack once
// CHECK: variadic_enum_errors.k:4:26: error [SC001E]: pack-expanded variant 'Err' must be the last variant of 'NotLast'
// CHECK-NEXT: variadic_enum_errors.k:4:43: note [I900N]: 'Ok' follows it, and its tag would move with the pack
// CHECK: variadic_enum_errors.k:5:51: error [SC001E]: variant 'Err' names the type pack 'E', but is one variant; add ... after it to make one variant per element of 'E'
// CHECK-NEXT: fix-it:{{.*}}:{5:54-5:54}:"..."
// CHECK: variadic_enum_errors.k:6:47: error [SC116E]: field 'e' of pack-expanded variant 'Err' builds a type from the pack; only the pack itself as the field's type is supported yet
// CHECK: variadic_enum_errors.k:10:44: error [SC001E]: no 'Good::Err' of 'Good<i32, i64, f64>' holds a 'bool'
// CHECK-NEXT: variadic_enum_errors.k:7:36: note [I900N]: its variants here: Err { e: i64 }, Err { e: f64 }
// CHECK: variadic_enum_errors.k:11:44: error [SC001E]: a 'i32' fits more than one 'Good::Err' of 'Good<i32, i64, f64>'; the payload's type must pick one
// CHECK: variadic_enum_errors.k:12:24: error [SC001E]: 'Good<i32>' has no 'Err' variant: its pack is empty
// CHECK: variadic_enum_errors.k:17:10: error [SC001E]: 'Err' is one variant per element of a pack in 'Good<i32, i64, f64>'; name the payload's type to pick one
// CHECK-NEXT: fix-it:{{.*}}:{17:20-17:20}:": i64"
// CHECK: variadic_enum_errors.k:18:22: error [SC001E]: no 'Err' of 'Good<i32, i64, f64>' holds a 'bool'
// CHECK: variadic_enum_errors.k:22:10: error [SC116E]: matching pack-expanded variant 'Err' at a type that depends on a generic parameter is not supported yet
