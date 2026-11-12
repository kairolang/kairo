/// --- The Kairo Project ----------------------- Sema/Type/CallTyping.k --- ///
///
///   \brief `callee(args)`: what the callee denotes, the candidate set that
///          gives, the arguments against it, and the result type.
///
///   \detail
///     Callee shapes, in the order they are recognised:
///
///       name            bound function        -> one candidate
///                       overload set          -> the cell
///                       type decl             -> constructor call
///                       value with fn type    -> call through a fn pointer
///       chain           last step is a method / set -> candidates with the
///                       chain's receiver
///                       last step is a type   -> constructor call
///                       otherwise a value     -> call through a fn pointer
///       Type<Args>      explicit instance     -> constructor on the instance
///       anything else   its type must be a fn pointer
///
///     Arguments are typed BEFORE resolution, except untyped literals, which
///     are ranked by shape and typed AFTER selection with the parameter type
///     (§5). Named arguments need a parser node; see the spec.
///
///   \par The `&` marker (AST/ParamMode.k)
///     `&x` in argument position is UnaryOperatorExpr(OpAmp, x): the parser
///     does not know the callee and cannot decide whether it is address-of
///     or the `@inout` marker. Nothing strips it before selection -- an
///     implementation that did would break every pointer argument in the
///     language. Instead arg_info records the operand's view alongside the
///     address-of view; OverloadResolution reads the operand's view against
///     an `@inout` parameter and the address-of view against everything
///     else; and finish_call_args, once the parameter is known, rewrites the
///     `&x` node to the operand's type (an lvalue) and sets is_mode_marker
///     so codegen emits the operand bare. An UNMARKED argument to `@inout`
///     binds with a warning (migration tolerance); the marker will become
///     required.
///
///     The one write to the tree outside `type_`: promoting a candidate cell
///     to the selected decl on the callee (NamedIdentExpr::resolved_decl or
///     Step::resolved_decl), which is the "cell -> decl: inference" line of
///     hard invariant #7. Plus the marker rewrite above, which is the one
///     place a memoized expression type is overwritten, and only after
///     selection, which is the only point the answer exists.
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

import AST::ASTSupport::FrozenList
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::SymbolTable::DeclName
import AST::DeclFacts::{
    decl_extension_of,
    decl_generic_params,
    decl_instantiated_from,
    decl_is_imported,
    decl_is_instance,
    param_type_pack_param,
}
import AST::LangItems::WellKnownType
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    BuiltinKind,
    QUAL_CONST,
    RecordType,
    canon_has_const,
    canon_quals,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    FunctionDecl, GenericParamDecl, InterfaceDecl, ModuleDecl, ParamDecl, TransferKind,
    TypeAliasDecl, VariableDecl,
}
import AST::Node::Expressions::{
    AlignOfExpr, CallExpr,     ClosureExpr,   ConstraintExpr,    NamedArgExpr, PackExpansionExpr,
    SizeOfExpr,  TypeCastExpr, TypeTraitExpr, UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    BooleanLiteralExpr, ChainExpr,      CharacterLiteralExpr, FloatingLiteralExpr,
    IntegerLiteralExpr, NamedIdentExpr, NullLiteralExpr,      StringLiteralExpr,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    ChainType,
    FunctionPointerType,
    GenericParamType,
    PackExpansionType,
    VariadicPackType,
}
import AST::ParamMode::ParamMode
import AST::Visitor::RecursiveASTVisitor::named_call_arg_value
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Diagnostic::NoteText::{
    named_declared_here,
    type_declared_here,
}
import Location::SourceRange::SourceRange
import Sema::Check::ClassLifecycle::moves_on_pass
import Sema::Resolve::MemberLookup::MemberLookup
import Sema::Resolve::NameLookup::NameLookup
import Sema::Type::Conversion::ImplicitRank
import Sema::Type::NullnessFlow::{
    NULL_READ_NARROWED,
    NULL_READ_REFUSED,
}
import Sema::Type::OverloadResolution::{
    ARG_C_VARARG,
    ARG_PACK_TAIL,
    ArgInfo,
    LitKind,
    OvlCallScope,
    OvlOutcome,
    OvlResult,
    cxx_lref_inout,
    has_opaque_ffi,
}
import Sema::Type::Substitution::Substitution
import Support::FlagSet::FlagSet
import Token::TokenKind::{
    TokenKind,
    is_annotation,
}

/// The operand of a `&e` written as a call argument, or null when \p e is
/// not that shape. Bare `&e` only: `(&e)` is address-of, as in C++. One
/// decoder, three readers (arg_info, finish_call_args, _call_through).
pub fn mode_marker_operand(e: unsafe *Expr) -> unsafe *Expr {
    if e == &null {
        return &null
    }

    if !isa<UnaryOperatorExpr>(e) {
        return &null
    }

    var unsafe *u = cast<UnaryOperatorExpr>(e)
    if u->op_token.kind != TokenKind::OpAmp {
        return &null
    }

    return u->operand
}

// TODO(DUCK-GENERIC): T uses chain_info, check_convertible, conv, ded_scratch, denoted_type, dotted_variant_shape, fail, finish, flow, fn_return_type, lint_cast_into_slot, list_literal_shape, ... (25). Stage 0 was duck-typed; bound it or keep `: type`.
pub class <T: type> CallTyping {
    @move
    fn CallTyping(self, other: Self) = default
    fn CallTyping(self) = default
    priv inline fn dyn(self) -> unsafe *T {
        return unsafe ((&self) as *T)
    }

    /// _functor_call is resolving: the winner is the call's `functor_op`.
    priv var _functor_next: bool = false

    /// # argument plumbing

    /// Type \p e now unless it is an untyped literal, and describe it.
    ///
    /// A named argument has no node of its own: `f(x: 1)` is parsed as an
    /// AssignOperatorExpr whose operator token is `:` and whose lhs is a bare
    /// identifier. `named_call_arg_value` is the one decoder of that shape
    /// (the RAV skips the label for the same reason). Unwrap it here so that
    /// everything downstream -- literal shapes, conversion checks, the
    /// diagnostics -- sees the VALUE, with the name carried beside it for
    /// OverloadResolution to place.
    fn arg_info(self, e_in: unsafe *Expr) -> ArgInfo {
        var        a  = ArgInfo()
        var unsafe *e = e_in
        a.carrier = e_in
        var unsafe *value = named_call_arg_value(e_in)
        if value != &null {
            var unsafe *na = cast<NamedArgExpr>(e_in)
            a.name       = self.dyn()->sc->ctx->get_spelling(na->name)
            a.name_range = na->name.range
            e            = value
        }

        a.expr  = e
        a.range = e->range

        // The `&` marker: record the operand's view BEFORE the whole `&e` is
        // typed. Both views exist until selection decides which one the
        // parameter reads; typing the operand first makes the outer typing a
        // memo hit on it.
        var unsafe *_op = mode_marker_operand(e)
        if _op != &null {
            self.dyn()->type_of(_op, &null)
            a.marked      = true
            a.inner_ty    = _op->type_
            a.inner_cat   = _op->value_category
            a.inner_const = self._const_lvalue(_op)
        }

        if self.dyn()->list_literal_shape(e, &a) {
            return a
        }

        if self.dyn()->literal_shape(e, &a) {
            return a
        }

        if self.dyn()->literal_expr_shape(e, &a) {
            return a
        }

        if self.dyn()->dotted_variant_shape(e, &a) {
            return a
        }

        a.ty = self.dyn()->type_of(e, &null)
        // `take(P)`: a type is no argument, not an unknown one.
        if a.ty == &null {
            self.dyn()->reject_type_value(e)
        }

        if a.ty == &null && !e->is_poisoned() {
            a.dependent = true
        }

        a.cat      = e->value_category     // set by the typer's finish (paren copies its inner).
        a.is_const = self._const_lvalue(e)
        // Passing a MOVE value moves it: the type decides, not the
        // expression, and Kairo has no std::move to write. So a MOVE lvalue
        // binds as the xvalue C++ would need: `v.push_back(m)` takes
        // push_back(T&&), and MoveCheck counts the call as the move. A const
        // one cannot be moved from and stays an lvalue.
        if a.cat == Expr::ValueCategory::LValue
            && !a.is_const
            && moves_on_pass(self.dyn()->sc, a.ty) {
            a.cat        = Expr::ValueCategory::XValue
            a.pass_moves = true
        }

        return a
    }

    /// An lvalue's const-ness as far as a reference parameter can see it: a
    /// `const` binding or parameter, or a `const T&`-typed result. Only a
    /// plain `T&` reads it -- a const lvalue does not bind there.
    priv fn _const_lvalue(self, e: unsafe *Expr) -> bool {
        var x = self.dyn()->tu.strip_parens(e)
        if x == &null {
            return false
        }

        if x->type_ != &null {
            // The type says so: `*p` through a `*const i32`, a field of a
            // const object, a `const T&` result.
            var t = x->type_
            if isa<CXXLValueRefType>(t) {
                t = cast<CXXLValueRefType>(t)->referee
            }

            if canon_has_const(t) {
                return true
            }
        }

        if !isa<NamedIdentExpr>(x) {
            return false
        }

        var d = cast<NamedIdentExpr>(x)->resolved_decl
        if d == &null {
            return false
        }

        if isa<VariableDecl>(d) {
            return cast<VariableDecl>(d)->is_const()
        }

        if isa<ParamDecl>(d) {
            return cast<ParamDecl>(d)->is_const
        }

        return false
    }

    fn build_args(self,
                  list:       FrozenList<unsafe *Expr>,
                  @inout out: cxx::std::vector<ArgInfo>) -> bool {
        var ok = true
        for var i: usize = 0; i < list.size(); ++i {
            var unsafe *e = list[i]
            if e == &null {
                continue
            }

            var a = self.arg_info(e)
            if a.expr->is_poisoned() {
                ok = false
            }

            out.push_back(a)
        }

        return ok
    }

    /// The `&x` node, now known to be the marker: it reads as its operand.
    /// `&x` was typed as address-of before selection (it had to be: against
    /// `x: *i32` that is what it means); now that the parameter is known to
    /// be `@inout`, the node is an lvalue of T, not a `*T`. This is the one
    /// place a memoized expression type is rewritten, and only after
    /// selection, which is the only point the answer exists.
    ///
    /// \p pt is the substituted parameter canonical, or null when still
    /// dependent; the binding is re-checked against it so a deduced
    /// `@inout x: T` is judged on the type it actually became.
    priv fn _commit_marker(self, a: *ArgInfo, pt: unsafe *Type) {
        var unsafe *_op = mode_marker_operand(a->expr)
        if _op == &null {
            return
        }

        var unsafe *u = cast<UnaryOperatorExpr>(a->expr)
        u->is_mode_marker = true
        u->type_          = _op->type_
        u->value_category = Expr::ValueCategory::LValue
        // The callee may write the operand; the marker was no pointer
        // (Compiler/Spec/Nullables.md#weakening).
        self.dyn()->flow.inout_arg(_op, a->expr)
        if _op->is_poisoned() {
            u->poison()
            return
        }

        if pt == &null || pt->is_dependent() {
            return
        }

        if _op->type_ == &null {
            return
        }

        var lref = self.dyn()->sc->types->cxx_lref(pt)
        var r = self.dyn()->conv.implicit_arg(
            _op->type_,
            lref,
            _op->value_category,
            self._const_lvalue(_op),
        )

        if r == ImplicitRank::None {
            self.dyn()->fail(
                u,
                DiagID::SC097E,
                f"cannot pass '{self.dyn()->tu.str(_op->type_)}' to an '@inout' parameter of type '{self.dyn()->tu.str(pt)}'; an '@inout' argument must be a mutable lvalue",
            )
        }
    }

    /// Parameter \p p is a forwarding reference a string literal deduces as
    /// a C string at: `T&&` (or a pack's `T&&...`) unsubstituted, or \p pt
    /// already substituted to `const char*&&`. The CallTyping side of
    /// OverloadResolution::_forwards_cstr, which judged the call so.
    priv fn _forwards_cstr_slot(self, p: unsafe *ParamDecl, pt: unsafe *Type) -> bool {
        if p == &null || p->type_ == &null {
            return false
        }

        var unsafe *u = canon_unqual(p->type_->canonical)
        if u != &null && isa<PackExpansionType>(u) {
            u = canon_unqual(cast<PackExpansionType>(u)->pattern)
        }

        if u != &null && isa<CXXLValueRefType>(u) {
            var unsafe *lr = cast<CXXLValueRefType>(u)->referee
            return lr != &null && isa<GenericParamType>(canon_unqual(lr)) && canon_quals(lr) == QUAL_CONST
        }

        if u != &null && isa<CXXRValueRefType>(u) {
            var unsafe *rr = cast<CXXRValueRefType>(u)->referee
            if rr != &null && isa<GenericParamType>(canon_unqual(rr)) && canon_quals(rr) == 0 {
                return true
            }
        }

        var unsafe *s = if (pt != &null) => (canon_unqual(pt)) else => &null
        if s != &null && isa<CXXRValueRefType>(s) {
            return self.dyn()->tu.is_c_string_param(canon_unqual(cast<CXXRValueRefType>(s)->referee))
        }

        return false
    }

    /// \p i is in \p xs.
    priv fn _listed(self, xs: *cxx::std::vector<usize>, i: usize) -> bool {
        for var k: usize = 0; k < xs->size(); ++k {
            if (*xs)[k] == i {
                return true
            }
        }

        return false
    }

    /// Migration tolerance: an unmarked argument to `@inout` bound; say so
    /// once per argument, at the argument, in words that say it will stop
    /// binding. No fixit by design (spec: MIGRATION).
    priv fn _warn_unmarked(self, args: unsafe *cxx::std::vector<ArgInfo>, r: *OvlResult) {
        for var k: usize = 0; k < r->inout_unmarked.size(); ++k {
            var i = r->inout_unmarked[k]
            if i >= args->size() {
                continue
            }

            var *a = &(*args)[(i)]
            var pn = "<parameter>"
            if k < r->inout_params.size() && r->inout_params[k] != &null {
                pn = self.dyn()->tu.param_name(r->inout_params[k])
            }

            // An error but not a poison: the argument types fine, only the marker is
            // missing, so poisoning would cascade into the rest of the call.
            var ub = self.dyn()->sc->diag->report(
                DiagID::SC097E,
                a->expr->range.start,
                f"argument to '@inout' parameter '{pn}' must be marked with '&'",
            )

            ub.first(a->expr->range)
            ub.insert(a->expr->range.start, "&", "mark the argument with '&'")
            ub.emit()
        }
    }

    /// After selection: type the untyped literals against their parameters,
    /// commit `&` markers, and re-check every argument against the
    /// substituted parameter type.
    fn finish_call_args(self,
                        f:    unsafe *FunctionDecl,
                        args: unsafe *cxx::std::vector<ArgInfo>,
                        r:    *OvlResult) {
        var params = cxx::std::vector<unsafe *ParamDecl>()
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null {
                continue
            }

            params.push_back(p)
        }

        // The resolver's param indices exclude a bound receiver; rebuild that
        // view. TOLD, not inferred: the old guess ("self was skipped unless
        // some argument maps to 0") was wrong for every receiver call WITH an
        // argument -- once self is skipped the first real param IS index 0 --
        // and matched that argument against `self`: `x as Wrap` through a
        // converting ctor checked the operand against Wrap itself.
        var view = cxx::std::vector<unsafe *ParamDecl>()
        for var i: usize = 0; i < params.size(); ++i {
            if i == 0 && params[0]->is_self && r->receiver_bound {
                continue
            }

            view.push_back(params[i])
        }

        for var i: usize = 0; i < args->size(); ++i {
            var *a = &(*args)[i]
            var pi = if (i < r->arg_to_param.size()) => (r->arg_to_param[i]) else => ARG_PACK_TAIL
            var p: unsafe *ParamDecl = &null
            if pi != ARG_PACK_TAIL {
                if pi < view.size() {
                    p = view[pi]
                }
            } else {
                // The pack tail. By is_pack, not position: a named-only
                // parameter may follow the pack, and the last one is then it.
                for var k: usize = 0; k < view.size(); ++k {
                    if view[k]->is_pack {
                        p = view[k]
                        break
                    }
                }
            }

            // C's `...` tail takes a literal as its static bytes, `const
            // char *` (printf("%s", "x")). Any other string is a C++
            // class, which C's varargs cannot carry: clang would reject it
            // in the generated C++, so it is said here, with the edit.
            if pi == ARG_C_VARARG && f->ffi_c_variadic {
                var sl = self.dyn()->tu.c_string_literal(a->expr)
                if sl != &null {
                    var cc = self.dyn()->sc->types->qualified(
                        self.dyn()->sc->builtin(BuiltinKind::CChar),
                        QUAL_CONST,
                    )

                    sl->c_string = self.dyn()->sc->types->pointer(cc, true)
                    continue
                }

                if a->ty != &null && self.dyn()->tu.is_string(a->ty) && !a->expr->is_poisoned() {
                    var b = self.dyn()->sc->diag->report(
                        DiagID::SC245E,
                        a->range.start,
                        "a 'string' cannot pass through C's '...'; pass its bytes as a C string with '.c_str()'",
                    )

                    b.first(a->range)
                    b.insert(a->range.end, ".c_str()", "pass the string's NUL-terminated bytes")
                    b.emit()
                    a->expr->poison()
                    continue
                }
            }

            if p == &null || p->type_ == &null {
                if a->lit != LitKind::None {
                    self.dyn()->type_of(a->expr, &null)
                }

                continue
            }

            var unsafe *pt = self._self_first(f, r, p->type_->canonical, true)
            // A parameter that deduces from the argument (`T`, `Args&&...`)
            // takes whatever type the cast gave it, so `f(x as u64)` is not
            // redundant against the u64 it deduced: without the cast T is u32.
            var slot_deduced = pt != &null && (pt->is_dependent() || pt->in_generic_owner())
            if slot_deduced {
                pt = r->ded.substitute(pt)
            }

            // `other: Self` is `other: T`. Resolution already judged the
            // argument this way; this is the same rule applied to the winner.
            pt = r->ded.through_receiver(f, r->receiver, pt)

            // A C++ callee takes this argument through one implicit
            // user-defined conversion (-fcxx-implicit-conv, P813): C++ performs
            // it, so the argument is emitted as written -- a string literal
            // as its bytes, the `const char[N]` C++ converts from.
            if self._listed(&r->user_convs, i) {
                var sl = self.dyn()->tu.c_string_literal(a->expr)
                if sl != &null {
                    var cc = self.dyn()->sc->types->qualified(
                        self.dyn()->sc->builtin(BuiltinKind::CChar),
                        QUAL_CONST,
                    )

                    sl->c_string = self.dyn()->sc->types->pointer(cc, true)
                }

                continue
            }

            // A C++ `T&` is `@inout x: T` (cxx_lref_inout), judged against T.
            var inout = p->mode == ParamMode::Inout
            if pi != ARG_PACK_TAIL
                && cxx_lref_inout(f, p, a->marked)
                && (a->marked || self._listed(&r->inout_unmarked, i)) {
                inout = true
                var unsafe *cu = if (pt != &null) => (canon_unqual(pt)) else => &null
                if cu != &null && isa<CXXLValueRefType>(cu) {
                    pt = cast<CXXLValueRefType>(cu)->referee
                }
            }

            // `@inout` with the marker: the operand is the argument.
            if inout && a->marked && pi != ARG_PACK_TAIL {
                self._commit_marker(a, if (pt != &null) => (canon_unqual(pt)) else => &null)
                continue
            }

            // Unmarked (an error, CallTyping::_warn_unmarked): written all the
            // same, and judged as the reference binding resolution made it --
            // the by-value checks below would add "cannot convert 'D' to 'B'"
            // for a derived object that binds a base `T&` fine.
            if inout && !a->marked {
                self.dyn()->flow.inout_arg(a->expr, &null)
                continue
            }

            self.dyn()->flow.pass_pointer(a->expr, pt)
            // A literal at an imported template's `T&&` (`fmt::print(fmt,
            // T&&... args)`, toml++'s `value_or(T&&)`): resolution deduced T
            // as a C string (OverloadResolution::_forwards_cstr), so the
            // literal goes as its bytes. Typed as a Kairo string it would be
            // a builtin::string temporary, which clang then deduces instead
            // and no C++ template knows how to format or store.
            if f->is_imported() && (!a->marked) && self._forwards_cstr_slot(p, pt) {
                var sl = self.dyn()->tu.c_string_literal(a->expr)
                if sl != &null {
                    var cc = self.dyn()->sc->types->qualified(
                        self.dyn()->sc->builtin(BuiltinKind::CChar),
                        QUAL_CONST,
                    )

                    sl->c_string = self.dyn()->sc->types->pointer(cc, true)
                    continue
                }
            }

            if a->lit != LitKind::None {
                // `&null` at a parameter C++ deduces (`Args&&...`) is the
                // nullptr_t it deduced it as.
                var unsafe *et = pt
                if a->lit == LitKind::NullPtr && (pt == &null || pt->is_dependent()) {
                    et = self.dyn()->tu.nullptr_t_type()
                }

                self.dyn()->push_null_target(a->expr, p->type_, p)
                self.dyn()->type_of(a->expr, et)
                self.dyn()->pop_null_target()
                continue
            }

            // A literal at an imported function's C string parameter: the
            // resolver ranked it so (OverloadResolution::_c_string_literal_arg,
            // the same test); StringLowering passes its bytes.
            if f->is_imported()
                && pt != &null
                && !inout
                && !a->marked
                && self.dyn()->tu.is_c_string_param(pt) {
                var sl = self.dyn()->tu.c_string_literal(a->expr)
                if sl != &null {
                    sl->c_string = self.dyn()->tu.as_value(pt)
                    continue
                }
            }

            // Either side dependent -- only reachable through a dependent
            // constructor call -- is the instance's question, as it is for
            // an initializer field.
            if pt != &null && pt->is_dependent() {
                continue
            }

            if a->dependent {
                continue
            }

            // `Base::m(obj)`: the object binds `self` as C++'s implicit
            // object does, by reference, so a Derived needs no value
            // conversion (OverloadResolution ranked it so). EmitIR writes
            // it as `obj.Base::m()`; nothing is copied or sliced.
            // The same for a transfer constructor's source called by name,
            // `Base::Base(self, other)` (OverloadResolution::_transfer_upcast).
            var by_ref = p->is_self
            if !by_ref
                && f->transfer != TransferKind::NotTransfer
                && !r->receiver_bound
                && pi == 1
                && f->is_method() {
                by_ref = true
            }

            if by_ref
                && pt != &null
                && a->expr->type_ != &null
                && Substitution(self.dyn()->sc).derives_from(
                    self.dyn()->tu.as_value(a->expr->type_),
                    canon_unqual(pt),
                ) {
                continue
            }

            if pt != &null {
                self.dyn()->lint_cast_into_slot(a->expr, pt, r->overloaded || slot_deduced)
                // The resolver admitted this argument by the boundary rung;
                // check_convertible asks the plain lattice and would refuse
                // the very widening that picked the winner.
                if f->is_imported()
                    && a->expr->type_ != &null
                    && self.dyn()->conv.abi_widen(a->expr->type_, pt) != ImplicitRank::None {
                    continue
                }

                self.dyn()->check_convertible(a->expr, pt)
            }
        }

        // The `name: value` wrapper is syntax, not a value: give it the type
        // of what it wraps so the dump does not report a hole where the
        // source only wrote a parameter name.
        for var i: usize = 0; i < args->size(); ++i {
            var *a = &(*args)[i]
            if a->carrier == &null || a->carrier == a->expr {
                continue
            }

            if a->expr->is_poisoned() {
                a->carrier->poison()
            }

            a->carrier->value_category = a->expr->value_category // the wrapper IS its value.
            self.dyn()->finish(a->carrier, a->expr->type_)
        }
    }

    /// \p t with an interface member's `Self` read as the receiver, BEFORE
    /// the deduction substitutes: a generic interface's Self is `I<T>` over
    /// its own parameters, and once `Container<i32>::get` binds T it reads
    /// `I<i32>`, which the Self rule no longer recognizes. A dependent
    /// receiver (a bound's T) goes first only for a parameter \p (any): a
    /// parameter left dependent is the instance's to check either way, while
    /// a return type has to substitute, and call_result_type says why that
    /// fails once Self is the caller's T.
    priv fn _self_first(self,
                        f:   unsafe *FunctionDecl,
                        r:   *OvlResult,
                        t:   unsafe *Type,
                        any: bool) -> unsafe *Type {
        if t == &null || r->receiver == &null {
            return t
        }

        if r->receiver->is_dependent() && !any {
            return t
        }

        return r->ded.through_receiver(f, r->receiver, t)
    }

    /// The declared return type of \p f after deduction. Expression-bodied
    /// functions without an annotation are inferred on demand.
    fn call_result_type(self, f: *FunctionDecl, r: *OvlResult) -> unsafe *Type {
        if f->is_noreturn {
            return self.dyn()->tu.builtin(BuiltinKind::Never)
        }

        var rt = self._self_first(f, r, self.dyn()->fn_return_type(f), false)
        if rt == &null {
            return &null
        }

        // A GENERIC interface's `-> Self` through a bound `C`: Self is
        // `I<T>`, dependent, so substituting first does not leave it alone
        // as it does a non-generic `record(I)` -- with the qualifier binding
        // T, it would read `I<i32>`. Read Self as C first, and let C stand
        // for itself in the substitution that follows, which the rest of
        // the type (`-> (Self, U)`) still needs. C is any dependent head: a
        // bounded parameter, or an associated type (`T::Item::make()` and
        // `x.clone()` on `x: T::Item` are `T::Item`), whose own parameters
        // this call's deduction never binds either.
        if rt->is_dependent() && r->receiver != &null && r->receiver->is_dependent() {
            var unsafe *rc = canon_unqual(r->receiver)
            var        rs  = r->ded.through_receiver(f, r->receiver, rt)
            if (isa<GenericParamType>(rc) || isa<AssocType>(rc)) && rs != rt {
                r->ded.bind_identity(rc)
                rt = rs
            }
        }

        // A member type of the receiver's generic class (`-> Self::P` on
        // `L<i32>`) is no parameter but still reads through the receiver:
        // `L<i32>::P` (InGenericOwner).
        if rt->is_dependent() || rt->in_generic_owner() {
            var s = r->ded.substitute(rt)
            if s == &null && r->cxx_ret != &null {
                s = r->cxx_ret
            }

            if s == &null { // still dependent: caller marks unknown.
                return &null
            }

            rt = s
        }

        // An imported template whose declared return type IS its SFINAE
        // (`enable_if_t<cond, int>`, `-> decltype(...)`) imports opaque;
        // clang's specialization has the real one (_clang_substitute).
        if r->cxx_ret != &null && has_opaque_ffi(rt) {
            rt = r->cxx_ret
        }

        // The same opaque with a dereference of a pointer to the enclosing
        // generic's parameter as argument (`cxx::std::move(*slot)` on `slot:
        // *T`, Compiler/Memory/ArenaList.k): clang was never asked
        // (_clang_substitute), and the declared spelling names the CALLEE's
        // template parameters (`__libcpp_remove_reference_t<_Tp>&&`), which
        // mean nothing at the call. Before P316 typed `*slot` as T the call
        // deferred on an untyped argument; this restores exactly that (the
        // local is `auto`, no cast spells `_Tp`). Only for the dereference:
        // `move(a0)` on `a0: A0` has always carried the opaque, and an
        // enclosing Kairo call (ASTContext's `_with_cleanup(&list, ...)`)
        // relies on it staying typed.
        if r->cxx_ret == &null && r->deref_dep && f->is_imported() && has_opaque_ffi(rt) {
            return &null
        }

        // A non-template C++ function declared `auto` (`auto* as_array()`
        // on toml++'s node_view<node>) imports its placeholder, an opaque
        // nothing can use: clang deduces it here, at the first call (P827).
        // `rt` is the Kairo-side imported type, never clang's: reading it
        // needs no set lock; deduced_return reads clang's under it (P853).
        if r->cxx_ret == &null && f->is_imported() && has_opaque_ffi(rt)
            && self.dyn()->sc->foreign != &null {
            var unsafe *dr = self.dyn()->sc->foreign->deduced_return(f)
            if dr != &null {
                rt = dr
            }
        }

        // An interface member's `Self` is the receiver, so `-> Self` through a
        // bound `T impl I` reads back as T. AFTER the deduced substitution,
        // not before, and the order is not cosmetic: rewriting first turns
        // `-> Self` into `T`, and `T` is the CALLER's parameter, which this
        // call's deduction never binds -- substitute would fail and the call
        // would type as unknown. Substituting first leaves `record(I)` alone
        // (a non-generic interface's record is not dependent) and the rewrite
        // then lands on the finished type.
        rt = r->ded.through_receiver(f, r->receiver, rt)
        // Register the generic function instance for M1/EmitPlan (see spec).
        // An extension member's instance arguments are its extension's, then
        // its own: the order CXXSpell::template_params spells them in.
        var unsafe *ext = decl_extension_of(unsafe (f as unsafe *Decl))
        var ext_n = if (ext != &null) => (decl_generic_params(unsafe (ext as unsafe *Decl)).size())
                    else => (0)
        if f->generic_params.size() > 0 || ext_n > 0 {
            var args = cxx::std::vector<unsafe *Type>()
            var ok = (ext == &null || self._bound_args(r, ext, &args))
                && self._bound_args(r, unsafe (f as unsafe *Decl), &args)
            if ok {
                r->instance = self.dyn()->sc->instances->instance_for(
                    NameLookup::representative(unsafe (f as unsafe *Decl)),
                    &args,
                    self.dyn()->sc->ctx->fid,
                    NameLookup::ctx_of(unsafe (f as unsafe *Decl)),
                )
            } else {
                // Dependent: keep what deduction found, for the enclosing
                // generic's instances to substitute (CallExpr::dep_args).
                r->dep_args.clear()
                var dok = (ext == &null || self._loose_args(r, ext, &r->dep_args))
                    && self._loose_args(r, unsafe (f as unsafe *Decl), &r->dep_args)
                if !dok {
                    r->dep_args.clear()
                }
            }
        }

        return rt
    }

    /// \p owner's deduced arguments, dependent ones included; false only on
    /// an unbound parameter or a pack.
    priv fn _loose_args(self,
                        r:          *OvlResult,
                        owner:      unsafe *Decl,
                        @inout out: cxx::std::vector<unsafe *Type>) -> bool {
        var gps = decl_generic_params(owner)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null || gp->is_pack {
                return false
            }

            var unsafe *b = r->ded.lookup(owner, gp->index)
            if b == &null {
                return false
            }

            out.push_back(b)
        }

        return true
    }

    /// \p f's `impl` bounds where the call binds one of its parameters to a
    /// bounds-checked parameter of the CALLER (`one(x)` with `x: T` inside
    /// `fn <T> fwd`), a forwarded pack's elements included (`print_all(
    /// args...)`). The caller's body is checked once, against its own bounds
    /// (generics.mdx), so the bound must be one of them: left to the
    /// instance, `fwd` compiled whatever it was given, and a non-conforming
    /// argument failed in C++ or not at all. A concrete argument is
    /// ConformanceChecking's, at the instance; a `: type` caller is C++'s.
    priv fn _check_forwarded_bounds(self, n: *CallExpr, f: unsafe *FunctionDecl, r: *OvlResult) {
        if f == &null || f->generic_params.size() == 0 {
            return
        }

        var sc = self.dyn()->sc
        var it = sc->bounds.find((unsafe (f as unsafe *Decl)) as usize as u64)
        if it == sc->bounds.end() {
            it = sc->bounds.find(
                NameLookup::representative(unsafe (f as unsafe *Decl)) as usize as u64,
            )

            if it == sc->bounds.end() {
                return
            }
        }

        var _set = &it->second
        for var i: usize = 0; i < _set->impl_constraints.size(); ++i {
            var k  = _set->impl_constraints[i]
            var id = dyn_cast<NamedIdentExpr>(k->lhs)
            if id == &null || k->rhs == &null || k->rhs->canonical == &null {
                continue
            }

            var gp = dyn_cast<GenericParamDecl>(id->resolved_decl)
            if gp == &null {
                continue
            }

            var xs = cxx::std::vector<unsafe *Type>()
            if gp->is_pack {
                if !r->ded.pack_elems(f, gp->index, &xs) {
                    continue
                }
            } else {
                var b = r->ded.lookup(f, gp->index)
                if b != &null {
                    xs.push_back(b)
                }
            }

            var iface = canon_unqual(k->rhs->canonical)
            if iface->is_dependent() {
                var s = r->ded.substitute(iface)
                if s != &null {
                    iface = canon_unqual(s)
                }
            }

            for var j: usize = 0; j < xs.size(); ++j {
                var unsafe *x = canon_unqual(xs[j])
                if x != &null && isa<PackExpansionType>(x) {
                    x = canon_unqual(cast<PackExpansionType>(x)->pattern)
                }

                if x != &null && isa<VariadicPackType>(x) {
                    x = canon_unqual((cast<VariadicPackType>(x)->param))
                }

                var cgp = self.dyn()->tu.op_checked_param(x)
                if cgp == &null {
                    continue
                }

                if self._param_meets(x, iface) {
                    continue
                }

                self._report_forwarded(n, f, k, cgp, x, iface)
                return
            }
        }
    }

    /// `create<T>(args)` (and `@create T(args)`, its sugar): alloc.k hands
    /// the pack to `T(args...)` inside its generic body, which only C++
    /// instantiates, so the constructor the arguments reach was never
    /// resolved in Kairo and a raw pointer reached a safe `*T` parameter
    /// unseen (P536). The arguments are resolved against T's constructors
    /// as a direct `T(args)` resolves them, diagnostics included; nothing is
    /// recorded on the call, whose own arguments stay the forwarder's.
    ///
    /// Left alone: a dependent or C++ T (clang resolves that constructor
    /// with the rules it is written in), a T with no declared constructor
    /// (implicit construction), and one argument of type T itself, the
    /// transfer constructor an implicit `@copy` / `@move` may be, and no
    /// argument at all: default construction passes nothing that could
    /// convert wrongly, and `create<T>()` of a class declaring only a
    /// transfer constructor is accepted today (Tests/Sema/Check/
    /// class_allocator_errors.k) where a direct `T()` is not.
    priv fn _check_created_ctor(self, n: *CallExpr, f: unsafe *FunctionDecl, r: *OvlResult) -> bool {
        var sc = self.dyn()->sc
        if f == &null || sc->well_known == &null || f->generic_params.size() == 0 || n->args.size() == 0 {
            return true
        }

        var unsafe *lang = sc->well_known->get(WellKnownType::Create)
        if lang == &null {
            return true
        }

        var unsafe *fd   = NameLookup::representative(unsafe (f as unsafe *Decl))
        var unsafe *want = NameLookup::representative(lang)
        if fd != want {
            return true
        }

        var unsafe *rec = r->ded.lookup(f, 0)
        if rec == &null || rec->is_dependent() {
            return true
        }

        rec = canon_unqual(rec)
        var unsafe *d = self.dyn()->tu.record_decl(rec)
        if d == &null || decl_is_imported(d) {
            return true
        }

        if decl_is_instance(d) && decl_is_imported(decl_instantiated_from(d)) {
            return true
        }

        if n->args.size() == 1 && n->args[0] != &null {
            var unsafe *a0 = n->args[0]->type_
            if a0 != &null && self.dyn()->tu.as_value(a0) == rec {
                return true
            }
        }

        var unsafe *body = sc->record_body(rec)
        if body == &null {
            body = self.dyn()->tu.pattern_of(d)
        }

        var dc    = NameLookup::context_of(body)
        var cands = cxx::std::vector<unsafe *Decl>()
        if dc != &null {
            var cell = sc->lookup.in_context(dc, DeclName::ctor())
            if cell.found() {
                for var i: usize = 0; i < cell.cell->size(); ++i {
                    cands.push_back(cell.cell->get(i))
                }
            }
        }

        if cands.size() == 0 {
            return true
        }

        var args = cxx::std::vector<ArgInfo>()
        if !self.build_args(n->args, &args) {
            return true
        }

        if !self._narrow_args(unsafe &cands, unsafe &args, true, rec) {
            return false
        }

        // The forwarder's `<T>` is still the explicit list resolution
        // reads; a constructor takes none, so it is set aside for this
        // resolution and put back for the rest of the forwarder's call.
        var cr = OvlResult()
        {
            var _ctx = OvlCallScope(unsafe &self.dyn()->ovl)
            self.dyn()->ovl.explicit_args.clear()
            self.dyn()->ovl.call_syntax = true
            cr = self.dyn()->ovl.resolve(
                &cands,
                &args,
                true,
                n->range,
                self.dyn()->tu.decl_name(d),
                rec,
            )
        }

        if cr.outcome == OvlOutcome::Dependent || cr.outcome == OvlOutcome::Deferred {
            return true
        }

        return cr.outcome == OvlOutcome::Selected
    }

    /// `print_all(args...)`: a pack forwarded whole has no type of its own
    /// (ExprTyper leaves the expansion unknown), so the call resolves as
    /// Dependent and _check_forwarded_bounds never sees it. With ONE
    /// candidate, the expansion fills its type pack, and each `impl` bound
    /// of that pack must be one of the forwarded pack's own, as for a
    /// single `T`. Overloads are left to the instance: which one the
    /// expansion selects is not known here.
    priv fn _check_forwarded_pack(self,
                                  n:          unsafe *CallExpr,
                                  const all:  cxx::std::vector<unsafe *Decl>,
                                  const args: cxx::std::vector<ArgInfo>) {
        if all.size() != 1 {
            return
        }

        var unsafe *f = dyn_cast<FunctionDecl>((all)[0])
        if f == &null || f->generic_params.size() == 0 {
            return
        }

        var pg: unsafe *GenericParamType = &null
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *tp = param_type_pack_param(f->params[i])
            if tp != &null {
                pg = tp
            }
        }

        if pg == &null {
            return
        }

        var x: unsafe *Type = &null
        for var i: usize = 0; i < args.size(); ++i {
            var pe = dyn_cast<PackExpansionExpr>(self.dyn()->tu.strip_parens((args)[i].expr))
            if pe == &null {
                continue
            }

            var id = dyn_cast<NamedIdentExpr>(self.dyn()->tu.strip_parens(pe->operand))
            if id == &null {
                continue
            }

            var pd = dyn_cast<ParamDecl>(id->resolved_decl)
            if pd == &null {
                continue
            }

            var cp = param_type_pack_param(pd)
            if cp != &null {
                x = unsafe (cp as unsafe *Type)
                break
            }
        }

        if x == &null {
            return
        }

        var cgp = self.dyn()->tu.op_checked_param(x)
        if cgp == &null {
            return
        }

        var sc = self.dyn()->sc
        var it = sc->bounds.find((unsafe (f as unsafe *Decl)) as usize as u64)
        if it == sc->bounds.end() {
            it = sc->bounds.find(
                NameLookup::representative(unsafe (f as unsafe *Decl)) as usize as u64,
            )

            if it == sc->bounds.end() {
                return
            }
        }

        var _set = unsafe &it->second
        for var i: usize = 0; i < _set->impl_constraints.size(); ++i {
            var k   = _set->impl_constraints[i]
            var kid = dyn_cast<NamedIdentExpr>(k->lhs)
            if kid == &null || k->rhs == &null || k->rhs->canonical == &null {
                continue
            }

            var gp = dyn_cast<GenericParamDecl>(kid->resolved_decl)
            if gp == &null || gp->index != pg->param_index {
                continue
            }

            var iface = canon_unqual(k->rhs->canonical)
            if self._param_meets(x, iface) {
                continue
            }

            self._report_forwarded(n, f, k, cgp, x, iface)
            return
        }
    }

    /// Whether the caller's parameter type \p x promises \p iface through
    /// its bounds: the interface itself (at any arguments: a dependent
    /// mismatch is the instance's), or one deriving it. A `derives` bound is
    /// taken on trust: whether the base conforms is not read here.
    priv fn _param_meets(self, x: *Type, iface: *Type) -> bool {
        if self.dyn()->tu.bound_bases(x).size() > 0 {
            return true
        }

        var unsafe *want = if (isa<RecordType>(iface)) => (cast<RecordType>(iface)->decl)
                           else => &null
        if want == &null {
            return true
        }

        var bis   = self.dyn()->tu.bound_ifaces(x)
        var subst = Substitution(self.dyn()->sc)
        for var i: usize = 0; i < bis.size(); ++i {
            var bi = canon_unqual(bis[i])
            if bi == &null {
                continue
            }

            if bi == iface {
                return true
            }

            if isa<RecordType>(bi)
                && NameLookup::representative(
                    cast<RecordType>(bi)->decl,
                ) == NameLookup::representative(want) {
                return true
            }

            if subst.derives_from(bi, iface) {
                return true
            }
        }

        return false
    }

    /// R051E for an unbounded \p cgp (with the fix-it adding the bound),
    /// R025E when it has bounds and none is \p iface: ExprTyper::needs_bound's
    /// split, for a call instead of an operator.
    priv fn _report_forwarded(self,
                              n:     *CallExpr,
                              f:     *FunctionDecl,
                              k:     *ConstraintExpr,
                              cgp:   *GenericParamDecl,
                              xt:    *Type,
                              iface: *Type) {
        var pname   = self.dyn()->tu.decl_name(cgp)
        var fname   = self.dyn()->tu.decl_name(f)
        var is      = self.dyn()->tu.str(iface)
        var x       = cgp->range
        var bounded = self.dyn()->tu.bound_ifaces(xt).size() > 0
        var msg     = f"'{fname}' needs '{pname}' to implement '{is}'"
        if bounded {
            var b = self.dyn()->sc->diag->report(
                DiagID::R025E,
                n->range.start,
                f"{msg}; none of the bounds of '{pname}' does",
            )

            b.first(n->range)
            b.note(k->range.start, "required by this bound")->first(k->range)
            b.note(
                x.start,
                f"'{pname}' is declared here; bound it 'impl {is}' too, or by an interface that derives it",
            )->first(x)
            b.emit()
        } else {
            var b = self.dyn()->sc->diag->report(DiagID::R051E, n->range.start, msg)
            b.first(n->range)
            b.note(k->range.start, "required by this bound")->first(k->range)
            b.note(DiagCode(DiagID::R051N), x.start, f"'{pname}' is declared with no bound")->first(
                x,
            )

            b.insert(x.end, f" impl {is}", f"bound '{pname}' by '{is}'")
            b.emit()
        }
    }

    /// \p owner's deduced arguments, appended to \p out in parameter order,
    /// a type pack flat (its elements, as InstanceEntry::args keeps them);
    /// false on an unbound or still-dependent binding.
    priv fn _bound_args(self,
                        r:          *OvlResult,
                        owner:      unsafe *Decl,
                        @inout out: cxx::std::vector<unsafe *Type>) -> bool {
        var gps = decl_generic_params(owner)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp == &null {
                continue
            }

            if gp->is_pack {
                var els = cxx::std::vector<unsafe *Type>()
                if !r->ded.pack_elems(owner, gp->index, unsafe &els) {
                    return false
                }

                for var k: usize = 0; k < els.size(); ++k {
                    if els[k]->is_dependent() {
                        return false
                    }

                    out.push_back(els[k])
                }

                continue
            }

            var unsafe *b = r->ded.lookup(owner, gp->index)
            if b == &null || b->is_dependent() {
                return false
            }

            out.push_back(b)
        }

        return true
    }

    /// # the call

    fn type_call(self, n: unsafe *CallExpr, expected: unsafe *Type) -> unsafe *Type {
        var callee = self.dyn()->tu.strip_parens(n->callee)
        if callee == &null {
            self.dyn()->fail(n, DiagID::SC093E, "call with no callee")
            return &null
        }

        /// ## name
        if isa<NamedIdentExpr>(callee) {
            var id = cast<NamedIdentExpr>(callee)
            if id->is_poisoned() {
                self.dyn()->poison_only(n)
                return &null
            }

            if id->is_deferred() {
                var cands = cxx::std::vector<*Decl>()
                for var i: usize = 0; i < id->candidate_cell->size(); ++i {
                    cands.push_back(id->candidate_cell->get(i))
                }

                self._set_explicit(&id->generic_args)
                var cname = self.dyn()->sc->ctx->get_spelling(id->name)
                var rt    = self._call_candidates(n, &cands, false, &null, cname, id, &null, true)
                self.dyn()->ovl.explicit_args.clear()
                return rt
            }

            // `u32(x)`: the parser admits a primitive before `(`, but Kairo
            // converts with `as` (casting.md), and a type is not callable.
            // N leaves the head unbound on purpose; without this the call
            // would fall to mark_unknown below and type as nothing, silently.
            if is_annotation(id->name.kind) {
                var sp = self.dyn()->sc->ctx->get_spelling(id->name)
                self.dyn()->sc->diag->report(
                    DiagID::SC037E,
                    n->range.start,
                    f"'{sp}' is a type, not a function; convert with 'x as {sp}'",
                ).first(n->range)->emit()
                id->poison()
                n->poison()
                return &null
            }

            if !id->is_bound() {
                self.dyn()->mark_unknown(n)
                return &null
            }

            var d = id->resolved_decl
            if isa<FunctionDecl>(d) {
                var cands = cxx::std::vector<*Decl>()
                cands.push_back(d)
                self._set_explicit(&id->generic_args)
                var cname = self.dyn()->sc->ctx->get_spelling(id->name)
                var rt    = self._call_candidates(n, &cands, false, &null, cname, id, &null, true)
                self.dyn()->ovl.explicit_args.clear()
                return rt
            }

            if self.dyn()->tu.is_type_decl(d) {
                var rec = self.dyn()->denoted_type(callee)
                if rec == &null {
                    // `type G = T::Guard; G(x)`: an alias of a nested type of a
                    // `: type` parameter has no type until an instance names
                    // T, so the construction is the instance's, as written
                    // (like `T::Guard(x)` itself). Poisoning it made codegen
                    // ICE on a call that is only unknown.
                    if self._dependent_alias(d) {
                        self.dyn()->mark_unknown(n)
                        self._type_args_blind(n)
                        return &null
                    }

                    self.dyn()->poison_only(n)
                    return &null
                }

                return self._ctor_call(n, rec)
            }

            if isa<GenericParamDecl>(d) {
                return self._param_ctor_call(n, cast<GenericParamDecl>(d))
            }

            // A module is not callable. `import A::B::both` with both
            // A/B/both.k and a `both` in A/B.k binds the MODULE (imports.mdx,
            // "Resolution with `::`": the module path is tried first), and the
            // call reached codegen as CL001E "no member named '_'" (P507).
            if isa<ModuleDecl>(d) {
                var sp = self.dyn()->sc->ctx->get_spelling(id->name)
                var b  = self.dyn()->sc->diag->report(
                    DiagID::SC001E,
                    n->range.start,
                    f"'{sp}' is a module, not a function",
                )

                b.first(callee->range)
                b.note(
                    d->range.start,
                    "\x27" + sp + "\x27 is this module: where a module and a declaration share a name, an import path names the module and a braced import (`::{" + sp + "}`) names the declaration",
                )
                b.emit()
                id->poison()
                n->poison()
                self._type_args_blind(n)
                return &null
            }

            // a value: must be a function pointer.
            var vt = self.dyn()->type_of(callee, &null)
            return self._call_through(n, vt)
        }

        /// ## chain
        if isa<ChainExpr>(callee) {
            var ce = cast<ChainExpr>(callee)
            self.dyn()->type_of(callee, &null)
            if callee->is_poisoned() {
                self.dyn()->poison_only(n)
                return &null
            }

            var info = self.dyn()->chain_info(ce)
            if info == &null {
                self.dyn()->mark_unknown(n)
                self._type_args_blind(n)
                return &null
            }

            if info->last_is_type {
                var rec = self.dyn()->denoted_type(callee)
                if rec == &null {
                    self.dyn()->poison_only(n)
                    return &null
                }

                return self._ctor_call(n, rec)
            }

            if info->callable_cands.size() > 0 {
                var last = ce->steps.get(ce->steps.size() - 1)
                var nm   = "<operator>"
                if last->name != &null {
                    nm = self.dyn()->sc->ctx->get_spelling(last->name->name)
                }

                self._set_explicit(&last->generic_args)
                self.dyn()->ovl.recv_cat = info->receiver_cat
                var r = self._call_candidates(
                    n,
                    &info->callable_cands,
                    info->has_receiver,
                    info->receiver,
                    nm,
                    &null,
                    last,
                )

                self.dyn()->ovl.explicit_args.clear()
                self.dyn()->ovl.recv_cat = Expr::ValueCategory::LValue
                if ce->has_optional_chaining() {
                    return self._safe_call_result(n, r)
                }

                return r
            }

            if info->unknown {
                self.dyn()->mark_unknown(n)
                self._type_args_dependent(n)
                return &null
            }

            return self._call_through(n, callee->type_)
        }

        /// ## anything else: a fn-pointer value
        var t = self.dyn()->type_of(callee, &null)
        if callee->is_poisoned() {
            self.dyn()->poison_only(n)
            return &null
        }

        return self._call_through(n, t)
    }

    /// ## a class's own allocator

    /// `x?.f(args)` whose call typed \p r: the expression is `if x? =>
    /// x.f(args) else null` (Compiler/Spec/Nullables.md#safe-access), so `R?`, and `R` itself when
    /// it is already nullable (the one flattening, 1.5). A `void` method is
    /// a statement either way; a `-> !` one is `void` too, since on null
    /// the expression completes. \p r is kept on the node for the lowering.
    priv fn _safe_call_result(self, n: *CallExpr, r: unsafe *Type) -> unsafe *Type {
        if r == &null || n->is_poisoned() {
            return r
        }

        n->safe_result = r
        if self.dyn()->tu.is_never(r) || self.dyn()->tu.is_builtin(r, BuiltinKind::Void) {
            return self.dyn()->tu.builtin(BuiltinKind::Void)
        }

        if r->is_dependent() || r->is_instantiation_dependent() {
            if self.dyn()->tu.nullable_inner(r) != &null {
                return r
            }

            return self.dyn()->sc->types->nullable(r)
        }

        if self.dyn()->tu.nullable_inner(self.dyn()->tu.as_value(r)) != &null {
            return self.dyn()->tu.as_value(r)
        }

        return self.dyn()->sc->types->nullable(self.dyn()->tu.as_value(r))
    }

    /// \p t is an interface's own type: `I` as a call's qualifier.
    priv fn _is_interface_type(self, t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var d = self.dyn()->tu.record_decl(canon_unqual(t))
        return d != &null
            && isa<InterfaceDecl>(NameLookup::representative(self.dyn()->tu.pattern_of(d)))
    }

    /// \p d is none of \p cands (as a `where` group's lead and as a
    /// redeclaration chain's representative): ADL added it.
    priv fn _outside(self, const cands: cxx::std::vector<unsafe *Decl>, d: unsafe *Decl) -> bool {
        var unsafe *want = NameLookup::representative(d)
        for var i: usize = 0; i < cands.size(); ++i {
            var unsafe *c = (cands)[i]
            var unsafe *f = dyn_cast<FunctionDecl>(c)
            if f != &null && f->where_lead != &null {
                c = f->where_lead
            }

            if NameLookup::representative(c) == want {
                return false
            }
        }

        return true
    }

    priv fn _any_method(self, const cands: cxx::std::vector<unsafe *Decl>) -> bool {
        for var i: usize = 0; i < cands.size(); ++i {
            var unsafe *f = dyn_cast<FunctionDecl>((cands)[i])
            if f != &null && f->is_method() {
                return true
            }
        }

        return false
    }

    /// A call through a local initialized with a closure literal takes the
    /// closure's defaults for the trailing arguments it omits (closures.md,
    /// Default Parameters: "matching the behavior of regular functions").
    /// The `fn` TYPE carries no defaults, so they are read off the literal
    /// the local was built from, and appended as fresh copies: each node has
    /// one parent. Only literal defaults are copied (FIXME(CLOSURE-DEFAULTS):
    /// any other expression needs a clone or a thunk); otherwise the call is
    /// left short and the arity error stands. A local reassigned to another
    /// closure keeps its initializer's defaults.
    priv fn _closure_defaults(self, n: *CallExpr, want: usize) {
        var c  = self.dyn()->tu.strip_parens(n->callee)
        var id = dyn_cast<NamedIdentExpr>(c)
        if id == &null {
            return
        }

        var vd = dyn_cast<VariableDecl>(id->resolved_decl)
        if vd == &null || vd->init == &null {
            return
        }

        var ce = dyn_cast<ClosureExpr>(self.dyn()->tu.strip_parens(vd->init))
        if ce == &null || ce->params.size() != want {
            return
        }

        var have  = n->args.size()
        var extra = cxx::std::vector<unsafe *Expr>()
        for var i: usize = have; i < want; ++i {
            var p = ce->params[i]
            if p == &null || p->default_val == &null {
                return
            }

            var x = self._copy_literal(p->default_val, n->range)
            if x == &null {
                return
            }

            extra.push_back(x)
        }

        var all = cxx::std::vector<unsafe *Expr>()
        for var i: usize = 0; i < have; ++i {
            all.push_back(n->args[i])
        }

        for var i: usize = 0; i < extra.size(); ++i {
            all.push_back(extra[i])
        }

        n->args.from_buf(all.data(), all.size(), self.dyn()->sc->ctx)
    }

    /// A fresh, untyped copy of the literal \p e (its token and immediate
    /// data shared, both immutable), or null for anything else.
    priv fn _copy_literal(self, e: *Expr, at: SourceRange) -> unsafe *Expr {
        var ctx               = self.dyn()->sc->ctx
        var out: unsafe *Expr = &null
        if isa<IntegerLiteralExpr>(e) {
            var x = ctx->alloc<IntegerLiteralExpr>()
            *x  = *cast<IntegerLiteralExpr>(e)
            out = x
        } else if isa<FloatingLiteralExpr>(e) {
            var x = ctx->alloc<FloatingLiteralExpr>()
            *x  = *cast<FloatingLiteralExpr>(e)
            out = x
        } else if isa<BooleanLiteralExpr>(e) {
            var x = ctx->alloc<BooleanLiteralExpr>()
            *x  = *cast<BooleanLiteralExpr>(e)
            out = x
        } else if isa<CharacterLiteralExpr>(e) {
            var x = ctx->alloc<CharacterLiteralExpr>()
            *x  = *cast<CharacterLiteralExpr>(e)
            out = x
        } else if isa<NullLiteralExpr>(e) {
            var x = ctx->alloc<NullLiteralExpr>()
            *x  = *cast<NullLiteralExpr>(e)
            out = x
        } else if isa<StringLiteralExpr>(e) && !cast<StringLiteralExpr>(e)->is_format() {
            var x = ctx->alloc<StringLiteralExpr>()
            *x  = *cast<StringLiteralExpr>(e)
            out = x
        }

        if out == &null {
            return &null
        }

        out->type_          = &null
        out->value_category = Expr::ValueCategory::Unknown
        out->expr_flags     = FlagSet<Expr::ExprFlags, u8>()
        out->poisoned       = false
        out->init_annotations(&ctx->ast_alloc)
        return out
    }

    priv fn _type_args_blind(self, n: unsafe *CallExpr) {
        for var i: usize = 0; i < n->args.size(); ++i {
            self.dyn()->type_of(n->args[i], &null)
        }
    }

    /// The arguments of a call only the instance resolves (a member call
    /// through a `: type` parameter, Compiler/Spec/Generics.md#duck-regime): typed as written, with no
    /// parameter to read a type from. A bare `&null` among them is the
    /// instance's too: it goes out as `nullptr`, which converts to whatever
    /// pointer the parameter clang picks takes, so it is left untyped
    /// (instantiation-dependent) rather than SC076E "cannot infer" -- the
    /// self-host mixins' `dyn()->type_of(e, &null)`.
    priv fn _type_args_dependent(self, n: unsafe *CallExpr) {
        for var i: usize = 0; i < n->args.size(); ++i {
            var unsafe *a = n->args[i]
            var        nl = dyn_cast<NullLiteralExpr>(self.dyn()->tu.strip_parens(a))
            if nl != &null && nl->is_ref {
                self.dyn()->mark_unknown(a)
                continue
            }

            var unsafe *at = self.dyn()->type_of(a, &null)
            // A nullable place proven non-null here goes out as its value
            // (Compiler/Spec/Nullables.md#narrowed-reads): no parameter is
            // known to say whether the value is needed, and without the
            // read a `*T?` reached C++ where the instance's parameter is a
            // `T*` (`self.dyn()->tu.decl_name(f)` after `if f == &null
            // { return }`). The value converts back implicitly
            // where the instance's parameter is the `T?` after all.
            if at != &null {
                self.dyn()->value_if_proven(a, at)
            }
        }
    }

    /// The explicit generic arguments of a call's callee name (`f<3>()`),
    /// for OverloadResolution to bind before deduction (Compiler/Spec/Eval.md#generic-value-parameters; the
    /// "explicit generic arguments are ignored" ticket). One that did not
    /// resolve leaves the list empty: the call deduces as it did before.
    priv fn _set_explicit(self, gargs: *FrozenList<ChainType::GenericArg>) {
        self.dyn()->ovl.explicit_args.clear()
        var tmp = cxx::std::vector<unsafe *Type>()
        for var i: usize = 0; i < gargs->size(); ++i {
            var unsafe *a = gargs->get(i)
            if a->name != &null || a->ty == &null || a->ty->canonical == &null {
                return
            }

            tmp.push_back(a->ty->canonical)
        }

        for var i: usize = 0; i < tmp.size(); ++i {
            self.dyn()->ovl.explicit_args.push_back(tmp[i])
        }
    }

    /// `y.foo(42)` selecting a STATIC requirement or a static extension
    /// member: rejected, with the fix-it to `T::foo(42)`. A requirement has no
    /// object to dispatch on, so a value names no witness; an extension
    /// member is a free function in the C++ it lowers to, so there is no
    /// receiver slot to drop the value into. Left alone, ExtensionLowering
    /// meets the call with nowhere to put it and ICEs. A plain class's static
    /// called through a value is C++'s rule and stays legal (it is a member
    /// of the class, and the value is simply discarded).
    priv fn _static_through_value(self,
                                  n:    *CallExpr,
                                  step: *ChainExpr::Step,
                                  f:    unsafe *FunctionDecl,
                                  recv: unsafe *Type) -> bool {
        if f == &null || f->is_method() || f->is_operator {
            return false
        }

        if step->access_kind == ChainExpr::AccessKind::ColonColon {
            return false
        }

        var unsafe *fd = unsafe (f as unsafe *Decl)
        var        req = false
        if f->semantic_dc != &null {
            var unsafe *home = (f->semantic_dc)->owner_decl()
            req = home != &null && isa<InterfaceDecl>(NameLookup::representative(home))
        }

        if !req && decl_extension_of(fd) == &null {
            return false
        }

        var nm   = self.dyn()->tu.decl_name(fd)
        var what = if (req) => ("static requirement") else => "static extension member"
        var ch   = dyn_cast<ChainExpr>(self.dyn()->tu.strip_parens(n->callee))
        var at   = if (step->name != &null) => (step->name->range.start) else => step->range.start
        var b = self.dyn()->sc->diag->report(
            DiagID::SC247E,
            at,
            f"'{nm}' is a {what}; it takes no 'self' and is called through the type, not a value",
        )

        if step->name != &null {
            b.first(step->name->range)
        } else {
            b.first(step->range)
        }

        if fd->range.is_valid() {
            b.note(
                DiagCode(DiagID::SC247N),
                fd->range.start,
                f"'{nm}' is declared here, without 'self'",
            )->first(fd->range)
        }

        // The receiver's TYPE as written in the diagnostics (`T`, not what a
        // bound T stands for): `T::foo` is the spelling that works in the
        // generic body the call is in.
        if ch != &null && recv != &null && step->name != &null {
            var ty = self.dyn()->tu.str(self.dyn()->tu.as_value(recv))
            b.fix(
                SourceRange(ch->range.start, step->name->range.start),
                ty + "::",
                f"call it through the type: '{ty}::{nm}'",
            )
        }

        b.emit()
        return true
    }

    /// `Box<i32>::zero()`: the record a static member is named THROUGH,
    /// when that record is a generic one's instance (or a pattern used
    /// dependently, `Box<T>::zero()`); null otherwise. The member's decl is
    /// the pattern's -- an instance shell has no members of its own -- so
    /// the decl alone spells `Box::zero`, a class template with no
    /// arguments, and clang rejects it. The arguments are on the qualifier
    /// and nowhere else after X. A requirement goes through its witness
    /// and an extension member is rewritten to a free call, so neither is
    /// named through a record here.
    priv fn _instance_qualifier(self, f: unsafe *FunctionDecl, recv: unsafe *Type) -> unsafe *Type {
        if f == &null || recv == &null || f->is_method() || f->semantic_dc == &null {
            return &null
        }

        var unsafe *dc = f->semantic_dc
        if !dc->is_type_scope() || dc->dc_kind == DeclContextKind::Extension {
            return &null
        }

        var unsafe *owner = dc->owner_decl()
        if owner == &null || isa<InterfaceDecl>(NameLookup::representative(owner)) {
            return &null
        }

        var unsafe *r = dyn_cast<RecordType>(canon_unqual(recv))
        if r == &null || r->args.size() == 0 {
            return &null
        }

        return r
    }

    /// Resolve against \p cands, promote the winner onto \p ident or \p step.
    /// \param adl  the callee was an unqualified name: widen \p cands with
    ///             argument-dependent lookup before resolving.
    priv fn _call_candidates(self,
                             n:            unsafe *CallExpr,
                             cands:        unsafe *cxx::std::vector<unsafe *Decl>,
                             has_receiver: bool,
                             receiver:     unsafe *Type,
                             const name:   string,
                             ident:        unsafe *NamedIdentExpr,
                             step:         unsafe *ChainExpr::Step,
                             adl:          bool = false) -> unsafe *Type {
        var args = cxx::std::vector<ArgInfo>()
        // THIS call's (_functor_call), taken before any argument's own call
        // is typed and could read it.
        var functor = self._functor_next
        self._functor_next = false
        // The explicit arguments are THIS call's; typing an argument can be
        // a call of its own, and one that never sets them (a constructor
        // call, `make_box<Pair>(Pair(3, 4))`) read them as written on it:
        // "it takes 0 generic argument(s), and 1 were written".
        // The receiver's category likewise (ChainInfo::receiver_cat).
        var ok = false
        {
            var _ctx = OvlCallScope(unsafe &self.dyn()->ovl)
            self.dyn()->ovl.explicit_args.clear()
            self.dyn()->ovl.recv_cat = Expr::ValueCategory::LValue
            ok = self.build_args(n->args, &args)
        }

        // ADL ([basic.lookup.argdep]): an unqualified call also sees functions
        // of the same name in the modules of its arguments' types -- how
        // `swap(a, b)` on two `std::` values finds `std::swap` unqualified.
        // AFTER build_args, because it needs the argument types; an untyped
        // literal has none and associates nothing. Suppressed, as in C++,
        // when ordinary lookup found a method.
        var all = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < cands->size(); ++i {
            all.push_back((*cands)[i])
        }

        if adl && !self._any_method(*cands) {
            var scopes = cxx::std::vector<*DeclContext>()
            for var i: usize = 0; i < args.size(); ++i {
                self.dyn()->ml.associated_scopes(args[i].ty, &scopes)
            }

            var imm = self.dyn()->sc->imm_table()->find_ident(name)
            if scopes.size() > 0 && imm != u32::MAX {
                self.dyn()->ml.adl_candidates(&scopes, DeclName::ident(imm), name, cands, &all)
            }
        }

        // The receiver goes IN, not on afterwards: an interface member's
        // `Self` is the receiver, and viability is judged against it.
        var recv: unsafe *Type = &null
        if receiver != &null {
            recv = self.dyn()->tu.strip_nullable(receiver)
            var pt = self.dyn()->tu.pointee(recv)
            if pt != &null {
                recv = pt
            }
        }

        // `I::m(x, ...)`, the qualified form of a requirement call: the
        // qualifier is the interface, not the receiver. `self` is the first
        // argument, so Self is ITS type, and the requirement's `Self` reads
        // as that (through_receiver), as it would for `x.m(...)`.
        // The qualifier stays on the call (CallExpr::witness_iface, until
        // ExtensionLowering writes the declaring instance over it): a GENERIC
        // interface's arguments are on it and nowhere else, and resolution
        // binds the requirement's interface parameters from it.
        var qual: unsafe *Type = &null
        if !has_receiver
            && args.size() > 0
            && args[0].ty != &null
            && self._is_interface_type(recv) {
            qual             = canon_unqual(recv)
            n->witness_iface = qual
            recv             = self.dyn()->tu.as_value(args[0].ty)
            // Bare `Container::get(b, 0)` names no instance. Which one b
            // conforms to could be deduced from its declarations when only one
            // fits, but that is a second lookup to keep sound; the arguments
            // are one edit away.
            var unsafe *qr = dyn_cast<RecordType>(qual)
            var qd = if (qr != &null) => (NameLookup::representative(
                         self.dyn()->tu.pattern_of(qr->decl),
                     ))
                     else => &null
            if qd != &null
                && decl_generic_params(qd).size() > 0
                && self.dyn()->ded_scratch()->own_args(qr, qd) {
                var iname = self.dyn()->tu.decl_name(qd)
                var d = self.dyn()->sc->diag->report(
                    DiagID::SC248E,
                    n->range.start,
                    f"'{iname}' is generic, and a qualified call names its instance: write '{iname}<...>::{name}'",
                )

                d.first(n->range)
                d.note(qd->range.start, named_declared_here(iname))->first(qd->range)
                d.emit()
                self.dyn()->poison_only(n)
                return &null
            }
        }

        if !self._narrow_args(unsafe &all, unsafe &args, has_receiver, recv) {
            self.dyn()->poison_only(n)
            return &null
        }

        // Not an OvlCallScope: `r` would then need a declared type ahead of
        // the scope, which makes every call below it a checked one through
        // a duck-typed receiver (TODO(DUCK-GENERIC)); resolve writes none of
        // the context, so restoring call_syntax alone is the whole restore.
        var outer_cs = self.dyn()->ovl.call_syntax
        self.dyn()->ovl.call_syntax = true
        var r = self.dyn()->ovl.resolve(&all, &args, has_receiver, n->range, name, recv, qual)
        self.dyn()->ovl.call_syntax = outer_cs
        if r.outcome == OvlOutcome::Dependent {
            self._check_forwarded_pack(n, all, args)
            self.dyn()->mark_unknown(n)
            return &null
        }

        if r.outcome != OvlOutcome::Selected {
            self.dyn()->poison_only(n)
            return &null
        }

        if !ok {
            self.dyn()->poison_only(n)
            return &null
        }

        if step != &null && self._static_through_value(n, step, r.decl, recv) {
            self.dyn()->poison_only(n)
            return &null
        }

        if recv != &null {
            r.ded.bind_from_record(canon_unqual(recv))
        }

        if step != &null && step->access_kind == ChainExpr::AccessKind::ColonColon {
            n->qualifier = self._instance_qualifier(r.decl, recv)
        }

        // promote cell -> decl (hard invariant #7). A name N bound to ONE
        // decl is repointed too when the winner came from argument-dependent
        // lookup instead: EmitIR calls what the name is bound to, so `tag(b,
        // d)` with a Kairo `tag(b, x: bool)` in scope and C++'s `adl::tag`
        // winning called the Kairo one, converting the f64 to bool -- a
        // conversion resolution had refused.
        if ident != &null && (ident->resolved_decl == &null || self._outside(*cands, r.decl)) {
            ident->resolved_decl  = r.decl
            ident->candidate_cell = &null
        }

        if step != &null && step->resolved_decl == &null {
            step->resolved_decl  = r.decl
            step->candidate_cell = &null
        }

        if functor {
            n->functor_op = r.decl
        }

        self.finish_call_args(r.decl, &args, &r)
        // A method taking a mutable `self` may write any field of its
        // receiver (Compiler/Spec/Nullables.md#weakening); a `const self` one cannot.
        if step != &null
            && r.receiver_bound
            && r.decl->is_method()
            && !r.decl->is_const()
            && !r.decl->params[0]->is_const {
            var ce = dyn_cast<ChainExpr>(self.dyn()->tu.strip_parens(n->callee))
            if ce != &null {
                self.dyn()->flow.mutable_self_call(ce, n->range)
            }
        }

        if !self._check_constant_args(r.decl, &args, &r) {
            self.dyn()->poison_only(n)
            return &null
        }

        self._warn_unmarked(&args, &r)
        self._write_arg_map(n, r.decl, args, &r)
        self._check_forwarded_bounds(n, r.decl, &r)
        if !self._check_created_ctor(n, r.decl, &r) {
            self.dyn()->poison_only(n)
            return &null
        }

        var rt = self.call_result_type(r.decl, &r)
        n->instance = r.instance
        if r.instance == &null && r.dep_args.size() > 0 {
            var arr = self.dyn()->sc->ctx->alloc_array<*Type>(r.dep_args.size())
            for var i: usize = 0; i < r.dep_args.size(); ++i {
                arr[i] = r.dep_args[i]
            }

            n->dep_args.from_raw(arr, r.dep_args.size())
        }

        if rt == &null {
            self.dyn()->mark_unknown(n)
            return &null
        }

        return rt
    }

    /// Nullable places passed where only their VALUE fits (Compiler/Spec/Nullables.md#narrowed-reads).
    /// Selection judges an argument by ArgInfo::ty, which for a `T?` place
    /// is `T?`, so `take(a)` with `fn take(x: i32)` would be "no matching
    /// overload" even after `if a?`. Only when no candidate takes the
    /// arguments as they are, and one does with the nullable places read as
    /// their values, are those reads made: each one narrowed when its place
    /// is proven non-null, else the nullness error (false: reported). A
    /// read some candidate does not need -- one still viable with that
    /// argument left nullable -- is left alone, so a `T?` parameter keeps
    /// its nullable and is never asked about. A `T?` overload, or a call
    /// that type-checks as written, is untouched.
    priv fn _narrow_args(self,
                         cands:        unsafe *cxx::std::vector<unsafe *Decl>,
                         args:         unsafe *cxx::std::vector<ArgInfo>,
                         has_receiver: bool,
                         recv:         unsafe *Type) -> bool {
        var idx = cxx::std::vector<usize>()
        for var i: usize = 0; i < args->size(); ++i {
            var *a = &(*args)[i]
            if a->expr == &null || a->marked || a->ty == &null {
                continue
            }

            if self.dyn()->flow.narrowed_type(a->ty) == &null {
                continue
            }

            idx.push_back(i)
        }

        if idx.size() == 0 {
            return true
        }

        // Judged as the call will be (OverloadResolution::call_syntax).
        var ok_as_is = false
        {
            var _ctx = OvlCallScope(unsafe &self.dyn()->ovl)
            self.dyn()->ovl.call_syntax = true
            ok_as_is = self.dyn()->ovl.any_viable(cands, args, has_receiver, &null, &null, recv)
        }

        if ok_as_is {
            return true
        }

        var alt = *args
        for var j: usize = 0; j < idx.size(); ++j {
            alt[idx[j]].ty = self.dyn()->flow.narrowed_type(alt[idx[j]].ty)
        }

        if !self.dyn()->ovl.any_viable(cands, &alt, has_receiver, &null, &null, recv) {
            return true
        }

        // Keep only the reads some viable candidate needs.
        var need = cxx::std::vector<usize>()
        for var j: usize = 0; j < idx.size(); ++j {
            var unsafe *keep = alt[idx[j]].ty
            alt[idx[j]].ty = (*args)[idx[j]].ty
            if self.dyn()->ovl.any_viable(cands, &alt, has_receiver, &null, &null, recv) {
                continue
            }

            alt[idx[j]].ty = keep
            need.push_back(idx[j])
        }

        var ok = true
        for var j: usize = 0; j < need.size(); ++j {
            var *a = &(*args)[need[j]]
            var o  = self.dyn()->flow.read_value(a->expr, true)
            if o == NULL_READ_REFUSED {
                ok = false
                continue
            }

            if o == NULL_READ_NARROWED {
                a->ty = a->expr->type_
            }
        }

        return ok
    }

    /// A clang builtin's `I` positions take an integer constant. Checked
    /// here, at the Kairo argument: left to clang, the error lands on the
    /// emitted token stream, where the user wrote nothing.
    ///
    /// A constant is an integer, bool or char literal, a `sizeof` or
    /// `alignof`, either under unary `-`, `+`, `~`, `!`, or cast `as` an
    /// integer or bool type: all of these are ICEs to clang, and a sizeof /
    /// alignof of a dependent type is a value-dependent one it folds at
    /// instantiation. Nothing else is yet: the evaluator is a stub, so an
    /// `eval` binding has no value sema can read, and accepting one here would
    /// only move the error back into clang.
    priv fn _check_constant_args(self,
                                 f:    *FunctionDecl,
                                 args: unsafe *cxx::std::vector<ArgInfo>,
                                 r:    *OvlResult) -> bool {
        if f->ffi_ice_mask == 0 {
            return true
        }

        var ok = true
        for var i: usize = 0; i < args->size(); ++i {
            var pi = if (i < r->arg_to_param.size()) => (r->arg_to_param[i]) else => ARG_PACK_TAIL
            if pi >= 32 { // pack tail / C `...`: no mask bit.
                continue
            }

            if (f->ffi_ice_mask & (1 as u32) << (pi as u32)) == 0 {
                continue
            }

            var *a = &(*args)[i]
            if self._is_constant_arg(a->expr) {
                continue
            }

            self.dyn()->fail(
                a->expr,
                DiagID::SC108E,
                f"argument {pi + 1} of '{self.dyn()->tu.decl_name((unsafe (f as unsafe *Decl)))}' must be an integer constant",
            )

            ok = false
        }

        return ok
    }

    priv fn _is_constant_arg(self, e_in: unsafe *Expr) -> bool {
        var e = self.dyn()->tu.strip_parens(e_in)
        if e == &null {
            return false
        }

        if isa<UnaryOperatorExpr>(e) {
            var u = cast<UnaryOperatorExpr>(e)
            var k = u->op_token.kind
            if k == TokenKind::OpMinus
                || k == TokenKind::OpPlus
                || k == TokenKind::OpTilde
                || k == TokenKind::OpExclaim {
                return self._is_constant_arg(u->operand)
            }

            return false
        }

        if isa<TypeCastExpr>(e) {
            // `alignof(T) as i32`: a cast keeps an ICE an ICE only when it
            // lands on an integer (or bool); `as f64` does not.
            var c = cast<TypeCastExpr>(e)
            if c->target == &null || c->target->canonical == &null {
                return false
            }

            var tt = c->target->canonical
            if !self.dyn()->tu.is_integer(tt) && !self.dyn()->tu.is_bool(tt) {
                return false
            }

            return self._is_constant_arg(c->operand)
        }

        if isa<SizeOfExpr>(e) || isa<AlignOfExpr>(e) || isa<TypeTraitExpr>(e) {
            return true
        }

        // Not literal_shape: that is the overload ranker's view, which takes
        // floats and `null` (not constants here) and refuses a bool, the
        // very literal `__builtin_coro_promise`'s third slot wants.
        return isa<IntegerLiteralExpr>(e)
            || isa<BooleanLiteralExpr>(e)
            || isa<CharacterLiteralExpr>(e)
    }

    /// `CallExpr::arg_map`, written once, at Selected. Parallel to the CALLEE'S
    /// PARAMETERS with `self` in slot 0, holding the index into `args` of the
    /// argument bound to each parameter, -1 for "use the default", and for the
    /// pack the index of its first argument with `pack_len` beside it.
    ///
    /// The resolver's own `arg_to_param` is the other direction and over a
    /// receiver-EXCLUDED view, so it cannot be handed to CallLowering as-is:
    /// inverting it here means nothing downstream re-derives the mapping.
    priv fn _write_arg_map(self,
                           n:          unsafe *CallExpr,
                           f:          unsafe *FunctionDecl,
                           const args: cxx::std::vector<ArgInfo>,
                           r:          *OvlResult) {
        if n == &null || f == &null {
            return
        }

        var np                                = f->params.size()
        var map: kairo::std::StackBuf<i32, 8>
        for var i: usize = 0; i < np; ++i {
            map.push_back(-1)
        }

        // view index -> f->params index. finish_call_args builds the same view
        // for the same reason; the offset is the receiver the resolver skipped.
        var off: usize = 0
        if np > 0 && f->params[0] != &null && f->params[0]->is_self && r->receiver_bound {
            off = 1
        }

        // The receiver bound to `self` is no argument: -2, not -1, which reads
        // as "use the default" and would send CallLowering looking for one.
        if off == 1 {
            map[0] = -2
        }

        var pack_lo: i32   = -1
        var pack_n:  usize = 0
        var pack_at        = usize::MAX
        for var i: usize = 0; i < np; ++i {
            if f->params[i] != &null && f->params[i]->is_pack {
                pack_at = i
                break
            }
        }

        for var i: usize = 0; i < args.size(); ++i {
            var pi = if (i < r->arg_to_param.size()) => (r->arg_to_param[i]) else => ARG_PACK_TAIL
            if pi == ARG_C_VARARG {
                continue
            }

            if pi == ARG_PACK_TAIL {
                // Pack tail. Its run is contiguous (SC022E rejects otherwise),
                // so the first index and the count describe it exactly.
                if pack_lo == (-1 as i32) {
                    pack_lo = (i as i32)
                }

                pack_n += 1
                continue
            }

            var slot = pi + off
            if slot < np {
                map[(slot as u32)] = (i as i32)
            }
        }

        if pack_at != usize::MAX && pack_lo != (-1 as i32) {
            map[(pack_at as u32)] = pack_lo
        }

        n->arg_map.from_buf(map.data(), map.size(), self.dyn()->sc->ctx)
        n->pack_len = (pack_n as u32)
    }

    /// An object of an abstract class -- one with a pure virtual method
    /// (a bodyless `virtual fn`) that it and its bases leave unoverridden --
    /// cannot be made: `A()`, `A{ ... }`. Said here, at the construction,
    /// with a note at the method that keeps it abstract; left to clang it
    /// is CL001E "allocating an object of abstract class type" pointing into
    /// the generated C++. A pointer or reference to one is fine. Reports,
    /// poisons `n` and returns true when `d` is abstract.
    fn reject_abstract(self, n: *Expr, d: *Decl) -> bool {
        var pure = self.dyn()->tu.first_pure_left(d)
        if pure == &null {
            return false
        }

        var cname = self.dyn()->tu.decl_name(d)
        var mname = self.dyn()->tu.decl_name(pure)
        var odc   = pure->semantic_dc
        var od    = if (odc != &null) => (odc->owner_decl()) else => &null
        var owner = if (od != &null) => (self.dyn()->tu.decl_name(od)) else => cname
        var b = self.dyn()->sc->diag->report(
            DiagID::SC249E,
            n->range.start,
            f"cannot create an object of abstract class '{cname}'",
        )

        b.first(n->range)
        var why = f"'{owner}::{mname}' is pure virtual and '{cname}' does not override it"
        if owner == cname {
            why = f"'{mname}' is pure virtual: a 'virtual fn' with no body"
        }

        b.note(DiagCode(DiagID::SC249N), pure->range.start, why)->first(pure->range)
        b.emit()
        n->poison()
        return true
    }

    /// `Foo(args)` on a record type: constructors live in the type's own
    /// table under DeclName::ctor(). No ctor + no args is the default ctor.
    ///
    /// A DEPENDENT record that can be named -- `Box<T>(p)` in a generic
    /// body -- is typed with that record, exactly as ControlTyping's
    /// _init_fields types `Box<T>{ ... }`: codegen ICEs on an untyped
    /// constructor call, and the type is right there to name. Its pattern's
    /// constructors are resolved in defer mode (resolve_deferred): a
    /// parameter still dependent through the record's arguments is assumed
    /// viable, a concrete one ranks and errors as in any call. A winner is
    /// written exactly as for a concrete call; a tie only the instance can
    /// break leaves ctor_decl null, and the emitted `Box<T>(args)` lets
    /// clang pick per instance (Compiler/Spec/Generics.md#member-types-of-a-generic-instance). Only a head with no
    /// record to name -- an unbounded `T::Inner` -- stays unknown.
    /// \p d is a type alias whose body Sema cannot resolve until an instance
    /// fixes a generic parameter (the alias names a member of a `: type`
    /// parameter): a sema gap that is not an error.
    priv fn _dependent_alias(self, d: *Decl) -> bool {
        var *td? = dyn_cast<TypeAliasDecl>(d)
        if td == &null || td->aliased == &null {
            return false
        }

        return td->aliased->is_dependent() && td->aliased->canonical == &null
    }

    priv fn _ctor_call(self, n: unsafe *CallExpr, rec: unsafe *Type) -> unsafe *Type {
        // `T::Node(args)`: only a constructor the associated type's bounds
        // promise (see ControlTyping::_assoc_init).
        if isa<AssocType>(canon_unqual(rec)) {
            return self._assoc_ctor_call(n, rec)
        }

        var d   = self.dyn()->tu.record_decl(rec)
        var dep = rec->is_dependent()
        if d == &null && dep {
            self.dyn()->mark_unknown(n)
            self._type_args_blind(n)
            return &null
        }

        if d == &null {
            // an alias of a builtin, `i32(x)` style: not a call.
            self.dyn()->fail(
                n,
                DiagID::SC037E,
                f"'{self.dyn()->tu.str(rec)}' is not constructible with a call; use 'as'",
            )

            return &null
        }

        if !dep && self.reject_abstract(n, d) {
            self._type_args_blind(n)
            return &null
        }

        // A C++ instance's constructors are clang's, read off its filled
        // table: unfilled, the pattern's stand in, every parameter spelled in
        // the template's own dependent names. `unique_ptr<Compilation>(raw)`
        // as an instance's first use then offered `explicit unique_ptr(
        // pointer)` with `pointer` '<ffi type>', and no raw pointer converted
        // (SC063E). Member lookup and `::` fill on demand; a
        // constructor call is the same demand.
        if !dep {
            MemberLookup::ensure_filled(self.dyn()->sc, d)
        }

        var body = self.dyn()->sc->record_body(rec) // an unfilled instance has an empty table; its body's (a selected partial's).
        if body == &null {
            body = self.dyn()->tu.pattern_of(d)
        }

        var dc    = NameLookup::context_of(body)
        var cands = cxx::std::vector<unsafe *Decl>()
        if dc != &null {
            var cell = self.dyn()->sc->lookup.in_context(dc, DeclName::ctor())
            if cell.found() {
                for var i: usize = 0; i < cell.cell->size(); ++i {
                    cands.push_back(cell.cell->get(i))
                }
            }
        }

        if cands.size() == 0 {
            if n->args.size() == 0 {
                // The implicit default constructor, which exists only when
                // every base and field can be built from nothing -- the one
                // answer `var x: R` gets too (TypeUtil::why_no_default).
                var why = if (dep) => ("") else => self.dyn()->tu.why_no_default(rec)
                if !why.empty() {
                    var nm = self.dyn()->tu.decl_name(d)
                    self.dyn()->sc->diag->report(
                        DiagID::SC250E,
                        n->range.start,
                        f"'{nm}()' cannot be called: {why}",
                    ).first(n->range)->note(
                        DiagCode(DiagID::SC250N),
                        d->range.start,
                        f"'{nm}' declared here",
                    )->first(d->range)->emit()
                    n->poison()
                    return &null
                }

                return rec
            }

            self._type_args_blind(n)
            self.dyn()->sc->diag->report(
                DiagID::SC038E,
                n->range.start,
                f"'{self.dyn()->tu.decl_name(d)}' declares no constructor taking arguments",
            ).first(n->range)->note(d->range.start, type_declared_here())->first(d->range)->emit()
            n->poison()
            return &null
        }

        var args = cxx::std::vector<ArgInfo>()
        var ok   = self.build_args(n->args, &args)
        if !dep && !self._narrow_args(unsafe &cands, unsafe &args, true, rec) {
            self.dyn()->poison_only(n)
            return &null
        }

        var r = OvlResult()
        if dep {
            r = self.dyn()->ovl.resolve_deferred(
                &cands,
                &args,
                true,
                n->range,
                self.dyn()->tu.decl_name(d),
                rec,
            )
        } else {
            var _ctx = OvlCallScope(unsafe &self.dyn()->ovl)
            self.dyn()->ovl.call_syntax = true
            r = self.dyn()->ovl.resolve(
                &cands,
                &args,
                true,
                n->range,
                self.dyn()->tu.decl_name(d),
                rec,
            )
        }

        // An argument only the instance types -- `Sink(args...)`, a pack
        // expansion -- leaves the constructor undecided, but not the type:
        // a constructor call is its record whichever one wins. Typed as
        // Deferred is, ctor_decl null, and clang picks per instance from
        // the emitted `Sink(args...)`. Left unknown, codegen ICEd on
        // the untyped constructor call; a function call has no such need.
        if r.outcome == OvlOutcome::Dependent || r.outcome == OvlOutcome::Deferred {
            if !ok {
                self.dyn()->poison_only(n)
                return &null
            }

            self._finish_args_unselected(&args)
            n->value_category = Expr::ValueCategory::RValue
            return rec
        }

        if r.outcome != OvlOutcome::Selected {
            self.dyn()->poison_only(n)
            return &null
        }

        if !ok {
            self.dyn()->poison_only(n)
            return &null
        }

        r.ded.bind_from_record(rec)
        self.finish_call_args(r.decl, unsafe &args, &r)
        self._warn_unmarked(unsafe &args, &r)
        self._write_arg_map(n, r.decl, args, &r)
        n->ctor_decl = r.decl
        if dep {
            n->value_category = Expr::ValueCategory::RValue
        }

        return rec
    }

    /// `T(args)` on a generic parameter. Typed as T when one of T's bounds
    /// promises a constructor of that arity (decl_is_ctor_requirement):
    /// every instance's `X(args)` then exists, ConformanceChecking having
    /// found it, so `var t = T()` has a type to carry into `t.m()`. Any
    /// other `T(args)` stays unknown, as it always was -- clang decides it
    /// per instance -- so a bound only ever adds a type, never accepts a
    /// call that was rejected. The arguments are not checked against the
    /// requirement: a conformer's constructor is matched exactly, so the
    /// C++ `T(args)` reaches it or fails at the concept.
    priv fn _param_ctor_call(self, n: unsafe *CallExpr, gp: *GenericParamDecl) -> unsafe *Type {
        self._type_args_blind(n)
        var t = self.dyn()->sc->types->generic_param(
            NameLookup::representative(gp->owner),
            gp->index,
            gp->is_pack,
        )

        // The same question an associated type's `T::Node(args)` asks
        // (_assoc_ctor_call), of the same bound list.
        if Substitution(self.dyn()->sc).bounds_construct(t, n->args.size()) {
            n->value_category = Expr::ValueCategory::RValue
            return t
        }

        self.dyn()->mark_unknown(n)
        return &null
    }

    priv fn _assoc_ctor_call(self, n: unsafe *CallExpr, rec: unsafe *Type) -> unsafe *Type {
        self._type_args_blind(n)
        if Substitution(self.dyn()->sc).bounds_construct(rec, n->args.size()) {
            n->value_category = Expr::ValueCategory::RValue
            return rec
        }

        var unsafe *a = cast<AssocType>(canon_unqual(rec))
        var        ts = self.dyn()->tu.str(rec)
        var        an = self.dyn()->tu.decl_name(a->assoc)
        var b = self.dyn()->sc->diag->report(
            DiagID::SC251E,
            n->range.start,
            f"cannot construct '{ts}': no bound of associated type '{an}' requires a constructor taking {n->args.size()} argument(s)",
        )

        b.first(n->range)
        b.note(
            a->assoc->range.start,
            f"'{an}' is declared here; bound it with an interface that declares a constructor requirement",
        )->first(a->assoc->range)
        b.emit()
        self.dyn()->poison_only(n)
        return &null
    }

    /// finish_call_args with no winner: there is no parameter to type an
    /// untyped literal against, so it takes its default (what clang will
    /// see it as), and a `name: value` wrapper takes its value's type.
    priv fn _finish_args_unselected(self, @inout args: cxx::std::vector<ArgInfo>) {
        for var i: usize = 0; i < args.size(); ++i {
            var *a = &(args)[i]
            // A bare `&null` has no parameter to read its pointer type from
            // while the constructor is undecided (a sibling argument is
            // instantiation-dependent): left untyped like
            // _type_args_dependent does, it goes out as `nullptr`, which
            // converts to the pointer the instance's constructor takes.
            // Typed against nothing it is SC076E "cannot infer".
            if a->lit == LitKind::NullPtr {
                self.dyn()->mark_unknown(a->expr)
            } else if a->lit != LitKind::None {
                self.dyn()->type_of(a->expr, &null)
            }

            if a->carrier == &null || a->carrier == a->expr {
                continue
            }

            if a->expr->is_poisoned() {
                a->carrier->poison()
            }

            a->carrier->value_category = a->expr->value_category
            self.dyn()->finish(a->carrier, a->expr->type_)
        }
    }

    /// `f(args)` on a C++ object with `operator()` (a function object, a
    /// lambda's closure type, llvm::function_ref, ...): resolved over its
    /// `operator()` set exactly as `f.operator()(args)` is, with `f` the
    /// receiver -- so a const object picks the const overload, a
    /// ref-qualified one sees the callee's category, and arity and argument
    /// types choose among overloads ([over.call.object], members only: a
    /// surrogate conversion-to-function-pointer is not looked for). The
    /// callee is only read as the object, never moved: it is not an
    /// argument. EmitIR writes the call as written, `f(args)`, which clang
    /// resolves to the same operator. Only a class type (the object itself,
    /// `(*p)(x)` through a pointer); a pointer to a functor is not callable,
    /// as in C++. False: no function object, the caller goes on as before;
    /// true: the call is typed (or reported), its type in `out`.
    priv fn _functor_call(self,
                          n:   unsafe *CallExpr,
                          t:   unsafe *Type,
                          out: unsafe *unsafe *Type) -> bool {
        var unsafe *ct = canon_unqual(t)
        if ct == &null || !isa<RecordType>(ct) {
            return false
        }

        var cands = cxx::std::vector<unsafe *Decl>()
        self.dyn()->ml.lookup(
            t,
            DeclName::op_name(TokenKind::OpLParen, TokenKind::OpRParen),
            &cands,
        )

        if cands.size() == 0 {
            return false
        }

        self.dyn()->ovl.recv_cat = n->callee->value_category
        self._functor_next       = true
        var unsafe *rt = self._call_candidates(n, unsafe &cands, true, t, "op ()", &null, &null)
        self._functor_next       = false
        self.dyn()->ovl.recv_cat = Expr::ValueCategory::LValue
        *out                     = rt
        return true
    }

    /// Call through a function-pointer-typed value.
    priv fn _call_through(self, n: unsafe *CallExpr, t: unsafe *Type) -> unsafe *Type {
        if t == &null {
            self._type_args_blind(n)
            if !n->callee->is_poisoned() {
                self.dyn()->mark_unknown(n)
            } else {
                self.dyn()->poison_only(n)
            }

            return &null
        }

        // A nullable callable proven non-null here is called through its
        // value (Compiler/Spec/Nullables.md#narrowed-reads); one that is not is the nullness error.
        if self.dyn()->tu.nullable_inner(t) != &null
            && self.dyn()->flow.read_value(n->callee, false) == NULL_READ_NARROWED {
            t = n->callee->type_
        } else if self.dyn()->tu.nullable_inner(t) != &null {
            var o = self.dyn()->flow.read_value(n->callee, true)
            if o == NULL_READ_REFUSED {
                self._type_args_blind(n)
                self.dyn()->poison_only(n)
                return &null
            }
        }

        var ft = self.dyn()->tu.strip_nullable(t)
        if ft != t {
            // A nullable callable is not callable: there is no code to run on
            // the null side, and nothing implicitly unwraps it here either.
            self._type_args_blind(n)
            self.dyn()->fail(
                n,
                DiagID::SC098E,
                f"'{self.dyn()->tu.str(t)}' may be null; unwrap it before calling, with '??' or 'unwrap!()'",
            )

            return &null
        }

        var fobj_ty: unsafe *Type = &null
        if self._functor_call(n, ft, &fobj_ty) {
            return fobj_ty
        }

        ft = canon_unqual(ft) // a `const` callable calls the same code.
        if ft == &null || !isa<FunctionPointerType>(ft) {
            self._type_args_blind(n)
            self.dyn()->fail(n, DiagID::SC062E, f"'{self.dyn()->tu.str(t)}' is not callable")
            return &null
        }

        var fp = cast<FunctionPointerType>(ft)

        // No candidate set and no deduction: one signature, arguments
        // positional, each converted to its own parameter type. An
        // unprototyped C import declares no parameters to check against, so
        // the arguments are typed on their own and the declaration is trusted
        // -- exactly what C does with `void f()`.
        if fp->is_unprototyped {
            self._type_args_blind(n)
            return fp->return_type
        }

        if n->args.size() < fp->params.size() {
            self._closure_defaults(n, fp->params.size())
        }

        if n->args.size() != fp->params.size() {
            self._type_args_blind(n)
            self.dyn()->fail(
                n,
                DiagID::SC099E,
                f"'{self.dyn()->tu.str(ft)}' takes {fp->params.size()} argument(s), {n->args.size()} given",
            )

            return &null
        }

        var bad = false
        for var i: usize = 0; i < n->args.size(); ++i {
            var unsafe *a = n->args[i]
            if a == &null {
                continue
            }

            var pt   = fp->params[i]
            var mode = if (i < fp->modes.size()) => (fp->modes[i]) else => ParamMode::Value

            if mode == ParamMode::Inout {
                // The type's `@inout` position: the argument is the operand of
                // a `&` marker, or (tolerated, warned) an unmarked lvalue. It
                // is judged as a `T&` binding, exactly as a declared
                // parameter's would be, and lends no type to a literal.
                var unsafe *_op    = mode_marker_operand(a)
                var unsafe *target = if (_op != &null) => (_op) else => a
                self.dyn()->type_of(target, &null)
                if target->is_poisoned() {
                    if _op != &null {
                        a->poison()
                    }

                    bad = true
                    continue
                }

                if _op == &null {
                    var ub = self.dyn()->sc->diag->report(
                        DiagID::SC097E,
                        a->range.start,
                        f"argument to '@inout' parameter {i + 1} of '{self.dyn()->tu.str(ft)}' must be marked with '&'",
                    )

                    ub.first(a->range)
                    ub.insert(a->range.start, "&", "mark the argument with '&'")
                    ub.emit()
                }

                if target->type_ != &null {
                    var lref = self.dyn()->sc->types->cxx_lref(canon_unqual(pt))
                    var r = self.dyn()->conv.implicit_arg(
                        target->type_,
                        lref,
                        target->value_category,
                        self._const_lvalue(target),
                    )

                    if r == ImplicitRank::None {
                        self.dyn()->fail(
                            target,
                            DiagID::SC097E,
                            f"cannot pass '{self.dyn()->tu.str(target->type_)}' to an '@inout' parameter of type '{self.dyn()->tu.str(pt)}'; an '@inout' argument must be a mutable lvalue",
                        )

                        bad = true
                        continue
                    }
                }

                if _op != &null {
                    // Never typed as address-of on this path: the type said
                    // `@inout` before the node was reached. Commit it as its
                    // operand and record it as done for the RAV's later visit.
                    var unsafe *u = cast<UnaryOperatorExpr>(a)
                    u->is_mode_marker = true
                    u->value_category = Expr::ValueCategory::LValue
                    self.dyn()->finish(a, _op->type_)
                }

                self.dyn()->flow.inout_arg(target, if (_op != &null) => (a) else => &null) // Compiler/Spec/Nullables.md#weakening.
                continue
            }

            // The parameter type is the EXPECTED type, not a post-hoc check:
            // an untyped literal argument takes it the same way it would
            // through an overload set (§5). `@move` ranks by value.
            self.dyn()->type_of(a, pt)
            if a->is_poisoned() {
                bad = true
                continue
            }

            if !self.dyn()->check_convertible(a, pt) {
                bad = true
            }

            self.dyn()->flow.pass_pointer(a, pt)
        }

        if bad {
            self.dyn()->poison_only(n)
            return &null
        }

        // A closure holding pointers may write what they point at (3.7).
        self.dyn()->flow.call_value(n->callee, n->range)
        if fp->return_type == &null {
            self.dyn()->mark_unknown(n)
            return &null
        }

        return fp->return_type
    }
}
