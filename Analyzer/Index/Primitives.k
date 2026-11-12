/// --- The Kairo Project ------------------ Analyzer/Index/Primitives.k --- ///
///
///   What `::` after a primitive type's name (`usize::`, `f64::`) can name
///   that no declaration table holds: the associated constants the
///   compiler computes (`usize::MAX`, `f64::EPSILON`; AST/PrimitiveLimits.k).
///   One list for the index path (Server/IndexCompletion.k) and the marker
///   path (Index/CompletionItems.k), read off the compiler's own table, so
///   neither offers a limit the compiler refuses (`i32::EPSILON`, R024E)
///   or misses one it has.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


ffi "c++" import "Native/Types.hh"

import AST::Node::CanonicalNodes::{
    BuiltinKind,
    builtin_for_token,
    builtin_info,
}
import AST::PrimitiveLimits::{
    PrimLimit,
    PrimitiveLimits,
}
import Token::TokenKind::{
    token_kind_to_readable_string,
    word_token_kinds,
}

/// One associated constant of a primitive, as an item shows it.
pub struct PrimConst {
    var name:   string = ""
    var detail: string = "" ///< `const MAX: usize`
}

/// The primitive a type NAME spells (`usize`, `f64`, `char`), or
/// BuiltinKind::COUNT: the lexer's word for it, mapped as TypeResolution
/// maps a type-position token (builtin_for_token), so a name is a
/// primitive here exactly when it is one to the compiler.
pub fn primitive_of(const name: string) -> BuiltinKind {
    if name.empty() {
        return BuiltinKind::COUNT
    }

    var ks = word_token_kinds()
    for var i: usize = 0; i < ks.size(); ++i {
        if token_kind_to_readable_string(ks[i]) == name {
            return builtin_for_token(ks[i])
        }
    }

    return BuiltinKind::COUNT
}

/// The source spelling of primitive \p b (`usize`).
pub fn primitive_spelling(b: BuiltinKind) -> string {
    return builtin_info(b)->spelling
}

/// The associated constants \p b has, in the enum's order: every
/// PrimLimit PrimitiveLimits::exists says \p b has, typed as the compiler
/// types it (result_kind: `u32` for a count, `i32` for an exponent).
pub fn primitive_consts(b: BuiltinKind) -> [PrimConst] {
    var out: [PrimConst]
    if b == BuiltinKind::COUNT {
        return out
    }

    // PrimLimit::None is 0 and Radix the last: the enum cannot be asked
    // for its size, and a limit added after Radix is added here.
    var last = (PrimLimit::Radix as u8)
    for var i: u8 = 1; i <= last; ++i {
        var k = (i as PrimLimit)
        if !PrimitiveLimits::exists(b, k) {
            continue
        }

        var c = PrimConst{}
        c.name   = PrimitiveLimits::name_of(k)
        c.detail = "const " + c.name + ": " + builtin_info(PrimitiveLimits::result_kind(b, k))->spelling
        out.push_back(c)
    }

    return out
}
