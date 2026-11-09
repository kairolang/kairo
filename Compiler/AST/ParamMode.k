/// --- The Kairo Project ------------------------------ AST/ParamMode.k --- ///
///
///   \brief Parameter passing modes.
///
///   \detail
///     Kairo source has no reference types, but it declares, overrides and
///     defines out of line C++ functions taking `T&`, `const T&` and `T&&`.
///     The mode is how a parameter says which:
///
///       x: T            Value   C++ `T`
///       const x: T      Value   C++ `const T&` when the lowering decides it
///                               is worth it, `const T` otherwise. NOT a mode:
///                               the parameter is a read-only value, and the
///                               ABI choice is a pure function of the
///                               canonical type, computed identically in
///                               every TU (or two TUs emit two declarations
///                               of one function). A generic parameter
///                               always takes `const T&`.
///       @inout x: T     Inout   C++ `T&`.  The call site writes `&x`.
///       @move x: T      Move    C++ `T&&`. The call site writes `x`.
///
///     A mode is legal ONLY on a function/closure/method parameter and on a
///     parameter position of a function pointer type. `@inout`/`@move` are
///     OpAt + identifier, deliberately: no new keywords in the token table.
///
///     Modes are part of the FUNCTION TYPE (FunctionPointerType::modes,
///     folded into the canonical key) because a closure lowers to a lambda
///     whose type is a fn-pointer canonical, and a mode that is not in the
///     type does not exist for closures.
///
///     Signature identity (RedeclMerge): `@inout` is in the signature and
///     can overload -- `f(a)` picks `f(x: T)`, `f(&a)` picks `f(@inout x: T)`.
///     `@move` is in the signature for C++ but CANNOT overload: `f(x)` is
///     the same text either way, so `f(x: T)` beside `f(@move x: T)` is an
///     error at the second.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub enum ParamMode derives u8 {
    Value = 0, ///< `x: T` / `const x: T`. The zero value: ASTContext::alloc's memset is a correct default.
    Inout, ///< `@inout x: T`.
    Move,  ///< `@move x: T`.
}

/// The source spelling of a mode, with a trailing space so a printer can
/// prefix it to a parameter; "" for Value.
pub fn param_mode_prefix(m: ParamMode) -> string {
    match m {
        case ParamMode::Inout {
            return "@inout "
        } case ParamMode::Move {
            return "@move "
        } default {
            return ""
        }
    }
}

/// The bare keyword, for diagnostics: "@inout" / "@move" / "by value".
pub fn param_mode_name(m: ParamMode) -> string {
    match m {
        case ParamMode::Inout {
            return "@inout"
        } case ParamMode::Move {
            return "@move"
        } default {
            return "by value"
        }
    }
}
