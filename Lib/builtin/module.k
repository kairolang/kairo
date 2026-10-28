/// --- The Kairo Project ------------------------- Lib/builtin/module.k --- ///
///
///   The builtin root: every declaration sema binds as a lang item is
///   declared here or re-exported from here. Shipped with the compiler,
///   installed under <resource-dir>/builtin, imported implicitly by every
///   translation unit. Nothing here is user-visible by any name but its
///   own; `[T]`, `{K: V}` and `string` are sugar for it. README has the
///   layout.
///
///   builtin DECLARES; std EXTENDS. A type sema needs a handle to goes here.
///   A method only users call goes in std.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

module builtin

pub import string::*

pub import base::range::*
pub import base::ordering::*
pub import base::byte_t::*
pub import base::pow::*
pub import base::intrinsics::*

pub import num::bigint::*
pub import num::bigfloat::*

pub import errors::panic_result::*
pub import errors::panic_raise::*
pub import errors::panic_catch::*
pub import errors::assert_fail::*
pub import errors::crash::*

pub import containers::slice::*
pub import containers::vector::*
pub import containers::hash_set::*
pub import containers::hash_map::*

pub import coro::future::*
pub import coro::suspend::*
pub import coro::generator::*

pub import fmt::fmt_buf::*

// --- declared in the root ---------------------------------------------------
//
// What stays here, and why, until it can move: a file is one C++ namespace,
// so the root's own declarations are the only ones in `::builtin`.
//   null_t, Nullable  a C++ host spells them `::builtin::null_t`,
//                     `::builtin::null` and `::builtin::Nullable`.
//   __builtin_c_char  C's `char`, one alias that std re-exports as
//                     std::c_char: builtin because a lang item binds from
//                     builtin only, and too small for a file of its own.
//   __builtin_*       each is an expression-bodied fn, and one that ends
//                     its file ICEs in codegen (TokenSink: "span runs past
//                     the end of its buffer"; TICKETS.TXT), so a file of
//                     only these cannot be built yet.
//   crash!            a prelude macro is found in the root's own scope
//                     only: the preprocessor does not follow a `pub import`.

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

/// C and C++'s plain `char`, the third 8-bit character type beside `signed
/// char` (i8) and `unsigned char` (u8). Users spell it `std::c_char` (std
/// re-exports this). The CChar lang item: TypeResolve gives this alias
/// BuiltinKind::CChar, which C++ spells `char`; the `u8` below is only what
/// parses, never the type. Here because a lang item binds from builtin.
pub type __builtin_c_char = u8

/// Kairo-only type queries: C++ spells a safe and an unsafe pointer alike,
/// and a class, a struct and an ADT enum are all C++ structs, so only the
/// compiler knows. EnumLayoutLowering answers each call for a concrete T;
/// a T that depends on a generic parameter is an error. These bodies never
/// run. The C++-answerable traits are in base/intrinsics.k.
pub eval fn <T> __builtin_is_safe_pointer() -> bool = false
pub eval fn <T> __builtin_is_unsafe_pointer() -> bool = false
pub eval fn <T> __builtin_is_nullable() -> bool = false
pub eval fn <T> __builtin_is_adt_enum() -> bool = false
pub eval fn <T> __builtin_is_class() -> bool = false
pub eval fn <T> __builtin_is_struct() -> bool = false
pub eval fn <T> __builtin_is_tuple() -> bool = false
pub eval fn <T> __builtin_tuple_arity() -> usize = 0

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
