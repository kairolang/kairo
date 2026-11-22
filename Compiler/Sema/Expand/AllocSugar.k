/// --- The Kairo Project --------------------- Sema/Expand/AllocSugar.k --- ///
///
/// `@create` / `@destroy` in expression position, rewritten to the
/// library calls they are sugar for, before anything
/// resolves a name.
///
///   \detail
///     Lib/builtin/base/alloc.k declares `create<T>(...args) -> *T` and
///     `destroy<T>(p: *T)`; the attributes are their spelling in the docs'
///     voice, and nothing else (allocators.mdx). So the rewrite is purely
///     syntactic and every later pass sees an ordinary call:
///
///       @create<T>(args)      create<T>(args)     (S001E at the parser;
///                                                 parsed as this call)
///       @create T(args)       create<T>(args)     T a name, a `::` path or
///                                                 a generic application
///       @create T{ f: v }     create<T>(T{ f: v }) the same T; the object
///                                                 is moved (or copied) from
///                                                 the initializer
///       @destroy<T>(p)        destroy<T>(p)       (the parser built it)
///       @destroy p            destroy(p)
///       @destroy(p)           destroy(p)
///
///     The callee is alloc.k's own `create` / `destroy`, which C++ spells
///     `::builtin::base::alloc::create<T>`, and it needs no import. A path
///     cannot say that -- `builtin::...` is not nameable in an expression,
///     and the builtin prelude does not re-export alloc.k -- so the callee
///     is minted already BOUND to the lang item (WellKnownType::Create /
///     Destroy), and N leaves a bound name alone. Two halves make the item
///     exist: DepScanner puts alloc.k in the graph of a file that writes
///     the sugar, and the driver gives that TU an import EDGE to it that
///     binds no name (so alloc.k is typed first, and a hand-written
///     `create<T>(...)` with no import is still R020E). With no lang item
///     (`--no-prelude`, a custom builtins dir) the callee is left to
///     ordinary lookup, as before. A class cannot have its own allocator
///     (SC149E), so nothing reroutes the call.
///
///     What is left alone: a `@create` / `@destroy` of any other shape
///     (`@create x`, `@create Config(1).port`, `@create .V { }`,
///     `@create(a) T()`, `@destroy(a) p`), which FeatureGateCheck reports as
///     a misuse (SC364E), and every other expression attribute, which it
///     reports as not yet supported (SC116E).
///
///   Phase: EXPAND (before N: the minted callee and type argument resolve
///          as written ones do)
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::LangItems::{
    LangAttrs,
    WellKnownType,
}
import AST::Node::Base::{
    Expr,
    Type,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Expressions::{
    AttributedExpr,
    CallExpr,
    NamedInitializerExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Types::ChainType
import AST::Visitor::ASTWriter::ASTWriter
import Location::SourceRange::SourceRange
import Parser::DeclParse::expr_as_type
import Sema::SemaContext::SemaContext

pub class AllocSugarDesugar derives ASTWriter<AllocSugarDesugar> {
    pub var sc: *SemaContext

    fn AllocSugarDesugar(self, sc: *SemaContext) {
        self.sc  = sc
        self.ctx = sc->ctx // ASTWriter rebuilds lists in this arena.
    }

    fn run(self) {
        if self.sc->tu == &null || !self.sc->tu->has_alloc_sugar {
            return
        }

        ASTWriter<AllocSugarDesugar>::run(self, self.sc->tu)
    }

    fn transform_attributed_expr(self, n: unsafe *AttributedExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<AllocSugarDesugar>::transform_attributed_expr(
            self,
            n,
        )

        if out != (unsafe (n as unsafe *Expr)) || n->operand == &null || n->has_args {
            return out
        }

        var nm        = self.sc->ctx->get_spelling(n->name)
        var is_create = nm == LangAttrs::create()
        if !is_create && nm != LangAttrs::destroy() {
            return out
        }

        // The generic form: the parser already built `name<T>(args)`, with
        // the attribute's token as the callee's.
        var unsafe *opd = n->operand
        if isa<CallExpr>(opd) {
            var unsafe *c   = cast<CallExpr>(opd)
            var unsafe *cid = dyn_cast<NamedIdentExpr>(c->callee)
            if cid != &null && cid->name.range == n->name.range {
                self._bind_callee(cid, is_create)
                return opd
            }
        }

        if !is_create {
            var unsafe *callee = NamedIdentExpr::create(
                self.sc->ctx,
                n->name.range,
                n->name,
            )

            self._bind_callee(callee, false)
            var unsafe *dc = CallExpr::create(
                self.sc->ctx,
                n->range,
                unsafe (callee as unsafe *Expr),
            )

            var unsafe **one = self.sc->ctx->alloc_array<unsafe *Expr>(1)
            one[0] = opd
            dc->args.from_raw(one, 1)
            return dc
        }

        // `@create T{ f: v }`: the initializer's head is T, and the
        // initializer itself is the one argument. A head-less initializer
        // (`.V { }`) names no type to allocate.
        if isa<NamedInitializerExpr>(opd) {
            var unsafe *ini = cast<NamedInitializerExpr>(opd)
            if ini->is_dotted || ini->type_expr == &null {
                return out
            }

            var unsafe *ity = expr_as_type(self.sc->ctx, ini->type_expr)
            if ity == &null {
                return out
            }

            var unsafe *ic   = self._create_of(n, ity)
            var unsafe **one = self.sc->ctx->alloc_array<unsafe *Expr>(1)
            one[0] = opd
            ic->args.from_raw(one, 1)
            return ic
        }

        // `@create T(args)`: T, the callee, becomes the type argument.
        if !isa<CallExpr>(opd) {
            return out
        }

        var unsafe *call = cast<CallExpr>(opd)
        var unsafe *ty   = expr_as_type(self.sc->ctx, call->callee)
        if ty == &null {
            return out
        }

        var unsafe *cc = self._create_of(n, ty)
        cc->args = call->args
        return cc
    }

    /// `create<ty>()` at the attribute, its callee bound to the lang item;
    /// the caller fills the arguments.
    priv fn _create_of(self, n: unsafe *AttributedExpr, ty: unsafe *Type) -> unsafe *CallExpr {
        var unsafe *ga = self.sc->ctx->alloc_array<ChainType::GenericArg>(1)
        ga[0].name       = &null
        ga[0].name_range = SourceRange::invalid()
        ga[0].ty         = ty
        var unsafe *callee = NamedIdentExpr::create(
            self.sc->ctx,
            n->name.range,
            n->name,
        )

        callee->generic_args.from_raw(ga, 1)
        self._bind_callee(callee, true)
        return CallExpr::create(self.sc->ctx, n->range, callee)
    }

    /// Bind the minted (or parser-built) callee to alloc.k's create /
    /// destroy. alloc.k was typed before this TU (the driver's edge), so
    /// the lang item is filled by now; when it is not, the name stays
    /// unbound and N looks it up as written.
    priv fn _bind_callee(self, id: unsafe *NamedIdentExpr, is_create: bool) {
        if id == &null || id->is_bound() || self.sc->well_known == &null {
            return
        }

        var unsafe *d = self.sc->well_known->get(
            if (is_create) => (WellKnownType::Create) else => WellKnownType::Destroy,
        )

        if d == &null {
            return
        }

        id->resolved_decl = d
    }
}
