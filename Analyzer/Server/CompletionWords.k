/// --- The Kairo Project ------------ Analyzer/Server/CompletionWords.k --- ///
///
///   The words of the language a completion offers: keywords, attributes,
///   builtin macros. Read from the compiler's own tables.
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

import AST::LangItems::{
    LangAttrs,
    LangIntrinsics,
    LangMacros,
}
import CompletionSite::*
import Token::TokenKind::{
    TokenKind,
    is_annotation,
    token_kind_to_readable_string,
    word_token_kinds,
}

/// A word of the language and where it can stand (KC_* bits).
pub struct Word {
    var text: string = ""
    var kc:   u32    = KC_ALL
}

/// A builtin attribute or macro: its word, how it is written with its
/// arguments, one line on what it does, and for an attribute what it may
/// stand before (LangAttrs::targets).
pub struct BuiltinRow {
    var word:    string = ""
    var usage:   string = ""
    var summary: string = ""
    var targets: string = ""
}

/// Where keyword \p k can start. The spelling is the compiler's; where a
/// word may stand is not something its table says, so it is said here, and
/// a word this does not name is offered everywhere.
fn word_context(k: TokenKind) -> u32 {
    match k {
        // a statement
        case TokenKind::KwReturn,  TokenKind::KwBreak,  TokenKind::KwContinue,
             TokenKind::KwWhile,   TokenKind::KwFor,    TokenKind::KwLoop,
             TokenKind::KwAssert,  TokenKind::KwDelete, TokenKind::KwYield,
             TokenKind::KwFinally, TokenKind::KwCase,   TokenKind::KwDefault,
             TokenKind::KwCatch {
            return KC_STMT
            // a statement or an expression
        } case TokenKind::KwIf,    TokenKind::KwElse,  TokenKind::KwMatch, TokenKind::KwTry,
               TokenKind::KwPanic, TokenKind::KwAwait, TokenKind::KwSpawn, TokenKind::KwThread {
            return KC_STMT | KC_EXPR
            // a declaration, in a body or outside one
        } case TokenKind::KwVar,    TokenKind::KwFn,    TokenKind::KwClass, TokenKind::KwStruct,
               TokenKind::KwEnum,   TokenKind::KwUnion, TokenKind::KwType,  TokenKind::KwInterface,
               TokenKind::KwStatic, TokenKind::KwEval,  TokenKind::KwMacro, TokenKind::KwInline,
               TokenKind::KwAsync {
            return KC_STMT | KC_DECL
            // a declaration outside a body
        } case TokenKind::KwExtend,   TokenKind::KwModule,  TokenKind::KwTest,
               TokenKind::KwImport,   TokenKind::KwFfi,     TokenKind::KwPub,
               TokenKind::KwPriv,     TokenKind::KwProt,    TokenKind::KwOverride,
               TokenKind::KwFinal,    TokenKind::KwVirtual, TokenKind::KwOp,
               TokenKind::KwDerives,  TokenKind::KwImpl,    TokenKind::KwWhere,
               TokenKind::KwRequires {
            return KC_DECL
            // a qualifier: before a declaration, in a type, before a parameter
        } case TokenKind::KwConst {
            return KC_STMT | KC_DECL | KC_TYPE | KC_PARAM
        } case TokenKind::KwUnsafe {
            return KC_STMT | KC_EXPR | KC_DECL | KC_TYPE
        } case TokenKind::KwAtomic, TokenKind::KwVolatile, TokenKind::KwMutable {
            return KC_DECL | KC_TYPE
        } case TokenKind::KwSelf {
            return KC_EXPR | KC_PARAM
        } case TokenKind::BiSelf {
            return KC_EXPR | KC_TYPE
            // values and operators that are words
        } case TokenKind::KwTrue,   TokenKind::KwFalse,    TokenKind::LitNull,
               TokenKind::KwSizeOf, TokenKind::KwAlignOf,  TokenKind::KwTypeOf,
               TokenKind::KwAs,     TokenKind::KwIn,       TokenKind::KwAnd,
               TokenKind::KwAndEq,  TokenKind::KwBitand,   TokenKind::KwBitor,
               TokenKind::KwCompl,  TokenKind::KwNot,      TokenKind::KwNotEq,
               TokenKind::KwOr,     TokenKind::KwOrEq,     TokenKind::KwXor,
               TokenKind::KwXorEq,  TokenKind::BiFile,     TokenKind::BiLine,
               TokenKind::BiColumn, TokenKind::BiFunction, TokenKind::BiModule {
            return KC_EXPR
        } default {
            // A primitive type's name: a type, and in an expression the
            // head of `i32::MAX` or a cast's target.
            if is_annotation(k) {
                return KC_TYPE | KC_EXPR
            }

            return KC_ALL
        }
    }
}

/// Every word the lexer makes a token kind of, spelled by the compiler's
/// table (Token/TokenKind.k), with where it can stand.
pub fn language_words() -> [Word] {
    var out:  [Word]
    var kinds        = word_token_kinds()
    for var i: usize = 0; i < kinds.size(); ++i {
        var w = Word{}
        w.text = token_kind_to_readable_string(kinds[i])
        w.kc   = word_context(kinds[i])
        if !w.text.empty() {
            out.push_back(w)
        }
    }

    return out
}

/// The attributes the compiler gives a meaning (AST/LangItems.k, LangAttrs).
pub fn builtin_attributes() -> [BuiltinRow] {
    var out: [BuiltinRow]
    var i:   usize        = 0
    while true {
        var word = LangAttrs::known(i)
        if word.empty() {
            break
        }

        // One row per word: `move` is a constructor's and a parameter's.
        var dup = false
        for var k: usize = 0; k < out.size(); ++k {
            if out[k].word == word {
                dup = true
            }
        }

        if !dup {
            var r = BuiltinRow{}
            r.word    = word
            r.usage   = LangAttrs::usage(word)
            r.summary = LangAttrs::summary(word)
            r.targets = LangAttrs::targets(word)
            out.push_back(r)
        }

        i += 1
    }

    return out
}

/// The preprocessor's builtin macros and the parser's `name!` intrinsics.
pub fn builtin_macros() -> [BuiltinRow] {
    var out: [BuiltinRow]
    var i:   usize        = 0
    while true {
        var word = LangMacros::known(i)
        if word.empty() {
            break
        }

        var r = BuiltinRow{}
        r.word    = word
        r.usage   = LangMacros::usage(word)
        r.summary = LangMacros::summary(word)
        out.push_back(r)
        i += 1
    }

    i = 0
    while true {
        var word = LangIntrinsics::known(i)
        if word.empty() {
            break
        }

        var r = BuiltinRow{}
        r.word    = word
        r.usage   = LangIntrinsics::usage(word)
        r.summary = LangIntrinsics::summary(word)
        out.push_back(r)
        i += 1
    }

    return out
}

/// Whether \p list, words separated by spaces, holds \p w.
pub fn has_word(const list: string, const w: string) -> bool {
    var i: usize = 0
    while i < list.size() {
        var e = i
        while (e < list.size()) && (list[e] != (' ' as u8)) {
            e += 1
        }

        if list.subslice(i, e - i) == w {
            return true
        }

        i = e + 1
    }

    return false
}

fn first_byte(const s: string, c: u8) -> usize {
    for var i: usize = 0; i < s.size(); ++i {
        if s[i] == c {
            return i
        }
    }

    return usize::MAX
}

/// \p usage (`align(N)`, `paste!(a, b)`) as a snippet: each argument a
/// placeholder (`align(${1:N})`). A usage with no arguments is itself.
pub fn usage_snippet(const usage: string) -> string {
    var open = first_byte(usage, '(' as u8)
    if open == usize::MAX {
        // `create T(args)`: the word, then the rest as one placeholder.
        var sp = first_byte(usage, ' ' as u8)
        if sp == usize::MAX {
            return usage
        }

        return usage.subslice(0, sp + 1) + "${1:" + usage.subslice(
            sp + 1,
            usage.size() - sp - 1,
        ) + "}"
    }

    var out       = usage.subslice(0, open + 1)
    var n:  usize = 1
    var p         = open + 1
    while p < usage.size() {
        var e = p
        while (e < usage.size()) && (usage[e] != (',' as u8)) && (usage[e] != (')' as u8)) {
            e += 1
        }

        var arg       = usage.subslice(p, e - p)
        var a:  usize = 0
        while (a < arg.size()) && (arg[a] == (' ' as u8)) {
            a += 1
        }

        arg = arg.subslice(a, arg.size() - a)
        if !arg.empty() {
            if n > 1 {
                out += ", "
            }

            out += "${" + f"{n}" + ":" + arg + "}"
            n += 1
        }

        if (e >= usage.size()) || (usage[e] == (')' as u8)) {
            break
        }

        p = e + 1
    }

    out += ")"
    return out
}
