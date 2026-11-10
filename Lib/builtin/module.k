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
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
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
pub import base::hash::*
pub import base::c_char::*

pub import num::bigint::*
pub import num::bigfloat::*
pub import num::float_ext::*
// num::f256_t / num::f512_t (and the softfloat engine under them) are NOT
// re-exported: four large files every program would compile. The compiler
// imports them into the files that name `f256` / `f512` (Preprocessor::
// _add_wide_floats, P723). num::f128_ext (f128's methods, whose sqrt and
// fma run that engine) is imported the same way, for files that name `f128`.

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
//   __builtin_*       each is an expression-bodied fn, and one that ends
//                     its file ICEs in codegen (TokenSink: "span runs past
//                     the end of its buffer"), so a file of
//                     only these cannot be built yet.
//   crash!            a prelude macro is found in the root's own scope
//                     only: the preprocessor does not follow a `pub import`.

/// The type of the `null` constant.
///
/// Every `null` converts to a `T?`, and a C++ host spells the constant
/// `::builtin::null`. It carries nothing, so the struct is empty.
pub struct null_t {}

/// The type behind `T?`. Kairo code spells it only as the `?` suffix; C++ hosts name it.
///
/// It is an ADT, so the payload is a real `T` only while present: it is constructed in place and
/// destroyed exactly once, and copy and move follow `T`'s own. Every implicit `T -> T?` and
/// `null -> T?` conversion is one of its constructors; C++ also gets `is_null()`, the unchecked
/// `__value()`, and `==` when `T` has one. The compiler may lay it out niche-filled (a null
/// pointer as the null case, for instance), so nothing may depend on the layout.
///
/// \see __builtin_niche_of
pub enum <T> Nullable {
    /// A present value: `T?` holding `v`.
    Value { v: T },
    /// No value: what `null` assigns to a `T?`.
    Null,
}

/// Counts the bit patterns a `T` never holds, which the layout engine uses to store a `T?` without
/// a tag: 1 for a pointer, the values past a plain enum's or an ADT tag's range, a record's first
/// field's niches, and 0 for anything else.
///
/// Answered at compile time: the compiler replaces every call with the count, so this body never
/// runs. Compiler test hook; user code has no reason to call it.
pub eval fn <T> __builtin_niche_of() -> u64 = 0

/// Returns `T`'s panic type id, the tag an `Err` holding a `T` is stored as. It is the same in
/// every translation unit.
///
/// Answered at compile time; this body never runs. Compiler test hook.
pub eval fn <T> __builtin_type_id() -> u32 = 0

/// Returns the panic site id of this call, registered in the translation unit's
/// `__kairo_panic_sites` table as a `panic` would be.
///
/// The compiler replaces every call with the id; this body never runs. Compiler test hook.
pub fn __builtin_panic_site() -> u32 = 0


/// Kairo-only type queries, answered at compile time for a concrete `T`. C++ spells a safe and an
/// unsafe pointer alike, and a class, a struct and an ADT enum are all C++ structs, so only the
/// compiler can tell them apart. A `T` that depends on a generic parameter is an error, and these
/// bodies never run. The queries C++ can answer are in `base/intrinsics.k`.
///
/// Each returns true when `T` is a safe pointer (`*U`).
pub eval fn <T> __builtin_is_safe_pointer() -> bool = false
/// Returns true when `T` is an unsafe pointer (`unsafe *U`).
pub eval fn <T> __builtin_is_unsafe_pointer() -> bool = false
/// Returns true when `T` is a nullable type (`U?`).
pub eval fn <T> __builtin_is_nullable() -> bool = false
/// Returns true when `T` is an enum with payload cases, not a plain enum.
pub eval fn <T> __builtin_is_adt_enum() -> bool = false
/// Returns true when `T` is a `class`.
pub eval fn <T> __builtin_is_class() -> bool = false
/// Returns true when `T` is a `struct`.
pub eval fn <T> __builtin_is_struct() -> bool = false
/// Returns true when `T` is a tuple type.
pub eval fn <T> __builtin_is_tuple() -> bool = false
/// Returns the number of elements of the tuple type `T`.
pub eval fn <T> __builtin_tuple_arity() -> usize = 0

/// Ends the process with an optional message: `crash!()` or `crash!("why")`.
///
/// Not a panic: it joins no panic set and no `try` catches it, so a function that calls it needs
/// no `panic` specifier and `main` may use it. The message and a newline go to stderr (nothing
/// when empty), then the process aborts. It expands to `crash_with(msg...)`, so the call never
/// returns and ends its path for the flow checks. What it reports is not final; rely only on "it
/// does not return". A file's own `crash!` shadows this one.
///
/// \see crash_with
/// \example
/// ```kairo
/// fn main() -> i32 {
///     if false { crash!("unreachable state") }
///     return 0
/// }
/// ```
pub macro crash!(...msg) { crash_with(msg...) }
