/// --- The Kairo Project -------------- Sema/Lower/NullableTypeLowering.k --- ///
///
///   \brief `T?` is `::builtin::Nullable<T>` to C++, and the `null` literal
///          is that record's null.
///
///   \detail
///     Two rewrites (NULLABLE.md 1.1, §5 step 4):
///
///       i32?            canonical NullableType  ->  lowered = record(Nullable, [i32])
///       null : i32?     NullLiteralExpr         ->  VariantInitExpr Nullable<i32>::Null
///       &null : (*T)?   NullLiteralExpr         ->  the same: a nullable pointer's
///                                                   null is the nullable's (1.3)
///
///     A TYPE is not rewritten in the tree: every canonical `T?` gets the
///     record it is (NullableType::lowered), and codegen spells and plans
///     through that slot. Canonicals are build-wide and interned, `T?` sits
///     inside instance keys (`Box<i32?>`), pointers (`*(i32?)`) and
///     function types, and an expression's type is often a canonical no
///     written type names (`var b = find(3)`); re-keying all of them is the
///     repointing G0 found breaks deduction. So the pass walks the
///     canonical TABLE, not the tree: whatever `T?` any TU minted is lowered,
///     and one this TU never uses costs one record. `T?`'s inner is the
///     record's argument as it is: `(i32?)?` is Nullable<i32?>, which spells
///     Nullable<Nullable<int>> through the inner's own slot, and since this
///     is the only writer there is one instance per C++ type. A dependent
///     inner gives the primary over it (SemaContext::lang_record), which is
///     what a generic body's `::builtin::Nullable<T>` is.
///
///     No VALUE conversion is rewritten. Sema checks `T -> T?` and
///     `null -> T?` (Conversion::_seq) but records no conversion node, as
///     for every implicit conversion; the record's two non-explicit
///     constructors (`Nullable(const T&)` / `Nullable(T&&)`, and the null
///     ones) make each of them C++ copy-initialization at every site --
///     initializer, assignment, return, argument, default, field default,
///     element. The null literal is the exception: bare, it has no C++
///     type, so an if-expression arm `null` against `5` would be a ternary
///     over `null_t` and `int`; typed, it is a Nullable, and the other arm
///     converts to it.
///
///   Phase: LOWER, after CopyMoveLowering and immediately before
///   OperatorLowering. After: CopyMoveLowering decides a transfer from the
///   value's lifecycle, which ClassLifecycle answers for a NullableType
///   from its inner; a freshly minted Nullable<Uniq> instance would have
///   no facts yet, the `T&&` would be lost and clang would pick the
///   deleted copy. Before OperatorLowering, so the null tests and coalesces
///   that land later (CoalesceLowering, NullTestLowering,
///   NarrowedAccessLowering: they go just before this pass) still see
///   NullableType; this pass is the LAST nullable one.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import Sema::Type::TypeUtil::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::LangItems::*;
import AST::Context::CanonicalTypes::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Node::CanonicalNodes::*;

class NullableTypeLowering derives ASTWriter::<NullableTypeLowering> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var _en: *EnumDecl = &null;       ///< the Nullable lang item's pattern.
    priv var _null_ix: u32 = 0;            ///< its payload-less variant's tag.

    fn NullableTypeLowering(self, sc: *SemaContext) {
        self.sc  = sc;
        self.ctx = sc->ctx;
        self.tu  = TypeUtil(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        // A build with no builtin root has no `T?` to lower to; a `T?` that
        // reaches codegen then ICEs naming this pass (CXXSpell), which is the
        // truth: nothing could lower it.
        var nd = self.sc->well_known->get(WellKnownType::Nullable);
        if nd == &null { return; }
        self._en = dyn_cast::<EnumDecl>(NameLookup::representative(nd));
        ICE_IF(self._en == &null, "NullableTypeLowering: the Nullable lang item is not an enum");
        var found = false;
        for var i: usize = 0; i < self._en->variants.size(); ++i {
            var v = self._en->variants[i];
            if (v != &null) && v->payload.is_empty() { self._null_ix = u32(i); found = true; }
        }
        ICE_IF(!found, "NullableTypeLowering: the Nullable lang item has no payload-less variant");

        self._lower_types();
        ASTWriter::<NullableTypeLowering>::run(self.sc->tu);
    }

    /// Every canonical `T?` gets its record (file header). Poisoned or
    /// absent inners are skipped: the pipeline stopped before codegen.
    priv fn _lower_types(self) {
        var all = self.sc->types->nullables();
        for var i: usize = 0; i < all.size(); ++i {
            var n = all[i];
            if (n->lowered != &null) || (n->inner == &null) { continue; }
            var args = vec::<*Type>();
            args.push_back(n->inner);
            var r = self.sc->lang_record(WellKnownType::Nullable, &args);
            self.sc->types->set_nullable_lowered(n, r);
        }
    }

    /// The record \p t is to C++ when it is a `T?`, else null.
    priv fn _record_of(self, t: *Type) -> *Type {
        var c = canon_unqual(t);
        if (c == &null) || (!isa::<NullableType>(c)) { return &null; }
        return cast::<NullableType>(c)->lowered;
    }

    /// `null` and `&null` typed as a nullable: the record's null variant.
    /// `&null` against a plain pointer stays the null pointer.
    fn transform_null_literal_expr(self, n: *NullLiteralExpr) -> *Expr {
        if n->is_poisoned() { return n; }
        var r = self._record_of(n->type_);
        if r == &null { return n; }
        var vi = VariantInitExpr::create(self.ctx, n->range, static_cast::<*Decl>(self._en), self._null_ix);
        vi->adopt_sema(n);
        vi->type_          = r;
        vi->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(vi);
    }
}
