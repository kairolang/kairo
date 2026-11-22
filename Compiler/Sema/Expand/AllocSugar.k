/// --- The Kairo Project --------------------- Sema/Expand/AllocSugar.k --- ///
///
/// The allocation attributes in expression position (`@create`,
/// `@try_create`, `@destroy`, `@alloc`, `@alloc_zeroed`, `@free`,
/// `@resize`, `@resize_in_place`, `@try_resize_in_place`), each rewritten
/// to the alloc.k call its overload stands for, before anything resolves a
/// name.
///
///   \detail
///     AllocAttrTable holds the overloads, one row each, and picks the row a
///     use was written for by its keyword arguments and by the node the
///     attribute applies to. The rewrite is the same for every row:
///
///       target<T?, A?>(operand?, size?, new_size?, align?, count?)
///
///     with T the node's type, A the `in:` allocator, and `target` the
///     row's alloc.k function (its `_in` / `_with` form when `in:` is
///     given). So every later pass sees an ordinary call:
///
///       @create T(args)               create<T>(args)
///       @create T{ f: v }             create<T>(T{ f: v })   the object is
///                                     moved (or copied) from the initializer
///       @create(in: A) T(args)        create_in<T, A>(args)
///       @destroy p / @destroy(p)      destroy(p)
///       @alloc(count: n) T            create_slice<T>(n)
///       @free(size: n, align: a) p    free_raw(p, n, a)
///
///     and the rest as AllocAttrTable lists them. `@create<T>(args)` /
///     `@destroy<T>(p)` are S001E at the parser, which builds the call they
///     were; its callee is bound here like a minted one.
///
///     The callee is alloc.k's own function, which C++ spells
///     `::builtin::base::alloc::create<T>`, and it needs no import. A path
///     cannot say that -- `builtin::...` is not nameable in an expression,
///     and the builtin prelude does not re-export alloc.k -- so the callee
///     is minted already BOUND to the declaration (WellKnownDecls::
///     alloc_fn), and N leaves a bound name alone. Two halves make the
///     declaration exist: DepScanner puts alloc.k in the graph of a file
///     that writes an allocation attribute, and the driver gives that TU an
///     import EDGE to it that binds no name (so alloc.k is typed first, and
///     a hand-written `create<T>(...)` with no import is still R020E). With
///     no alloc.k (`--no-prelude`, a custom builtins dir) the callee is
///     left to ordinary lookup. A class cannot have its own allocator
///     (SC149E), so nothing reroutes the call.
///
///     What is left alone: a use that matches no row (`@create x`,
///     `@create Config(1).port`, `@create .V { }`, `@alloc(size: 8)`,
///     `@free(sz: 8) p`), which FeatureGateCheck reports with the reason
///     (SC364E for the operand, SC365E for the arguments), and every other
///     expression attribute, which it reports as not yet supported
///     (SC116E).
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
    AllocFn,
    LangAttrs,
    alloc_fn_name,
}
import AST::Node::Base::Expr
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Expressions::{
    AttributedExpr,
    CallExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Types::ChainType
import AST::Visitor::ASTWriter::ASTWriter
import Location::SourceRange::SourceRange
import Sema::Expand::AllocAttrTable::{
    ALLOC_KW_VALUES,
    AllocAttrTable,
    AllocMismatch,
    AllocNode,
}
import Sema::Lower::LowerSynth::LowerSynth
import Sema::SemaContext::SemaContext

pub class AllocSugarDesugar derives ASTWriter<AllocSugarDesugar> {
    pub var  sc:     *SemaContext
    priv var _synth: LowerSynth

    fn AllocSugarDesugar(self, sc: *SemaContext) {
        self.sc     = sc
        self.ctx    = sc->ctx // ASTWriter rebuilds lists in this arena.
        self._synth = LowerSynth(unsafe (sc as unsafe *SemaContext))
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

        if out != (unsafe (n as unsafe *Expr)) {
            return out
        }

        var nm = self.sc->ctx->get_spelling(n->name)
        if !LangAttrs::is_alloc_attr(nm) {
            return out
        }

        // The generic form of `@create` / `@destroy`: the parser already
        // built `name<T>(args)`, with the attribute's token as the callee's.
        var unsafe *opd = n->operand
        if !n->has_args && opd != &null && isa<CallExpr>(opd) {
            var unsafe *c   = cast<CallExpr>(opd)
            var unsafe *cid = dyn_cast<NamedIdentExpr>(c->callee)
            if cid != &null && cid->name.range == n->name.range {
                self._bind_callee(
                    cid,
                    if (nm == LangAttrs::create()) => (AllocFn::Create) else => AllocFn::Destroy,
                )

                return opd
            }
        }

        var u = AllocAttrTable::classify(self.sc->ctx, n)
        if u.why != AllocMismatch::Ok || u.row < 0 {
            return out
        }

        var row    = AllocAttrTable::row(u.row as usize)
        var target = if (u.kw_in != &null) => (row.target_in) else => row.target

        // The callee, spelled as alloc.k declares it, with T then A.
        var unsafe *callee = NamedIdentExpr::create(
            self.sc->ctx,
            n->name.range,
            self._synth.ident(n->name.range, alloc_fn_name(target)),
        )

        var gcount: usize = 0
        if u.ty != &null {
            gcount += 1
        }

        if u.in_ty != &null {
            gcount += 1
        }

        if gcount > 0 {
            var unsafe *ga = self.sc->ctx->alloc_array<ChainType::GenericArg>(
                gcount,
            )

            var gi: usize = 0
            if u.ty != &null {
                ga[gi].name       = &null
                ga[gi].name_range = SourceRange::invalid()
                ga[gi].ty         = u.ty
                gi += 1
            }

            if u.in_ty != &null {
                ga[gi].name       = &null
                ga[gi].name_range = SourceRange::invalid()
                ga[gi].ty         = u.in_ty
            }

            callee->generic_args.from_raw(ga, gcount)
        }

        self._bind_callee(callee, target)
        var unsafe *call = CallExpr::create(self.sc->ctx, n->range, callee)

        // `T(args)` passes its constructor arguments; `T { f: v }` is itself
        // the one argument. No row with a Construction takes a value
        // keyword.
        if row.node == AllocNode::Construction {
            if isa<CallExpr>(opd) {
                call->args = cast<CallExpr>(opd)->args
                return call
            }

            var unsafe **one = self.sc->ctx->alloc_array<unsafe *Expr>(1)
            one[0] = opd
            call->args.from_raw(one, 1)
            return call
        }

        var argc: usize = 0
        if row.node == AllocNode::Value {
            argc += 1
        }

        for var vi: usize = 0; vi < ALLOC_KW_VALUES; ++vi {
            if u.values[vi] != &null {
                argc += 1
            }
        }

        if argc == 0 {
            return call
        }

        var unsafe **av       = self.sc->ctx->alloc_array<unsafe *Expr>(argc)
        var        ai:  usize = 0
        if row.node == AllocNode::Value {
            av[ai] = opd
            ai += 1
        }

        for var vi: usize = 0; vi < ALLOC_KW_VALUES; ++vi {
            if u.values[vi] != &null {
                av[ai] = u.values[vi]->value
                ai += 1
            }
        }

        call->args.from_raw(av, argc)
        return call
    }

    /// Bind the minted (or parser-built) callee to alloc.k's function.
    /// alloc.k was typed before this TU (the driver's edge), so the entry
    /// is filled by now; when it is not, the name stays unbound and N looks
    /// it up as written. An entry with several overloads is bound to its
    /// first: the call typer adds the others (CallTyping::type_call).
    priv fn _bind_callee(self, id: unsafe *NamedIdentExpr, k: AllocFn) {
        if id == &null || id->is_bound() || self.sc->well_known == &null {
            return
        }

        var unsafe *d = self.sc->well_known->alloc_fn(k)
        if d == &null {
            return
        }

        id->resolved_decl = d
    }
}
