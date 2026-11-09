/// --- The Kairo Project -------------------------- AST/OperatorFacts.k --- ///
///
///   \brief What an operator declaration IS, read off its tokens: the
///          operator with the fixity marker removed, its table key, whether
///          it is postfix, and the compound/base pairing. Every sema reader
///          of `FunctionDecl::op_token` goes through here. CXXSpell's
///          is_place_operator mirrors is_place, return-type test included,
///          on the codegen side of the import boundary, on purpose.
///
///   Spelled through the DECL'S OWN context: `op_token` carries per-fid imm
///   indices, and reading it against another TU's context gives the
///   interner's fallback text for an operator declared anywhere else.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::SymbolTable::DeclName
import AST::Context::TranslationUnit::TranslationUnit
import AST::LangItems::LangAttrs
import AST::Node::Base::Type
import AST::Node::CanonicalNodes::canon_unqual
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations::FunctionDecl
import AST::Node::Types::{
    CXXLValueRefType,
    PointerType,
}
import Token::TokenKind::TokenKind

pub class OperatorFacts {
    /// The context \p f's tokens were interned in: its TU's. NameLookup::
    /// ctx_of's walk, restated here because the AST layer cannot import
    /// Sema -- the function's own scope chain first, then its semantic and
    /// lexical parents for a decl whose own chain is not linked.
    priv static fn _ctx(f: unsafe *FunctionDecl) -> unsafe *ASTContext {
        if f == &null {
            return &null
        }

        var unsafe *tu = OperatorFacts::_tu_of(unsafe (f as unsafe *DeclContext))
        if tu == &null {
            tu = OperatorFacts::_tu_of(f->semantic_dc)
        }

        if tu == &null {
            tu = OperatorFacts::_tu_of(f->lexical_dc)
        }

        if tu == &null {
            return &null
        }

        return tu->ctx
    }

    priv static fn _tu_of(dc: unsafe *DeclContext) -> unsafe *TranslationUnit {
        var unsafe *c = dc
        while c != &null {
            if c->dc_kind == DeclContextKind::TranslationUnit {
                return unsafe (c as unsafe *TranslationUnit)
            }

            c = c->dc_parent
        }

        return &null
    }

    /// `l` / `r` written in front of `++` / `--`. By KIND: a bare identifier
    /// is never an operator token, and the marker's spelling depends on how
    /// the parser cut the ranges.
    pub static fn has_fixity(f: unsafe *FunctionDecl) -> bool {
        if f == &null || !f->is_operator || f->op_token.size() != 2 {
            return false
        }

        if f->op_token[0].kind != TokenKind::LitIdentifier {
            return false
        }

        var k = f->op_token[1].kind
        return k == TokenKind::OpPlusPlus || k == TokenKind::OpMinusMinus
    }

    /// `op r++` / `op r--`. An unmarked `op ++` is prefix (OperatorSignatureCheck warns).
    pub static fn is_postfix(f: unsafe *FunctionDecl) -> bool {
        if !OperatorFacts::has_fixity(f) {
            return false
        }

        var unsafe *c = OperatorFacts::_ctx(f)
        if c == &null {
            return false
        }

        var s = c->get_spelling(f->op_token[0])
        return s.size() > 0 && s[0] == ('r' as u8)
    }

    /// Index of the first token that is the operator itself.
    priv static fn _first(f: unsafe *FunctionDecl) -> usize {
        return if (OperatorFacts::has_fixity(f)) => (1) else => 0
    }

    /// The operator's token kind (the first one: `[` for `op []`).
    pub static fn op_kind(f: unsafe *FunctionDecl) -> TokenKind {
        if f == &null || f->op_token.size() == 0 {
            return TokenKind::TkUnknown
        }

        var i = OperatorFacts::_first(f)
        if i >= f->op_token.size() {
            return TokenKind::TkUnknown
        }

        return f->op_token[i].kind
    }

    /// THE table key. Fixity is a fact about the decl, not part of its name:
    /// `op l++` and `op r++` are one cell, and X picks by is_postfix.
    /// ASTParse::_op_decl_name keys the parser side by the same rule.
    pub static fn key(f: unsafe *FunctionDecl) -> DeclName {
        var k0 = TokenKind::TkUnknown
        var k1 = TokenKind::TkUnknown
        var n  = f->op_token.size()
        var i  = OperatorFacts::_first(f)
        if i < n {
            k0 = f->op_token[i].kind
        }

        if i + 1 < n {
            k1 = f->op_token[i + 1].kind
        }

        return DeclName::op_name(k0, k1)
    }

    /// `+`, `+=`, `[]`, `<=>`, `in`: the spelling with the marker dropped.
    /// A marked `++`/`--` is spelled from its kind: the token's own range may
    /// include the marker.
    pub static fn symbol(f: unsafe *FunctionDecl) -> string {
        if OperatorFacts::has_fixity(f) {
            return if (f->op_token[1].kind == TokenKind::OpPlusPlus) => ("++") else => "--"
        }

        var unsafe *c = OperatorFacts::_ctx(f)
        if c == &null {
            return "<op>"
        }

        var s = ""
        for var i: usize = 0; i < f->op_token.size(); ++i {
            s += c->get_spelling(f->op_token[i])
        }

        return s
    }

    /// `[]`: the one operator that MAY be a place, whatever it returns. `->`
    /// is not one: C++'s `operator->` returns a pointer, and so does Kairo's.
    /// `.*` and `->*` are not overloadable at all (the parser rejects the
    /// declaration), so they never reach here. Signature identity keys on
    /// this (RedeclMerge); the place/value decision is is_place's.
    pub static fn is_place_kind(f: unsafe *FunctionDecl) -> bool {
        if f == &null || !f->is_operator || !f->is_method() {
            return false
        }

        var s = OperatorFacts::symbol(f)
        return s == "[]"
    }

    /// `[]` returning a safe `*T` / `*const T`: a place into `self`,
    /// which C++ receives as `T&` / `const T&`. The kind alone does not decide:
    /// `op [] -> [T;]` (slicing) is a value operator. `->` is never a place.
    /// A null canonical (no return type, or unresolved) is not a place.
    /// returns_place: that, or a `cxx_ref_return` function (the same C++ shape).
    /// \p kairo_ret (a Kairo definition's return type) is `*T` / `*const T`,
    /// raw or safe, and \p cxx_ret (the C++ declaration's) is `T&` / `const
    /// T&` of the same T: the definition implements the reference return
    /// (FunctionDecl::cxx_ref_return).
    pub static fn ptr_implements_lref(kairo_ret: unsafe *Type, cxx_ret: unsafe *Type) -> bool {
        var unsafe *pc = canon_unqual(kairo_ret)
        var unsafe *lc = canon_unqual(cxx_ret)
        if pc == &null || lc == &null || (!isa<PointerType>(pc)) || !isa<CXXLValueRefType>(lc) {
            return false
        }

        var unsafe *a = cast<PointerType>(pc)->pointee
        var unsafe *b = cast<CXXLValueRefType>(lc)->referee
        if a == &null || b == &null {
            return false
        }

        var unsafe *ac = if (a->canonical != &null) => (a->canonical) else => a
        var unsafe *bc = if (b->canonical != &null) => (b->canonical) else => b
        return ac == bc
    }

    pub static fn returns_place(f: unsafe *FunctionDecl) -> bool {
        return f != &null && (f->cxx_ref_return || OperatorFacts::is_place(f))
    }

    pub static fn is_place(f: unsafe *FunctionDecl) -> bool {
        if !OperatorFacts::is_place_kind(f) {
            return false
        }

        if f->return_type == &null || f->return_type->canonical == &null {
            return false
        }

        var unsafe *c = canon_unqual(f->return_type->canonical)
        return c != &null && isa<PointerType>(c) && !cast<PointerType>(c)->is_unsafe
    }

    /// `@implicit fn op as (self) -> T`: a conversion the compiler may apply
    /// without an `as` (Conversion::implicit's user rung). Probed in the
    /// DECL'S OWN imm table: attribute names are per-fid imms, and the
    /// operator is usually declared in another TU (Lib/builtin). Never
    /// interned: a name its file never spelled is on no decl there.
    pub static fn is_implicit_conv(f: unsafe *FunctionDecl) -> bool {
        if f == &null || !f->is_operator || !f->is_method() {
            return false
        }

        if OperatorFacts::op_kind(f) != TokenKind::KwAs {
            return false
        }

        return OperatorFacts::has_implicit_attr(f)
    }

    /// `@implicit` written on \p f, whatever \p f is. OperatorSignatureCheck
    /// rejects it everywhere but on a member `op as`.
    pub static fn has_implicit_attr(f: unsafe *FunctionDecl) -> bool {
        if f == &null {
            return false
        }

        var unsafe *c = OperatorFacts::_ctx(f)
        if c == &null || c->get_imm_table() == &null {
            return false
        }

        var k = c->get_imm_table()->find_ident(LangAttrs::implicit_conversion())
        if k == u32::MAX {
            return false
        }

        return f->has_attribute_named(k)
    }

    /// Parameters after `self`.
    pub static fn arity(f: unsafe *FunctionDecl) -> usize {
        var n: usize = 0
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null || p->is_self {
                continue
            }

            n += 1
        }

        return n
    }

    /// The binary operator a compound assignment is built from, or TkUnknown.
    pub static fn compound_base(k: TokenKind) -> TokenKind {
        match k {
            case TokenKind::OpPlusEqual {
                return TokenKind::OpPlus
            } case TokenKind::OpMinusEqual {
                return TokenKind::OpMinus
            } case TokenKind::OpStarEqual {
                return TokenKind::OpStar
            } case TokenKind::OpSlashEqual {
                return TokenKind::OpSlash
            } case TokenKind::OpPercentEqual {
                return TokenKind::OpPercent
            } case TokenKind::OpAmpEqual {
                return TokenKind::OpAmp
            } case TokenKind::OpPipeEqual {
                return TokenKind::OpPipe
            } case TokenKind::OpCaretEqual {
                return TokenKind::OpCaret
            } case TokenKind::OpLessLessEqual {
                return TokenKind::OpLessLess
            } case TokenKind::OpGreaterGreaterEqual {
                return TokenKind::OpGreaterGreater
            } case TokenKind::KwAndEq {
                return TokenKind::OpAmp
            } case TokenKind::KwOrEq {
                return TokenKind::OpPipe
            } case TokenKind::KwXorEq {
                return TokenKind::OpCaret
            } default {
                return TokenKind::TkUnknown
            }
        }
    }

    /// The compound assignment built from a binary operator, or TkUnknown.
    pub static fn compound_of(k: TokenKind) -> TokenKind {
        match k {
            case TokenKind::OpPlus {
                return TokenKind::OpPlusEqual
            } case TokenKind::OpMinus {
                return TokenKind::OpMinusEqual
            } case TokenKind::OpStar {
                return TokenKind::OpStarEqual
            } case TokenKind::OpSlash {
                return TokenKind::OpSlashEqual
            } case TokenKind::OpPercent {
                return TokenKind::OpPercentEqual
            } case TokenKind::OpAmp {
                return TokenKind::OpAmpEqual
            } case TokenKind::OpPipe {
                return TokenKind::OpPipeEqual
            } case TokenKind::OpCaret {
                return TokenKind::OpCaretEqual
            } case TokenKind::OpLessLess {
                return TokenKind::OpLessLessEqual
            } case TokenKind::OpGreaterGreater {
                return TokenKind::OpGreaterGreaterEqual
            } case TokenKind::KwBitand {
                return TokenKind::OpAmpEqual
            } case TokenKind::KwBitor {
                return TokenKind::OpPipeEqual
            } case TokenKind::KwXor {
                return TokenKind::OpCaretEqual
            } default {
                return TokenKind::TkUnknown
            }
        }
    }

    pub static fn is_compound(k: TokenKind) -> bool {
        return OperatorFacts::compound_base(k) != TokenKind::TkUnknown
    }
}
