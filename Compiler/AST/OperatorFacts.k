/// --- The Kairo Project ----------------------- AST/OperatorFacts.k ----- ///
///
///   \brief What an operator declaration IS, read off its tokens: the
///          operator with the fixity marker removed, its table key, whether
///          it is postfix, and the compound/base pairing. Every sema reader
///          of `FunctionDecl::op_token` goes through here. CXXSpell keeps its
///          own three-line copy on the codegen side of the import boundary,
///          on purpose.
///
///   Spelled through the DECL'S OWN context: `op_token` carries per-fid imm
///   indices, and reading it against another TU's context gives the
///   interner's fallback text for an operator declared anywhere else.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Context::SymbolTable::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import Token::Token::*;
import Token::TokenKind::*;

class OperatorFacts {
    /// The context \p f's tokens were interned in: its TU's. NameLookup::
    /// ctx_of's walk, restated here because the AST layer cannot import
    /// Sema -- the function's own scope chain first, then its semantic and
    /// lexical parents for a decl whose own chain is not linked.
    priv static fn _ctx(f: *FunctionDecl) -> *ASTContext {
        if f == &null { return &null; }
        var tu = OperatorFacts::_tu_of(static_cast::<*DeclContext>(f));
        if tu == &null { tu = OperatorFacts::_tu_of(reinterpret_cast::<*DeclContext>(f->semantic_dc)); }
        if tu == &null { tu = OperatorFacts::_tu_of(reinterpret_cast::<*DeclContext>(f->lexical_dc)); }
        if tu == &null { return &null; }
        return tu->ctx;
    }

    priv static fn _tu_of(dc: *DeclContext) -> *TranslationUnit {
        var c = dc;
        while c != &null {
            if c->dc_kind == DeclContextKind::TranslationUnit { return reinterpret_cast::<*TranslationUnit>(c); }
            c = c->dc_parent;
        }
        return &null;
    }

    /// `l` / `r` written in front of `++` / `--`.
    static fn has_fixity(f: *FunctionDecl) -> bool {
        if (f == &null) || (!f->is_operator) || (f->op_token.size() != 2) { return false; }
        var c = OperatorFacts::_ctx(f);
        if c == &null { return false; }
        var s = c->get_spelling(f->op_token[0]);
        return (s == "l") || (s == "r");
    }

    /// `op r++` / `op r--`. An unmarked `op ++` is prefix (OperatorSignatureCheck warns).
    static fn is_postfix(f: *FunctionDecl) -> bool {
        if !OperatorFacts::has_fixity(f) { return false; }
        var c = OperatorFacts::_ctx(f);
        return c->get_spelling(f->op_token[0]) == "r";
    }

    /// Index of the first token that is the operator itself.
    priv static fn _first(f: *FunctionDecl) -> usize {
        return (1) if (OperatorFacts::has_fixity(f)) else (0);
    }

    /// The operator's token kind (the first one: `[` for `op []`).
    static fn op_kind(f: *FunctionDecl) -> TokenKind {
        if (f == &null) || (f->op_token.size() == 0) { return TokenKind::TkUnknown; }
        var i = OperatorFacts::_first(f);
        if i >= f->op_token.size() { return TokenKind::TkUnknown; }
        return f->op_token[i].kind;
    }

    /// THE table key. Fixity is a fact about the decl, not part of its name:
    /// `op l++` and `op r++` are one cell, and X picks by is_postfix.
    /// ASTParse::_op_decl_name keys the parser side by the same rule.
    static fn key(f: *FunctionDecl) -> DeclName {
        var k0 = TokenKind::TkUnknown;
        var k1 = TokenKind::TkUnknown;
        var n  = f->op_token.size();
        var i  = OperatorFacts::_first(f);
        if i < n       { k0 = f->op_token[i].kind; }
        if (i + 1) < n { k1 = f->op_token[i + 1].kind; }
        return DeclName::op_name(k0, k1);
    }

    /// `+`, `+=`, `[]`, `<=>`, `in`: the spelling with the marker dropped.
    static fn symbol(f: *FunctionDecl) -> string {
        var c = OperatorFacts::_ctx(f);
        if c == &null { return "<op>"; }
        var s = "";
        for var i: usize = OperatorFacts::_first(f); i < f->op_token.size(); ++i {
            s += c->get_spelling(f->op_token[i]);
        }
        return s;
    }

    /// Parameters after `self`.
    static fn arity(f: *FunctionDecl) -> usize {
        var n: usize = 0;
        for var i: usize = 0; i < f->params.size(); ++i {
            var p = f->params[i];
            if (p == &null) || p->is_self { continue; }
            n += 1;
        }
        return n;
    }

    /// The binary operator a compound assignment is built from, or TkUnknown.
    static fn compound_base(k: TokenKind) -> TokenKind {
        switch k {
            case TokenKind::OpPlusEqual           { return TokenKind::OpPlus; }
            case TokenKind::OpMinusEqual          { return TokenKind::OpMinus; }
            case TokenKind::OpStarEqual           { return TokenKind::OpStar; }
            case TokenKind::OpSlashEqual          { return TokenKind::OpSlash; }
            case TokenKind::OpPercentEqual        { return TokenKind::OpPercent; }
            case TokenKind::OpAmpEqual            { return TokenKind::OpAmp; }
            case TokenKind::OpPipeEqual           { return TokenKind::OpPipe; }
            case TokenKind::OpCaretEqual          { return TokenKind::OpCaret; }
            case TokenKind::OpLessLessEqual       { return TokenKind::OpLessLess; }
            case TokenKind::OpGreaterGreaterEqual { return TokenKind::OpGreaterGreater; }
            case TokenKind::KwAndEq               { return TokenKind::OpAmp; }
            case TokenKind::KwOrEq                { return TokenKind::OpPipe; }
            case TokenKind::KwXorEq               { return TokenKind::OpCaret; }
            default                               { return TokenKind::TkUnknown; }
        }
    }

    /// The compound assignment built from a binary operator, or TkUnknown.
    static fn compound_of(k: TokenKind) -> TokenKind {
        switch k {
            case TokenKind::OpPlus           { return TokenKind::OpPlusEqual; }
            case TokenKind::OpMinus          { return TokenKind::OpMinusEqual; }
            case TokenKind::OpStar           { return TokenKind::OpStarEqual; }
            case TokenKind::OpSlash          { return TokenKind::OpSlashEqual; }
            case TokenKind::OpPercent        { return TokenKind::OpPercentEqual; }
            case TokenKind::OpAmp            { return TokenKind::OpAmpEqual; }
            case TokenKind::OpPipe           { return TokenKind::OpPipeEqual; }
            case TokenKind::OpCaret          { return TokenKind::OpCaretEqual; }
            case TokenKind::OpLessLess       { return TokenKind::OpLessLessEqual; }
            case TokenKind::OpGreaterGreater { return TokenKind::OpGreaterGreaterEqual; }
            case TokenKind::KwBitand         { return TokenKind::OpAmpEqual; }
            case TokenKind::KwBitor          { return TokenKind::OpPipeEqual; }
            case TokenKind::KwXor            { return TokenKind::OpCaretEqual; }
            default                          { return TokenKind::TkUnknown; }
        }
    }

    static fn is_compound(k: TokenKind) -> bool {
        return OperatorFacts::compound_base(k) != TokenKind::TkUnknown;
    }
}