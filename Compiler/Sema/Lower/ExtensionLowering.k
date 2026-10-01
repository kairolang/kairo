/// --- The Kairo Project ------------------- Sema/Lower/ExtensionLowering.k --- ///
///
///   \brief A call to an extension member becomes the free-function call it
///          is: the receiver is passed as argument zero.
///
///   \detail
///     Every extension member is a free function with an explicit receiver
///     (RESOLUTION.md §2b): `extend Foo { fn m(self, x: i32) }` is
///     `m(Foo* self, int x)` in the extension's module. X bound `a.m(x)` to
///     that decl through member lookup; this pass makes the tree say so.
///
///       a.m(x)              m(&a, x)                    an object with an address
///       p->m(x)             m(p, x)
///       (*p).m(x)           m(p, x)
///       self.m(x)           m(self, x)                  `self` is a pointer in C++
///       make().m(x)         m(__kairo_tmp(make()), x)   materialized; lives to the `;`
///       make().f.m(x)       m(__kairo_tmp(make().f), x) a field of a prvalue is one too
///       d.m(x)              m(static_cast<Base*>(&d), x) found on a base: the upcast is written
///       Foo::m(a, x)        m(&a, x)                    `self` positional, same rules
///       Foo::make()         make()                      a static member: the callee only
///
///     An extension OPERATOR is a non-member C++ operator taking `X&` /
///     `const X&` ([over.oper]/7), so its receiver is the OBJECT:
///
///       a == b              operator==(a, b)
///       p->op==(b)          operator==(*p, b)
///       make() == b         operator==(make(), b)               const: `const X&` binds it
///       -make()             operator-(*__kairo_tmp(make()))     non-const: `X&` binds no prvalue
///
///   \par Materialization
///     `__kairo_tmp(e)` is a UnaryOperatorExpr `&` with `materialize` set;
///     EmitIR spells it as the LowerTargets::tmp_addr() helper InterfaceEmitter
///     declares once per preamble. A temporary created for an argument lives
///     to the end of the full-expression ([class.temporary]/4), so the pointer
///     is valid for the call and no StmtExpr (which would copy a record out)
///     is needed. SequenceLowering, next, binds the PRVALUE, never the
///     pointer: a pointer local ends the temporary at its own `;`.
///
///   \par Addressable or not
///     Decided by structure, not by value_category alone: MemberTyping marks
///     every field step an lvalue, and a field of a prvalue is an xvalue C++
///     will not take the address of. A field path is addressable iff its root
///     is; a `->` anywhere re-roots it at a dereference.
///
///   \par No headroom
///     Every extension member of one module is a free function in one
///     namespace, so C++ sees them as one overload set. The receiver is
///     therefore passed as exactly the extension's target type: a receiver
///     reached through a base is upcast in the tree, and clang has nothing to
///     choose. A generic extension's arguments are X's
///     (Deduction::bind_from_extension), registered as the call's instance,
///     and EmitIR spells them; nothing is deduced by clang.
///
///   \par Postcondition
///     No call whose callee is a ChainExpr ending in an extension-member
///     step. Declarations are untouched: emission, friends and the operator
///     prologue are EmitPlan's, InterfaceEmitter's and EmitIR's.
///
///   Phase: LOWER, after CallLowering (arguments in parameter order; the
///   receiver goes in front) and before SequenceLowering (which then sees
///   the receiver as argument zero, the position it had as the chain base).
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
import AST::DeclFacts::*;
import AST::Context::DeclContext::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::ExprKind::*;
import AST::Kind::TypeKind::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_ExtensionLowering ASTWriter<ExtensionLowering>
");

class ExtensionLowering derives ASTWriter::<ExtensionLowering> {
    pub var sc: *SemaContext;
    priv var tu:    TypeUtil;
    priv var synth: LowerSynth;

    fn ExtensionLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_ExtensionLowering::run(self.sc->tu);
    }

    // --- the rewrite ----------------------------------------------------------

    fn transform_call_expr(self, n: *CallExpr) -> *Expr {
        ASTWriter_ExtensionLowering::transform_call_expr(n);   // receiver and arguments first.
        if n->is_poisoned() { return static_cast::<*Expr>(n); }
        var ch = dyn_cast::<ChainExpr>(self.tu.strip_parens(n->callee));
        if (ch == &null) || (ch->steps.size() == 0) { return static_cast::<*Expr>(n); }
        var st  = ch->steps.get(ch->steps.size() - 1);
        var f   = dyn_cast::<FunctionDecl>(st->resolved_decl);
        var ext = decl_extension_of(static_cast::<*Decl>(f));
        if ext == &null { return static_cast::<*Expr>(n); }

        // A generic extension member's arguments are X's, never clang's.
        var generic = (decl_generic_params(static_cast::<*Decl>(ext)).size() > 0) || (f->generic_params.size() > 0);
        ICE_IF(generic && (n->instance == &null) && (!n->is_instantiation_dependent()),
            "ExtensionLowering: a generic extension member called with no registered instance; CallTyping::call_result_type registers it at Selected");

        if st->access_kind == ChainExpr::AccessKind::ColonColon { self._qualified(n, st, f, ext); }
        else { self._through_receiver(n, ch, st, f, ext); }
        return static_cast::<*Expr>(n);
    }

    /// `Foo::m(a, x)`: `self` is argument zero already, as the object.
    priv fn _qualified(self, n: *CallExpr, st: *ChainExpr::Step, f: *FunctionDecl, ext: *ExtensionDecl) {
        n->callee = self._head(st, f);
        if !f->is_method() { return; }   // a static member: nothing to pass.
        ICE_IF(n->args.size() == 0, "ExtensionLowering: `::` call to an extension member with no receiver argument; CallLowering postcondition");
        var args = self.list_builder::<*Expr>();
        args.push(self._receiver(n->args[0], f, ext, false));
        for var i: usize = 1; i < n->args.size(); ++i { args.push(n->args[i]); }
        args.freeze_into(&(n->args));
    }

    /// `a.m(x)` / `p->m(x)`: the chain minus its last step is the receiver.
    priv fn _through_receiver(self, n: *CallExpr, ch: *ChainExpr, st: *ChainExpr::Step,
                              f: *FunctionDecl, ext: *ExtensionDecl) {
        ICE_IF(ch->has_optional_chaining(),
            "ExtensionLowering: `?.` into an extension member; the nullable trio runs after this pass and must hand it a plain receiver first");
        ICE_IF(!f->is_method(), "ExtensionLowering: a static extension member called through a value; X should have rejected it");
        var via_ptr = (st->access_kind == ChainExpr::AccessKind::Arrow);
        n->callee = self._head(st, f);   // reads `st` before _split drops it from the list.
        var obj  = self._split(ch);
        var args = self.list_builder::<*Expr>();
        args.push(self._receiver(obj, f, ext, via_ptr));
        for var i: usize = 0; i < n->args.size(); ++i { args.push(n->args[i]); }
        args.freeze_into(&(n->args));
    }

    /// The receiver: the chain minus its last step. The ChainExpr node is
    /// reused, truncated, and typed as the value its new last step yields.
    priv fn _split(self, ch: *ChainExpr) -> *Expr {
        var n = ch->steps.size();
        if n == 1 {
            ICE_IF(ch->base == &null, "ExtensionLowering: a member step with no receiver");
            return ch->base;
        }
        var prev = ch->steps.get(n - 2);
        ICE_IF(prev->resolved_type == &null, "ExtensionLowering: the receiver step has no type; MemberTyping gate failure");
        var variant = (prev->resolved_decl != &null) && isa::<EnumVariantDecl>(prev->resolved_decl);
        var kept = self.list_builder::<ChainExpr::Step>();
        for var i: usize = 0; i + 1 < n; ++i { kept.push(*(ch->steps.get(i))); }
        kept.freeze_into(&(ch->steps));
        ch->type_          = prev->resolved_type;
        ch->value_category = (Expr::ValueCategory::RValue) if (variant) else (Expr::ValueCategory::LValue);
        return static_cast::<*Expr>(ch);
    }

    /// The callee: a name bound to the member. EmitIR spells it
    /// `::module::m<args>` / `::module::operator==` from the decl and the
    /// call's instance; the token only anchors it, and is the step's own.
    priv fn _head(self, st: *ChainExpr::Step, f: *FunctionDecl) -> *Expr {
        var tok = Token();
        if st->is_operator() {
            ICE_IF(st->op_tokens.size() == 0, "ExtensionLowering: an operator step with no tokens");
            tok = st->op_tokens[0];
        } else {
            ICE_IF(st->name == &null, "ExtensionLowering: a named step with no name");
            tok = st->name->name;
        }
        var head = NamedIdentExpr::create(self.ctx, st->range, tok);
        head->resolved_decl = static_cast::<*Decl>(f);
        return static_cast::<*Expr>(head);
    }

    // --- the receiver --------------------------------------------------------------

    /// Argument zero: a pointer for a named member, the object for an
    /// operator, in either case of exactly the extension's target type.
    priv fn _receiver(self, obj: *Expr, f: *FunctionDecl, ext: *ExtensionDecl, via_ptr: bool) -> *Expr {
        var x  = self.tu.strip_parens(obj);
        var up = self._upcast_to(f, ext, self._object_type(obj, via_ptr));

        if f->is_operator && (up == &null) {
            if via_ptr { return self._deref(obj); }
            if self._is_self(x) { return self._deref(self._self_ptr(x)); }
            if self._addressable(obj) || f->is_const() { return obj; }   // `const X&` binds the prvalue.
            return self._deref(self._addr(obj, true));
        }
        var p = self._pointer_to(obj, x, via_ptr);
        if up != &null { p = self.synth.cast_to(p->range, p, up, CastMode::Default); }
        return (self._deref(p)) if (f->is_operator) else (p);
    }

    /// A pointer to the receiver object, in whatever form it already has one.
    priv fn _pointer_to(self, obj: *Expr, x: *Expr, via_ptr: bool) -> *Expr {
        if via_ptr { return obj; }
        if self._is_self(x) { return self._self_ptr(x); }
        if self._is_deref(x) { return cast::<UnaryOperatorExpr>(x)->operand; }
        return self._addr(obj, !self._addressable(obj));
    }

    /// The pointer type to cast the receiver to when it is not the target
    /// itself (a member found through a base), or null. A generic
    /// extension's target is matched exactly by X's seed, so it never needs one.
    priv fn _upcast_to(self, f: *FunctionDecl, ext: *ExtensionDecl, obj: *Type) -> *Type {
        if decl_generic_params(static_cast::<*Decl>(ext)).size() > 0 { return &null; }
        if (obj == &null) || (ext->target == &null) || (ext->target->canonical == &null) { return &null; }
        var tgt = canon_unqual(ext->target->canonical);
        if obj == tgt { return &null; }
        var pointee = (self.sc->types->qualified(tgt, QUAL_CONST())) if (f->is_const()) else (tgt);
        return self.sc->types->pointer(pointee);
    }

    /// True when \p e names an object C++ will take the address of.
    priv fn _addressable(self, e_in: *Expr) -> bool {
        var e = self.tu.strip_parens(e_in);
        if e == &null { return false; }
        switch e->kind {
            case ExprKind::NamedIdentExpr {
                var d = cast::<NamedIdentExpr>(e)->resolved_decl;
                return (d != &null) && (isa::<VariableDecl>(d) || isa::<ParamDecl>(d) || isa::<FieldDecl>(d));
            }
            case ExprKind::ChainExpr         { return self._chain_addressable(cast::<ChainExpr>(e)); }
            case ExprKind::UnaryOperatorExpr { return self._is_deref(e); }
            case ExprKind::UnsafeExpr        { return self._addressable(cast::<UnsafeExpr>(e)->operand); }
            case ExprKind::StmtExpr          { return false; }
            default { return e->value_category == Expr::ValueCategory::LValue; }   // a builtin `[]`, a `T&` result.
        }
        return false;
    }

    /// `a.b.c` is addressable iff its root is. A `->` re-roots it at a
    /// dereference; a `::` step roots it at what it names; a variant is a
    /// value, never an object.
    priv fn _chain_addressable(self, c: *ChainExpr) -> bool {
        var ok = false;
        if c->base != &null { ok = self._is_self(self.tu.strip_parens(c->base)) || self._addressable(c->base); }
        for var i: usize = 0; i < c->steps.size(); ++i {
            var st = c->steps.get(i);
            var d  = st->resolved_decl;
            switch st->access_kind {
                case ChainExpr::AccessKind::Arrow      { ok = true; }
                case ChainExpr::AccessKind::ColonColon { ok = (d != &null) && (isa::<VariableDecl>(d) || isa::<FieldDecl>(d)); }
                default { 0; }   // `.`: a member of whatever the root is.
            }
            if (d != &null) && isa::<EnumVariantDecl>(d) { ok = false; }
        }
        return ok;
    }

    priv fn _is_self(self, e: *Expr) -> bool {
        var ni = dyn_cast::<NamedIdentExpr>(e);
        if ni == &null { return false; }
        var p = dyn_cast::<ParamDecl>(ni->resolved_decl);
        return (p != &null) && p->is_self;
    }

    priv fn _is_deref(self, e: *Expr) -> bool {
        var u = dyn_cast::<UnaryOperatorExpr>(e);
        return (u != &null) && u->is_prefix() && (u->resolved_op == &null) && (u->op_token.kind == TokenKind::OpStar);
    }

    /// `self` read as what it is in C++: a pointer to the receiver. A fresh
    /// node, typed as the pointer; EmitIR spells it `this` or `self`.
    priv fn _self_ptr(self, s_in: *Expr) -> *Expr {
        var s = cast::<NamedIdentExpr>(s_in);
        ICE_IF(s->type_ == &null, "ExtensionLowering: untyped `self`; ExprTyper gate failure");
        var use = NamedIdentExpr::create(self.ctx, s->range, s->name);
        use->resolved_decl  = s->resolved_decl;
        use->type_          = self.sc->types->pointer(self._object(s->type_));
        use->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(use);
    }

    /// `&e`, or with \p materialize the address of \p e's materialized
    /// temporary (`__kairo_tmp(e)`). Keeps \p e's cv: a const object's
    /// address is a `*const T`.
    priv fn _addr(self, e: *Expr, materialize: bool) -> *Expr {
        ICE_IF(e->type_ == &null, "ExtensionLowering: untyped receiver; ExprTyper gate failure");
        var u = UnaryOperatorExpr::create(self.ctx, e->range, e, self.synth.punct(e->range, TokenKind::OpAmp),
                                          UnaryOperatorExpr::Fix::Prefix);
        u->type_          = self.sc->types->pointer(self._object(e->type_));
        u->value_category = Expr::ValueCategory::RValue;
        u->materialize    = materialize;
        return static_cast::<*Expr>(u);
    }

    /// `*p`, an lvalue of what \p p points to.
    priv fn _deref(self, p: *Expr) -> *Expr {
        var pt = (self.tu.pointee(canon_unqual(p->type_))) if (p->type_ != &null) else (&null);
        ICE_IF(pt == &null, "ExtensionLowering: dereferencing a receiver that is not a pointer");
        var d = UnaryOperatorExpr::create(self.ctx, p->range, p, self.synth.punct(p->range, TokenKind::OpStar),
                                          UnaryOperatorExpr::Fix::Prefix);
        d->type_          = pt;
        d->value_category = Expr::ValueCategory::LValue;
        return static_cast::<*Expr>(d);
    }

    /// The object a C++ reference names; anything else as it is, cv kept.
    priv fn _object(self, t: *Type) -> *Type {
        if t == &null { return &null; }
        if isa::<CXXLValueRefType>(t) { return cast::<CXXLValueRefType>(t)->referee; }
        if isa::<CXXRValueRefType>(t) { return cast::<CXXRValueRefType>(t)->referee; }
        return t;
    }

    /// The receiver's object type, unqualified, for the upcast test.
    priv fn _object_type(self, obj: *Expr, via_ptr: bool) -> *Type {
        var t = self._object(obj->type_);
        if t == &null { return &null; }
        if via_ptr { t = self.tu.pointee(canon_unqual(t)); }
        return (canon_unqual(t)) if (t != &null) else (&null);
    }
}

__inline_cpp("
#undef ASTWriter_ExtensionLowering
");