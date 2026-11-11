/// --- The Kairo Project ---------------------------------- AST/Serialize/NodeCommon.k --- ///
///
///   What every node family shares: the annotation list (attributes, and
///   comments under --preserve-comments).
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

import AST::Mixin::Annotation::{
    AnnotationEntry,
    AnnotationKind,
    AnnotationPresence,
}
import AST::Node::Base::Expr
import AST::Serialize::Archive::ASTArchive
import Location::SourceRange::SourceRange

/// The annotations of node \p n (any family: all five derive Annotation).
/// `presence` is not stored: add_annotation derives it from the entries,
/// and the writer checks that the node's own bits are those.
pub fn <N: type> io_annotations(ar: unsafe *ASTArchive, n: unsafe *N) {
    var has = n->annotations.size() > 0
    ar->flag(has)
    if !has {
        eval if defined!(DEBUG) {
            ar->sema_is(n->presence.bits == 0, "Annotation::presence without entries")
        }

        return
    }

    var count        = ar->len_(n->annotations.size())
    var derived: u8  = 0
    for var i: usize = 0; i < count; ++i {
        var e = AnnotationEntry(AnnotationKind::Attribute, u32::MAX, SourceRange::invalid())
        if !ar->reading {
            e = *n->annotations.get(i)
        }

        ar->en<AnnotationKind>(&e.kind)
        ar->ident(&e.name)
        ar->range(&e.range)
        ar->expr_list<Expr>(&e.args)
        eval if defined!(DEBUG) {
            ar->sema_null<void>(unsafe (e.resolved_decl as unsafe *void), "AnnotationEntry::resolved_decl")
        }

        derived = derived | ((1 as u8) << (e.kind as u8))
        if ar->reading {
            n->add_annotation(e.kind, e.name, e.range, e.args)
        }
    }

    eval if defined!(DEBUG) {
        ar->sema_is(n->presence.bits == derived, "Annotation::presence differs from its entries")
    }
}
