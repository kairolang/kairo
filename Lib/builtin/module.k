/// --- The Kairo Project ------------------------- Lib/builtin/module.k --- ///
///
///   The builtin root: every declaration sema binds as a lang item. Shipped
///   with the compiler, installed under <resource-dir>/builtin, imported
///   implicitly by every translation unit. Nothing here is user-visible by
///   any name but its own; `[T]`, `{K: V}` and `string` are sugar for it.
///
///   builtin DECLARES; std EXTENDS. A type sema needs a handle to goes here.
///   A method only users call goes in std.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

module builtin

pub import containers::*
pub import string::*
pub import types::*
pub import fmt::*

ffi "c" import "rt/unwrap.h"
ffi "c" import "rt/crash.h"

/// `null` as a value: the type of the constant every null converts from. A
/// C++ host spells the constant `::builtin::null` (InterfaceEmitter writes
/// it after this record; `null` is a Kairo keyword, so it has no Kairo
/// declaration of its own). Empty: a null carries nothing.
pub struct null_t {}

/// `T?`. Kairo code never names it (the `?` suffix is the only spelling);
/// C++ code does. An ADT (NULLABLE.md 1.2), so the payload is a real T only while present, constructed in place and
/// destroyed exactly once, and copy and move follow T's own -- the special
/// members EnumLayoutLowering gives every generic ADT. That pass also gives
/// THIS one, the lang item, the C++ surface the desugars and a C++ host
/// use: `Nullable()` and `Nullable(null_t)` (null), `Nullable(const T&)`
/// and `Nullable(T&&)` (present), `is_null()`, the unchecked `__value()`
/// and `==` when T has one. Every implicit `T -> T?` and `null -> T?` is
/// one of those constructors. EnumLayoutLowering may lay it out
/// niche-filled; nothing outside this declaration may depend on the layout.
pub enum <T> Nullable {
    Value { v: T },
    Null,
}

/// `^^` on a primitive base. Repeated squaring, so overflow is exactly `*`'s.
/// A negative exponent is `(1 / base) ^^ -exp` under the base type's own
/// division: for an integer base that reciprocal is 0, 1 or -1 and nothing
/// can overflow on the way back; for a float base it is the reciprocal.
/// `-(exp + 1)` rather than `-exp`, which has no value for the minimum.
priv fn <B, E> pow(base: B, exp: E) -> B {
    if exp < 0 {
        var inv: B = 1 / base
        return pow(inv, -(exp + 1)) * inv
    }
    var r: B = 1
    var b = base
    var e = exp
    while e > 0 {
        if (e % 2) == 1 { r = r * b }
        b = b * b
        e = e / 2
    }
    return r
}

/// How many bit patterns a `T` never holds: the layout engine's niche_of
/// (EnumLayoutLowering, spec ENUMLAYOUT §5.1) -- 1 for a pointer, the
/// values past a plain enum's or an ADT tag's, a record's first field's,
/// 0 for anything else. Answered at compile time: EnumLayoutLowering
/// replaces every call with the count, so this body never runs.
pub eval fn <T> __builtin_niche_of() -> u64 = 0

/// T's panic type id (PANIC.md §1.3): the tag an `Err` holding a T is
/// stored as, the same in every TU. A compiler test hook, answered at
/// compile time like __builtin_niche_of.
pub eval fn <T> __builtin_type_id() -> u32 = 0

/// The panic site id of this call (PANIC.md §1.4), registered in the TU's
/// `__kairo_panic_sites` table as a `panic` would be. A compiler test hook:
/// EnumLayoutLowering replaces every call with the id.
pub fn __builtin_panic_site() -> u32 = 0

/// `unwrap!(x)` on null (NULLABLE.md 2.6): `msg` (the expression and where
/// it is, built at compile time) to stderr, then abort. A lang item the
/// lowering calls; `-> !` makes the null arm of the expansion `Never`. Not
/// a panic: no `try` catches it and it is in no panic set.
pub fn unwrap_failed(msg: *const u8, len: usize) -> ! {
    unsafe { kairo_rt_unwrap_failed(msg as unsafe *const u8, len) }
}

/// What `crash!` calls: `msg` and a newline to stderr (nothing when it is
/// empty), then abort. `-> !`, so a `crash!()` ends its path for the flow
/// checks like any other call that never returns.
pub fn crash_with(msg: string = "") -> ! {
    unsafe { kairo_rt_crash(msg.data as unsafe *const u8, msg.len) }
}

/// `crash!()` / `crash!("why")`: end the process (PANIC.md §2.4). Not a
/// panic -- it joins no panic set and no `try` catches it -- so a function
/// that calls it needs no `panic` specifier, and `main` may use it. A
/// plain macro, not a compiler intrinsic: every file sees it through the
/// prelude, after its own imports, so a file's own `crash!` shadows it.
/// What it reports is not final; rely only on "it does not return".
///
/// The body is one identifier and the caller's own tokens: a literal
/// written here would be another file's literal at the use (TICKETS:
/// SC073E for a macro from another file), so the empty message is
/// crash_with's default, not the macro's. The call is unqualified (the
/// builtin root has no spelling in user code), so a function named
/// `crash_with` in scope at the use would capture it.
pub macro crash!(...msg) { crash_with(msg...) }
