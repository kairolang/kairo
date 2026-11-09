/// --- The Kairo Project ------------------------------ AST/AttrFacts.k --- ///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::LangItems::LangAttrs
import AST::Mixin::Annotation::{
    AnnotationEntry,
    AnnotationKind,
}
import AST::Node::Base::Decl
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::PrimaryExpressions::IntegerLiteralExpr
import Lexer::Immediate::ImmediateTable

/// The largest `@align(N)`: clang's limit for an ELF object (2^28).
pub fn attr_max_align() -> u64 {
    return 268435456
}

pub class AttrFacts {
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

    /// \p d's attribute named \p name, or null. \p local is the table of
    /// the file \p d is written in, for a decl no scope reaches (a local
    /// variable has no semantic_dc): the caller knows the file it is in.
    pub static fn find(d:          unsafe *Decl,
                       const name: string,
                       local:      unsafe *ImmediateTable = &null) -> unsafe *AnnotationEntry {
        if d == &null || !d->has_attribute() {
            return &null
        }

        var unsafe *tbl = local
        var unsafe *tu  = AttrFacts::_tu_of(d->semantic_dc)
        if tu == &null {
            tu = AttrFacts::_tu_of(d->lexical_dc)
        }

        if tu != &null && tu->ctx != &null && tu->ctx->get_imm_table() != &null {
            tbl = tu->ctx->get_imm_table()
        }

        if tbl == &null {
            return &null
        }

        var k = tbl->find_ident(name)
        if k == u32::MAX {
            return &null
        }

        for var i: usize = 0; i < d->annotations.size(); ++i {
            var unsafe *e = d->annotations.get(i)
            if e->kind == AnnotationKind::Attribute && e->name == k {
                return e
            }
        }

        return &null
    }

    /// The N of one `@align(N)`: a single integer literal that is a power
    /// of two no larger than attr_max_align(); 0 for anything else.
    pub static fn align_value(e: unsafe *AnnotationEntry) -> u64 {
        if e == &null || e->args.size() != 1 {
            return 0
        }

        var unsafe *a = e->args[0]
        if a == &null || !isa<IntegerLiteralExpr>(a) {
            return 0
        }

        var unsafe *lit = cast<IntegerLiteralExpr>(a)
        if lit->imm == &null || lit->imm->big != &null || lit->imm->value_hi != 0 {
            return 0
        }

        var v = lit->imm->value_lo
        if v == 0 || (v & v - 1) != 0 || v > attr_max_align() {
            return 0
        }

        return v
    }

    /// `@packed` on \p d (a record).
    pub static fn is_packed(d: unsafe *Decl) -> bool {
        return AttrFacts::find(d, LangAttrs::packed()) != &null
    }

    /// The N of \p d's `@align(N)`, or 0 when it has none (or an invalid one).
    pub static fn align_of(d: unsafe *Decl, local: unsafe *ImmediateTable = &null) -> u64 {
        return AttrFacts::align_value(AttrFacts::find(d, LangAttrs::align(), local))
    }

    /// The C++ attribute a record definition carries between its class-key
    /// and its name, with its trailing space, or "". GNU `aligned`, not
    /// `alignas`, for `@align(N)`: both raise the alignment to N, but
    /// `alignas` below the natural alignment is ill-formed C++, where
    /// Kairo's `@align` is a minimum (max(N, natural)). With `@packed` the
    /// two combine as clang's `packed, aligned(N)`: members at alignment 1,
    /// the record at N.
    pub static fn record_attr(d: unsafe *Decl) -> string {
        var p = AttrFacts::is_packed(d)
        var n = AttrFacts::align_of(d)
        if p && n != 0 {
            return f"__attribute__((packed, aligned({n}))) "
        }

        if p {
            return "__attribute__((packed)) "
        }

        if n != 0 {
            return f"__attribute__((aligned({n}))) "
        }

        return ""
    }

    /// The C++ attribute leading a field or variable declaration, with its
    /// trailing space, or "". GNU `aligned` for the reason record_attr gives.
    pub static fn decl_align_attr(d:     unsafe *Decl,
                                  local: unsafe *ImmediateTable = &null) -> string {
        var n = AttrFacts::align_of(d, local)
        if n == 0 {
            return ""
        }

        return f"__attribute__((aligned({n}))) "
    }
}
