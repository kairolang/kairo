/// --- The Kairo Project -------------------------- AST/AttrFacts.k ----- ///
///
///   \brief What a declaration's layout attributes say: `@packed` and
///          `@align(N)` (LangAttrs). One reading for the three places that
///          act on them -- Sema's layout prediction
///          (EnumLayoutQuery::_plain_record_size), the C++ record and the
///          C++ field / variable (CXXSpell) -- so the size Kairo folds and
///          the size clang lays out come from the same rule.
///
///   Read through the DECL'S OWN context: an annotation's name is a per-fid
///   imm index (OperatorFacts has the same rule), and a record laid out
///   from another TU is spelled in that TU's table.
///
///   An attribute AttributeCheck rejects (an `@align` whose argument is not
///   a power-of-two integer literal) reads here as absent: the error is
///   the checker's, and nothing downstream lays out a guess.
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
import AST::Mixin::Annotation::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Casting::*;
import AST::LangItems::*;
import Lexer::Immediate::*;

/// The largest `@align(N)`: clang's limit for an ELF object (2^28).
fn attr_max_align() -> u64 { return u64(268435456); }

class AttrFacts {
    priv static fn _tu_of(dc: *DeclContext) -> *TranslationUnit {
        var c = dc;
        while c != &null {
            if c->dc_kind == DeclContextKind::TranslationUnit { return reinterpret_cast::<*TranslationUnit>(c); }
            c = c->dc_parent;
        }
        return &null;
    }

    /// \p d's attribute named \p name, or null. \p local is the table of
    /// the file \p d is written in, for a decl no scope reaches (a local
    /// variable has no semantic_dc): the caller knows the file it is in.
    static fn find(d: *Decl, name: string, local: *ImmediateTable = &null) -> *AnnotationEntry {
        if (d == &null) || (!d->has_attribute()) { return &null; }
        var tbl = local;
        var tu = AttrFacts::_tu_of(reinterpret_cast::<*DeclContext>(d->semantic_dc));
        if tu == &null { tu = AttrFacts::_tu_of(reinterpret_cast::<*DeclContext>(d->lexical_dc)); }
        if (tu != &null) && (tu->ctx != &null) && (tu->ctx->get_imm_table() != &null) { tbl = tu->ctx->get_imm_table(); }
        if tbl == &null { return &null; }
        var k = tbl->find_ident(name);
        if k == u32(-1) { return &null; }
        for var i: usize = 0; i < d->annotations.size(); ++i {
            var e = d->annotations.get(i);
            if (e->kind == AnnotationKind::Attribute) && (e->name == k) { return e; }
        }
        return &null;
    }

    /// The N of one `@align(N)`: a single integer literal that is a power
    /// of two no larger than attr_max_align(); 0 for anything else.
    static fn align_value(e: *AnnotationEntry) -> u64 {
        if (e == &null) || (e->args.size() != 1) { return 0; }
        var a = reinterpret_cast::<*Expr>(e->args[0]);
        if (a == &null) || (!isa::<IntegerLiteralExpr>(a)) { return 0; }
        var lit = cast::<IntegerLiteralExpr>(a);
        if (lit->imm == &null) || (lit->imm->big != &null) || (lit->imm->value_hi != 0) { return 0; }
        var v = lit->imm->value_lo;
        if (v == 0) || ((v & (v - 1)) != 0) || (v > attr_max_align()) { return 0; }
        return v;
    }

    /// `@packed` on \p d (a record).
    static fn is_packed(d: *Decl) -> bool {
        return AttrFacts::find(d, LangAttrs::packed()) != &null;
    }

    /// The N of \p d's `@align(N)`, or 0 when it has none (or an invalid one).
    static fn align_of(d: *Decl, local: *ImmediateTable = &null) -> u64 {
        return AttrFacts::align_value(AttrFacts::find(d, LangAttrs::align(), local));
    }

    /// The C++ attribute a record definition carries between its class-key
    /// and its name, with its trailing space, or "". GNU `aligned`, not
    /// `alignas`, for `@align(N)`: both raise the alignment to N, but
    /// `alignas` below the natural alignment is ill-formed C++, where
    /// Kairo's `@align` is a minimum (max(N, natural)). With `@packed` the
    /// two combine as clang's `packed, aligned(N)`: members at alignment 1,
    /// the record at N.
    static fn record_attr(d: *Decl) -> string {
        var p = AttrFacts::is_packed(d);
        var n = AttrFacts::align_of(d);
        if p && (n != 0) { return f"__attribute__((packed, aligned({n}))) "; }
        if p { return "__attribute__((packed)) "; }
        if n != 0 { return f"__attribute__((aligned({n}))) "; }
        return "";
    }

    /// The C++ attribute leading a field or variable declaration, with its
    /// trailing space, or "". GNU `aligned` for the reason record_attr gives.
    static fn decl_align_attr(d: *Decl, local: *ImmediateTable = &null) -> string {
        var n = AttrFacts::align_of(d, local);
        if n == 0 { return ""; }
        return f"__attribute__((aligned({n}))) ";
    }
}
