// An instantiation chain that never ends: `f<T>` calls `f<Wrap<T>>`. The
// discovery fixpoint follows it to --cmax-generic-depth (default 128) and
// reports it at the use that started it, naming the chain's first three
// and last three instances; it used to stop silently at depth 8 and leave
// the recursion to clang.

pub struct <E> Wrap { pub var item: E }
pub fn <T> f(x: T) -> i32 {
    return f(Wrap<T> { item: x })
}
fn main() -> i32 {
    return f(1)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DEF
// DEF: instantiation_depth.k:12:12: error [SC001E]: instantiation depth exceeds 128: 'f<i32>' -> 'f<Wrap<i32>>' -> 'f<Wrap<Wrap<i32>>>' -> ... -> 'f<Wrap<{{(Wrap<)+}}i32{{>+}}' -> 'f<Wrap<{{(Wrap<)+}}i32{{>+}}' -> 'f<Wrap<{{(Wrap<)+}}i32{{>+}}'{{$}}
// DEF: instantiation_depth.k:9:12: note [I900N]: 'f<Wrap<{{(Wrap<)+}}i32{{>+}}' is required here, instantiation 129 of the chain
// DEF: note [I900N]: the limit is set by --cmax-generic-depth
// DEF-NOT: error

// RUN: { %kairo %s --type-check-only --cmax-generic-depth=4 2>&1 || true; } | %FileCheck %s --check-prefix=LOW
// LOW: instantiation_depth.k:12:12: error [SC001E]: instantiation depth exceeds 4: 'f<i32>' -> 'f<Wrap<i32>>' -> 'f<Wrap<Wrap<i32>>>' -> 'f<Wrap<Wrap<Wrap<i32>>>>' -> 'f<Wrap<Wrap<Wrap<Wrap<i32>>>>>'{{$}}
// LOW: instantiation_depth.k:9:12: note [I900N]: 'f<Wrap<Wrap<Wrap<Wrap<i32>>>>>' is required here, instantiation 5 of the chain
// LOW-NOT: error
