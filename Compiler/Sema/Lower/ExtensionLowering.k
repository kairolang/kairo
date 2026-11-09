/// --- The Kairo Project --------------- Sema/Lower/ExtensionLowering.k --- ///
///
///   \brief A call to an extension member becomes the free-function call it
///          is: the receiver is passed as argument zero.
///
///   \detail
///     Every extension member is a static member of its extension scope,
///     `struct N::__kairo_ext_Foo` (Compiler/Spec/Generics.md#partial-selection), with the receiver
///     passed explicitly: `extend Foo { fn m(self, x: i32) }` is
///     `static void m(Foo* self, int x)`. X bound `a.m(x)` to that decl
///     through member lookup; this pass makes the tree say so.
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
///     An extension OPERATOR is a static `__kairo_op_<name>` taking `X&` /
///     `const X&`; the C++ `operator<sym>` beside the scope is a forwarder for
///     C++ consumers and Kairo never calls it. Its receiver is the OBJECT:
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
///     A qualified call into the scope sees only that scope's members, which
///     X already resolved, and no ADL. The receiver is still passed as
///     exactly the extension's target type, so a member found through a base
///     is called with the upcast written. A generic extension's arguments are
///     X's (Deduction::bind_from_extension), registered as the call's
///     instance, and EmitIR spells them; nothing is deduced by clang.
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::DeclFacts::{
    decl_extension_of,
    decl_generic_params,
}
import AST::Kind::ExprKind::ExprKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    QUAL_CONST,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    EnumVariantDecl, ExtensionDecl, FieldDecl, FunctionDecl, GenericParamDecl, InterfaceDecl,
    ParamDecl,       VariableDecl,
}
import AST::Node::Expressions::{
    CallExpr,
    CastMode,
    UnaryOperatorExpr,
    UnsafeExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    GenericParamType,
}
import AST::Visitor::ASTWriter::ASTWriter
import Sema::Lower::LowerSynth::LowerSynth
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::Substitution::Substitution
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenKind::TokenKind

pub class ExtensionLowering derives ASTWriter<ExtensionLowering> {
    pub var  sc:    unsafe *SemaContext
    priv var tu:    TypeUtil
    priv var synth: LowerSynth

    fn ExtensionLowering(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.ctx   = sc->ctx
        self.tu    = TypeUtil(sc)
        self.synth = LowerSynth(sc)
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked)
        if self.sc->tu == &null {
            return
        }

        ASTWriter<ExtensionLowering>::run(self, self.sc->tu)
    }

    /// # the rewrite

    fn transform_call_expr(self, n: unsafe *CallExpr) -> unsafe *Expr {
        ASTWriter<ExtensionLowering>::transform_call_expr(self, n) // receiver and arguments first.
        if n->is_poisoned() {
            return n
        }

        var unsafe *ch = dyn_cast<ChainExpr>(self.tu.strip_parens(n->callee))
        if ch == &null || ch->steps.size() == 0 {
            return n
        }

        var unsafe *st  = ch->steps.get(ch->steps.size() - 1)
        var unsafe *f   = dyn_cast<FunctionDecl>(st->resolved_decl)
        var unsafe *req = self._requirement_of(f)
        if req != &null {
            if st->access_kind != ChainExpr::AccessKind::ColonColon {
                self._through_witness(n, ch, st, f, req)
            } else if f->is_method() {
                self._qualified_witness(n, st, f, req)
            } else {
                self._static_witness(n, ch, st, f, req)
            }

            return n
        }

        var unsafe *ext = decl_extension_of(f)
        if ext == &null {
            return n
        }

        // A generic extension member's arguments are X's, never clang's.
        var generic = decl_generic_params(unsafe (ext as unsafe *Decl)).size() > 0
            || f->generic_params.size() > 0
        if generic && n->instance == &null && !n->is_instantiation_dependent() {
            kairo::std::ice_fail(
                "ExtensionLowering: a generic extension member called with no registered instance; CallTyping::call_result_type registers it at Selected",
            )
        }

        if st->access_kind == ChainExpr::AccessKind::ColonColon {
            self._qualified(n, st, f, ext)
        } else {
            self._through_receiver(n, ch, st, f, ext)
        }

        return n
    }

    /// `Foo::m(a, x)`: `self` is argument zero already, as the object.
    priv fn _qualified(self,
                       n:   unsafe *CallExpr,
                       st:  unsafe *ChainExpr::Step,
                       f:   unsafe *FunctionDecl,
                       ext: unsafe *ExtensionDecl) {
        n->callee = self._head(st, f)
        if !f->is_method() { // a static member: nothing to pass.
            return
        }

        if n->args.size() == 0 {
            kairo::std::ice_fail(
                "ExtensionLowering: `::` call to an extension member with no receiver argument; CallLowering postcondition",
            )
        }

        var args = self.list_builder<unsafe *Expr>()
        args.push(self._receiver(n->args[0], f, ext, false))
        for var i: usize = 1; i < n->args.size(); ++i {
            args.push(n->args[i])
        }

        args.freeze_into(&n->args)
    }

    /// `a.m(x)` / `p->m(x)`: the chain minus its last step is the receiver.
    priv fn _through_receiver(self,
                              n:   unsafe *CallExpr,
                              ch:  unsafe *ChainExpr,
                              st:  unsafe *ChainExpr::Step,
                              f:   unsafe *FunctionDecl,
                              ext: unsafe *ExtensionDecl) {
        if ch->has_optional_chaining() {
            kairo::std::ice_fail(
                "ExtensionLowering: `?.` into an extension member; the nullable trio runs after this pass and must hand it a plain receiver first",
            )
        }

        if !f->is_method() {
            kairo::std::ice_fail(
                "ExtensionLowering: a static extension member called through a value; X should have rejected it",
            )
        }

        var via_ptr = st->access_kind == ChainExpr::AccessKind::Arrow
        n->callee = self._head(st, f) // reads `st` before _split drops it from the list.
        var unsafe *obj = self._split(ch)
        var        args = self.list_builder<unsafe *Expr>()
        args.push(self._receiver(obj, f, ext, via_ptr))
        for var i: usize = 0; i < n->args.size(); ++i {
            args.push(n->args[i])
        }

        args.freeze_into(&n->args)
    }

    /// # calls through an interface bound

    /// The interface \p f is a requirement of, or null. The typer binds a
    /// call on a bounded `T` to the requirement itself (Compiler/Spec/Generics.md#partial-selection).
    priv fn _requirement_of(self, f: unsafe *FunctionDecl) -> unsafe *InterfaceDecl {
        if f == &null || f->semantic_dc == &null {
            return &null
        }

        var unsafe *home = (f->semantic_dc)->owner_decl()
        if home == &null {
            return &null
        }

        return dyn_cast<InterfaceDecl>(NameLookup::representative(home))
    }

    /// `a.m(x)` bound to requirement `m` of I: `m(&a, x)`, with the witness
    /// recorded (Compiler/Spec/Witnesses.md#call-sites). The receiver takes the form an extension
    /// member's does -- a witness member is declared as the requirement would
    /// be as an extension member of Self -- with no upcast: the witness is
    /// keyed on the receiver's own type. A `::` call (`T::make()`,
    /// `I::m(a)`) is not rewritten yet, and EmitIR ICEs on it.
    priv fn _through_witness(self,
                             n:   unsafe *CallExpr,
                             ch:  unsafe *ChainExpr,
                             st:  unsafe *ChainExpr::Step,
                             f:   unsafe *FunctionDecl,
                             req: unsafe *InterfaceDecl) {
        if ch->has_optional_chaining() {
            kairo::std::ice_fail(
                "ExtensionLowering: `?.` into an interface requirement; the nullable trio runs after this pass and must hand it a plain receiver first",
            )
        }

        if !f->is_method() {
            kairo::std::ice_fail(
                "ExtensionLowering: a static requirement called through a value; X should have rejected it",
            )
        }

        var via_ptr = st->access_kind == ChainExpr::AccessKind::Arrow
        n->callee = self._head(st, f)
        var unsafe *obj = self._split(ch)
        var unsafe *me  = self._object_type(obj, via_ptr)
        if me == &null {
            kairo::std::ice_fail(
                "ExtensionLowering: an untyped receiver for a requirement call; ExprTyper gate failure",
            )
        }

        n->witness_self  = me
        n->witness_iface = self._declaring_iface(me, f)
        var args = self.list_builder<unsafe *Expr>()
        args.push(self._witness_receiver(obj, f, via_ptr))
        for var i: usize = 0; i < n->args.size(); ++i {
            args.push(n->args[i])
        }

        args.freeze_into(&n->args)
    }

    /// `T::make(x)` bound to static requirement `make` of I: `make(x)`
    /// through the witness, Self the qualifier, no receiver. The qualifier
    /// is any dependent head a bound reaches the requirement through: a
    /// bounded parameter (`T::make()`) or an associated type
    /// (`T::Item::make()`, `T::Item::Inner::make()`), whose denoted type the
    /// typer left on the step before. Any other `::` form of a requirement
    /// (`I::m(a)`, a method named through `T::`) is left for EmitIR's ICE.
    priv fn _static_witness(self,
                            n:   unsafe *CallExpr,
                            ch:  unsafe *ChainExpr,
                            st:  unsafe *ChainExpr::Step,
                            f:   unsafe *FunctionDecl,
                            req: unsafe *InterfaceDecl) {
        // CallTyping's qualifier, not a witness: a form left unrewritten
        // must still reach EmitIR's ICE rather than spell a Self-less one.
        n->witness_iface = &null
        if f->is_method() {
            return
        }

        var unsafe *me = self._static_self(ch)
        if me == &null {
            return
        }

        n->callee        = self._head(st, f)
        n->witness_self  = me
        n->witness_iface = self._declaring_iface(me, f)
    }

    /// The dependent Self a static requirement is named through as the LAST
    /// step of \p ch: a bounded parameter (`T::make`) or an associated type
    /// (`T::Item::make`); null for any other head.
    priv fn _static_self(self, ch: unsafe *ChainExpr) -> unsafe *Type {
        if ch->base == &null {
            return &null
        }

        var k = ch->steps.size()
        if k == 1 {
            var unsafe *q = dyn_cast<NamedIdentExpr>(self.tu.strip_parens(ch->base))
            if q == &null {
                return &null
            }

            var unsafe *gp = dyn_cast<GenericParamDecl>(q->resolved_decl)
            if gp == &null || gp->owner == &null {
                return &null
            }

            return self.sc->types->generic_param(
                NameLookup::representative(gp->owner),
                gp->index,
                gp->is_pack,
            )
        }

        var unsafe *prev = ch->steps.get(k - 2)
        if prev == &null
            || prev->resolved_type == &null
            || !isa<AssocType>(canon_unqual(prev->resolved_type)) {
            return &null
        }

        return canon_unqual(prev->resolved_type)
    }

    /// `A::make` used as a VALUE, A bounded: the step records the
    /// witness a `::` call would get (_static_witness), so the function it
    /// denotes is the witness's member, not the requirement -- which has no
    /// C++ definition, and named as `I::make` is the interface's. A call's
    /// callee comes through here too, first; the call then replaces it.
    fn transform_chain_expr(self, n: unsafe *ChainExpr) -> unsafe *Expr {
        ASTWriter<ExtensionLowering>::transform_chain_expr(self, n)
        if n->is_poisoned() || n->steps.size() == 0 {
            return n
        }

        var unsafe *st = n->steps.get(n->steps.size() - 1)
        if st->access_kind != ChainExpr::AccessKind::ColonColon {
            return n
        }

        var unsafe *f = dyn_cast<FunctionDecl>(st->resolved_decl)
        if self._requirement_of(f) == &null || f->is_method() {
            return n
        }

        var unsafe *me = self._static_self(n)
        if me == &null {
            return n
        }

        st->witness_self  = me
        st->witness_iface = self._declaring_iface(me, f)
        return n
    }

    /// `I::m(a, x)`, the qualified form of a requirement call: `self` is
    /// argument zero already (CallLowering), and takes the receiver form a
    /// `.` call's would. Self is that argument's type -- a bounded `T`, or a
    /// concrete conformer whose row ConformanceChecking put on the call.
    priv fn _qualified_witness(self,
                               n:   unsafe *CallExpr,
                               st:  unsafe *ChainExpr::Step,
                               f:   unsafe *FunctionDecl,
                               req: unsafe *InterfaceDecl) {
        if n->args.size() == 0 {
            kairo::std::ice_fail(
                "ExtensionLowering: `I::m` call to a requirement with no receiver argument; CallLowering postcondition",
            )
        }

        var unsafe *me = self._object_type(n->args[0], false)
        if me == &null {
            kairo::std::ice_fail(
                "ExtensionLowering: an untyped receiver for a qualified requirement call; ExprTyper gate failure",
            )
        }

        n->callee       = self._head(st, f)
        n->witness_self = me
        if isa<GenericParamType>(me) || isa<AssocType>(me) {
            // The bound ConformanceChecking chose by the qualifier; the first
            // bound with the requirement serves only a call that named none.
            if n->witness_iface == &null {
                n->witness_iface = self._declaring_iface(me, f)
            }
        } else {
            var unsafe *row = n->witness_row
            if row == &null {
                kairo::std::ice_fail(
                    "ExtensionLowering: a qualified requirement call on a concrete type with no row; ConformanceChecking records it",
                )
            }

            n->witness_iface = row->iface
        }

        var args = self.list_builder<unsafe *Expr>()
        args.push(self._witness_receiver(n->args[0], f, false))
        for var i: usize = 1; i < n->args.size(); ++i {
            args.push(n->args[i])
        }

        args.freeze_into(&n->args)
    }

    /// Argument zero of a witness call: the pointer for a named member, the
    /// object for an operator, as _receiver gives an extension member.
    priv fn _witness_receiver(self,
                              obj:     unsafe *Expr,
                              f:       unsafe *FunctionDecl,
                              via_ptr: bool) -> unsafe *Expr {
        var unsafe *x = self.tu.strip_parens(obj)
        if f->is_operator {
            if via_ptr {
                return self._deref(obj)
            }

            if self._is_self(x) {
                return self._deref(self._self_ptr(x))
            }

            if self._addressable(obj) || f->is_const() {
                return obj
            }

            return self._deref(self._addr(obj, true))
        }

        return self._pointer_to(obj, x, via_ptr)
    }

    /// The canonical instance of the interface the call's witness belongs
    /// to: the bound on \p me whose composed requirement list contains
    /// callee \p f (InterfaceComposition). An inherited requirement goes
    /// through the BOUND's witness -- `Stream_witness<T>::read` -- since every
    /// interface's list holds what it derives. Self must be a generic
    /// parameter: a concrete receiver is bound to the implementing decl,
    /// never to a requirement. Self is a dependent head -- a bounded
    /// parameter, or an associated type (`x.show()` on `x: T::Item` is
    /// `Display_witness<typename Store_witness<T>::Item>`) -- and its bounds
    /// are Substitution::bound_ifaces', the one list every reader shares.
    priv fn _declaring_iface(self, me: unsafe *Type, f: unsafe *FunctionDecl) -> unsafe *Type {
        if (!isa<GenericParamType>(me)) && !isa<AssocType>(me) {
            kairo::std::ice_fail(
                "ExtensionLowering: a requirement call on a receiver that is neither a bounded generic parameter nor an associated type; witness Self must be dependent",
            )
        }

        var bs = Substitution(self.sc).bound_ifaces(me)
        for var i: usize = 0; i < bs.size(); ++i {
            if self._has_requirement(canon_unqual(bs[i]), f) {
                return canon_unqual(bs[i])
            }
        }

        // The taken branch of `eval if T impl I`: I is a bound there
        // only, so no declared bound has the requirement, and the witness is
        // I's own. A generic I's arguments are the test's, which the step
        // does not keep yet: those still end here.
        var unsafe *req = self._requirement_of(f)
        if req != &null && req->generic_params.size() == 0 {
            var none = cxx::std::vector<unsafe *Type>()
            return self.sc->types->record(
                NameLookup::representative(unsafe (req as unsafe *Decl)),
                unsafe &none,
            )
        }

        kairo::std::ice_fail("ExtensionLowering: no bound of the receiver requires the callee")
    }

    /// Interface instance \p t's composed list contains requirement \p f.
    priv fn _has_requirement(self, t: unsafe *Type, f: unsafe *FunctionDecl) -> bool {
        if t == &null || !isa<RecordType>(t) {
            return false
        }

        var unsafe *d = dyn_cast<InterfaceDecl>(
            NameLookup::representative(self.tu.pattern_of(cast<RecordType>(t)->decl)),
        )

        if d == &null {
            return false
        }

        var unsafe *fr = NameLookup::representative(unsafe (f as unsafe *Decl))
        for var i: usize = 0; i < d->requirements.size(); ++i {
            if NameLookup::representative(d->requirements.get(i)->decl) == fr {
                return true
            }
        }

        return false
    }

    /// The receiver: the chain minus its last step. The ChainExpr node is
    /// reused, truncated, and typed as the value its new last step yields.
    priv fn _split(self, ch: unsafe *ChainExpr) -> unsafe *Expr {
        var n = ch->steps.size()
        if n == 1 {
            if ch->base == &null {
                kairo::std::ice_fail("ExtensionLowering: a member step with no receiver")
            }

            return ch->base
        }

        var unsafe *prev = ch->steps.get(n - 2)
        if prev->resolved_type == &null {
            kairo::std::ice_fail(
                "ExtensionLowering: the receiver step has no type; MemberTyping gate failure",
            )
        }

        var variant = prev->resolved_decl != &null && isa<EnumVariantDecl>(prev->resolved_decl)
        var kept    = self.list_builder<ChainExpr::Step>()
        for var i: usize = 0; i + 1 < n; ++i {
            kept.push(*ch->steps.get(i))
        }

        kept.freeze_into(&ch->steps)
        ch->type_ = prev->resolved_type
        ch->value_category = if (variant) => (Expr::ValueCategory::RValue)
                             else => Expr::ValueCategory::LValue
        return unsafe (ch as unsafe *Expr)
    }

    /// The callee: a name bound to the member. EmitIR spells it
    /// `::module::m<args>` / `::module::operator==` from the decl and the
    /// call's instance; the token only anchors it, and is the step's own.
    priv fn _head(self, st: unsafe *ChainExpr::Step, f: unsafe *FunctionDecl) -> unsafe *Expr {
        var tok = Token()
        if st->is_operator() {
            if st->op_tokens.size() == 0 {
                kairo::std::ice_fail("ExtensionLowering: an operator step with no tokens")
            }

            tok = st->op_tokens[0]
        } else {
            if st->name == &null {
                kairo::std::ice_fail("ExtensionLowering: a named step with no name")
            }

            tok = st->name->name
        }

        var unsafe *head = NamedIdentExpr::create(self.ctx, st->range, tok)
        head->resolved_decl = unsafe (f as unsafe *Decl)
        // The step's written generic arguments go with it: a dependent call
        // has no instance, and they are all EmitIR has to spell.
        head->generic_args = st->generic_args
        return head
    }

    /// # the receiver

    /// Argument zero: a pointer for a named member, the object for an
    /// operator, in either case of exactly the extension's target type.
    priv fn _receiver(self,
                      obj:     unsafe *Expr,
                      f:       unsafe *FunctionDecl,
                      ext:     unsafe *ExtensionDecl,
                      via_ptr: bool) -> unsafe *Expr {
        var unsafe *x  = self.tu.strip_parens(obj)
        var unsafe *up = self._upcast_to(f, ext, self._object_type(obj, via_ptr))

        if f->is_operator && up == &null {
            if via_ptr {
                return self._deref(obj)
            }

            if self._is_self(x) {
                return self._deref(self._self_ptr(x))
            }

            if self._addressable(obj) || f->is_const() { // `const X&` binds the prvalue.
                return obj
            }

            return self._deref(self._addr(obj, true))
        }

        var unsafe *p = self._pointer_to(obj, x, via_ptr)
        if up != &null {
            p = self.synth.cast_to(p->range, p, up, CastMode::Default)
        }

        return if (f->is_operator) => (self._deref(p)) else => p
    }

    /// A pointer to the receiver object, in whatever form it already has one.
    priv fn _pointer_to(self, obj: unsafe *Expr, x: unsafe *Expr, via_ptr: bool) -> unsafe *Expr {
        if via_ptr {
            return obj
        }

        if self._is_self(x) {
            return self._self_ptr(x)
        }

        if self._is_deref(x) {
            return cast<UnaryOperatorExpr>(x)->operand
        }

        return self._addr(obj, !self._addressable(obj))
    }

    /// The pointer type to cast the receiver to when it is not the target
    /// itself (a member found through a base), or null. A generic
    /// extension's target is matched exactly by X's seed, so it never needs one.
    priv fn _upcast_to(self,
                       f:   unsafe *FunctionDecl,
                       ext: unsafe *ExtensionDecl,
                       obj: unsafe *Type) -> unsafe *Type {
        if decl_generic_params(unsafe (ext as unsafe *Decl)).size() > 0 {
            return &null
        }

        if obj == &null || ext->target == &null || ext->target->canonical == &null {
            return &null
        }

        var unsafe *tgt = canon_unqual(ext->target->canonical)
        if obj == tgt {
            return &null
        }

        var unsafe *pointee = if (f->is_const()) => (self.sc->types->qualified(tgt, QUAL_CONST))
                              else => tgt
        return self.sc->types->pointer(pointee)
    }

    /// True when \p e names an object C++ will take the address of.
    priv fn _addressable(self, e_in: unsafe *Expr) -> bool {
        var unsafe *e = self.tu.strip_parens(e_in)
        if e == &null {
            return false
        }

        match e->kind {
            case ExprKind::NamedIdentExpr {
                var unsafe *d = cast<NamedIdentExpr>(e)->resolved_decl
                return d != &null
                    && (isa<VariableDecl>(d) || isa<ParamDecl>(d) || isa<FieldDecl>(d))
            } case ExprKind::ChainExpr {
                return self._chain_addressable(cast<ChainExpr>(e))
            } case ExprKind::UnaryOperatorExpr {
                return self._is_deref(e)
            } case ExprKind::UnsafeExpr {
                return self._addressable(cast<UnsafeExpr>(e)->operand)
            } case ExprKind::StmtExpr {
                return false
            } default { // a builtin `[]`, a `T&` result.
                return e->value_category == Expr::ValueCategory::LValue
            }
        }
    }

    /// `a.b.c` is addressable iff its root is. A `->` re-roots it at a
    /// dereference; a `::` step roots it at what it names; a variant is a
    /// value, never an object.
    priv fn _chain_addressable(self, c: unsafe *ChainExpr) -> bool {
        var ok = false
        if c->base != &null {
            ok = self._is_self(self.tu.strip_parens(c->base)) || self._addressable(c->base)
        }

        for var i: usize = 0; i < c->steps.size(); ++i {
            var unsafe *st = c->steps.get(i)
            var unsafe *d  = st->resolved_decl
            match st->access_kind {
                case ChainExpr::AccessKind::Arrow {
                    ok = true
                } case ChainExpr::AccessKind::ColonColon {
                    ok = d != &null && (isa<VariableDecl>(d) || isa<FieldDecl>(d))
                } default { // `.`: a member of whatever the root is.
                    0
                }
            }

            if d != &null && isa<EnumVariantDecl>(d) {
                ok = false
            }
        }

        return ok
    }

    priv fn _is_self(self, e: unsafe *Expr) -> bool {
        var unsafe *ni = dyn_cast<NamedIdentExpr>(e)
        if ni == &null {
            return false
        }

        var unsafe *p = dyn_cast<ParamDecl>(ni->resolved_decl)
        return p != &null && p->is_self
    }

    priv fn _is_deref(self, e: unsafe *Expr) -> bool {
        var unsafe *u = dyn_cast<UnaryOperatorExpr>(e)
        return u != &null
            && u->is_prefix()
            && u->resolved_op == &null
            && u->op_token.kind == TokenKind::OpStar
    }

    /// `self` read as what it is in C++: a pointer to the receiver. A fresh
    /// node, typed as the pointer; EmitIR spells it `this` or `self`.
    priv fn _self_ptr(self, s_in: unsafe *Expr) -> unsafe *Expr {
        var unsafe *s = cast<NamedIdentExpr>(s_in)
        if s->type_ == &null {
            kairo::std::ice_fail("ExtensionLowering: untyped `self`; ExprTyper gate failure")
        }

        var unsafe *use = NamedIdentExpr::create(self.ctx, s->range, s->name)
        use->resolved_decl  = s->resolved_decl
        use->type_          = self.sc->types->pointer(self._object(s->type_))
        use->value_category = Expr::ValueCategory::RValue
        return use
    }

    /// `&e`, or with \p materialize the address of \p e's materialized
    /// temporary (`__kairo_tmp(e)`). Keeps \p e's cv: a const object's
    /// address is a `*const T`.
    priv fn _addr(self, e: unsafe *Expr, materialize: bool) -> unsafe *Expr {
        if e->type_ == &null {
            kairo::std::ice_fail("ExtensionLowering: untyped receiver; ExprTyper gate failure")
        }

        var unsafe *u = UnaryOperatorExpr::create(
            self.ctx,
            e->range,
            e,
            self.synth.punct(e->range, TokenKind::OpAmp),
            UnaryOperatorExpr::Fix::Prefix,
        )

        u->type_          = self.sc->types->pointer(self._object(e->type_))
        u->value_category = Expr::ValueCategory::RValue
        u->materialize    = materialize
        return u
    }

    /// `*p`, an lvalue of what \p p points to.
    priv fn _deref(self, p: unsafe *Expr) -> unsafe *Expr {
        var unsafe *pt = if (p->type_ != &null) => (self.tu.pointee(canon_unqual(p->type_)))
                         else => &null
        if pt == &null {
            kairo::std::ice_fail(
                "ExtensionLowering: dereferencing a receiver that is not a pointer",
            )
        }

        var unsafe *d = UnaryOperatorExpr::create(
            self.ctx,
            p->range,
            p,
            self.synth.punct(p->range, TokenKind::OpStar),
            UnaryOperatorExpr::Fix::Prefix,
        )

        d->type_          = pt
        d->value_category = Expr::ValueCategory::LValue
        return d
    }

    /// The object a C++ reference names; anything else as it is, cv kept.
    priv fn _object(self, t: unsafe *Type) -> unsafe *Type {
        if t == &null {
            return &null
        }

        if isa<CXXLValueRefType>(t) {
            return cast<CXXLValueRefType>(t)->referee
        }

        if isa<CXXRValueRefType>(t) {
            return cast<CXXRValueRefType>(t)->referee
        }

        return t
    }

    /// The receiver's object type, unqualified, for the upcast test.
    priv fn _object_type(self, obj: unsafe *Expr, via_ptr: bool) -> unsafe *Type {
        var unsafe *t = self._object(obj->type_)
        if t == &null {
            return &null
        }

        if via_ptr {
            t = self.tu.pointee(canon_unqual(t))
        }

        return if (t != &null) => (canon_unqual(t)) else => &null
    }
}
