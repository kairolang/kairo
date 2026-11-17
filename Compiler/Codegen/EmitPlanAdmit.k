/// --- The Kairo Project ---------------------- Codegen/EmitPlanAdmit.k --- ///
///
///   EmitPlan, part: the working set. Admitting a declaration, a type or an
///   instance at a strength, and the closure: expanding what is admitted into
///   what its signature, members, bases and extensions need.
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
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::Context::DeclContext::DeclContext
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::DeclFacts
import AST::Kind::DeclKind::DeclKind
import AST::Kind::TypeKind::TypeKind
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    BuiltinKind,
    BuiltinType,
    QualifiedType,
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Program::TopLevelKind
import AST::Node::Types::{
    CXXLValueRefType, CXXRValueRefType, FixedArrayType, FunctionPointerType, NullableType,
    PointerType,      TypeExpr,         ValueOp,
}
import Codegen::Emit::Spell::Speller
import Codegen::EmitPlan::{
    EmitPlan,
    PlanMode,
    PlanNeed,
    plan_under_duck,
}
import Codegen::EmitPlanEarly
import Codegen::EmitPlanFriends
import Codegen::EmitPlanLayout
import Codegen::EmitPlanRoots
import Codegen::EmitPlanWitness

extend EmitPlan {
    /// # The working set

    /// Everything funnels through here. Decides what is plannable, redirects
    /// instances to their primary and nested types to their outermost owner.
    fn _admit(self, d: unsafe *Decl, need: PlanNeed) {
        if d == &null {
            return
        }

        var unsafe *c = Speller::rep(d)
        if c == &null {
            return
        }

        // A record declared in a function body (FinallyLowering's guard) is part
        // of that body: EmitIR emits it in place, and nothing about it belongs
        // in the preamble or the header. Its fields' owner and its destructor
        // land here too and are skipped the same way.
        if Speller::in_function_scope(c) {
            return
        }

        // The header declares it (Compiler/Spec/Interop.md#ffi-imports) -- but an instance of an
        // imported C++ template is written out in THIS TU's text with its
        // arguments spelled whole (`std::vector<Loc::File::File *>`), so the
        // Kairo types they name must be declared here (_admit_instance).
        if DeclFacts::decl_is_imported(c) && !DeclFacts::decl_is_instance(c) {
            return
        }

        if DeclFacts::decl_ffi_tag_target(c) != &null { // `ffi "c" struct T`: the header's tag, not a Kairo type (§5.2).
            return
        }

        // An interface's C++ entity is its witness: named by a call through a
        // bound (_admit_use on the requirement), or by a bound's concept.
        if isa<Declarations::InterfaceDecl>(c) {
            self._witness_primary(c)
            return
        }

        // An extension member reached through a use (`l.pos.len()`) is not a
        // member by _member_owner, so without this it is admitted a second time
        // as an ordinary function; it is its scope's static member instead.
        var unsafe *x = DeclFacts::decl_extension_of(c)
        if x != &null {
            self._scope_for(x, true)
            return
        }

        if DeclFacts::decl_is_instance(c) {
            var unsafe *e = self._cg->instances->entry_of(c)
            if e == &null && DeclFacts::decl_is_imported(c) { // no registry entry: nothing of ours to name.
                return
            }

            if e == &null {
                self._ice(
                    c->range,
                    "EmitPlan: instance shell with no registry entry",
                )
            }

            self._admit_instance(e, need)
            return
        }

        if !self._plannable(c) {
            return
        }

        // A nested type is part of its outermost owner's definition.
        var unsafe *outer = self._outermost_type(c)
        if outer != c {
            self._admit(outer, need)
            return
        }

        // A payload struct is minted inside its ADT (its semantic_dc is the
        // enum), so the fold above always takes it to the enum, whose layout
        // record defines it. One planned here as a record of its own would be
        // defined twice -- inside the ADT and again beside it.
        var unsafe *ps = dyn_cast<Declarations::StructDecl>(c)
        if ps != &null && ps->is_adt_payload {
            self._ice(
                c->range,
                "EmitPlan: an ADT payload struct reached the plan as a record of its own; EnumLayoutLowering places it in its enum",
            )
        }

        var at = self._index_of(c)
        if at == usize::MAX {
            self._set_at.try_emplace(c as usize as u64, (self._set.size() as u64))
            self._set.push_back(c)
            self._need.push_back(need)
            self._decl_need.push_back(
                if (self._in_body) => (u8::MAX) else => (need as u8),
            )

            self._queue.push_back(self._set.size() - 1)
            self._admit_specs(c, need)
            return
        }

        // A declaration reaching what only a body reached before expands it
        // again, so what it needs is reached from the declarations too.
        var by_decl = !self._in_body
            && (self._decl_need[at] == u8::MAX || (need as u8) > self._decl_need[at])
        if by_decl {
            self._decl_need[at] = need as u8
        }

        if (need as u8) > (self._need[at] as u8) {
            self._need[at] = need
            self._queue.push_back(at)
            self._admit_specs(c, need)
        } else if by_decl {
            self._queue.push_back(at)
        }
    }

    /// `d` is in the set at Complete for the declarations themselves (a
    /// layout, a signature's default argument), not only for a body.
    fn decl_complete(self, d: unsafe *Decl) -> bool {
        var at = self._index_of(d)
        return at != usize::MAX && self._decl_need[at] == (PlanNeed::Complete as u8)
    }

    /// `d` is reached from the declarations at any strength.
    fn decl_reached(self, d: unsafe *Decl) -> bool {
        var at = self._index_of(d)
        return at != usize::MAX && self._decl_need[at] != u8::MAX
    }

    /// A generic record's specializations ride with it at the same strength:
    /// every C++ TU that can name `Store<X>` must have seen each `Store<P*>` /
    /// `Store<bool>` before the first use that would instantiate one, or it
    /// instantiates the primary for it ([temp.expl.spec]/7, no diagnostic
    /// required). A Complete primary admits them Complete so an instance
    /// selected into a partial is laid out by it.
    fn _admit_specs(self, c: unsafe *Decl, need: PlanNeed) {
        // A function specialization is declared after its primary, which a
        // file that specializes an imported one may otherwise never name.
        if Speller::is_fn_spec(c) {
            self._admit(
                Speller::rep(DeclFacts::decl_instantiated_from(c)),
                PlanNeed::Fwd,
            )

            return
        }

        // A class's methods' member specializations: the methods' bodies
        // call them (EmitIR::_member_spec_dispatch), so wherever the class
        // is, their scope structs are declared.
        self._admit_member_specs(c)
        if DeclFacts::decl_generic_params(c).size() == 0 || Speller::is_record_spec(c) {
            return
        }

        var specs = cxx::std::vector<unsafe *Decl>()
        // A generic function's explicit specializations, the same way: a
        // TU that declares `p` and calls `p<int>()` without having seen
        // `template <> int p<int>()` instantiates the primary's body. A
        // member's are declared by its owner's definition.
        if isa<Declarations::FunctionDecl>(c) {
            if c->semantic_dc == &null || c->semantic_dc->is_type_scope() {
                return
            }

            Speller::fn_specs_of(c, unsafe &specs, self._cg->instances)
            for var i: usize = 0; i < specs.size(); ++i {
                self._admit(specs[i], PlanNeed::Fwd)
            }

            return
        }

        self._cg->instances->specs_of(c, unsafe &specs)
        for var i: usize = 0; i < specs.size(); ++i {
            var unsafe *sd = Speller::rep(specs[i])
            if sd == &null || sd->is_poisoned() {
                continue
            }

            self._admit(sd, need)
        }
    }

    fn _admit_member_specs(self, c: unsafe *Decl) {
        var unsafe *cd = dyn_cast<Declarations::ClassDecl>(c)
        if cd == &null {
            return
        }

        for var i: usize = 0; i < cd->methods.size(); ++i {
            var unsafe *m = cd->methods[i]
            if m == &null
                || m->generic_params.size() == 0 && DeclFacts::decl_generic_params(c).size() == 0 {
                continue
            }

            var ms = cxx::std::vector<unsafe *Decl>()
            Speller::member_specs_of(
                unsafe (m as unsafe *Decl),
                unsafe &ms,
                self._cg->instances,
            )

            for var k: usize = 0; k < ms.size(); ++k {
                self._admit(ms[k], PlanNeed::Fwd)
            }
        }
    }

    /// `Box<Foo>`: the primary at `need`, each argument at `need` only
    /// where the primary stores it by value, else Fwd; the instance itself
    /// recorded for tier 3.
    fn _admit_instance(self, e: unsafe *InstanceEntry, need: PlanNeed) {
        var unsafe *prim = Speller::rep(e->primary)
        // clang instantiates it from the PCH, but its arguments are spelled in
        // THIS TU's text: `std::vector<Loc::File::File *>` in a foreign class's
        // field needs `File` declared here, or the qualified name does not
        // resolve. Naming the instance asks only Fwd of them; an instance held
        // at Complete is one whose members this TU instantiates -- the
        // destructor an owner's implicit one calls, size(), the allocator's
        // sizeof -- and every one of those needs a by-value argument complete.
        // _admit_type still weakens an argument behind a pointer
        // (`vector<File *>`) to Fwd. Strength only: definition order is the
        // layout's (_needs_complete), which a template argument never is.
        //
        // An imported FUNCTION template (`kairo::std::create<T>(a)`, which is
        // `new T(a)`) is instantiated in this TU at its arguments whatever the
        // call's strength, so each is complete (O36b), as a Kairo one's is below.
        if DeclFacts::decl_is_imported(prim) {
            var imp_need = if (isa<Declarations::FunctionDecl>(prim)) => (PlanNeed::Complete)
                           else => need
            for var i: usize = 0; i < e->args.size(); ++i {
                self._admit_type(e->args[i], imp_need)
            }

            self._std_hash(prim, e)
            return
        }

        // A `<T: type>` instance (O36b): its body is checked by C++ alone, and a
        // chain through T (`self.dyn()->sc->g->is_builtin_fid(...)`) is spelled
        // as written, untyped, so no node names the classes it walks through.
        // The C++ that instantiates the body here needs every one complete:
        // what an argument reaches through its fields and method results.
        // A header carries no body of a foreign instance, and the wider
        // closure would only turn its forward declarations into includes.
        if self._mode != PlanMode::Header && plan_under_duck(prim) {
            for var i: usize = 0; i < e->args.size(); ++i {
                self._duck_reach(e->args[i], 0)
            }
        }

        // A generic REQUIREMENT's instance names no C++ function: the call goes
        // through the witness's member template, instantiated implicitly. No
        // tier-3 line, ever (Compiler/Spec/Witnesses.md#rows-instances-and-odr); its arguments are still named.
        if self._is_requirement(prim) {
            for var i: usize = 0; i < e->args.size(); ++i {
                self._admit_type(e->args[i], PlanNeed::Fwd)
            }

            return
        }

        // A member template of a CLASS TEMPLATE: the entry holds the member's own
        // arguments only, not the owner's, so it names no one C++ entity
        // (`Box<A>::both<X>` and `Box<B>::both<X>` are one entry) and no tier-3
        // line can spell it. Its body is visible wherever the owner is complete
        // (§7), so the C++ instantiates it implicitly; its rows still apply.
        if self._member_of_template(prim) {
            for var i: usize = 0; i < e->rows.size(); ++i {
                self._witness_row(e->rows[i])
            }

            for var i: usize = 0; i < e->args.size(); ++i {
                self._admit_type(e->args[i], PlanNeed::Fwd)
            }

            // Its body is compiled wherever the owner is, so what it reaches is
            // needed there too, rows included (no tier-3 line of its own).
            var mseen = false
            for var i: usize = 0; i < self._members.size(); ++i {
                if self._members[i] == e {
                    mseen = true
                    break
                }
            }

            if !mseen {
                self._members.push_back(e)
                self._admit_reached(e)
                for var i: usize = 0; i < e->panic_types.size(); ++i {
                    self._admit_type(e->panic_types[i], PlanNeed::Complete)
                }
            }

            return
        }

        // An argument that holds an interface's own Self (`-> Self?` in a
        // requirement is `Null<Self>`) names no C++ type here: the witness
        // spells the instance with the conforming type in its place.
        for var i: usize = 0; i < e->args.size(); ++i {
            if Speller::mentions_iface_self(e->args[i]) {
                // The template itself is still named by that witness.
                self._admit(prim, PlanNeed::Complete)
                return
            }
        }

        if self._inst_seen.insert(e as usize as u64).second {
            self._insts.push_back(e)
            self._admit_reached(e)
            // The panic results its body names at these arguments (Compiler/Spec/Panic.md,
            // InstanceEntry::panic_types): C++ forms them only when it
            // instantiates the body, so their elements' ids must be written
            // wherever it may.
            for var i: usize = 0; i < e->panic_types.size(); ++i {
                self._admit_type(e->panic_types[i], PlanNeed::Complete)
            }
        }

        self._admit(prim, PlanNeed::Complete)
        // Every TU holding the instance may compile its body (it is a visible
        // C++ inline body), so every one needs the specializations its bounds
        // bind, or it compiles the primary instead (Compiler/Spec/Witnesses.md#emission).
        for var i: usize = 0; i < e->rows.size(); ++i {
            self._witness_row(e->rows[i])
        }

        // A panic result's elements are complete wherever it is named, even
        // where a declaration only names it (a header's `Panic<T, E...> f()`):
        // its tier-3 line asserts its size, and a C++ caller receives it by
        // value and reads its error (Compiler/Spec/Panic.md#the-c-view).
        var unsafe *en   = dyn_cast<Declarations::EnumDecl>(prim)
        var        whole = en != &null && en->adt_explicit_tags
        // A FUNCTION template is instantiated here at its arguments -- its
        // tier-3 line in the home TU, implicitly in any TU that sees the body
        // -- and a `<T: type>` body may do anything with T (`T::classof(p)`
        // in Casting's isa): each argument is complete, a pointer one at Fwd
        // as _admit_type has it. A record's argument is held as its
        // layout says.
        var fn_inst = isa<Declarations::FunctionDecl>(prim)
        for var i: usize = 0; i < e->args.size(); ++i {
            var n = if (whole || fn_inst) => (PlanNeed::Complete) else => need
            if !fn_inst && !self._arg_by_value(prim, i) {
                n = PlanNeed::Fwd
            }

            self._admit_type(e->args[i], n)
        }

        // Laid out by a partial specialization: what IT holds by value is what
        // the instance needs complete, read off its own parameters' bindings.
        if e->pattern != &null {
            var unsafe *part = Speller::rep(e->pattern)
            for var i: usize = 0; i < e->pattern_args.size(); ++i {
                if self.param_by_value(part, i as u32) {
                    self._admit_type(e->pattern_args[i], need)
                }
            }
        }
    }

    /// Follow a type to the records it needs at the strength the SHAPE
    /// dictates: an indirection weakens to Fwd, the by-value spine keeps
    /// `need`.
    fn _admit_type(self, t: unsafe *Type, need: PlanNeed) {
        if t == &null {
            return
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        match c->kind {
            case TypeKind::QualifiedType {
                self._admit_type(cast<QualifiedType>(c)->inner, need)
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                var unsafe *d = Speller::rep(r->decl)
                // Naming `L<i32>::P` at all -- through a pointer too -- looks P
                // up inside L<i32>, which C++ must have instantiated.
                if r->outer != &null {
                    self._admit_type(r->outer, PlanNeed::Complete)
                }

                if d != &null && DeclFacts::decl_is_instance(d) {
                    self._admit(d, need) // _admit_instance handles the args.
                } else {
                    self._admit(d, need)
                    // `Outer::Inner` spelled anywhere -- behind a pointer or as an
                    // argument a template holds only by pointer (`FrozenList<
                    // ChainType::GenericArg>`) -- is a nested-name-specifier: C++
                    // needs Outer complete, whatever the layout needs of Inner.
                    if d != &null && d->semantic_dc != &null {
                        var unsafe *own = self._outermost_type(d)
                        if own != d {
                            self._admit(own, PlanNeed::Complete)
                        }
                    }

                    for var i: usize = 0; i < r->args.size(); ++i {
                        var n = need
                        if !self._arg_by_value(d, i) {
                            n = PlanNeed::Fwd
                        }

                        self._admit_type(*r->args.get(i), n)
                    }
                }
            } case TypeKind::PointerType {
                self._admit_type(cast<PointerType>(c)->pointee, PlanNeed::Fwd)
            } case TypeKind::CXXLValueRefType {
                self._admit_type(
                    cast<CXXLValueRefType>(c)->referee,
                    PlanNeed::Fwd,
                )
            } case TypeKind::CXXRValueRefType {
                self._admit_type(
                    cast<CXXRValueRefType>(c)->referee,
                    PlanNeed::Fwd,
                )
            }

            // `T?` is its record to C++ (NullableTypeLowering), held by value.
            case TypeKind::NullableType {
                self._admit_type(self._nullable_record(c), need)
            }

            // No Vector/Set/Map/Tuple arms: they are RecordTypes and admit
            // through the record path, which already walks their generic
            // arguments (a tuple's elements are by value, so at `need`).
            case TypeKind::FixedArrayType {
                self._admit_type(cast<FixedArrayType>(c)->element, need)
                self._admit_type(
                    cast<FixedArrayType>(c)->extent_param,
                    PlanNeed::Fwd,
                )
            }

            // A computed value (Compiler/Spec/Eval.md#value-nodes) names what C++ computes it from:
            // the eval fn it calls (consteval, so its body comes too), the eval
            // constant it reads (its definition comes too, visible_eval_vars),
            // a cast's type.
            case TypeKind::TypeExpr {
                var unsafe *v = cast<TypeExpr>(c)
                if !v->is_value || v->is_exact() {
                    return
                }

                // A string (Compiler/Spec/Eval.md#eval-classes): the string record is constructed right
                // in the argument, over `__kairo_estr<...>` or a named array.
                if v->vop == ValueOp::Str {
                    self.needs_eval_str = true
                    self._admit_type(v->vty, PlanNeed::Complete)
                    if self._cg->tu != &null
                        && self._cg->tu->global_scope != &null
                        && self._cg->tu->global_scope->well_known()->two_word() {
                        self.note_lit_str(v->vbytes, v->vmag as usize)
                    } else {
                        self.note_eval_str(v->vbytes, v->vmag as usize)
                    }

                    return
                }

                // Not an `eval for` binding: a local, declared where it stands.
                var local = v->vdecl != &null
                    && (v->vdecl->semantic_dc == &null || Speller::in_function_scope(v->vdecl))
                if v->vdecl != &null && !local {
                    self._admit_use(v->vdecl)
                }

                if v->vty != &null {
                    self._admit_type(v->vty, PlanNeed::Fwd)
                }

                for var i: usize = 0; i < v->vops.size(); ++i {
                    self._admit_type(v->vops[i], PlanNeed::Fwd)
                }
            } case TypeKind::FunctionPointerType {
                var unsafe *f = cast<FunctionPointerType>(c)
                if !f->is_unprototyped {
                    self.needs_fn_value = true
                }

                for var i: usize = 0; i < f->params.size(); ++i {
                    self._admit_type(*f->params.get(i), PlanNeed::Fwd)
                }

                self._admit_type(f->return_type, PlanNeed::Fwd)
                self._admit_type(f->panic_result, PlanNeed::Complete) // its value returns this (Compiler/Spec/Panic.md#paniclowering).
            }

            // `T::Node` names the bound's witness (its member type) and T.
            case TypeKind::AssocType {
                var unsafe *a = cast<AssocType>(c)
                self._admit_type(a->base, PlanNeed::Fwd)
                for var i: usize = 0; i < a->args.size(); ++i {
                    self._admit_type(a->args[i], PlanNeed::Fwd)
                }

                var unsafe *ic = canon_unqual(a->iface)
                if ic != &null && isa<RecordType>(ic) {
                    self._admit(cast<RecordType>(ic)->decl, PlanNeed::Complete)
                }
            } case TypeKind::BuiltinType {
                // A builtin spelled as a Kairo declaration (`byte` -> Byte): an
                // opaque `enum class : unsigned char;` is already complete, so
                // any strength will do. f256 / f512 / f8e4m3 / f8e5m2 are
                // classes whose members C++ calls where Kairo sees a builtin
                // operator (`a + b`), and nothing else admits those: always
                // the complete class.
                var unsafe *bt = cast<BuiltinType>(c)
                if bt->lang_decl != &null {
                    var bneed = need
                    if bt->builtin != BuiltinKind::Byte {
                        bneed = PlanNeed::Complete
                    }

                    self._admit(bt->lang_decl, bneed)
                }
            } default { } // generic param, opaque: nothing to declare.
        }
    }

    /// # Closure

    fn _close(self) {
        var outer = self._in_body
        while self._queue.size() > 0 {
            var at = self._queue[self._queue.size() - 1]
            self._queue.pop_back()
            self._in_body = outer
                || self._decl_need[at] == u8::MAX
                || self._decl_need[at] < (self._need[at] as u8)
            self._expand(self._set[(at)], self._need[(at)])
        }

        self._in_body = outer
    }

    fn _expand(self, d: unsafe *Decl, need: PlanNeed) {
        if isa<Declarations::FunctionDecl>(d) {
            self._expand_fn(cast<Declarations::FunctionDecl>(d))
            return
        }

        // `extern T x;` only names T; the defining TU's own walk (visit_decl)
        // asks for Complete where the definition lays it out.
        if isa<Declarations::VariableDecl>(d) {
            self._admit_type(
                cast<Declarations::VariableDecl>(d)->type_,
                PlanNeed::Fwd,
            )

            return
        }

        // A bounded record's head carries its concepts, and even its tier-0
        // forward declaration is a head: at any strength.
        self._witness_bounds(d)
        // So is a value parameter's class (Compiler/Spec/Eval.md#eval-classes): C++ needs it complete
        // at the forward declaration too (InterfaceEmitter::_vp_fwd_decls).
        var vgps = DeclFacts::decl_generic_params(d)
        for var i: usize = 0; i < vgps.size(); ++i {
            var unsafe *gp = vgps[i]
            if gp != &null
                && gp->is_const_param
                && gp->value_type != &null
                && self.value_param_record(d, &null) {
                self._admit_type(gp->value_type, PlanNeed::Complete)
            }
        }

        if need != PlanNeed::Complete {
            return
        }

        self._expand_type(d)
    }

    /// A declaration names its types, it does not lay them out.
    /// A declaration written with `= __kairo_default_f_x()` (InterfaceEmitter::
    /// _default_arg) makes clang build that call where the declaration sits, and
    /// a call needs the thunk's return type COMPLETE, whatever the shape of the
    /// parameter: a signature alone only names it. Function templates carry
    /// no C++ default (their friend line declares them first), so they add nothing.
    fn _admit_default_returns(self, n: unsafe *Declarations::FunctionDecl) {
        if Speller::template_params(unsafe (n as unsafe *Decl)).size() > 0 {
            return
        }

        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = *n->params.get(i)
            if p == &null
                || p->is_self
                || p->is_pack
                || p->default_thunk == &null
                || !p->default_thunk_home {
                continue
            }

            self._admit_type(p->type_, PlanNeed::Complete)
        }
    }

    fn _expand_fn(self, n: unsafe *Declarations::FunctionDecl) {
        self._witness_bounds(unsafe (n as unsafe *Decl))
        self._admit_default_returns(n)
        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = *n->params.get(i)
            if p == &null || p->is_self {
                continue
            }

            self._admit_type(
                (if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_),
                PlanNeed::Fwd,
            )
        }

        self._admit_type(n->return_type, PlanNeed::Fwd)
        self._admit_type(n->panic_result, PlanNeed::Fwd)
    }

    /// The whole definition (invariant 11): bases and by-value fields at
    /// Complete, the by-value types of method signatures at Complete too
    /// (_expand_member_sig), nested types recursively, and the same-file
    /// extension members that will be named as friends. An ADT is defined as
    /// its layout record (adt_record): its fields, role functions, nested tag
    /// enum and payload structs, and the friends written on it.
    fn _expand_type(self, d: unsafe *Decl) {
        // A value parameter's class (Compiler/Spec/Eval.md#eval-classes) is part of the template's head.
        var gps = DeclFacts::decl_generic_params(d)
        for var i: usize = 0; i < gps.size(); ++i {
            var unsafe *gp = gps[i]
            if gp != &null && gp->is_const_param && gp->value_type != &null {
                self._admit_type(gp->value_type, PlanNeed::Complete)
            }
        }

        var unsafe *rec = self.adt_record(d)
        match rec->kind {
            case DeclKind::ClassDecl {
                var unsafe *n = cast<Declarations::ClassDecl>(rec)
                self._bases(&n->derives_list)
                self._fields(&n->fields)
                self._methods(&n->methods)
            } case DeclKind::StructDecl {
                var unsafe *n = cast<Declarations::StructDecl>(rec)
                self._fields(&n->fields)
                self._methods(&n->methods)
            } case DeclKind::UnionDecl {
                var unsafe *n = cast<Declarations::UnionDecl>(rec)
                self._fields(&n->fields)
                self._methods(&n->methods)
            } case DeclKind::EnumDecl {
                // A plain enum, or an ADT whose record was never built.
                var unsafe *n = cast<Declarations::EnumDecl>(rec)
                for var i: usize = 0; i < n->variants.size(); ++i {
                    var unsafe *v = *n->variants.get(i)
                    if v == &null {
                        continue
                    }

                    self._fields(&v->payload)
                }
            } case DeclKind::TypeAliasDecl {
                self._admit_type(
                    cast<Declarations::TypeAliasDecl>(rec)->aliased,
                    PlanNeed::Complete,
                )
            } default { }
        }

        // Nested types ride inside this definition. So do member aliases
        // (InterfaceEmitter writes them as `using`), and what one names is held
        // at Complete for the reason _expand_member_sig gives: whoever reads
        // `R::promise_type` -- <coroutine>'s traits, any C++ user -- gets the
        // type itself, not a declaration of it.
        var unsafe *dc = Speller::dc_of(rec)
        if dc != &null {
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                var unsafe *nd = *dc->dc_decls.get(i)
                if nd == &null {
                    continue
                }

                if isa<Declarations::TypeAliasDecl>(nd) {
                    self._admit_type(
                        cast<Declarations::TypeAliasDecl>(nd)->aliased,
                        PlanNeed::Complete,
                    )

                    continue
                }

                if !self._is_type_decl(nd) {
                    continue
                }

                // An anonymous union is not a nested type: it has no name and no
                // definition of its own, and its members were walked through its
                // field by _fields. Expanding it here would walk them twice.
                if isa<Declarations::UnionDecl>(nd)
                    && cast<Declarations::UnionDecl>(nd)->is_anonymous {
                    continue
                }

                self._expand_type(Speller::rep(nd))
            }
        }

        self._collect_same_file_extensions(rec)
        self._admit_friends(rec)
    }

    fn _bases(self, bases: *FrozenList<Declarations::InheritEdge>) {
        for var i: usize = 0; i < bases->size(); ++i {
            var unsafe *e = bases->get(i)
            if e == &null {
                continue
            }

            self._admit_type(e->base, PlanNeed::Complete)
        }
    }

    fn _fields(self, fields: *FrozenList<unsafe *Declarations::FieldDecl>) {
        for var i: usize = 0; i < fields->size(); ++i {
            var unsafe *f = *fields->get(i)
            if f == &null {
                continue
            }

            // The union is written inline as this field (`union { ... };`), so
            // what its members hold by value is this record's dependency, at the
            // same strength as an ordinary field's. Admitting the union type
            // itself would only land on the owner again (_outermost_type).
            if f->is_anonymous_union {
                self._fields(&self.anon_union_of(f)->fields)
                continue
            }

            self._admit_type(f->type_, PlanNeed::Complete)
        }
    }

    fn _methods(self, methods: *FrozenList<unsafe *Declarations::FunctionDecl>) {
        for var i: usize = 0; i < methods->size(); ++i {
            var unsafe *m = *methods->get(i)
            if m == &null {
                continue
            }

            self._expand_member_sig(m)
        }
    }

    /// A method of a record this TU holds COMPLETE: what its signature names by
    /// value is Complete too, shape-weakened as always (a pointer stays Fwd).
    ///
    /// A free function's declaration only names its types, and _expand_fn keeps
    /// them Fwd. A complete class is different: anything in this TU may call
    /// any of its members, and a call whose return or parameter is an incomplete
    /// class is ill-formed -- including calls Kairo never sees. clang's
    /// coroutine machinery calls `promise.initial_suspend()` on a YieldPromise<T>
    /// the plan only ever held at Complete for its layout, and Suspend, named in
    /// nothing but those signatures, stayed `class Suspend;` in every TU but its
    /// own. The body-less definition is all that is needed; no bodies follow.
    ///
    /// Strength only, never ORDER: _needs_complete reads bases and fields, so a
    /// method returning a type that returns this one is two definitions in
    /// either order, not a tier-1 cycle.
    fn _expand_member_sig(self, n: unsafe *Declarations::FunctionDecl) {
        self._witness_bounds(unsafe (n as unsafe *Decl)) // a bounded member template's head.
        self._admit_default_returns(n)
        for var i: usize = 0; i < n->params.size(); ++i {
            var unsafe *p = *n->params.get(i)
            if p == &null || p->is_self {
                continue
            }

            self._admit_type(
                (if (p->is_pack && p->pack_type != &null) => (p->pack_type) else => p->type_),
                PlanNeed::Complete,
            )
        }

        self._admit_type(n->return_type, PlanNeed::Complete)
        self._admit_type(n->panic_result, PlanNeed::Complete)
    }

    /// Extensions targeting `d` written in d's OWN file: their scope is the
    /// definition's friend struct (Compiler/Spec/Generics.md#partial-selection), so it must be declared
    /// before it. Touched, not reached. Found by walking that file's program;
    /// an extension index lives in sema and codegen keeps no second one.
    fn _collect_same_file_extensions(self, d: unsafe *Decl) {
        var unsafe *tu = Speller::tu_of(d)
        if tu == &null || tu->program == &null {
            return
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); ++i {
            var item = *items->get(i)
            if item.kind != TopLevelKind::Decl {
                continue
            }

            self._collect_ext_in(item.as_decl(), d)
        }
    }

    fn _collect_ext_in(self, cand: unsafe *Decl, target: unsafe *Decl) {
        if cand == &null {
            return
        }

        if isa<Declarations::VisibilityGroupDecl>(cand) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(cand)
            for var i: usize = 0; i < g->members.size(); ++i {
                self._collect_ext_in(g->members[i], target)
            }

            return
        }

        if isa<Declarations::FFIBlockDecl>(cand) {
            var unsafe *g = cast<Declarations::FFIBlockDecl>(cand)
            for var i: usize = 0; i < g->body.size(); ++i {
                self._collect_ext_in(g->body[i], target)
            }

            return
        }

        if isa<Declarations::ModuleDecl>(cand) {
            var unsafe *dc = unsafe (cast<Declarations::ModuleDecl>(cand) as unsafe *DeclContext)
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                self._collect_ext_in(*dc->dc_decls.get(i), target)
            }

            return
        }

        var unsafe *x = dyn_cast<Declarations::ExtensionDecl>(cand)
        if x == &null {
            return
        }

        if self._ext_target(x) != target {
            return
        }

        if x->methods.size() == 0 {
            return
        }

        // A conditional block is never carried along with its target's
        // definition: only a use brings its scope into a plan.
        if x->gate != &null {
            return
        }

        // An include is emitted as a preamble is, the bodies of what it
        // carries included, and a member's out-of-line body needs its scope
        // defined: only a header, which carries no foreign body, declares it.
        self._scope_for(x, self._mode != PlanMode::Header)
    }

    /// The layout decl an extension targets: the primary for a generic one.
    fn _ext_target(self, x: unsafe *Declarations::ExtensionDecl) -> unsafe *Decl {
        if x == &null || x->target == &null {
            return &null
        }

        var unsafe *c = x->target->canonical
        if c == &null || c->kind != TypeKind::RecordType {
            return &null
        }

        return self.layout_decl(cast<RecordType>(c)->decl)
    }

    /// What `e`'s body reaches once its arguments are known (`outer<M>`
    /// calling `inner(Wrap<T>{...})`: `inner<Wrap<M>>`, `Wrap<M>`) is named in
    /// no tree, yet this TU compiles that body or links against it: hold each
    /// reached instance too, so tier 3 writes its explicit instantiation in its
    /// home and `extern template` everywhere else, and its witness rows are
    /// admitted with it -- an instance's rows are its own bounds', never its
    /// reach's (the discovery walk checks each instance once, Compiler/Spec/Generics.md#m1-enumeration).
    /// Callers run this once per instance, so a body that reaches itself
    /// stops. A function instance comes in as a call's does, its arguments
    /// Fwd. A record instance as a type naming it does (_admit: an interface's
    /// is its witness, an imported one clang's), Complete: its explicit
    /// instantiation lays it out.
    fn _admit_reached(self, e: unsafe *InstanceEntry) {
        var rs = cxx::std::vector<unsafe *InstanceEntry>()
        self._cg->instances->reached_of(e, unsafe &rs)
        for var i: usize = 0; i < rs.size(); ++i {
            var unsafe *r = rs[i]
            if isa<Declarations::FunctionDecl>(r->primary) {
                self._admit_instance(r, PlanNeed::Fwd)
            } else if r->decl != &null {
                self._admit(r->decl, PlanNeed::Complete)
            }
        }
    }
}
