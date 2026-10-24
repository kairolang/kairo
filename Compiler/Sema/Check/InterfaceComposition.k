/// --- The Kairo Project ---------------- Sema/InterfaceComposition.k --- ///
///
///   \brief Normalize an algebraic interface into a regular one: a plain
///          requirement list, before binding and conformance see it.
///
///   \detail
///     `interface Foo derives X + (Y - Z) & W` composes requirement sets:
///     `+` union, `-` difference, `&` intersection (private/PLAN-interface-
///     algebra.md, D2-D4). The parser keeps the clause as the expression it
///     read (InterfaceDecl::derives_expr), each leaf resolved as a type in
///     derives_list. This pass is where the sets are computed.
///
///     Not built yet: an interface whose clause uses `-` or `&` is rejected
///     here, so it never compiles as the union its derives_list would read
///     as. A plain union (`derives A, B`, `derives A + B`) is today's
///     inheritance and passes.
///
///   Phase: TYPES, after TypeResolution and RedeclMerge (leaves resolved),
///   before ConstraintExtraction and ChainBinding (a bound `T impl Foo`
///   gets its members at binding).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ----------------------------------------------------------------- ///

import Sema::SemaContext::*;
import AST::Context::DeclContext::*;
import AST::Context::TranslationUnit::*;
import AST::Node::Base::*;
import AST::Node::Program::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import Diagnostic::Registry::*;

class InterfaceComposition {
    pub var sc: *SemaContext;

    fn InterfaceComposition(self, sc: *SemaContext) {
        self.sc = sc;
    }

    fn run(self) {
        var tu = self.sc->tu;
        if (tu == &null) || (tu->program == &null) { return; }
        self._walk(static_cast::<*DeclContext>(tu));
    }

    priv fn _walk(self, dc: *DeclContext) {
        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var d = *(dc->dc_decls.get(i));
            if (d == &null) || d->is_poisoned() { continue; }
            if isa::<InterfaceDecl>(d) { self._compose(cast::<InterfaceDecl>(d)); continue; }
            if isa::<ModuleDecl>(d) { self._walk(static_cast::<*DeclContext>(cast::<ModuleDecl>(d))); }
        }
    }

    priv fn _compose(self, id: *InterfaceDecl) {
        if !id->derives_composed { return; }
        var at = id->derives_expr->range;
        var b = self.sc->diag->report(DiagID::SC001E, at.start,
            "interface composition with '-' or '&' is not compiled yet; only a union ('+' or ',') is");
        b.first(at);
        b.emit();
        id->poison();
    }
}
