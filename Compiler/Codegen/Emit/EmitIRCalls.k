/// --- The Kairo Project ------------------- Codegen/Emit/EmitIRCalls.k --- ///
///
///   EmitIR, part: calls. A call's callee and arguments, each argument cast
///   to its parameter so the call is exact, pack arguments, calls through a
///   function value, the overload sets only an instance can pick from, witness
///   members of interface-bound generics, the no-panic wrapper around a
///   callee only an instance knows, and the callee each call tells the sink
///   Sema bound (EmitSink::agree_call).
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
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/Shims.hh"
ffi "c++" import "clang/Basic/TokenKinds.h"
ffi "c++" import "vector"

import API::LinkABI::call_conv_note_bit
import AST::ASTSupport::FrozenList
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::Context::SymbolTable::OverloadCell
import AST::DeclFacts::{
    decl_ffi_tag_keyword,
    decl_is_imported,
    decl_pattern,
    param_is_type_pack,
    param_type_pack_param,
}
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::LowerTargets
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    BuiltinKind,
    BuiltinType,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::{
    ClassDecl,
    FunctionDecl,
    InterfaceDecl,
    ParamDecl,
    TypeAliasDecl,
}
import AST::Node::Expressions::{
    CallExpr,
    FinalizeKind,
    PackExpansionExpr,
    ParenExpr,
    UnaryOperatorExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
    NullLiteralExpr,
}
import AST::Node::Types::{
    CXXLValueRefType,
    CXXRValueRefType,
    ChainType,
    FixedArrayType,
    FunctionPointerType,
    GenericParamType,
}
import AST::ParamMode::ParamMode
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::EmitIRConvert
import Codegen::Emit::EmitIRCtors
import Codegen::Emit::EmitIRDecls
import Codegen::Emit::EmitIRExprs
import Codegen::Emit::EmitIRLocals
import Codegen::Emit::EmitIRNames
import Codegen::Emit::EmitIRStmts
import Codegen::Emit::Spell::Speller
import Codegen::EmitPlan::plan_under_duck
import Location::SourceRange::SourceRange
import Token::TokenKind::TokenKind

extend EmitIR {
    /// A call of a `cxx_ref_return` function: C++ returns `T&`, Kairo typed
    /// the call `*T`, so the reference's address is what the call is.
    prot fn _call(self, n: unsafe *CallExpr) {
        if n->finalize != FinalizeKind::None {
            self._finally_site(n)
            return
        }

        // Read off the callee as bound, without _callee_decl's gates (a
        // dependent or deferred call is checked below, by the inner path).
        var        rd:  unsafe *Decl = &null
        var unsafe *cni              = dyn_cast<NamedIdentExpr>(n->callee)
        if cni != &null {
            rd = cni->resolved_decl
        }

        var unsafe *cch = dyn_cast<ChainExpr>(n->callee)
        if cch != &null && cch->steps.size() > 0 {
            rd = cch->steps.get(cch->steps.size() - 1)->resolved_decl
        }

        var unsafe *rf = dyn_cast<FunctionDecl>(rd)
        if rf != &null && rf->cxx_ref_return {
            self._cg->sink->spell(n->range, "(&")
            self._call_inner(n)
            self._cg->sink->spell(n->range, ")")
            return
        }

        self._call_inner(n)
    }

    priv fn _call_inner(self, n: unsafe *CallExpr) {
        // A deferred f-string hole (CallExpr::fmt_dyn): the preamble's
        // template picks the put at each instance. Its callee is a
        // placeholder bound to nothing; the arguments go as written.
        if n->fmt_dyn {
            self._cg->sink->spell(
                n->callee->range,
                "::" + LowerTargets::fmt_dyn(),
            )

            self._cg->sink->synth_at_end(n->callee->range, clang::tok::l_paren)
            self._args(n, &null, true, &null)
            self._cg->sink->synth_at_end(n->range, clang::tok::r_paren)
            return
        }

        // An overload set of imported templates that only an instance can
        // split (`on_default(x)` with `x: T`: which `enable_if` holds is
        // T's question -- OverloadResolution::_sfinae_pending). Left
        // unpromoted by decision; it goes out as the dependent call it is,
        // by the set's one C++ name, and clang resolves it per instance.
        var dset = self._dependent_imported_set(n->callee)
        if dset.size() == 0 {
            dset = self._dependent_free_set(n)
        }

        if dset.size() > 0 {
            // Under `<T: type>` the overload only the instance picks may be
            // a Kairo function that panics, as a duck member call's may.
            var dw = self._cur_fn != &null && plan_under_duck(self._cur_fn)
            if dw {
                self._nopanic_open(n->range)
            }

            var wa = self._written_targs(n->callee)
            if wa.size() > 0 {
                dset += self._spell.args_str(wa)
            }

            self._cg->sink->spell(n->callee->range, dset)
            self._cg->sink->synth_at_end(n->callee->range, clang::tok::l_paren)
            self._args(n, &null, true, &null)
            self._cg->sink->synth_at_end(n->range, clang::tok::r_paren)
            if dw {
                self._nopanic_close(n->range)
            }

            return
        }

        var callee: unsafe *Decl = &null
        if !self._dependent_arg_member(n) {
            callee = self._callee_decl(n->callee)
        }

        // `type G = T::Guard; G(x)` under `<T: type>`: the alias has no C++
        // entity and no canonical until an instance names T, so the type it
        // stands for is spelled as written and clang constructs per instance.
        var unsafe *dal = dyn_cast<TypeAliasDecl>(callee)
        if dal != &null
            && n->ctor_decl == &null
            && dal->aliased != &null
            && dal->aliased->canonical == &null
            && self._spell.dependent_member(dal->aliased).size() > 0 {
            var dnw = self._cur_fn != &null && plan_under_duck(self._cur_fn)
            var dty = self._spell._type(dal->aliased)
            if dnw {
                self._nopanic_open_of(n->range, dty)
            }

            self._cg->sink->spell(n->callee->range, dty)
            self._cg->sink->synth_at_end(n->callee->range, clang::tok::l_paren)
            self._args(n, &null, true, &null)
            self._cg->sink->synth_at_end(n->range, clang::tok::r_paren)
            if dnw {
                self._nopanic_close(n->range)
            }

            return
        }

        // A call through a `fn` value: a local, a parameter, a field, or any
        // expression of `fn` type (`make()(4)`). Its parameters are the
        // type's; an operand that names a function is a plain call below.
        var unsafe *fv = self._fn_value_type(n->callee, callee)
        if fv != &null {
            // A call through a convention's pointer is a call with it: the
            // type spells the attribute, and the object's ABI note records it.
            if fv->call_conv != 0 {
                self._cc_bits |= call_conv_note_bit(fv->call_conv)
            }

            // `fn(...) -> !` lowers to `__kairo_fn<void(...)>`: C++ cannot
            // put noreturn on that call, so a function whose last act is
            // the call (`oom`) would fall off its end under [[noreturn]]
            // (C532W). The value's own type says it never returns; say so.
            var never = self._returns_never(fv)
            if never {
                self._cg->sink->spell(n->range, "(")
            }

            self.emit(n->callee)
            self._cg->sink->synth_at_end(n->callee->range, clang::tok::l_paren)
            self._fn_value_args(n, fv)
            self._cg->sink->synth_at_end(n->range, clang::tok::r_paren)
            if never {
                self._cg->sink->spell(
                    n->range,
                    ", " + LowerTargets::clang_unreachable() + "())",
                )
            }

            return
        }

        // `f(args)` on a C++ function object (CallExpr::functor_op): the
        // callee is the object, written as is, and clang resolves it to the
        // `operator()` Sema selected; the arguments convert to its
        // parameters, `self` bound by the object.
        var unsafe *fop = dyn_cast<FunctionDecl>(n->functor_op)
        if fop != &null {
            self.emit(n->callee)
            self._cg->sink->synth_at_end(n->callee->range, clang::tok::l_paren)
            self._args(n, fop, true, n->instance)
            self._cg->sink->synth_at_end(n->range, clang::tok::r_paren)
            return
        }

        if callee == &null {
            // A member call on a dependent receiver (`t.value()` under
            // `<T: type>`): Sema typed it as written and bound nothing, by
            // decision (Compiler/Spec/Generics.md#duck-regime). It goes out as written, receiver chain
            // and arguments untouched, and clang resolves and checks it in
            // each instance. No parameter to convert to, no arity to check.
            // Nor a panic set: only the instance can tell the callee returns
            // a panic result, which the body cannot handle (its panics are
            // SC116E) and a discarded call would drop. The wrapper stops
            // that instance (LowerTargets::nopanic_call).
            if self._dependent_member_call(n) {
                if self._dependent_arg_member(n) {
                    var unsafe *dch = cast<ChainExpr>(n->callee)
                    self._arg_dep_step = dch->steps.get(dch->steps.size() - 1)
                }

                // A C++ member left to each instance cannot return a
                // Kairo panic result; only a duck body's callee can.
                var nw = self._cur_fn != &null && plan_under_duck(self._cur_fn)
                if nw {
                    self._nopanic_open(n->range)
                }

                self.emit(n->callee)
                self._arg_dep_step = &null
                self._cg->sink->synth_at_end(
                    n->callee->range,
                    clang::tok::l_paren,
                )

                self._args(n, &null, true, &null)
                self._cg->sink->synth_at_end(n->range, clang::tok::r_paren)
                if nw {
                    self._nopanic_close(n->range)
                }

                return
            }

            self._ice(
                n->range,
                "EmitIR: unbound callee reached codegen; ExprTyper gate failure",
            )
        }

        var unsafe *ch = dyn_cast<ChainExpr>(n->callee)
        var last: unsafe *ChainExpr::Step = &null
        if ch != &null && ch->steps.size() > 0 {
            last = ch->steps.get(ch->steps.size() - 1)
        }

        if last != &null && self._is_extension_member(last->resolved_decl) {
            self._ice(
                n->range,
                "EmitIR: an extension member called through a chain reached codegen; ExtensionLowering rewrites it to a free call",
            )
        }

        // A requirement is no C++ function: the call goes through its
        // interface's witness, which ExtensionLowering records (Compiler/Spec/Codegen.md
        // §7b.5). `T::make()` and `I::m(a)` are not rewritten yet.
        if self._is_requirement(callee) && n->witness_iface == &null {
            self._ice(
                n->range,
                "EmitIR: a call bound to an interface requirement with no recorded witness; ExtensionLowering rewrites `a.m()` through a bound (a `::` form is not built)",
            )
        }

        // The constructor, not the type the callee names: its parameters are
        // what the arguments are cast to.
        var unsafe *f = dyn_cast<FunctionDecl>(callee)
        if n->ctor_decl != &null {
            f = dyn_cast<FunctionDecl>(n->ctor_decl)
        }

        var unsafe *inst = n->instance
        self._cc_mark(f)
        // `__builtin_expect(c, e)` (the Expect lang item) is clang's builtin
        // here, at the call: through the library function the hint
        // weighted that function's return, and the branch the caller tests
        // kept no weight. Its `long` result goes back to Kairo's `bool`.
        var unsafe *xf = dyn_cast<FunctionDecl>(Speller::rep(f))
        if f != &null
            && (f->lowers_to_expect || xf != &null && xf->lowers_to_expect)
            && n->args.size() == 2 {
            self._cg->sink->spell(
                n->callee->range,
                "static_cast<bool>(" + LowerTargets::clang_expect() + "(",
            )

            self._args(n, f, false, inst)
            self._cg->sink->spell(n->range, "))")
            return
        }

        // `__builtin_unpredictable(c)` is clang's builtin at the call, where
        // the branch on its result can still be formed as a select. As an
        // `if`'s whole condition it is spelled bare: clang attaches the hint
        // only to a branch whose condition is the builtin's call, and a cast
        // of its `long` back to `bool` hides it.
        if f != &null
            && (f->lowers_to_unpredictable || xf != &null && xf->lowers_to_unpredictable)
            && n->args.size() == 1 {
            var bare = self._if_cond == unsafe (n as unsafe *Expr)
            self._cg->sink->spell(
                n->callee->range,
                if (bare) => (LowerTargets::clang_unpredictable() + "(")
                else => "static_cast<bool>(" + LowerTargets::clang_unpredictable() + "(",
            )

            self._args(n, f, false, inst)
            self._cg->sink->spell(n->range, if (bare) => (")") else => "))")
            return
        }

        // `__builtin_assume(c)` (what `@assume(c)` parses to) is likewise
        // clang's builtin at the call: behind a library call the assumption
        // would hold only inside that function. An unoptimized build tests
        // `c` and traps: nothing there uses the assumption, and a false one
        // is found at its line instead of as undefined behavior later.
        if f != &null
            && (f->lowers_to_assume || xf != &null && xf->lowers_to_assume)
            && n->args.size() == 1 {
            if self._cg->opts.check_assume {
                self._cg->sink->spell(n->callee->range, "((")
                self._args(n, f, false, inst)
                self._cg->sink->spell(
                    n->range,
                    ") ? static_cast<void>(0) : " + LowerTargets::clang_trap() + "())",
                )

                return
            }

            self._cg->sink->spell(
                n->callee->range,
                LowerTargets::clang_assume() + "(",
            )

            self._args(n, f, false, inst)
            self._cg->sink->spell(n->range, ")")
            return
        }

        // A free imported binary operator is written infix, `(a == b)`. The
        // function-call spelling `operator ==(a, b)` is looked up by name
        // first, and inside a class that declares its own `operator==` that
        // finds the member and stops: ADL never runs, so the imported free
        // one (a std iterator's) is "no matching member function".
        if f != &null
            && f->is_operator
            && !f->is_method()
            && decl_is_imported(callee)
            && self._plain_callee(n->callee)
            && n->args.size() == 2
            && f->params.size() == 2
            && f->op_token.size() == 1
            && self._infix_operator(f->op_token[0].kind) {
            self._cg->sink->spell(n->range, "(")
            self._arg(n->args[0], f->params[0], inst)
            self._cg->sink->spell(
                n->range,
                " " + self._cg->ctx->get_spelling(f->op_token[0]) + " ",
            )

            self._arg(n->args[1], f->params[1], inst)
            self._cg->sink->spell(n->range, ")")
            return
        }

        // `T::Node(args)`: the callee is the requirement, the type is the
        // witness's member type, constructed as any type is (CallTyping
        // admitted it through a constructor bound).
        var assoc_ctor = isa<TypeAliasDecl>(callee)
            && n->type_ != &null
            && isa<AssocType>(canon_unqual(n->type_))
        var bound = n->ctor_decl != &null
            || self._is_type_decl(callee)
            || self._is_ctor(f)
            || assoc_ctor
            || last != &null && last->access_kind != ChainExpr::AccessKind::ColonColon
        self._check_arity(n, f, bound)

        // `Base::m(obj)`: a record's own method named by its qualified name,
        // the object as argument zero (classes-inheritance.md, Calling base
        // class methods). C++ has no such call; its spelling is
        // `obj.Base::m(...)`, which is also the NON-virtual call the
        // qualified name asks for. An extension member, a witness call and
        // a constructor have their own forms above and below.
        if !bound
            && f != &null
            && f->is_method()
            && n->args.size() > 0
            && last != &null
            && n->witness_iface == &null
            && !self._is_extension_member(callee) {
            self._cg->sink->spell(n->args[0]->range, "(")
            self._arg(n->args[0], f->params[0], inst)
            self._cg->sink->spell(n->args[0]->range, ").")
            var unsafe *qt = n->qualifier
            if qt == &null
                && Speller::template_params(
                    Speller::rep((f->semantic_dc)->dc_owner),
                ).size() > 0 {
                qt = self._qualifying_instance(n->args[0], f)
            }

            if qt != &null {
                // Through a generic record's instance, `Box<int>::get`: the
                // arguments are on the qualifier (CallExpr::qualifier), or on
                // the object's base list (`IntBox derives Box<i32>`).
                var s = self._spell._type(qt) + "::"
                if inst != &null && f->generic_params.size() > 0 {
                    s += "template " + self._spell.leaf(callee) + self._spell.args_str(
                        inst->args,
                    )
                } else {
                    s += self._spell.leaf(callee)
                }

                self._cg->sink->spell(n->callee->range, s)
            } else {
                self.emit(n->callee)
            }

            self._cg->sink->synth_at_end(n->callee->range, clang::tok::l_paren)
            self._args(n, f, bound, inst, true)
            self._cg->sink->synth_at_end(n->range, clang::tok::r_paren)
            // Named through a base that is a type parameter (`A::begin(self)`),
            // the call is each instance's argument's member by design, and
            // clang choosing an override of \p f there is no disagreement.
            if qt == &null || !isa<GenericParamType>(canon_unqual(qt)) {
                self._agree(n, f)
            }

            return
        }

        // ctor_decl too: a constructor call a lowering minted naming the
        // constructor (OperatorLowering::_ctor_cast), whose owner may be a
        // class template instance that _is_ctor's name match misses.
        if self._is_ctor(f) || self._is_type_decl(callee) || assoc_ctor || n->ctor_decl != &null {
            if n->type_ == &null {
                self._ice_untyped(
                    n,
                    "EmitIR: untyped constructor call; ExprTyper gate failure",
                )
            }

            // An elaborated tag (`struct ::stat`, hidden by a function of the
            // same name) is no simple-type-specifier, so `struct ::stat()` is
            // not an expression; `__typeof__(...)` is one and names the same type.
            var ctor_head = self._spell._type(n->type_)
            if self._elaborated_tag(n->type_) {
                ctor_head = "__typeof__(" + ctor_head + ")"
            }

            self._cg->sink->spell(n->callee->range, ctor_head)
        } else if n->witness_iface != &null {
            // `::ring::Scalable_witness<T>::scale(`: the receiver is argument
            // zero already, in the form the witness member takes it.
            // A generic requirement's arguments, when the call has concrete
            // ones, spelled with `template`: the witness is a dependent type.
            // A dependent call (no instance) has the written ones:
            // `A::f<B>()` cannot deduce B, and they are what clang substitutes.
            var ta = ""
            if f->generic_params.size() > 0 && inst != &null {
                ta = self._spell.args_str(inst->args)
            } else if inst == &null {
                ta = self._written_args_str(
                    callee,
                    self._written_list(n->callee),
                )
            }

            self._cg->sink->spell(
                n->callee->range,
                self._witness_member(n->witness_iface, n->witness_self, f, ta),
            )
        } else if n->qualifier != &null {
            // A default thunk of a generic type's method: a static member of a
            // class template, named through the receiver's record so the
            // owner's arguments are spelled.
            var s = self._spell._type(n->qualifier) + "::"
            var wq = if (inst != &null) => ("")
                     else => self._written_args_str(
                         callee,
                         self._written_list(n->callee),
                     )

            if inst != &null && f != &null && f->generic_params.size() > 0 {
                if n->qualifier->is_dependent() {
                    s += "template "
                }

                s += self._spell.leaf(callee) + self._spell.args_str(inst->args)
            } else if wq.size() > 0 {
                // `G<A>::f<B>()` in a generic body: no instance, so
                // the written arguments.
                if n->qualifier->is_dependent() {
                    s += "template "
                }

                s += self._spell.leaf(callee) + wq
            } else {
                s += self._spell.leaf(callee)
            }

            self._cg->sink->spell(n->callee->range, s)
        } else if f != &null
            && f->is_operator
            && !f->is_method()
            && decl_is_imported(callee)
            && self._plain_callee(n->callee) {
            // A free imported operator is spelled as C++ looks `a == b` up:
            // unqualified, so ADL finds it, and with no template arguments.
            // Qualified, `std::operator==` misses a hidden friend (found only
            // by ADL); and an operator's arguments are always deduced, so
            // clang deduces them again from the operands' real types --
            // spelling Kairo's would round-trip them, and C++ `char` comes
            // back as `i8`'s `signed char`: a std::string iterator's `==`
            // named `operator==<signed char*>`.
            self._cg->sink->spell(n->callee->range, self._spell.leaf(callee))
        } else if f != &null
            && f->generic_params.size() > 0
            && decl_is_imported(callee)
            && self._plain_callee(n->callee) {
            // An imported function template is called as C++ calls it: the
            // generic arguments the call WROTE, and clang deduces the rest
            // from the arguments -- which Sema already had clang do
            // (OverloadResolution::_clang_substitute). Kairo's instance args
            // are the wrong spelling for the rest: a forwarding pack's
            // elements are value types (`Args&&` against an lvalue needs
            // `T&`, which only deduction produces), and a parameter only
            // C++ fills (`enable_if_t<...> = 0`) has no instance arg at all,
            // so the instance is null and `make_unique<i32>(5)` lost its
            // `<int>` along with it.
            var wa = self._written_targs(n->callee)
            var s  = self._spell.qual_name(callee)
            if wa.size() > 0 {
                s += self._spell.args_str(wa)
            }

            self._cg->sink->spell(n->callee->range, s)
        } else if inst != &null
            && Speller::template_params(callee).size() > 0
            && self._plain_callee(n->callee) {
            // A generic extension member's instance is `<ext args..., member args...>`.
            self._cg->sink->spell(
                n->callee->range,
                self._spell.qual_name(callee) + self._spell.args_str(inst->args),
            )
        } else if inst == &null
            && n->dep_args.size() > 0
            && self._is_extension_member(callee)
            && Speller::template_params(callee).size() == n->dep_args.size()
            && self._plain_callee(n->callee) {
            // The same member called in a generic body, its arguments still
            // naming the body's parameters: spelled, not left to deduction.
            // The extension's parameters are the receiver's, and C++ would
            // deduce them from every parameter that names them:
            // `has(const View<T> *, T const &)` on a `View<const U>` with a
            // `U` argument is T := const U to Sema and a conflict to clang.
            var da = cxx::std::vector<unsafe *Type>()
            for var i: usize = 0; i < n->dep_args.size(); ++i {
                da.push_back(n->dep_args[i])
            }

            self._cg->sink->spell(
                n->callee->range,
                self._spell.qual_name(callee) + self._spell.args_str(da),
            )
        } else if last != &null
            && f != &null
            && f->generic_params.size() > 0
            && !f->is_operator
            && last->name != &null
            && last->pack_index < 0
            && (last->access_kind == ChainExpr::AccessKind::Dot
                || last->access_kind == ChainExpr::AccessKind::Arrow) {
            // `c.m<i64>()`: a generic method through its receiver
            // spells its generic arguments, or C++ must deduce them, and a
            // `T` no parameter mentions is "couldn't infer template
            // argument". From the instance (all of them, the deduced ones
            // too, as a free call's), else the written ones: a dependent
            // call, or an imported template, whose instance args are not
            // the C++ spelling (the imported-template branch above).
            var ta = ""
            if inst != &null && !decl_is_imported(callee) {
                ta = self._spell.args_str(inst->args)
            } else {
                var wl = self._written_targs(n->callee)
                if wl.size() > 0 {
                    ta = self._spell.args_str(wl)
                }
            }

            if ta.size() > 0 {
                self._generic_member_callee(ch, last, ta)
            } else {
                self.emit(n->callee)
            }
        } else {
            self.emit(n->callee)
        }

        self._cg->sink->synth_at_end(n->callee->range, clang::tok::l_paren)
        self._args(n, f, bound, inst)
        self._cg->sink->synth_at_end(n->range, clang::tok::r_paren)
        self._agree(n, f)
    }

    /// Tells the sink that the token just written closes \p n, which Sema
    /// bound to \p f (EmitSink::agree_call). Nothing is said of a call that
    /// clang resolves by design: one in a duck body, whose callee each
    /// instance picks, and one through a witness, whose C++ callee is the
    /// witness's member and not the requirement Sema bound.
    priv fn _agree(self, n: unsafe *CallExpr, f: unsafe *FunctionDecl) {
        if !self._cg->sink->agree_on || f == &null || n->witness_iface != &null {
            return
        }

        if self._cur_fn != self._agree_fn {
            self._agree_fn = self._cur_fn
            self._agree_duck = self._cur_fn != &null && plan_under_duck(self._cur_fn)
        }

        if self._agree_duck {
            return
        }

        var unsafe *d = f
        if self._cg->opts.agree_swap_from.size() > 0 {
            d = self._agree_swap(f)
        }

        var nr = SourceRange()
        if !d->is_operator {
            nr = d->name.range
        } else if d->op_token.size() > 0 {
            nr = d->op_token[0].range
        }

        self._cg->sink->agree_call(n->range, d->range, nr)
        if n->via_adl && !self._cg->opts.agree_no_adl {
            self._cg->sink->agree_adl()
        }

        // Declared more than once (a prototype and its definition, an
        // out-of-line method): the stream may have written any of them, and
        // each is the same function.
        var unsafe *g = d->next_in_chain()
        for var i: u32 = 0; g != &null && g != d && i < 16; ++i {
            if !g->is_operator {
                self._cg->sink->agree_alt(g->name.range)
            } else if g->op_token.size() > 0 {
                self._cg->sink->agree_alt(g->op_token[0].range)
            }

            g = g->next_in_chain()
        }
    }

    /// --test-sema-agreement-swap: for a call bound to a function named as
    /// the flag's first half, the function named as its second half, looked
    /// for in the scopes enclosing \p f, innermost first.
    priv fn _agree_swap(self, f: unsafe *FunctionDecl) -> unsafe *FunctionDecl {
        if f->is_operator
            || self._cg->ctx->get_spelling(f->name) != self._cg->opts.agree_swap_from {
            return f
        }

        var unsafe *dc = f->semantic_dc
        for var depth: u32 = 0; dc != &null && depth < 64; ++depth {
            // A record's methods are its own list, not its scope's.
            var unsafe *oc = dyn_cast<ClassDecl>(dc->dc_owner)
            if oc != &null {
                for var i: usize = 0; i < oc->methods.size(); ++i {
                    var unsafe *m = oc->methods[i]
                    if m != &null
                        && !m->is_operator
                        && self._cg->ctx->get_spelling(m->name) == self._cg->opts.agree_swap_to {
                        return m
                    }
                }
            }

            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                var unsafe *g = dyn_cast<FunctionDecl>(*dc->dc_decls.get(i))
                if g != &null
                    && !g->is_operator
                    && self._cg->ctx->get_spelling(g->name) == self._cg->opts.agree_swap_to {
                    return g
                }
            }

            dc = dc->dc_parent
        }

        return f
    }

    /// The receiver chain \p ch up to its last step \p last, then that step
    /// as `.template m<A...>`: `template` because the receiver's type may be
    /// dependent (`self` in a generic record, a `where` dispatcher's
    /// candidate call), where C++ would read the `<` as less-than; it is
    /// allowed, and inert, on a known one.
    priv fn _generic_member_callee(self,
                                   ch:       unsafe *ChainExpr,
                                   last:     unsafe *ChainExpr::Step,
                                   const ta: string) {
        var is_ptr    = self._chain_prefix(ch, ch->steps.size() - 1)
        var sep_arrow = is_ptr || last->access_kind == ChainExpr::AccessKind::Arrow // `op ->`, as _chain_prefix
        self._cg->sink->spell(
            last->range,
            (if (sep_arrow) => ("->") else => ".") + "template ",
        )

        self._name(last->name->name)
        self._cg->sink->spell(last->range, ta)
    }

    /// `(::__kairo_nopanic(), ` before a site whose callee only a `<T: type>`
    /// instance knows (LowerTargets::nopanic_call), `)` after it. The
    /// wrapper has no Kairo bytes: its tokens are unanchored, as five on the
    /// site's first byte would walk on into the site's own and take the `.`
    /// clang places a member-access error on. Only the `,` -- the
    /// expression a failed instance is "requested" at -- sits on the
    /// site's first byte.
    prot fn _nopanic_open(self, at: SourceRange) {
        self._cg->sink->unanchored(true)
        self._cg->sink->spell(at, "(::" + LowerTargets::nopanic_call() + "()")
        self._cg->sink->unanchored(false)
        self._cg->sink->synth_at_start(at, clang::tok::comma)
    }

    /// As _nopanic_open for a construction of \p ty: the check names the
    /// type, so the wrapper's comma is the builtin one and the construction
    /// stays a prvalue, never moved (a RAII guard's move may be deleted).
    priv fn _nopanic_open_of(self, at: SourceRange, const ty: string) {
        self._cg->sink->unanchored(true)
        self._cg->sink->spell(
            at,
            "(::" + LowerTargets::nopanic_of() + "<" + ty + ">()",
        )

        self._cg->sink->unanchored(false)
        self._cg->sink->synth_at_start(at, clang::tok::comma)
    }

    prot fn _nopanic_close(self, at: SourceRange) {
        self._cg->sink->unanchored(true)
        self._cg->sink->spell(at, ")")
        self._cg->sink->unanchored(false)
    }

    /// A member of a concrete C++ instance (`out.push_back(x)` on a
    /// `vector<*Decl>`) left to its overload set because an ARGUMENT is
    /// dependent (`unsafe (cur as *Decl)` with `cur` of a `<T: type>` type):
    /// the overload cannot be picked until an instance fixes the argument,
    /// so the call goes out as written and clang resolves it per instance.
    priv fn _dependent_arg_member(self, n: unsafe *CallExpr) -> bool {
        var unsafe *ch = dyn_cast<ChainExpr>(n->callee)
        if ch == &null || ch->steps.size() == 0 {
            return false
        }

        var unsafe *last = ch->steps.get(ch->steps.size() - 1)
        if last->resolved_decl != &null || last->candidate_cell == &null {
            return false
        }

        for var i: usize = 0; i < n->args.size(); ++i {
            if n->args[i]->is_instantiation_dependent() {
                return true
            }
        }

        return false
    }

    /// \p n calls a member Sema left unbound because its receiver is
    /// dependent (_dependent_step): the callee is a value chain whose LAST
    /// step is that member.
    priv fn _dependent_member_call(self, n: unsafe *CallExpr) -> bool {
        if self._dependent_arg_member(n) {
            return true
        }

        var unsafe *ch = dyn_cast<ChainExpr>(n->callee)
        if ch == &null || ch->steps.size() == 0 {
            return false
        }

        var unsafe *last = ch->steps.get(ch->steps.size() - 1)
        if last->resolved_decl != &null {
            return false
        }

        return self._dependent_step(ch, last)
    }

    /// CallLowering's postcondition, checked where it matters: every
    /// parameter has an argument. The one exception: trailing
    /// imported C++ defaults are omitted and clang supplies them -- the one
    /// place this layer gives clang headroom, on purpose. A dependent call is
    /// as written until M2 and is not checked.
    priv fn _check_arity(self, n: unsafe *CallExpr, f: unsafe *FunctionDecl, bound: bool) {
        if f == &null || n->is_instantiation_dependent() {
            return
        }

        var want: usize = 0
        var tail: usize = 0
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null {
                continue
            }

            if p->is_self && bound {
                continue
            }

            want += 1
            if p->has_default && p->default_thunk == &null {
                tail += 1
            } else {
                tail = 0
            }
        }

        // `x.op++(0)`: C++'s postfix dummy, minted by OperatorLowering and
        // declared by no Kairo parameter (Speller::op_is_postfix).
        if Speller::op_is_postfix(f) {
            want += 1
        }

        var have = n->args.size()
        // A type pack takes any number of arguments, none included.
        var tpack = false
        for var i: usize = 0; i < f->params.size(); ++i {
            if param_is_type_pack(f->params[i]) {
                tpack = true
                break
            }
        }

        if tpack {
            want -= 1
            if have >= want {
                return
            }
        }

        if have + tail < want {
            self._ice(
                n->range,
                "EmitIR: a call short of arguments reached codegen; CallLowering owns defaults",
            )
        }

        if have > want && !f->ffi_c_variadic {
            self._ice(
                n->range,
                "EmitIR: a call with more arguments than parameters reached codegen",
            )
        }
    }

    /// A callee whose name is spelled whole: a bare name or a `::` path. A
    /// generic METHOD through `.` needs `.template m<...>` and is still
    /// Compiler/Spec/Pipeline.md item r.
    /// The one C++ name of an UNPROMOTED plain callee whose candidates are
    /// all imported functions spelled alike, or "" for any other callee.
    priv fn _dependent_imported_set(self, c: unsafe *Expr) -> string {
        if !self._plain_callee(c) {
            return ""
        }

        var        cell: unsafe *OverloadCell = &null
        var unsafe *ni                        = dyn_cast<NamedIdentExpr>(c)
        if ni != &null && ni->resolved_decl == &null {
            cell = ni->candidate_cell
        }

        var unsafe *ch = dyn_cast<ChainExpr>(c)
        if ch != &null && ch->steps.size() > 0 {
            var unsafe *last = ch->steps.get(ch->steps.size() - 1)
            if last->resolved_decl == &null {
                cell = last->candidate_cell
            }
        }

        if cell == &null || cell->size() == 0 {
            return ""
        }

        var name = ""
        for var i: usize = 0; i < cell->size(); ++i {
            var unsafe *d = cell->get(i)
            if d == &null || !isa<FunctionDecl>(d) || !decl_is_imported(d) {
                return ""
            }

            var s = self._spell.qual_name(d)
            if i == 0 {
                name = s.copy()
            } else if s != name {
                return ""
            }
        }

        return name
    }

    /// The one C++ name of an UNPROMOTED plain callee whose candidates are Kairo
    /// functions spelled alike (`is_recovery(x)` over an `Expr`/`Stmt` pair)
    /// when an ARGUMENT is dependent or untyped (`x` deduced from a duck call):
    /// which overload wins is the instance's question, so the call goes out as
    /// written and clang picks per instance, as for the imported set above.
    /// "" for any other call, so an unpromoted set with plain arguments still
    /// trips the gate.
    priv fn _dependent_free_set(self, n: unsafe *CallExpr) -> string {
        if !self._plain_callee(n->callee) {
            return ""
        }

        var unsafe *ni = dyn_cast<NamedIdentExpr>(n->callee)
        if ni == &null || ni->resolved_decl != &null || ni->candidate_cell == &null {
            return ""
        }

        var unsafe *cell = ni->candidate_cell
        if cell->size() == 0 {
            return ""
        }

        var any_dep = false
        for var j: usize = 0; j < n->args.size(); ++j {
            var unsafe *a = n->args[j]
            if a->is_instantiation_dependent() || a->type_ == &null {
                any_dep = true
            }
        }

        if !any_dep {
            return ""
        }

        var name = ""
        for var i: usize = 0; i < cell->size(); ++i {
            var unsafe *d = cell->get(i)
            if d == &null || !isa<FunctionDecl>(d) {
                return ""
            }

            var s = self._spell.qual_name(d)
            if i == 0 {
                name = s.copy()
            } else if s != name {
                return ""
            }
        }

        return name
    }

    /// The generic-argument list written on a callee's name: a bare name's,
    /// or a chain's last step's; null for any other callee.
    priv fn _written_list(self, c: unsafe *Expr) -> unsafe *FrozenList<ChainType::GenericArg> {
        if isa<NamedIdentExpr>(c) {
            return unsafe &cast<NamedIdentExpr>(c)->generic_args
        }

        var unsafe *ch = dyn_cast<ChainExpr>(c)
        if ch != &null && ch->steps.size() > 0 {
            return unsafe &ch->steps.get(ch->steps.size() - 1)->generic_args
        }

        return &null
    }

    /// `::ns::I_witness<Self, A...>::m`, requirement \p f of interface
    /// instance \p wi through its witness, Self spelled from \p me; with
    /// \p targs (`<B>`) it is `::template m<B>`, the witness being a
    /// dependent type. One spelling for a witness call and a witness member
    /// used as a value.
    prot fn _witness_member(self,
                            wi0:         unsafe *Type,
                            me:          unsafe *Type,
                            f:           unsafe *FunctionDecl,
                            const targs: string) -> string {
        var unsafe *wi = canon_unqual(wi0)
        if wi == &null || !isa<RecordType>(wi) {
            self._ice(
                f->range,
                "EmitIR: a witness that is not an interface instance",
            )
        }

        var unsafe *idecl = Speller::rep(
            decl_pattern(Speller::rep(cast<RecordType>(wi)->decl)),
        )

        // A pack element (`for x in xs` over `...xs: T`) as Self is the
        // element's own type, read off the binding _pack_for opened
        // (`__remove_cvref(decltype(x))`). Not `T...`, the type speller's
        // expansion, and not a bare `T` either: the fold would expand that
        // in step with `xs`, but clang refuses an unexpanded pack in a
        // declaration's initializer, which a statement-expression lowering
        // of the call puts it in.
        var        subj = ""
        var unsafe *mc  = canon_unqual(me)
        var        k    = self._pe_gp.size()
        while k > 0 {
            k -= 1
            if mc != &null && self._pe_gp[k] == mc {
                subj = "__remove_cvref(decltype(" + self._pe_name[k] + "))"
                break
            }
        }

        if subj.size() == 0 {
            subj = self._spell._type(me)
        }

        var s = self._spell.witness_name(idecl) + self._spell.witness_args(
            subj,
            wi,
        ) + "::"
        if targs.size() > 0 {
            return s + "template " + self._spell.witness_member_name(f) + targs
        }

        return s + self._spell.witness_member_name(f)
    }

    /// The generic arguments written on a plain callee (`f<A>` or
    /// `ns::f<A>`), as canonicals in order; empty when none were written.
    priv fn _written_targs(self, c: unsafe *Expr) -> cxx::std::vector<unsafe *Type> {
        var out = cxx::std::vector<unsafe *Type>()
        var gl: unsafe *FrozenList<ChainType::GenericArg> = &null
        if isa<NamedIdentExpr>(c) {
            gl = unsafe &cast<NamedIdentExpr>(c)->generic_args
        }

        var unsafe *ch = dyn_cast<ChainExpr>(c)
        if ch != &null && ch->steps.size() > 0 {
            gl = unsafe &ch->steps.get(ch->steps.size() - 1)->generic_args
        }

        if gl == &null {
            return out
        }

        for var i: usize = 0; i < gl->size(); ++i {
            var unsafe *ga = gl->get(i)
            if ga->ty == &null || ga->ty->canonical == &null {
                self._ice(
                    c->range,
                    "EmitIR: a written generic argument with no type",
                )
            }

            out.push_back(ga->ty->canonical)
        }

        return out
    }

    /// \p t is an imported tag C++ can only name elaborated (`struct ::stat`,
    /// its name hidden by an ordinary one): Speller::_type spells the keyword
    /// in front of it.
    priv fn _elaborated_tag(self, t: unsafe *Type) -> bool {
        var unsafe *c = canon_unqual(t)
        if c == &null || !isa<RecordType>(c) {
            return false
        }

        var unsafe *d = cast<RecordType>(c)->decl
        return d != &null && decl_is_imported(d) && decl_ffi_tag_keyword(d).size() > 0
    }

    /// The binary operators C++ spells infix and a free function can overload
    /// (shifts excluded: `>>` is a split-token hazard in a template).
    priv fn _infix_operator(self, k: TokenKind) -> bool {
        return k == TokenKind::OpEqualEqual
            || k == TokenKind::OpExclaimEqual
            || k == TokenKind::OpLess
            || k == TokenKind::OpLessEqual
            || k == TokenKind::OpGreater
            || k == TokenKind::OpGreaterEqual
            || k == TokenKind::OpPlus
            || k == TokenKind::OpMinus
            || k == TokenKind::OpStar
            || k == TokenKind::OpSlash
            || k == TokenKind::OpPercent
    }

    priv fn _plain_callee(self, c: unsafe *Expr) -> bool {
        if isa<NamedIdentExpr>(c) {
            return true
        }

        var unsafe *ch = dyn_cast<ChainExpr>(c)
        if ch == &null || ch->steps.size() == 0 {
            return false
        }

        return ch->steps.get(ch->steps.size() - 1)->access_kind == ChainExpr::AccessKind::ColonColon
    }

    /// Arguments, each cast to its parameter's canonical where it differs.
    /// \p bound: the callee carries its receiver, so `self` takes no argument.
    /// \p skip_object: argument zero is the object of a qualified method
    /// call, already written in front of the callee.
    prot fn _args(self,
                  n:           unsafe *CallExpr,
                  f:           unsafe *FunctionDecl,
                  bound:       bool,
                  inst:        unsafe *InstanceEntry,
                  skip_object: bool = false) {
        var params = self._call_params(f, bound)
        // A type pack's run (CallLowering leaves it one argument per
        // element): every argument from the pack's slot to the surplus is the
        // pack's, and goes as written -- the instance's elements ARE those
        // arguments' types (CallTyping), so there is nothing to convert to.
        var pk         = usize::MAX
        var run: usize = 0
        for var i: usize = 0; i < params.size(); ++i {
            if param_is_type_pack(params[i]) {
                pk = i
                break
            }
        }

        if pk != usize::MAX && n->args.size() + 1 >= params.size() {
            run = n->args.size() + 1 - params.size()
        }

        for var i: usize = 0; i < n->args.size(); ++i {
            var unsafe *a = n->args[i]
            if skip_object && i == 0 {
                continue
            }

            var first: usize = if (skip_object) => (1) else => 0
            if i > first {
                self._cg->sink->synth_at_end(
                    n->args[i - 1]->range,
                    clang::tok::comma,
                )
            }

            if pk != usize::MAX && i >= pk && i < pk + run {
                self._pack_arg(a, params[pk], inst, i - pk)
                continue
            }

            var p: unsafe *ParamDecl = &null
            var pi                   = i
            if pk != usize::MAX && i >= pk + run {
                pi = i + 1 - run
            }

            if pi < params.size() {
                p = params[pi]
            }

            var alias = self._alias_ptr_spelling(f, p, a)
            if alias.size() > 0 {
                self._cg->sink->spell(
                    a->range,
                    "reinterpret_cast<" + alias + ">(",
                )
            }

            self._arg(a, p, inst)
            if alias.size() > 0 {
                self._cg->sink->spell(a->range, ")")
            }
        }
    }

    /// The imported parameter's own C++ spelling when \p a must be cast to
    /// it, or "". A C integer alias reached through a pointer
    /// (ParamDecl::cxx_alias_ptr) imports as the Kairo integer of its width,
    /// whose C++ spelling is the target's natural one: `&tid` is `unsigned
    /// int*` and i686 `pthread_create` takes `unsigned long*`. Same object,
    /// same width, and Sema already accepted the call, so the cast only
    /// tells C++ what Kairo knows. Never on a null literal: nullptr has no
    /// reinterpret_cast, and converts on its own.
    priv fn _alias_ptr_spelling(self,
                                f: unsafe *FunctionDecl,
                                p: unsafe *ParamDecl,
                                a: unsafe *Expr) -> string {
        if f == &null || p == &null || !p->cxx_alias_ptr || p->is_self || p->is_pack {
            return ""
        }

        var unsafe *e = a
        while e != &null && isa<ParenExpr>(e) {
            e = cast<ParenExpr>(e)->inner
        }

        if e == &null || isa<NullLiteralExpr>(e) {
            return ""
        }

        // cxx_param_spellings holds the value parameters only.
        var k: usize = 0
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *q = f->params[i]
            if q == p {
                break
            }

            if q != &null && !q->is_self {
                k += 1
            }
        }

        if k >= f->cxx_param_spellings.size() {
            return ""
        }

        return f->cxx_param_spellings[k].copy()
    }

    /// Element \p k of a type pack's run. Under an instance a forwarding
    /// pack's parameter is `E&&` (Speller::param_type), which an lvalue
    /// does not bind: a by-value pack gets `static_cast<E>(x)`, the one copy
    /// any `x: T` parameter makes, and `@move` gets `static_cast<E&&>(x)`.
    /// A prvalue, a moved MOVE value (CopyMoveLowering's xvalue cast) and an
    /// expansion bind as they are, so they reach the last layer without a
    /// copy. With no instance (a dependent call) C++ deduces each element,
    /// and an lvalue binds as `E&`.
    priv fn _pack_arg(self,
                      a:    unsafe *Expr,
                      p:    unsafe *ParamDecl,
                      inst: unsafe *InstanceEntry,
                      k:    usize) {
        if !Speller::forwarding_pack(p) || !a->is_lvalue() || isa<PackExpansionExpr>(a) {
            self.emit(a)
            return
        }

        var els = cxx::std::vector<unsafe *Type>()
        if !self._spell.subst_pack(param_type_pack_param(p), inst, &els) || k >= els.size() {
            self.emit(a)
            return
        }

        var unsafe *e = canon_unqual(els[k])
        if e == &null
            || isa<CXXLValueRefType>(e)
            || isa<CXXRValueRefType>(e)
            || e->kind == TypeKind::FixedArrayType {
            self.emit(a)
            return
        }

        var rr = if (p->mode == ParamMode::Move) => ("&&") else => ""
        self._cg->sink->spell(
            a->range,
            "static_cast<" + self._spell._type(els[k]) + rr + ">(",
        )

        self.emit(a)
        self._cg->sink->spell(a->range, ")")
    }

    priv fn _arg(self, a: unsafe *Expr, p: unsafe *ParamDecl, inst: unsafe *InstanceEntry) {
        // `&x` bound to an @inout parameter is the mode marker, not address-of.
        var unsafe *u = dyn_cast<UnaryOperatorExpr>(a)
        if u != &null && u->is_mode_marker {
            self.emit(u->operand)
            return
        }

        // An extension call's receiver: its pointer or object form was decided
        // in the tree (ExtensionLowering), so it is emitted as it stands.
        if p != &null && p->is_self {
            self.emit(a)
            return
        }

        if p == &null {
            self.emit(a)
            return
        }

        var unsafe *pt = p->type_
        if p->is_pack {
            if p->pack_type == &null {
                self._ice(
                    a->range,
                    "EmitIR: pack parameter with no slice type; CallLowering stamps it",
                )
            }

            pt = p->pack_type
        }

        if p->mode == ParamMode::Move {
            // An lvalue must be moved explicitly; a prvalue already is.
            // A parameter type naming the callee's own parameters (`T` of
            // `fn <T> move(@move x: T)`) is spelled by the argument's type
            // when the call is in a generic body: the callee's names are
            // not in scope there, and the call has no concrete instance.
            if a->is_lvalue() {
                var unsafe *mt = pt
                var unsafe *pc = if (pt != &null && pt->canonical != &null) => (pt->canonical)
                                 else => pt
                if pc != &null && pc->is_dependent() && a->type_ != &null && !p->is_pack {
                    mt = canon_unqual(a->type_)
                    if mt != &null && isa<CXXLValueRefType>(mt) {
                        mt = canon_unqual(cast<CXXLValueRefType>(mt)->referee)
                    }

                    if mt == &null {
                        mt = pt
                    }
                }

                self._cg->sink->spell(
                    a->range,
                    "static_cast<" + self._spell._type(mt, inst) + "&&>(",
                )

                self.emit(a)
                self._cg->sink->spell(a->range, ")")
                return
            }

            self.emit(a)
            return
        }

        if p->mode == ParamMode::Inout {
            self.emit(a)
            return
        } // an lvalue binds to T& as is.

        self._value(a, pt, inst)
    }

    /// The `fn` type of a callee that is a VALUE, not a function: one whose
    /// decl (if any) is not a function or a type and whose canonical is a
    /// `fn(...)`. Null otherwise.
    priv fn _fn_value_type(self, c: unsafe *Expr, d: unsafe *Decl) -> unsafe *FunctionPointerType {
        if d != &null && (isa<FunctionDecl>(d) || self._is_type_decl(d)) {
            return &null
        }

        if c == &null || c->type_ == &null {
            return &null
        }

        var unsafe *t = canon_unqual(c->type_)
        if t == &null || !isa<FunctionPointerType>(t) {
            return &null
        }

        return cast<FunctionPointerType>(t)
    }

    /// True when \p f is `fn(...) -> !`.
    priv fn _returns_never(self, f: unsafe *FunctionPointerType) -> bool {
        if f->return_type == &null || f->return_type->canonical == &null {
            return false
        }

        var unsafe *r = canon_unqual(f->return_type->canonical)
        if r == &null || r->kind != TypeKind::BuiltinType {
            return false
        }

        return cast<BuiltinType>(r)->builtin == BuiltinKind::Never
    }

    /// Arguments of a call through a `fn` value, each as its parameter in
    /// the type: `@inout` bare, `@move` cast to `T&&` from an lvalue, the
    /// rest through the exactness cast, as for a function's (_arg).
    priv fn _fn_value_args(self, n: unsafe *CallExpr, f: unsafe *FunctionPointerType) {
        for var i: usize = 0; i < n->args.size(); ++i {
            var unsafe *a = n->args[i]
            if i > 0 {
                self._cg->sink->synth_at_end(
                    n->args[i - 1]->range,
                    clang::tok::comma,
                )
            }

            if i >= f->params.size() {
                self.emit(a)
                continue
            }

            var unsafe *pt = *f->params.get(i)
            var        m   = *f->modes.get(i)
            var unsafe *u  = dyn_cast<UnaryOperatorExpr>(a)
            if u != &null && u->is_mode_marker {
                self.emit(u->operand)
                continue
            }

            if m == ParamMode::Inout {
                self.emit(a)
                continue
            }

            if m == ParamMode::Move && a->is_lvalue() {
                self._cg->sink->spell(
                    a->range,
                    "static_cast<" + self._spell._type(pt) + "&&>(",
                )

                self.emit(a)
                self._cg->sink->spell(a->range, ")")
                continue
            }

            self._value(a, pt)
        }
    }

    /// The parameters an argument list maps onto: `self` excluded only when
    /// \p bound -- an extension call passes its receiver as argument zero.
    priv fn _call_params(self,
                         f:     unsafe *FunctionDecl,
                         bound: bool) -> cxx::std::vector<unsafe *ParamDecl> {
        var out = cxx::std::vector<unsafe *ParamDecl>()
        if f == &null {
            return out
        }

        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null {
                continue
            }

            if p->is_self && bound {
                continue
            }

            out.push_back(p)
        }

        return out
    }

    prot fn _callee_decl(self, c: unsafe *Expr) -> unsafe *Decl {
        var unsafe *ni = dyn_cast<NamedIdentExpr>(c)
        if ni != &null {
            if ni->resolved_decl == &null && ni->candidate_cell != &null {
                self._ice(
                    ni->range,
                    "EmitIR: unpromoted callee; ExprTyper gate failure",
                )
            }

            return ni->resolved_decl
        }

        var unsafe *ch = dyn_cast<ChainExpr>(c)
        if ch != &null && ch->steps.size() > 0 {
            var unsafe *last = ch->steps.get(ch->steps.size() - 1)
            if last->resolved_decl == &null && last->candidate_cell != &null {
                // Left to each instance: spelled as written below.
                if self._dependent_step(ch, last) {
                    return &null
                }

                self._ice(
                    c->range,
                    "EmitIR: unpromoted callee step; ExprTyper gate failure",
                )
            }

            return last->resolved_decl
        }

        return &null // a fn-pointer expression; no decl to consult.
    }

    /// \p d is declared in an interface: a requirement, never a C++ function.
    priv fn _is_requirement(self, d: unsafe *Decl) -> bool {
        if d == &null || !isa<FunctionDecl>(d) || d->semantic_dc == &null {
            return false
        }

        var unsafe *home = (d->semantic_dc)->owner_decl()
        return home != &null && isa<InterfaceDecl>(home)
    }
}
