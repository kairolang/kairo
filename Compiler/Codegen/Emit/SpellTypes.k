/// --- The Kairo Project -------------------- Codegen/Emit/SpellTypes.k --- ///
///
///   Speller, part: types. A canonical type's C++ spelling, declarators,
///   values, function signatures and parameter types, and the names a type
///   reaches through a dependent qualifier.
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

import AST::Context::InstantiationRegistry::InstanceEntry
import AST::DeclFacts
import AST::Kind::DeclKind::to_string
import AST::Kind::TypeKind::{
    TypeKind,
    to_string,
}
import AST::LangItems::{
    LowerTargets,
    to_string,
}
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,  BuiltinKind,  BuiltinType,     QUAL_CONST,   QUAL_VOLATILE, QualifiedType,
    RecordType, builtin_info, canon_has_const, canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, ChainType,     FixedArrayType, FunctionPointerType,
    GenericParamType, NullableType,     OpaqueFFIType, PointerType,    TypeExpr,
    ValueOp,
}
import AST::OperatorFacts::OperatorFacts
import AST::ParamMode::ParamMode
import Codegen::Emit::Spell::Speller
import Codegen::Emit::SpellConstraints
import Codegen::Emit::SpellFacts
import Codegen::Emit::SpellRecords
import Codegen::Emit::SpellScopes
import Token::TokenKind::TokenKind
import Token::TokenText::TokenText

extend Speller {
    /// # Types

    /// C++ spelling of a canonical type. \p subst substitutes the primary's
    /// generic parameters with an instance's args (tier 3). Declarator
    /// shapes (arrays, function pointers) need a name to wrap; use decl().
    ///
    /// \p scope is the record whose class body the text is written in, or
    /// null. Inside it, its own nested types are named by leaf: the
    /// qualified form of a type nested in a class template needs the
    /// template's arguments, which a nested decl's canonical does not carry.
    /// It is the decl being emitted, never ambient state, so the text stays a
    /// function of that decl (InterfaceEmitter's ODR argument).
    fn _type(self,
             t:     unsafe *Type,
             subst: unsafe *InstanceEntry = &null,
             scope: unsafe *Decl = &null) -> string {
        return self.decl(t, "", subst, scope)
    }

    /// \p t as ONE type-specifier that text may follow: `_type`, except that
    /// a C array (`signed int[2]`), whose declarator wraps whatever follows
    /// it (`int (*p)[2]`), is `__typeof__(signed int[2])`. Every spelling
    /// that appends `*`, `&`, ` const &` or a name to a type it got as a
    /// string goes through here: an extension's receiver, a
    /// witness's Self, a generic parameter an instance binds to an array.
    fn type_specifier(self,
                      t:     unsafe *Type,
                      subst: unsafe *InstanceEntry = &null,
                      scope: unsafe *Decl = &null) -> string {
        var        s  = self._type(t, subst, scope)
        var unsafe *c = if (t != &null && t->canonical != &null) => (t->canonical) else => t
        if c != &null && isa<FixedArrayType>(canon_unqual(c)) {
            return "__typeof__(" + s + ")"
        }

        return s
    }

    /// The C++ spelling of an unresolved member type of a generic parameter
    /// (`T::Guard`, `T::A::B`) or of a template-id over one
    /// (`traits<T>::size_type`) as `typename T::Guard`, or "" for any other
    /// type: a type unresolved for any other reason is still a Sema gate
    /// failure, and must keep ICEing.
    fn dependent_member(self, t: unsafe *Type) -> string {
        if t == &null || t->kind != TypeKind::ChainType {
            return ""
        }

        var unsafe *ch = cast<ChainType>(t)
        if ch->segments.size() < 2 {
            return ""
        }

        var unsafe *s0 = ch->segments.get(0)
        var        out = ""
        if s0->resolved_type != &null
            && s0->resolved_type->canonical != &null
            && isa<GenericParamType>(s0->resolved_type->canonical) {
            out = "typename " + self._type(s0->resolved_type)
        } else if s0->resolved_decl != &null
            && isa<Declarations::GenericParamDecl>(s0->resolved_decl)
            && s0->name != &null {
            out = "typename " + *TokenText::from_range(
                s0->name->range,
                self._cg->ctx->sm,
            ).get_text()
        } else if s0->generic_args.size() > 0
            && s0->resolved_type != &null
            && s0->resolved_type->canonical != &null
            && s0->resolved_type->canonical->is_dependent() {
            // `traits<T>::size_type`: a member of a template-id whose
            // arguments name a generic parameter, as dependent as `T::X`.
            out = "typename " + self._type(s0->resolved_type)
        } else if s0->resolved_decl != &null && s0->generic_args.size() > 0 {
            var args = ""
            var dep  = false
            for var i: usize = 0; i < s0->generic_args.size(); ++i {
                var unsafe *a = s0->generic_args.get(i)->ty
                if a == &null || a->canonical == &null {
                    return ""
                }

                dep = dep || a->canonical->is_dependent()
                if i > 0 {
                    args += ", "
                }

                args += self._type(a)
            }

            if !dep {
                return ""
            }

            out = "typename " + self.qual_name(s0->resolved_decl) + "<" + args + ">"
        } else {
            return ""
        }

        for var i: usize = 1; i < ch->segments.size(); ++i {
            var unsafe *sg = ch->segments.get(i)
            if sg->name == &null || sg->generic_args.size() > 0 {
                return ""
            }

            out += "::" + *TokenText::from_range(
                sg->name->range,
                self._cg->ctx->sm,
            ).get_text()
        }

        return out
    }

    /// `type name` with the declarator folded in: `int x`, `int (*f)(int)`.
    /// Empty \p name gives the abstract form. \p scope as for _type.
    fn decl(self,
            t_in:       unsafe *Type,
            const name: string,
            subst:      unsafe *InstanceEntry = &null,
            scope:      unsafe *Decl = &null) -> string {
        if t_in == &null {
            return self._join("void", name)
        }

        var unsafe *t = t_in->canonical
        if t == &null {
            // `T::Guard` under a duck `<T: type>`: no canonical until an
            // instance names T, so C++ resolves it (`typename T::Guard`).
            var dm = self.dependent_member(t_in)
            if dm.size() > 0 {
                return self._join(dm, name)
            }

            self._ice(
                t_in->range,
                "CXXSpell: type with no canonical reached codegen (sema gate failure)",
            )
        }

        match t->kind {
            case TypeKind::QualifiedType {
                var unsafe *q  = cast<QualifiedType>(t)
                var        pfx = ""
                if (q->quals & QUAL_CONST) != 0 {
                    pfx += "const "
                }

                if (q->quals & QUAL_VOLATILE) != 0 {
                    pfx += "volatile "
                }

                // A qualifier on a pointer belongs to the pointer, after the
                // `*` (`S *const &`); a prefix would make it the pointee's
                // (`const S *&`), a reference clang refuses to bind to a
                // `S *` element (vector<S *>::push_back's `const value_type&`).
                var unsafe *ic = q->inner->canonical
                if ic != &null && ic->kind == TypeKind::PointerType {
                    var after = ""
                    if (q->quals & QUAL_CONST) != 0 {
                        after += "const"
                    }

                    if (q->quals & QUAL_VOLATILE) != 0 {
                        after += if (after.size() > 0) => (" volatile") else => "volatile"
                    }

                    return self.decl(
                        q->inner,
                        if (name.size() > 0) => (after + " " + name) else => after,
                        subst,
                        scope,
                    )
                }

                // `const T` under an instance that binds T to a const type
                // is that type: the qualifier folds, as it does in the
                // template, and is spelled once.
                if q->quals == QUAL_CONST && self._subst_is_const(q->inner, subst) {
                    return self.decl(q->inner, name, subst, scope)
                }

                return pfx + self.decl(q->inner, name, subst, scope)
            } case TypeKind::BuiltinType {
                var unsafe *b = cast<BuiltinType>(t)
                if b->builtin == BuiltinKind::Never {
                    return self._join("void", name)
                }

                if self.fold_sizes {
                    var fk = self.size_fold(b->builtin)
                    if fk != b->builtin {
                        self.sizes_folded += 1
                        return self._join(builtin_info(fk)->cxx, name)
                    }
                }

                return self._join(b->cxx_emission(), name)
            } case TypeKind::RecordType {
                if self.auto_hidden && self.names_hidden_member(t) {
                    return self._join("auto", name)
                }

                return self._join(
                    self._record(cast<RecordType>(t), subst, scope),
                    name,
                )
            } case TypeKind::PointerType {
                return self.decl(
                    cast<PointerType>(t)->pointee,
                    "*" + name,
                    subst,
                    scope,
                )
            } case TypeKind::CXXLValueRefType {
                return self.decl(
                    cast<CXXLValueRefType>(t)->referee,
                    "&" + name,
                    subst,
                    scope,
                )
            } case TypeKind::CXXRValueRefType {
                return self.decl(
                    cast<CXXRValueRefType>(t)->referee,
                    "&&" + name,
                    subst,
                    scope,
                )
            } case TypeKind::FixedArrayType {
                var unsafe *a  = cast<FixedArrayType>(t)
                var        ext = ""
                if !a->is_incomplete {
                    ext = f"{a->size_bits}"
                }

                // `[T; N]` for a generic value parameter: the parameter, or
                // its instance's value (Compiler/Spec/Eval.md#generic-value-parameters).
                if a->extent_param != &null {
                    ext = self._type(a->extent_param, subst, scope)
                }

                // `[]` binds tighter than `*` and `&`: a pointer or reference
                // TO an array parenthesizes its declarator.
                var nm = name
                if nm.size() > 0 && (nm[0] == ('*' as u8) || nm[0] == ('&' as u8)) {
                    nm = "(" + nm + ")"
                }

                return self.decl(a->element, f"{nm}[{ext}]", subst, scope)
            }

            // A Kairo `fn(A) -> R` holds a capturing closure as well as a
            // function (closures.md: "no separate closure type"), so it is
            // the `::__kairo_fn<R(A...)>` value type, never a raw pointer:
            // a lambda with captures has no `R(*)(A...)`. It converts from a
            // function and back to one (for a C callee) on its own. Only a C
            // no-prototype pointer stays raw: no Kairo value has that type.
            case TypeKind::FunctionPointerType {
                var unsafe *f = cast<FunctionPointerType>(t)
                if f->is_unprototyped {
                    return self.decl(
                        f->return_type,
                        f"(*{name})()",
                        subst,
                        scope,
                    )
                }

                // `unsafe fn(A) -> R` is the plain `R(*)(A)`: one word,
                // called directly, what a C callee or field holds.
                // A convention leads the signature: inside a type-id clang takes
                // `__attribute__((preserve_most)) R(A)`, not a trailing one.
                // `noexcept` unless -funwind: every Kairo function is, so the
                // indirect call (`f->alloc(...)`) is a call, not an invoke
                // whose landing pad calls __clang_call_terminate. An imported
                // C++ function that is not noexcept does not convert to it.
                if f->is_raw {
                    var nx = ""
                    if self._cg == &null || !self._cg->opts.unwind {
                        nx = " noexcept"
                    }

                    return self._join(
                        "::" + LowerTargets::raw_fn() + "<" + Speller::call_conv_attr(
                            f->call_conv,
                        ) + self.fn_signature(f, subst, scope) + nx + ">",
                        name,
                    )
                }

                return self._join(
                    "::" + LowerTargets::fn_value() + "<" + self.fn_signature(
                        f,
                        subst,
                        scope,
                    ) + ">",
                    name,
                )
            } case TypeKind::GenericParamType {
                return self._join(
                    self._gparam(cast<GenericParamType>(t), subst),
                    name,
                )
            }

            // `T::Node` is the witness's member type: `typename
            // ::ns::Graph_witness<T>::Node`. One template body, every
            // instance: each conformance's specialization declares it
            // (EmitWitness), so C++ selects the type per instance (Compiler/Spec/Generics.md
            // D2). Inside a witness, a base that is the interface's Self is
            // spelled as Self is there. `typename` always: it is allowed on
            // a qualified name that turns out not to be dependent.
            case TypeKind::AssocType {
                return self._join(
                    self.assoc_spelling(cast<AssocType>(t), subst, scope),
                    name,
                )
            }

            // A generic VALUE argument (`4` of `Buf<4>`): the integer.
            case TypeKind::TypeExpr {
                var unsafe *v = cast<TypeExpr>(t)
                if !v->is_value {
                    self._ice(
                        t_in->range,
                        "CXXSpell: an unfolded generic value argument reached codegen; TypeResolve folds every one",
                    )

                    return ""
                }

                return self._join(self.value(v, subst, scope), name)
            } case TypeKind::OpaqueFFIType {
                var unsafe *o = cast<OpaqueFFIType>(t)
                return self._join(o->text(), name)
            }

            // `T?` is spelled as the record NullableTypeLowering gave it; with
            // none, that pass never saw this canonical.
            case TypeKind::NullableType {
                var unsafe *lw = cast<NullableType>(t)->lowered
                if lw == &null {
                    self._ice(
                        t_in->range,
                        "CXXSpell: T? reached codegen with no lowered record; NullableTypeLowering must run first",
                    )

                    return ""
                }

                return self.decl(lw, name, subst, scope)
            } case TypeKind::TupleType {
                self._ice(
                    t_in->range,
                    "CXXSpell: TupleType canonical reached codegen; TypeResolve canonicalizes every tuple to its TupleN record",
                )

                return ""
            } default {
                self._ice(
                    t_in->range,
                    f"CXXSpell: {to_string(t->kind)} is not a canonical kind",
                )

                return ""
            }
        }
    }

    /// A canonical value (Compiler/Spec/Eval.md#value-nodes, 3) as the C++ expression that
    /// computes it: the integer, or the expression Sema kept (`(N + 1)`,
    /// `::m::f(3)`, `::m::K`), each operand spelled as a type argument is
    /// (a value parameter, or its instance's value under \p subst). Every
    /// operator application is parenthesized, so the text means the same as
    /// an array bound and as a template argument, where a bare `>>` would
    /// close the list.
    fn value(self,
             v:     unsafe *TypeExpr,
             subst: unsafe *InstanceEntry = &null,
             scope: unsafe *Decl = &null) -> string {
        if v->is_exact() {
            return if (v->vneg) => (f"-{v->vmag}") else => f"{v->vmag}"
        }

        match v->vop {
            case ValueOp::Decl {
                // An `eval for` binding is a local with no scope home: its
                // name, read from the table of the file it is written in.
                var unsafe *vd = dyn_cast<Declarations::VariableDecl>(v->vdecl)
                if vd != &null
                    && (vd->semantic_dc == &null || Speller::in_function_scope(v->vdecl)) {
                    return self.tok_name(
                        vd->name,
                        self._cg->ctx->sm->get_fid(vd->name.range),
                    )
                }

                return self.qual_name(v->vdecl)
            } case ValueOp::Call {
                // An eval class's constructor (Compiler/Spec/Eval.md#eval-classes) is named by its
                // class; with no arguments, braced, or `X()` reads as a type.
                var isrec = isa<Declarations::ClassDecl>(v->vdecl)
                    || isa<Declarations::StructDecl>(v->vdecl)
                if isrec && v->vops.size() == 0 {
                    return self.qual_name(v->vdecl) + "{}"
                }

                var s = self.qual_name(v->vdecl) + "("
                for var i: usize = 0; i < v->vops.size(); ++i {
                    if i > 0 {
                        s += ", "
                    }

                    s += self._type(v->vops[i], subst, scope)
                }

                return s + ")"
            } case ValueOp::Unary {
                var sym = if (v->vtok == TokenKind::OpTilde) => ("~") else => "-"
                return "(" + sym + self._type(v->vops[0], subst, scope) + ")"
            } case ValueOp::Binary {
                return "(" + self._type(v->vops[0], subst, scope) + " " + Speller::value_op(
                    v->vtok,
                ) + " " + self._type(v->vops[1], subst, scope) + ")"
            } case ValueOp::Cast {
                return "static_cast<" + self._type(v->vty, subst, scope) + ">(" + self._type(
                    v->vops[0],
                    subst,
                    scope,
                ) + ")"
            } case ValueOp::Str {
                // The literal constructor over the bytes, as a compile-time
                // literal is built in a body (Compiler/Spec/Eval.md#strings-at-compile-time): `__kairo_estr<...>`
                // or, past the inline limit, the named array EmitPlan
                // collected (note_eval_str). One object per content, so two
                // spellings of one value are template-argument-equivalent.
                var n    = (v->vmag as usize)
                var data = ""
                var two = self._cg != &null
                    && self._cg->tu != &null
                    && self._cg->tu->global_scope != &null
                    && self._cg->tu->global_scope->well_known()->two_word()
                if two {
                    data = "::" + LowerTargets::lit_str(
                        LowerTargets::eval_str_hash(v->vbytes, n),
                        n,
                    ) + "." + LowerTargets::lit_str_bytes()
                } else if n > LowerTargets::eval_str_inline_max() {
                    data = "::" + LowerTargets::eval_str_hashed(
                        LowerTargets::eval_str_hash(v->vbytes, n),
                        n,
                    )
                } else {
                    data = "::" + LowerTargets::eval_str() + "<"
                    for var i: usize = 0; i < n; ++i {
                        if i > 0 {
                            data += ", "
                        }

                        data += f"{(v->vbytes[i] as u32)}"
                    }

                    data += ">"
                }

                var cp: usize = 0
                for var i: usize = 0; i < n; ++i {
                    if (v->vbytes[i] & (0xC0 as u8)) != (0x80 as u8) {
                        cp += 1
                    }
                }

                return self._type(
                    v->vty,
                    subst,
                    scope,
                ) + "(" + data + ", " + f"{n}" + ", " + f"{cp}" + ")"
            } default {
                return ""
            }
        }
    }

    /// The C++ operator for a computed value's binary operator; Kairo's
    /// keyword forms were normalized to these by TypeResolve.
    static fn value_op(k: TokenKind) -> string {
        match k {
            case TokenKind::OpPlus,           TokenKind::OpMinus,   TokenKind::OpStar,
                 TokenKind::OpSlash,          TokenKind::OpPercent, TokenKind::OpPipe,
                 TokenKind::OpAmp,            TokenKind::OpCaret,   TokenKind::OpLessLess,
                 TokenKind::OpGreaterGreater {
                return OperatorFacts::cxx_symbol(k)
            } default {
                return "?"
            }
        }
    }

    /// `R(A...)`, the function type a `fn(A) -> R` value wraps: each
    /// parameter in its mode's abstract spelling, `!` as `void`.
    fn fn_signature(self,
                    f:     unsafe *FunctionPointerType,
                    subst: unsafe *InstanceEntry = &null,
                    scope: unsafe *Decl = &null) -> string {
        var ps = ""
        for var i: usize = 0; i < f->params.size(); ++i {
            if i > 0 {
                ps += ", "
            }

            ps += self._param_type(
                f->params[i],
                f->modes[i],
                false,
                "",
                subst,
                scope,
            )
        }

        // A panicking `fn` type's value returns its panic result (§4.1).
        var unsafe *canon = if (f->canonical != &null
                                && isa<FunctionPointerType>(
                                    canon_unqual(f->canonical),
                                )) => (cast<FunctionPointerType>(
                                canon_unqual(f->canonical),
                            ))
                            else => f
        if canon->panic_result != &null {
            return self.decl(canon->panic_result, f"({ps})", subst, scope)
        }

        return self.decl(f->return_type, f"({ps})", subst, scope)
    }

    /// A parameter's C++ type from its mode (AST/ParamMode.k rules, as
    /// EmitIR documents them). \p is_const is the `const x: T` marker.
    fn param_type(self,
                  p:     unsafe *Declarations::ParamDecl,
                  subst: unsafe *InstanceEntry = &null,
                  scope: unsafe *Decl = &null) -> string {
        // A type pack is `T...` (the C++ parameter pack); under an instance it
        // is that instance's elements, one parameter each.
        if DeclFacts::param_is_type_pack(p) {
            var unsafe *g = DeclFacts::param_type_pack_param(p)
            var        cq = if (p->is_const) => ("const ") else => ""
            // A by-value (or `@move`) pack is `T&&... xs`: each layer
            // binds its caller's object instead of copying it, and an
            // expansion forwards it on (EmitIR::_pack_expansion). The
            // instance's elements are value types, so under one each is
            // `E&&` and the caller hands it an rvalue (EmitIR::_args).
            var rr  = if (Speller::forwarding_pack(p)) => ("&&") else => ""
            var els = cxx::std::vector<unsafe *Type>()
            if self.subst_pack(g, subst, &els) {
                var ps = ""
                for var i: usize = 0; i < els.size(); ++i {
                    if i > 0 {
                        ps += ", "
                    }

                    var unsafe *e = canon_unqual(els[i])
                    var        er = rr
                    if e != &null && (isa<CXXLValueRefType>(e) || isa<CXXRValueRefType>(e)) {
                        er = ""
                    }

                    ps += cq + self._type(els[i], &null, scope) + er
                }

                return ps
            }

            return cq + self._gparam(g, &null, rr)
        }

        if p->is_pack {
            if p->pack_type == &null {
                self._ice(
                    p->range,
                    "CXXSpell: pack parameter with no slice type; CallLowering stamps it",
                )
            }

            return (if (p->is_const) => ("const ") else => "") + self._type(
                p->pack_type,
                subst,
                scope,
            )
        }

        return self._param_type(
            p->type_,
            p->mode,
            Speller::const_param(p),
            "",
            subst,
            scope,
        )
    }

    /// The parameter is spelled as a `const` one: written `const x: T`, or a
    /// by-value COPY record its function never mutates
    /// (ParamPassInference). Only a record is ever inferred, so an inferred
    /// one always takes _param_type's `const T&` arm; a written `const` on a
    /// scalar stays `const T`.
    static fn const_param(p: unsafe *Declarations::ParamDecl) -> bool {
        return p != &null && (p->is_const || p->inferred_const)
    }

    /// A by-value parameter of \p f that C++ declares as a reference,
    /// `const T&` (a concrete record, `const` or inferred): its `fn` type's
    /// by-value parameter is a different C++ type, so a `fn` value of \p f
    /// goes through an adapter (EmitIR::_fn_ref_adapter).
    static fn by_ref_value_param(p: unsafe *Declarations::ParamDecl) -> bool {
        if p == &null || p->is_self || p->is_pack || p->mode != ParamMode::Value {
            return false
        }

        if !Speller::const_param(p) {
            return false
        }

        if p->type_ == &null || p->type_->canonical == &null {
            return false
        }

        var unsafe *c = p->type_->canonical
        return c->kind == TypeKind::RecordType && !c->is_dependent()
    }

    /// `type name` for a parameter, name folded into the declarator for
    /// EVERY type, never `param_type(p) + " " + name`: a function pointer
    /// spelled that way is `U(*)(T) f`, which clang reads as a cast-like
    /// expression ("expected ')'", "undeclared identifier 'f'"); the name
    /// belongs inside, `U (*f)(T)`. An array is still its own branch:
    /// `[T; N]` is passed by reference (`const T (&xs)[N]` / `T (&xs)[N]`),
    /// never by value (StmtTyping rejects that). Empty \p name is the
    /// abstract form. \p scope as for _type.
    fn param_decl(self,
                  p:          unsafe *Declarations::ParamDecl,
                  const name: string,
                  subst:      unsafe *InstanceEntry = &null,
                  scope:      unsafe *Decl = &null) -> string {
        var unsafe *c = if (p->type_ != &null) => (p->type_->canonical) else => &null
        if !p->is_pack && c != &null && canon_unqual(c)->kind == TypeKind::FixedArrayType {
            if p->mode == ParamMode::Value && !p->is_const {
                self._ice(
                    p->range,
                    "CXXSpell: array parameter by value; StmtTyping must reject it",
                )
            }

            var s = self.decl(canon_unqual(c), "&" + name, subst, scope)
            return (if (p->is_const) => ("const " + s) else => s)
        }

        if p->is_pack {
            var s = self.param_type(p, subst, scope)
            if name.size() > 0 {
                s += " " + name
            }

            return s
        }

        return self._param_type(
            p->type_,
            p->mode,
            Speller::const_param(p),
            name,
            subst,
            scope,
        )
    }

    /// The mode's reference and the const marker folded into decl(), so a
    /// name lands inside the declarator: `@inout` on a function pointer is
    /// `U (*&f)(T)`, which decl() brackets as it does any `*`/`&` declarator.
    /// A `fn` type's parameter \p t in mode \p mode, declared as \p name
    /// (a wrapper lambda's parameter, EmitIR::_fn_effect_value).
    fn param_named(self, t: unsafe *Type, mode: ParamMode, const name: string) -> string {
        return self._param_type(t, mode, false, name, &null, &null)
    }

    /// A closure's parameter \p p, declared as \p name. The `fn` value is
    /// built from the lambda's own function pointer, so the lambda's C++
    /// function type is the one its `fn` type spells (fn_signature): each
    /// parameter is that type's parameter for its mode, and a written
    /// `const` qualifies the parameter itself, which C++ leaves out of the
    /// function type.
    fn closure_param(self, p: unsafe *Declarations::ParamDecl, const name: string) -> string {
        if p->is_pack || DeclFacts::param_is_type_pack(p) {
            return self.param_decl(p, name)
        }

        return self._param_type(
            p->type_,
            p->mode,
            p->is_const,
            name,
            &null,
            &null,
            true,
        )
    }

    /// \p t in mode \p mode, declared as \p name: the one spelling of a
    /// parameter, for a declaration, a `fn` type and a closure alike.
    /// \p is_const is the `const x: T` marker; with \p fn_param it stays
    /// on the parameter (a closure's, whose type is its `fn` type's), and
    /// without it a record or a type parameter is passed as `const T&`.
    priv fn _param_type(self,
                        t:          unsafe *Type,
                        mode:       ParamMode,
                        is_const:   bool,
                        const name: string,
                        subst:      unsafe *InstanceEntry,
                        scope:      unsafe *Decl,
                        fn_param:   bool = false) -> string {
        // `[T; N]` is never passed by value: a Value-mode array is a
        // `const` parameter's reference, in a `fn` type as in param_decl.
        if mode == ParamMode::Value && t != &null && t->canonical != &null {
            var unsafe *ac = canon_unqual(t->canonical)
            if ac != &null && ac->kind == TypeKind::FixedArrayType {
                return "const " + self.decl(ac, "&" + name, subst, scope)
            }
        }

        // `const T&` only from a stamped `@copy fn X(self, const other: Self)`
        // (ClassLifecycle); nothing else sets Inout together with `const`.
        if mode == ParamMode::Inout {
            var s = self.decl(t, self._ref_declarator("&", name), subst, scope)
            return if (is_const) => ("const " + s) else => s
        }

        if mode == ParamMode::Move {
            return self.decl(t, self._ref_declarator("&&", name), subst, scope)
        }

        if is_const && fn_param {
            // After the `*` for a pointer (`T *const p`): a prefix would
            // make the pointee const and change the function type.
            var unsafe *pc = t->canonical
            if pc != &null && pc->kind == TypeKind::PointerType {
                return self.decl(
                    t,
                    if (name.size() > 0) => ("const " + name) else => "const",
                    subst,
                    scope,
                )
            }

            return "const " + self.decl(t, name, subst, scope)
        }

        if is_const {
            // `T const&` for a bare type parameter (it may be a record: a
            // `const k: K` lookup in a `{K: V}` must not copy a string key
            // per call), `const T&` for a record, `const T` otherwise.
            var unsafe *c = t->canonical
            // East const for the parameter: an instance's explicit
            // instantiation spells T as text (`int *`), and `const int *&`
            // would be a reference to a pointer to const, not `T const&`.
            if c != &null
                && c->kind == TypeKind::GenericParamType
                && !cast<GenericParamType>(c)->is_pack {
                return self.decl(
                    t,
                    self._ref_declarator(
                        if (self._subst_is_const(t, subst)) => ("&") else => "const&",
                        name,
                    ),
                    subst,
                    scope,
                )
            }

            // A generic record's own instance type (`const other: Q<T>`) is a
            // record in every instance, so it is `const Q<T>&` as well: by
            // value, a move-only Q (an ArenaList field) could not be passed
            // at all.
            if c != &null && c->kind == TypeKind::RecordType {
                return "const " + self.decl(
                    t,
                    self._ref_declarator("&", name),
                    subst,
                    scope,
                )
            }

            return "const " + self.decl(t, name, subst, scope)
        }

        return self.decl(t, name, subst, scope)
    }

    /// `& name`, keeping the `T& x` spelling the printed C++ has always had
    /// (and that tests match); bare `&` for the abstract form.
    /// \p t is a type parameter that \p subst binds to a const type, so a
    /// `const` written on it in the pattern is already in its spelling.
    priv fn _subst_is_const(self, t: unsafe *Type, subst: unsafe *InstanceEntry) -> bool {
        if t == &null || subst == &null || t->canonical == &null {
            return false
        }

        var unsafe *g = dyn_cast<GenericParamType>(t->canonical)
        if g == &null || g->is_pack {
            return false
        }

        var unsafe *b = self.subst_for(g, subst)
        return b != &null && b->canonical != &null && canon_has_const(b->canonical)
    }

    priv fn _ref_declarator(self, sigil: string, const name: string) -> string {
        if name.size() == 0 {
            return sigil
        }

        return sigil + " " + name
    }

    /// `<a, b>` from an instance's args or a pattern's own params.
    /// The fixed-width builtin \p k IS in C++ on this target: `usize` /
    /// `isize` become the integer of the pointer width where the target
    /// says size_t / ptrdiff_t is it (target.usize_is_fixed, as RedeclMerge
    /// and PanicTypeIds read it); \p k itself otherwise, and on Darwin,
    /// where they are C++ types of their own. An unfilled invocation is the
    /// 64-bit host.
    fn size_fold(self, k: BuiltinKind) -> BuiltinKind {
        if k != BuiltinKind::USize && k != BuiltinKind::ISize {
            return k
        }

        var        sgn         = k == BuiltinKind::ISize
        var        fixed       = true
        var        pw:   usize = 64
        var unsafe *ci         = self._cg->ctx->ci
        if ci != &null {
            fixed = if (sgn) => (ci->target.isize_is_fixed) else => ci->target.usize_is_fixed
            if ci->target.pointer_width != (0 as usize) {
                pw = ci->target.pointer_width
            }
        }

        if !fixed {
            return k
        }

        if pw == (16 as usize) {
            return if (sgn) => (BuiltinKind::I16) else => BuiltinKind::U16
        }

        if pw == (32 as usize) {
            return if (sgn) => (BuiltinKind::I32) else => BuiltinKind::U32
        }

        if pw == (64 as usize) {
            return if (sgn) => (BuiltinKind::I64) else => BuiltinKind::U64
        }

        return k
    }

    fn args_str(self,
                const args: cxx::std::vector<unsafe *Type>,
                subst:      unsafe *InstanceEntry = &null,
                scope:      unsafe *Decl = &null) -> string {
        var s = "<"
        for var i: usize = 0; i < args.size(); ++i {
            if i > 0 {
                s += ", "
            }

            s += self._type((args)[i], subst, scope)
        }

        s += ">"
        return s
    }

    /// # Dependent-qualified names

    /// `Q::leaf`, a member type named through the record type \p record:
    /// `typename Q::leaf` when Q is dependent, and with \p args
    /// `typename Q::template leaf<args>`. This is the one place a member of
    /// a dependent type is spelled; a nested type of a generic record, an
    /// associated type (`T::Bar`), a generic associated type
    /// (`T::Bar<U>`) and a member-template call (`x.template f<U>()`) are
    /// all the same C++ rule -- inside a template, a name qualified by a
    /// dependent type is assumed to be neither a type nor a template unless
    /// it says so -- and spelling it twice is how the two copies drift.
    ///
    /// A non-dependent Q drops both keywords. C++ allows them there, but Q is
    /// then a concrete class whose members are looked up at once, so they
    /// say nothing. \p subst and \p scope are passed through to Q's spelling
    /// and to \p args. Q's top-level cv is dropped: it qualifies the object,
    /// not the scope a member is named from.
    fn dependent_member_type(self,
                             record:     unsafe *Type,
                             const leaf: string,
                             args:       unsafe *cxx::std::vector<unsafe *Type> = &null,
                             subst:      unsafe *InstanceEntry = &null,
                             scope:      unsafe *Decl = &null) -> string {
        if record == &null || record->canonical == &null {
            kairo::std::ice_fail(
                "CXXSpell: dependent_member_type with no canonical qualifier",
            )
        }

        var unsafe *q    = canon_unqual(record->canonical)
        var        targs = ""
        if args != &null && args->size() > 0 {
            targs = self.args_str(*args, subst, scope)
        }

        return Speller::_member_type(
            self._type(q, subst, scope),
            q->is_dependent(),
            leaf,
            targs,
        )
    }

    /// \p t names an associated type anywhere inside it (`Self::Node`,
    /// `[Self::Node]`): a witness member whose signature does is served by
    /// the specializations alone (EmitWitness).
    static fn mentions_assoc(t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        match c->kind {
            case TypeKind::AssocType {
                return true
            } case TypeKind::QualifiedType {
                return Speller::mentions_assoc(cast<QualifiedType>(c)->inner)
            } case TypeKind::PointerType {
                return Speller::mentions_assoc(cast<PointerType>(c)->pointee)
            } case TypeKind::NullableType {
                return Speller::mentions_assoc(cast<NullableType>(c)->inner)
            } case TypeKind::FixedArrayType {
                return Speller::mentions_assoc(cast<FixedArrayType>(c)->element)
            } case TypeKind::CXXLValueRefType {
                return Speller::mentions_assoc(
                    cast<CXXLValueRefType>(c)->referee,
                )
            } case TypeKind::CXXRValueRefType {
                return Speller::mentions_assoc(
                    cast<CXXRValueRefType>(c)->referee,
                )
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                for var i: usize = 0; i < r->args.size(); ++i {
                    if Speller::mentions_assoc(*r->args.get(i)) {
                        return true
                    }
                }

                return false
            } case TypeKind::FunctionPointerType {
                var unsafe *f = cast<FunctionPointerType>(c)
                for var i: usize = 0; i < f->params.size(); ++i {
                    if Speller::mentions_assoc(*f->params.get(i)) {
                        return true
                    }
                }

                return Speller::mentions_assoc(f->return_type)
            } default {
                return false
            }
        }
    }

    /// \p t names an interface record anywhere inside it: the `Self` of a
    /// requirement's signature (`-> Self?` is `Null<Self>`). Only a witness
    /// spells it, with the conforming type in its place.
    static fn mentions_iface_self(t: unsafe *Type) -> bool {
        if t == &null {
            return false
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        match c->kind {
            case TypeKind::QualifiedType {
                return Speller::mentions_iface_self(
                    cast<QualifiedType>(c)->inner,
                )
            } case TypeKind::PointerType {
                return Speller::mentions_iface_self(
                    cast<PointerType>(c)->pointee,
                )
            } case TypeKind::NullableType {
                return Speller::mentions_iface_self(
                    cast<NullableType>(c)->inner,
                )
            } case TypeKind::FixedArrayType {
                return Speller::mentions_iface_self(
                    cast<FixedArrayType>(c)->element,
                )
            } case TypeKind::CXXLValueRefType {
                return Speller::mentions_iface_self(
                    cast<CXXLValueRefType>(c)->referee,
                )
            } case TypeKind::CXXRValueRefType {
                return Speller::mentions_iface_self(
                    cast<CXXRValueRefType>(c)->referee,
                )
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                if r->decl != &null && isa<Declarations::InterfaceDecl>(r->decl) {
                    return true
                }

                for var i: usize = 0; i < r->args.size(); ++i {
                    if Speller::mentions_iface_self(*r->args.get(i)) {
                        return true
                    }
                }

                return false
            } case TypeKind::FunctionPointerType {
                var unsafe *f = cast<FunctionPointerType>(c)
                for var i: usize = 0; i < f->params.size(); ++i {
                    if Speller::mentions_iface_self(*f->params.get(i)) {
                        return true
                    }
                }

                return Speller::mentions_iface_self(f->return_type)
            } default {
                return false
            }
        }
    }

    /// The text of dependent_member_type from an already-spelled qualifier.
    static fn _member_type(const q:     string,
                           dependent:   bool,
                           const leaf:  string,
                           const targs: string) -> string {
        if !dependent {
            return q + "::" + leaf + targs
        }

        if targs.size() == 0 {
            return "typename " + q + "::" + leaf
        }

        return "typename " + q + "::template " + leaf + targs
    }

    /// \p d's C++ template parameters: an extension member's extension's,
    /// then its own. One list; a non-member function takes one.
    static fn template_params(d: unsafe *Decl) -> cxx::std::vector<unsafe *Declarations::GenericParamDecl> {
        var out = cxx::std::vector<unsafe *Declarations::GenericParamDecl>()
        var unsafe *ext = DeclFacts::decl_extension_of(d)
        if ext != &null {
            var eps = DeclFacts::decl_generic_params(
                unsafe (ext as unsafe *Decl),
            )

            for var i: usize = 0; i < eps.size(); ++i {
                out.push_back(eps[i])
            }
        }

        var gps = DeclFacts::decl_generic_params(d)
        for var i: usize = 0; i < gps.size(); ++i {
            out.push_back(gps[i])
        }

        return out
    }

    /// The instance argument \p g stands for in \p subst, or null. Keyed on
    /// the GenericParamDecl's identity in the primary's template_params, so
    /// an extension's T, a member's own U and a default thunk's borrowed
    /// list (the callee's GenericParamDecls) all resolve the same way.
    /// A pack parameter's elements under \p subst, appended to \p out: every
    /// instance argument from the pack's position on (InstanceEntry::args
    /// keeps packs flat, so the pack is the tail). False when \p subst does
    /// not bind \p g.
    fn subst_pack(self,
                  g:          unsafe *GenericParamType,
                  subst:      unsafe *InstanceEntry,
                  @inout out: cxx::std::vector<unsafe *Type>) -> bool {
        if g == &null || g->owner == &null || subst == &null || !g->is_pack {
            return false
        }

        var own = DeclFacts::decl_generic_params(Speller::rep(g->owner))
        var idx = (g->param_index as usize)
        if idx >= own.size() {
            return false
        }

        var unsafe *gp = own[idx]
        var        tps = Speller::template_params(Speller::rep(subst->primary))
        for var k: usize = 0; k < tps.size(); ++k {
            if tps[k] != gp {
                continue
            }

            for var j: usize = k; j < subst->args.size(); ++j {
                out.push_back(subst->args[j])
            }

            return true
        }

        return false
    }

    fn subst_for(self, g: unsafe *GenericParamType, subst: unsafe *InstanceEntry) -> unsafe *Type {
        if g == &null || g->owner == &null || subst == &null {
            return &null
        }

        var own = DeclFacts::decl_generic_params(Speller::rep(g->owner))
        var idx = (g->param_index as usize)
        if idx >= own.size() {
            return &null
        }

        var unsafe *gp = own[idx]
        var        tps = Speller::template_params(Speller::rep(subst->primary))
        for var k: usize = 0; k < tps.size(); ++k {
            if tps[k] != gp {
                continue
            }

            if k >= subst->args.size() {
                kairo::std::ice_fail(
                    "CXXSpell: instance args shorter than the primary's template parameters",
                )
            }

            return subst->args[k]
        }

        return &null
    }

    /// An extension member's receiver parameter, unnamed: `[const ]X*`, or
    /// `[const ]X&` for an operator ([over.oper]/7 wants a class type).
    fn ext_receiver(self,
                    f:     unsafe *Declarations::FunctionDecl,
                    x:     unsafe *Declarations::ExtensionDecl,
                    subst: unsafe *InstanceEntry = &null) -> string {
        var s = ""
        if f->is_const() {
            s += "const "
        }

        // A C array's declarator wraps the name (`int (*self)[2]`), and every
        // caller appends the name after this text (`extend [i32; 2]`).
        s += self.type_specifier(x->target, subst)
        s += if (f->is_operator) => ("&") else => "*"
        return s
    }
}
