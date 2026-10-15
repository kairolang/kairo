/// --- The Kairo Project ------------------- Sema/Lower/TupleLowering.k --- ///
///
///   \brief A tuple is its arity's lang record. This pass makes the tree say
///          so where X left the tuple-shaped nodes: a literal becomes the
///          record's initializer, an index step becomes the field it already
///          names, a destructuring becomes one local per binder.
///
///   \detail
///     TypeResolve canonicalized every `(A, B)` to `record(Tuple2, [A, B])`,
///     so no canonical here is a TupleType and nothing after T has to know a
///     tuple from a struct. Three nodes still carry the written shape:
///
///       (a, b)                 TupleLiteralExpr       ->  Tuple2<A, B>{ ._0 = a, ._1 = b }
///       t.1                    Step target TupleIndex ->  Step target Name, bound to `_1`
///       var (x, _, z) = e      DestructuringDeclStmt  ->  T& __kairo_tupK = e;         (an lvalue; const T& to a const one)
///                                                         T __kairo_tupK = e;          (a prvalue)
///                                                         X x = __kairo_tupK._0;
///                                                         Z z = __kairo_tupK._2;
///
///     The literal's fields are in declaration order, which is written
///     order, so SequenceLowering has nothing to reorder. EmitIR renders the
///     initializer as it renders any record's (_init): the record has no
///     constructor, so it is an aggregate. The index step was bound to its
///     FieldDecl by MemberTyping; this pass only gives it a name to spell.
///
///   \par Destructuring
///     An lvalue is read through a reference (of the value's own constness,
///     so a `*x` binder can point into a mutable one), so the elements are
///     copied once, out of the original. A prvalue is bound by value
///     (elided) and each element is MOVED out of the local, since nothing
///     else reads it: `var (a, b) = make()` moves a move-only element rather
///     than failing to copy it. A `*x` binder takes the element's address,
///     which is stable for the enclosing scope either way.
///
///   \par Not lowered here
///     A tuple literal that is a match's scrutinee is left for MatchLowering,
///     which binds each element as its own column and never builds the
///     tuple. Struct destructuring (`var {r, g} = c`) is FeatureGateCheck's
///     SC116E until it has a lowering; reaching one here is a hole in the
///     gate. A `for (k, v) in m` binder list is IterLowering's, by the same
///     shape as the destructuring here.
///
///   Phase: LOWER, after CopyMoveLowering (a destructured value's `T&&`
///   cast is on the node this pass keeps as the local's initializer) and
///   before OperatorLowering (an operator on `t.0` sees a field path).
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
import Sema::Type::TypeUtil::*;
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Statements::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import AST::Node::CanonicalNodes::*;
import AST::Kind::TypeKind::*;
import Token::Token::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_TupleLowering ASTWriter<TupleLowering>
");

class TupleLowering derives ASTWriter::<TupleLowering> {
    pub var sc: *SemaContext;
    priv var tu:    TypeUtil;
    priv var synth: LowerSynth;

    /// The scrutinee of the match being rewritten, parens stripped, or null.
    /// A tuple literal there is MatchLowering's (file header).
    priv var _scrutinee: *Expr = &null;

    fn TupleLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_TupleLowering::run(self.sc->tu);
    }

    // --- literals -------------------------------------------------------------

    fn transform_tuple_literal_expr(self, n: *TupleLiteralExpr) -> *Expr {
        // Children first: a nested tuple is lowered on its own.
        var out = ASTWriter_TupleLowering::transform_tuple_literal_expr(n);
        if n->is_poisoned() || (n->type_ == &null) { return out; }
        if static_cast::<*Expr>(n) == self._scrutinee { return out; }

        var t = canon_unqual(n->type_);
        ICE_IF(!self.tu.is_tuple(t), "TupleLowering: a tuple literal whose type is not a Tuple record; TypeResolve canonicalizes every tuple to one");
        var count = n->elements.size();
        ICE_IF(self.tu.tuple_arity(t) != count, "TupleLowering: literal arity differs from its type's; LiteralTyping::type_tuple_literal gate failure");

        var init = NamedInitializerExpr::create(self.ctx, n->range, &null);
        var fields = self.list_builder::<InitField>();
        for var i: usize = 0; i < count; ++i {
            var e  = n->elements[i];
            var fd = self.tu.tuple_field(t, i);
            ICE_IF(fd == &null, "TupleLowering: Tuple record with fewer fields than its arity; TupleRecords minted it wrong");
            var f = InitField{};
            f.name       = self.synth.ident(e->range, self.tu.decl_name(static_cast::<*Decl>(fd)));
            f.value      = e;
            f.range      = e->range;
            f.field_decl = static_cast::<*Decl>(fd);
            fields.push(f);
        }
        fields.freeze_into(&(init->fields));
        init->adopt_sema(static_cast::<*Expr>(n));
        return static_cast::<*Expr>(init);
    }

    // --- index steps ----------------------------------------------------------

    /// `t.1` -> the field step `._1`. MemberTyping bound `resolved_decl` to
    /// the FieldDecl and typed the step; the step only lacked a name to
    /// spell, since an ordinal is not an identifier. Rewritten in place: the
    /// node keeps its identity for every record keyed on it (move_sites).
    fn transform_chain_expr(self, n: *ChainExpr) -> *Expr {
        var out = ASTWriter_TupleLowering::transform_chain_expr(n);
        if n->is_poisoned() { return out; }
        for var i: usize = 0; i < n->steps.size(); ++i {
            var st = n->steps.get(i);
            if (st == &null) || (!st->is_tuple_index()) { continue; }
            ICE_IF(st->resolved_decl == &null, "TupleLowering: a tuple index step with no field; MemberTyping binds it");
            var nm = self.synth.ident(st->range, self.tu.decl_name(st->resolved_decl));
            var id = NamedIdentExpr::create(self.ctx, st->range, nm);
            id->resolved_decl = st->resolved_decl;
            st->name   = id;
            st->target = ChainExpr::StepTarget::Name;
        }
        return out;
    }

    // --- destructuring --------------------------------------------------------

    fn transform_destructuring_decl_stmt(self, n: *DestructuringDeclStmt) -> vec::<*Stmt> {
        var out = ASTWriter_TupleLowering::transform_destructuring_decl_stmt(n);
        if n->kind_ != DestructureKind::Tuple { return out; }   // Struct: FeatureGateCheck rejected it.
        if (n->value == &null) || n->value->is_poisoned() || (n->value->type_ == &null) { return out; }

        var t = canon_unqual(self.tu.as_value(n->value->type_));
        ICE_IF(!self.tu.is_tuple(t), "TupleLowering: destructuring a value that is not a Tuple record; StmtTyping::_bind_list gate failure");
        var elems = self.tu.tuple_elems(t);
        ICE_IF(elems.size() != n->bindings.size(), "TupleLowering: binder count differs from the arity; StmtTyping::_bind_list gate failure");

        var stmts = vec::<*Stmt>();

        // The value, once. An lvalue is read in place through a reference
        // of its own constness (a `*x` binder takes a field's address, and
        // `*i32` cannot point into a `const`); a prvalue is bound by value
        // and moved out of below.
        var by_ref = n->value->is_lvalue();
        var lt = t;
        if by_ref {
            var rt = (self.sc->types->qualified(t, QUAL_CONST())) if (canon_has_const(n->value->type_)) else (t);
            lt = self.sc->types->cxx_lref(rt);
        }
        var tmp = self.synth.local(n->range, "tup", lt, n->value);
        stmts.push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, n->range, static_cast::<*Decl>(tmp))));

        for var i: usize = 0; i < n->bindings.size(); ++i {
            var b = n->bindings.get(i);
            if (b == &null) || b->is_discard || (b->decl == &null) { continue; }
            var bd = dyn_cast::<VariableDecl>(b->decl);
            ICE_IF(bd == &null, "TupleLowering: a binder whose decl is not a variable");
            ICE_IF(bd->type_ == &null, "TupleLowering: untyped binder; StmtTyping::_bind_one gate failure");
            var fd = self.tu.tuple_field(t, i);
            ICE_IF(fd == &null, "TupleLowering: Tuple record with fewer fields than its arity");

            var place = self.synth.field_of(b->range, self.synth.use_of(tmp, b->range, Expr::ValueCategory::LValue),
                                            static_cast::<*Decl>(fd), elems[i]);
            var sh = static_cast::<u8>(b->shorthand);
            var as_ptr = ((sh & static_cast::<u8>(BindingShorthand::Pointer)) != 0) && (b->type_ == &null);
            if as_ptr {
                bd->init = self.synth.addr_of(place);
            } else if by_ref {
                bd->init = place;
            } else {
                bd->init = self._moved(place);
            }
            stmts.push_back(static_cast::<*Stmt>(DeclStmt::create(self.ctx, b->range, static_cast::<*Decl>(bd))));
        }
        return stmts;
    }

    /// An element of a by-value local nothing else reads: moved into its
    /// binder. A record only; a scalar or pointer copies as cheaply.
    priv fn _moved(self, place: *Expr) -> *Expr {
        var c = canon_unqual(place->type_);
        if (c == &null) || (!isa::<RecordType>(c)) { return place; }
        var en = dyn_cast::<EnumDecl>(cast::<RecordType>(c)->decl);
        if (en != &null) && (!en->is_adt) { return place; }
        return self.synth.cast_to(place->range, place, self.sc->types->cxx_rref(c), CastMode::Default);
    }

    // --- match scrutinees -------------------------------------------------------

    fn transform_match_stmt(self, n: *MatchStmt) -> vec::<*Stmt> {
        var saved = self._scrutinee;
        self._scrutinee = self.tu.strip_parens(n->scrutinee);
        var out = ASTWriter_TupleLowering::transform_match_stmt(n);
        self._scrutinee = saved;
        return out;
    }

    fn transform_match_expr(self, n: *MatchExpr) -> *Expr {
        var saved = self._scrutinee;
        self._scrutinee = self.tu.strip_parens(n->scrutinee);
        var out = ASTWriter_TupleLowering::transform_match_expr(n);
        self._scrutinee = saved;
        return out;
    }
}

__inline_cpp("
#undef ASTWriter_TupleLowering
");