/// --- The Kairo Project ------------ Sema/Lower/ImplicitConvLowering.k --- ///
///
///   \brief An implicit conversion through an extension's `@implicit op as`
///          becomes the cast it stands for.
///
///   \detail
///       extend string { @implicit fn op as (const self) -> Path { ... } }
///       open(s)          ->  open(s as Path)
///       var p: Path = s  ->  var p: Path = s as Path
///
///     A member's `@implicit op as` is a C++ conversion function, which C++
///     applies at the site by itself. An extension's is a static member of
///     its scope struct, which C++ never looks up, so the call has to be in
///     the tree. X recorded where one was accepted and what it converts to
///     (SemaContext::implicit_convs / implicit_conv_targets); this pass
///     wraps each such expression in the TypeCastExpr an explicit `as` would
///     have been, and OperatorLowering and ExtensionLowering turn that into
///     the call, as they do for a written cast.
///
///   Phase: LOWER, first: the record is keyed by the expression node, and
///   every later lowering may replace nodes.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"

import AST::DeclFacts::decl_extension_of
import AST::Node::Base::{
    Expr,
    Type,
}
import AST::Node::Declarations::FunctionDecl
import AST::Node::Expressions::{
    CastMode,
    TypeCastExpr,
}
import AST::Visitor::ASTWriter::ASTWriter
import Sema::Lower::LowerStep::LowerStep
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}

pub class ImplicitConvLowering derives ASTWriter<ImplicitConvLowering> {
    pub var sc: *SemaContext

    fn ImplicitConvLowering(self, sc: *SemaContext) {
        self.sc  = sc
        self.ctx = sc->ctx
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        self.sc->begin_lower(LowerStep::ImplicitConv)
        if self.sc->tu == &null || self.sc->implicit_conv_targets.empty() {
            return
        }

        ASTWriter<ImplicitConvLowering>::run(self, self.sc->tu)
    }

    pub fn transform_expr(self, e: unsafe *Expr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<ImplicitConvLowering>::transform_expr(
            self,
            e,
        )

        if e == &null || out == &null {
            return out
        }

        var key = e as usize as u64
        var tt  = self.sc->implicit_conv_targets.find(key)
        if tt == self.sc->implicit_conv_targets.end() {
            return out
        }

        var ft = self.sc->implicit_convs.find(key)
        if ft == self.sc->implicit_convs.end() || decl_extension_of(ft->second) == &null {
            return out
        }

        var unsafe *to = tt->second
        var unsafe *c = TypeCastExpr::create(
            self.ctx,
            out->range,
            out,
            to,
            false,
            CastMode::Default,
        )

        c->type_          = to
        c->value_category = Expr::ValueCategory::RValue
        c->resolved_op    = ft->second
        var it = self.sc->implicit_conv_instances.find(key)
        if it != self.sc->implicit_conv_instances.end() {
            c->op_instance = it->second
        }

        // One cast per accepted conversion: a later walk over this node
        // must not wrap it again.
        self.sc->implicit_conv_targets.erase(key)
        return c
    }
}
