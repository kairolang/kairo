/// --- The Kairo Project -------------- Codegen/Emit/InterfaceRecords.k --- ///
///
///   InterfaceEmitter, part: records. Forward declarations (tier 0) and
///   record definitions (tier 1): the class head and its bases, the `using`
///   declarations and narrowing a base edge needs, members by visibility,
///   friends, the transfers C++ would otherwise define, and the asserts of a
///   record's body predicates.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import AST::AttrFacts::AttrFacts
import AST::DeclFacts
import AST::Kind::DeclKind::DeclKind
import AST::LangItems::{
    LowerTargets,
    entry_point_name,
}
import AST::Node::Base::{
    Decl,
    Expr,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    RecordType,
    builtin_info,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions::{
    BinaryOperatorExpr,
    ConstraintExpr,
}
import AST::Node::PrimaryExpressions::NamedIdentExpr
import AST::Node::Types
import Codegen::Emit::EmitIR::EmitIR
import Codegen::Emit::EmitIRExprs
import Codegen::Emit::InterfaceDerived
import Codegen::Emit::InterfaceEmitter::InterfaceEmitter
import Codegen::Emit::InterfaceEnums
import Codegen::Emit::InterfaceFields
import Codegen::Emit::InterfaceFunctions
import Codegen::Emit::InterfaceInterop
import Codegen::Emit::Spell::{
    Speller,
    VIS_PRIV,
    VIS_PROT,
    VIS_PUB,
}
import Codegen::EmitPlan::{
    ExtScope,
    FileFriends,
    PlanMode,
    PlanNeed,
    PlanTier,
}
import Location::SourceRange::SourceRange
import Token::TokenKind::TokenKind

extend InterfaceEmitter {
    /// # Tier 0

    prot fn _fwd_decl(self, d: unsafe *Decl) {
        var s = self._spell->record_head(d)
        match d->kind {
            case DeclKind::ClassDecl {
                s += "class "
            } case DeclKind::StructDecl {
                s += "struct "
            } case DeclKind::UnionDecl {
                s += "union "
            } case DeclKind::EnumDecl {
                var unsafe *en = cast<Declarations::EnumDecl>(d)
                // An ADT is written as a record (_adt_def), so it is declared
                // as one.
                if self._plan->adt_record(d) != d {
                    s += "struct "
                    s += self._spell->leaf(d)
                    s += ";"
                    self._cg->sink->spell(self._fwd_at(d), s)
                    return
                }

                s += "enum class "
                s += self._spell->leaf(d)
                s += " : "
                s += self._enum_underlying(en)
                s += ";"
                self._cg->sink->spell(self._fwd_at(d), s)
                return
            } default {
                self._ice(self._at(d), "InterfaceEmitter: not a type decl")
            }
        }

        s += self._spell->leaf(d)
        s += self._spell->spec_suffix(d) // `Store<P*>`: which specialization.
        s += ";"
        // On the decl's first byte, not its name: the name's byte goes to
        // the definition's name token (TokenSink::_claim).
        self._cg->sink->spell(self._fwd_at(d), s)
    }

    /// The tier-0 forward declarations of templates over a class-typed
    /// value parameter (Compiler/Spec/Eval.md#eval-classes, EmitPlan::value_param_record), each
    /// written as soon as every such class is defined: entries [0, \p
    /// t0_end) are tier 0, and tier 1 has written its entries before \p at.
    /// C++ needs the class complete at every declaration of the template,
    /// so tier 0 leaves these out, and a record that names `*Widget<...>`
    /// ahead of Widget's definition needs one (EmitPlan::_needs_complete
    /// orders that record after the class, so it follows this too).
    prot fn _vp_fwd_decls(self, t0_end: usize, at: usize, header: bool) {
        for var k: usize = 0; k < t0_end; ++k {
            var unsafe *f = unsafe &self._plan->entries[k]
            if f->scope != &null || f->witness != &null {
                continue
            }

            if !self._plan->value_param_record(f->decl, &null) {
                continue
            }

            if header && !f->own && f->need == PlanNeed::Complete { // included.
                continue
            }

            var done = false
            for var j: usize = 0; j < self._vp_declared.size(); ++j {
                if self._vp_declared[j] == f->decl {
                    done = true
                    break
                }
            }

            if done {
                continue
            }

            if self._vp_class_pending(f->decl, at) {
                continue
            }

            self._vp_declared.push_back(f->decl)
            var unsafe *fd = f->decl
            self._wrapped(fd, fn () { self._fwd_decl(fd) })
        }
    }

    /// One of \p d's value-parameter classes is defined by tier 1 at or
    /// after entry \p at: not yet written.
    priv fn _vp_class_pending(self, d: unsafe *Decl, at: usize) -> bool {
        for var j: usize = at; j < self._plan->entries.size(); ++j {
            var *e = &self._plan->entries[j]
            if e->tier != PlanTier::Definitions {
                break
            }

            if e->scope != &null || e->witness != &null || e->eval_item != &null {
                continue
            }

            if self._plan->value_param_record(d, e->decl) {
                return true
            }
        }

        return false
    }

    /// This stream writes \p d's out-of-line method definitions: a TU's own
    /// record (EmitIR emits every body of its program). A header or an
    /// include carries only the inline and template ones, and a record of
    /// another file is defined in that file's TU.
    priv fn _defines_methods(self, d: unsafe *Decl) -> bool {
        if self._plan->mode() != PlanMode::Preamble {
            return false
        }

        return Speller::fid_of(d) == self._plan->home()
    }

    prot fn _fwd_at(self, d: unsafe *Decl) -> SourceRange {
        if !d->range.is_valid() {
            return self._at(d)
        }

        return SourceRange::from_bounds(d->range.start, 1)
    }

    prot fn _enum_underlying(self, en: unsafe *Declarations::EnumDecl) -> string {
        if en->underlying != &null {
            return self._spell->_type(en->underlying)
        }

        return builtin_info(BuiltinKind::U32)->cxx.copy() // Kairo's default enum width.
    }

    /// # Tier 1

    prot fn _type_def(self, d: unsafe *Decl) {
        match d->kind {
            case DeclKind::ClassDecl {
                self._record_def(d, "class")
            } case DeclKind::StructDecl {
                self._record_def(d, "struct")
            } case DeclKind::EnumDecl {
                self._enum_def(cast<Declarations::EnumDecl>(d))
            } case DeclKind::UnionDecl {
                self._record_def(d, "union")
            } default {
                self._ice(self._at(d), "InterfaceEmitter: not a type decl")
            }
        }
    }

    /// The definition, body-less (invariant 12): bases, nested types,
    /// fields, method declarations, the derived `op =` (the exception:
    /// _derived_assign), friends. A field's default is a constant or a
    /// call of its thunk (_field_default); parameter defaults are not
    /// declared. See the file header.
    ///
    /// Every type written inside the braces is spelled with \p d as its
    /// scope (Speller::_type), so the record's own nested types go out by
    /// leaf: qualified, a nested type of a class template would need the
    /// template's arguments, and inside the body the injected class name
    /// already supplies them. A nested record's definition passes itself.
    priv fn _record_def(self, d: unsafe *Decl, const kw: string) {
        var at       = self._at(d)
        var is_class = d->kind == DeclKind::ClassDecl
        var is_union = d->kind == DeclKind::UnionDecl
        var s        = self._spell->record_head(d)
        s += kw
        s += " "
        var name = self._spell->leaf(d) + self._spell->spec_suffix(d)

        // Only ever forward-declared (a nested `struct Cell;` whose body
        // lives elsewhere): a declaration, never an empty definition, which
        // would give it a layout it does not have. Sema has refused every
        // by-value use (TypeCycleCheck, TypeUtil::why_no_default).
        if DeclFacts::decl_only_forward(d) {
            self._cg->sink->spell(at, s + name + ";")
            return
        }

        // `@packed` / `@align(N)`: on the definition only, between the
        // class-key and the name, where C++ puts a record's attributes.
        // Sema predicted the same layout (EnumLayoutQuery::_plain_record_size).
        s += AttrFacts::record_attr(d, self._ms_abi())
        s += name

        if is_class {
            var unsafe *n = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < n->derives_list.size(); ++i {
                var unsafe *e = n->derives_list.get(i)
                if e == &null {
                    continue
                }

                s += if (i == 0) => (" : ") else => ", "
                if e->is_virtual {
                    s += "virtual "
                }

                s += self._base_access(e->visibility)
                s += " "
                s += self._spell->_type(e->base)
            }
        }

        s += " {"
        self._cg->sink->spell(at, s)
        // Which body this is, for the pin beside each instance (Compiler/Spec/Generics.md#where-groups-on-generic-functions).
        var tag = self._spec_tag(d)
        if tag >= 0 {
            var line = f"static constexpr unsigned {LowerTargets::spec_tag()} = {tag}u;"
            if is_class {
                line = "public: " + line + " private:"
            }

            self._cg->sink->spell(at, line)
        }

        if AttrFacts::is_relocatable(d) {
            // Its own name, not `true`: a derived record inherits the
            // member, and is relocatable only if it says so itself.
            var line = f"using {LowerTargets::relocatable_marker()} = {name};"
            if is_class {
                line = "public: " + line + " private:"
            }

            self._cg->sink->spell(at, line)
        }

        self._body_predicate_asserts(d)
        // An ADT payload is built inside its union by `new (&member) P(...)`,
        // which must not depend on the TU including <new>: this placement
        // form, found in the class before any global one, is what it calls.
        if isa<Declarations::StructDecl>(d) && cast<Declarations::StructDecl>(d)->is_adt_payload {
            self._cg->sink->spell(
                at,
                "static void* operator new(" + builtin_info(
                    BuiltinKind::USize,
                )->cxx + ", void* p) noexcept { return p; }",
            )
        } else if !is_union {
            // C++'s `new X` / `delete p` on a Kairo record go to Kairo's
            // allocator (_cxx_alloc_ops). Public in a class, whose C++
            // default is private, and back: what follows assumes it.
            if is_class && self._plan->mode() != PlanMode::Preamble {
                self._cg->sink->spell(at, "public:")
            }

            self._cxx_alloc_ops(d, name, at)
            if is_class && self._plan->mode() != PlanMode::Preamble {
                self._cg->sink->spell(at, "private:")
            }
        }

        // Default access follows the keyword: a Kairo struct's members are
        // public unless marked; in a class only the VARIABLES are private
        // unless marked, and methods, constructors and nested types are
        // public (classes.md, Default visibility).
        var cur_access = if (is_class) => (VIS_PRIV()) else => VIS_PUB()

        // Nested types first: a field may name one.
        var unsafe *dc = Speller::dc_of(d)
        if dc != &null {
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                var unsafe *nd = *dc->dc_decls.get(i)
                if nd == &null {
                    continue
                }

                if isa<Declarations::VisibilityGroupDecl>(nd) { // members are pointers back into the lists below.
                    continue
                }

                if !self._is_type(nd) {
                    continue
                }

                // An anonymous union is not a nested type: it has no name to
                // define it under, and its one declaration is the field
                // below that holds it (_anon_union_field).
                if isa<Declarations::UnionDecl>(nd)
                    && cast<Declarations::UnionDecl>(nd)->is_anonymous {
                    continue
                }

                // A forward declaration and its definition in one body
                // (`struct Cell;` ... `struct Cell { }`) are one entity, and
                // its representative is the definition: emit it at the link
                // that IS the representative, once. Every other link would
                // define it again (clang: "redefinition of 'Cell'").
                var unsafe *rep = Speller::rep(nd)
                if rep != nd && DeclFacts::decl_ffi_tag_target(nd) == &null {
                    continue
                }

                cur_access = self._access(
                    cur_access,
                    self._cxx_vis(nd),
                    false,
                    at,
                )

                self._type_def(rep)
            }

            // Member aliases, in declaration order, before any field or
            // method: an alias is usually named in the record's own
            // signatures (`promise_type`, which <coroutine>'s primary reads as
            // `typename R::promise_type`), and a C++ declaration cannot use a
            // member declared below it -- only a body sees the whole class.
            // After the nested types, because an alias may name one. An alias
            // can only refer to what the record itself can name, and Kairo
            // does not let it name a later field, so hoisting is safe.
            for var i: usize = 0; i < dc->dc_decls.size(); ++i {
                var unsafe *nd = *dc->dc_decls.get(i)
                if nd == &null || !isa<Declarations::TypeAliasDecl>(nd) {
                    continue
                }

                var unsafe *ta = cast<Declarations::TypeAliasDecl>(nd)
                if ta->aliased == &null {
                    continue
                }

                cur_access = self._access(
                    cur_access,
                    self._cxx_vis(nd),
                    false,
                    at,
                )

                var us = self._spell->template_head(nd)
                us += "using " + self._spell->leaf(nd) + " = " + self._spell->_type(
                    ta->aliased,
                    &null,
                    d,
                ) + ";"
                self._cg->sink->spell(self._at(nd), us)
            }
        }

        var fields  = DeclFacts::decl_fields(d)
        var methods = DeclFacts::decl_methods(d)



        var union_first = true
        // An ADT payload is only ever built whole, from its variant's
        // values (the enum's constructors), and sits in the enum's union.
        var payload = isa<Declarations::StructDecl>(d)
            && cast<Declarations::StructDecl>(d)->is_adt_payload
        for var i: usize = 0; i < fields.size(); ++i {
            var unsafe *f = fields[i]
            if f == &null {
                continue
            }

            cur_access = self._access(
                cur_access,
                self._cxx_vis(unsafe (f as unsafe *Decl)),
                is_class,
                at,
            )

            // Before anything spells the field: it has no name.
            if f->is_anonymous_union {
                self._anon_union_field(f, d)
                continue
            }

            var fs = ""
            // `@align(N)` on the field: GNU `aligned` leads its declaration.
            fs += AttrFacts::decl_align_attr(unsafe (f as unsafe *Decl))
            if f->is_static() {
                fs += "static "
            }

            if f->is_static() && f->is_thread {
                fs += "thread_local "
            }

            if f->is_mutable {
                fs += "mutable "
            }

            // An eval field is `static const T k;` here and `constexpr` at its
            // definition (_static_def; Compiler/Spec/Eval.md#eval-bindings).
            if f->is_const() || f->is_eval() {
                fs += "const "
            }

            fs += self._spell->decl(
                f->type_,
                self._spell->leaf(unsafe (f as unsafe *Decl)),
                &null,
                d,
            )

            // A static's value is its definition's (_static_defs), never an
            // in-class initializer, which C++ refuses on a non-const static.
            if !f->is_static() {
                var dflt = self._field_default(f)
                // A union's one initializer is its first member's: `{}`
                // keeps the union default-constructible (C++ deletes its
                // default constructor when a member's is non-trivial, as a
                // struct whose fields are zeroed below is) and zeroes it.
                if dflt.size() == 0
                    && !payload
                    && (is_union && union_first || !is_union && self._zero_by_default(f)) {
                    dflt = "{}"
                }

                union_first = false
                fs += dflt
            }

            fs += ";"
            self._cg->sink->spell(f->name.range, fs)
        }

        // Two passes: an explicit specialization is declared after every
        // primary it may specialize, wherever it was written.
        for var k: usize = 0; k < methods.size() * 2; ++k {
            var unsafe *m = methods[k % methods.size()]
            if m == &null
                || Speller::is_fn_spec(unsafe (m as unsafe *Decl)) != (k >= methods.size()) {
                continue
            }

            cur_access = self._access(
                cur_access,
                self._cxx_vis(unsafe (m as unsafe *Decl)),
                false,
                at,
            )

            // A method defined out of line (EmitIR::_method) is declared on
            // its first byte, not its name, as _fwd_decl declares a type:
            // only one exact token gets the name's byte (TokenSink::_claim),
            // and the definition is the one that keeps it. Clang reports at
            // the definition (what a constructor fails to initialize, an
            // incomplete result type) and its lookup finds the definition, so
            // its "declared here" notes do too; on the name the definition's
            // walked to its `{` or lines away (for constructors).
            // Only where this stream writes the definition: a class another
            // TU defines, or a header's, keeps the name for the declaration,
            // which is all the C++ that includes it sees.
            var mat = self._at(unsafe (m as unsafe *Decl))
            if m->has_body()
                && m->body_kind == Declarations::FnBodyKind::Block
                && m->ci_split == 0
                && (self._is_ctor(m, d) || self._defines_methods(d)) {
                mat = self._fwd_at(unsafe (m as unsafe *Decl))
            }

            self._cg->sink->spell(mat, self._method_decl(m, d))
        }

        cur_access = self._subscript_forwarders(d, methods, cur_access, at)

        if is_class {
            cur_access = self._base_usings(
                cast<Declarations::ClassDecl>(d),
                cur_access,
                at,
            )
        }

        if is_class {
            cur_access = self._edge_narrowing(
                cast<Declarations::ClassDecl>(d),
                cur_access,
                at,
            )
        }

        // Each constructor that initializes a field in place: its slot record,
        // its pre-function and the constructor that takes the slots
        // (_split_ctor_decls). Private: only the public constructor calls
        // them.
        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null || m->ci_split == 0 {
                continue
            }

            cur_access = self._access(cur_access, VIS_PRIV(), false, at)
            self._split_ctor_decls(m, d)
        }

        // The comparisons derived from a member `op <=>` (_derived_cmps).
        cur_access = self._derived_cmps(d, cur_access, at)

        // `op =`, derived from the transfer constructor (_derived_assign).
        // Public, as C++'s implicit one is.
        if self._assign_form_of(d) != Declarations::AssignForm::Implicit {
            cur_access = self._access(cur_access, VIS_PUB(), false, at)
            self._derived_assign(d)
        } else if self._implicit_transfer_of(d) != Declarations::ImplicitTransfer::None {
            cur_access = self._access(cur_access, VIS_PUB(), false, at)
            self._implicit_transfers(d)
        }

        // `__builtin_dynamic_size` / `_align`'s hidden virtual: last, so the
        // `public:` it needs changes no other member's access.
        if is_class && Speller::has_virtual_dtor(d) {
            cur_access = self._access(cur_access, VIS_PUB(), false, at)
            self._layout_virtual(d, at)
        }

        self._friends(d)

        self._cg->sink->spell(at, "};")
        // `null_t`'s one value, `::builtin::null` to a C++ host. Inline, so
        // every TU that includes the record has it and none owns it.
        if isa<Declarations::StructDecl>(d) && cast<Declarations::StructDecl>(d)->is_null_type {
            self._cg->sink->spell(
                at,
                "inline constexpr " + self._spell->leaf(
                    d,
                ) + " " + LowerTargets::null_constant() + "{};",
            )
        }

        self._cg->sink->brk()
    }

    /// `virtual const size_t* __kairo_layout() const noexcept`, in every class
    /// with a virtual destructor (Speller::has_virtual_dtor): the most
    /// derived class's {sizeof, alignof}, which `__builtin_dynamic_size` /
    /// `_align` read (EmitIR::_dynamic_layout_body) so that `destroy<Base>`
    /// gives a sized allocator the size it allocated. A pointer to a
    /// constant pair rather than a struct, so no helper type has to be
    /// declared ahead of the class, and every override has the same return
    /// type. Defined in the class: it is the same text in every TU.
    priv fn _layout_virtual(self, d: unsafe *Decl, at: SourceRange) {
        var sz = "decltype(sizeof(0))"
        var me = self._spell->leaf(d)
        var ov = if (Speller::layout_overrides(d)) => (" override") else => ""
        self._cg->sink->spell(
            at,
            "virtual const " + sz + "* " + LowerTargets::layout_virtual() + "() const noexcept" + ov + " { static constexpr " + sz + " l[2] = { sizeof(" + me + "), alignof(" + me + ") }; return l; }",
        )
    }

    /// `using B::m;` for every method name \p d declares that a direct base
    /// B also answers with a method. Kairo MERGES a base's members with the
    /// derived class's (Compiler/Spec/Generics.md#partial-selection, the `needs_using` rule) and
    /// overload resolution picks among all of them; C++ name lookup stops at
    /// the derived class, so without this `d.f(x)` that Kairo bound to the
    /// base's `f(f64)` went to the derived `f(i32)` through a conversion --
    /// a silent miscompile. The using-declaration makes C++'s overload set
    /// Kairo's. An override still overrides: a derived member hides the
    /// using-declared base member of the same signature ([namespace.udecl]/14).
    /// Constructors, the destructor and compiler-made members are never
    /// brought in (constructors are not inherited, and a made member's name
    /// is its own class's).
    priv fn _base_usings(self,
                         d:      unsafe *Declarations::ClassDecl,
                         cur_in: u8,
                         at:     SourceRange) -> u8 {
        var cur  = cur_in
        var own  = self._spell->leaf(unsafe (d as unsafe *Decl))
        var done = cxx::std::vector<string>()
        for var i: usize = 0; i < d->methods.size(); ++i {
            var unsafe *m = d->methods[i]
            if m == &null || m->is_implicit {
                continue
            }

            var nm = self._spell->leaf(m)
            if nm.size() == 0 || nm == own || nm[0] == ('~' as u8) {
                continue
            }

            var dup = false
            for var k: usize = 0; k < done.size(); ++k {
                if done[k] == nm {
                    dup = true
                    break
                }
            }

            if dup {
                continue
            }

            done.push_back(nm)
            for var j: usize = 0; j < d->derives_list.size(); ++j {
                var unsafe *e = d->derives_list.get(j)
                if e == &null || e->base == &null {
                    continue
                }

                var seen = cxx::std::vector<unsafe *Decl>()
                var found = self._base_method_named(
                    self._edge_decl(e),
                    nm,
                    unsafe &seen,
                    0,
                    Speller::fid_of(unsafe (d as unsafe *Decl)),
                )

                if found == 0 || found == 255 {
                    continue
                }

                // At the base members' own access, narrowed by a `priv` /
                // `prot` edge (_edge_narrowing): a public using of a
                // protected member would make it public through d.
                var want = found
                if (e->visibility == VIS_PRIV() || e->visibility == VIS_PROT())
                    && e->visibility < want {
                    want = e->visibility
                }

                cur = self._access(cur, want, false, at)
                self._cg->sink->spell(
                    at,
                    "using " + self._spell->_type(e->base) + "::" + nm + ";",
                )
            }
        }

        return cur
    }

    /// `derives priv B` / `derives prot B`: the base stays public (a private
    /// base would refuse the upcast Kairo allows from another file, and null
    /// the checked downcast at run time), and the narrowing is said the other
    /// way, `private: using B::x;` (`protected:` for `prot`) for every name
    /// d inherits through the edge and does not declare itself. Through d, and
    /// whatever derives d, those names are then private (protected); through
    /// a `*B` they are B's own -- Kairo's rule (AccessCheck::_check_edges).
    /// Left alone: B's constructors and destructor, names d declares (its own
    /// hide B's, and _base_usings brings in the shared method names), nested
    /// types, a name one of whose members d cannot name (private to a base in
    /// another file: hidden from d anyway), and a name already narrower than
    /// the edge. Members of B's own bases are reached only through B's public
    /// edges. One using takes a whole overload set at one level, the
    /// narrowest of the edge's and the members' own.
    priv fn _edge_narrowing(self,
                            d:      unsafe *Declarations::ClassDecl,
                            cur_in: u8,
                            at:     SourceRange) -> u8 {
        var        cur  = cur_in
        var unsafe *dd  = unsafe (d as unsafe *Decl)
        var        fid  = Speller::fid_of(dd)
        var        mine = cxx::std::vector<string>()
        for var i: usize = 0; i < d->fields.size(); ++i {
            if d->fields[i] != &null {
                mine.push_back(
                    self._spell->leaf(unsafe (d->fields[i] as unsafe *Decl)),
                )
            }
        }

        for var i: usize = 0; i < d->methods.size(); ++i {
            if d->methods[i] != &null {
                mine.push_back(
                    self._spell->leaf(unsafe (d->methods[i] as unsafe *Decl)),
                )
            }
        }

        for var j: usize = 0; j < d->derives_list.size(); ++j {
            var unsafe *e = d->derives_list.get(j)
            if e == &null || e->base == &null {
                continue
            }

            var ev = e->visibility
            if ev != VIS_PRIV() && ev != VIS_PROT() {
                continue
            }

            var names = cxx::std::vector<string>()
            var acc   = cxx::std::vector<u8>()
            var seen  = cxx::std::vector<unsafe *Decl>()
            self._edge_names(
                self._edge_decl(e),
                fid,
                unsafe &names,
                unsafe &acc,
                unsafe &seen,
                0,
            )

            var bs = self._spell->_type(e->base)
            for var k: usize = 0; k < names.size(); ++k {
                var nm = names[k].copy()
                if acc[k] == 255 {
                    continue
                }

                var dup = false
                for var q: usize = 0; q < mine.size(); ++q {
                    if mine[q] == nm {
                        dup = true
                        break
                    }
                }

                if dup {
                    continue
                }

                // VIS_PRIV < VIS_PROT < VIS_PUB: the narrower of the two.
                var want = if (ev < acc[k]) => (ev) else => acc[k]
                if want == acc[k] {
                    continue
                }

                cur = self._access(cur, want, false, at)
                self._cg->sink->spell(at, "using " + bs + "::" + nm + ";")
            }
        }

        return cur
    }

    /// The member names class \p b (and its bases through public edges)
    /// lets a deriving class of file \p fid inherit: fields and methods,
    /// each name once, with the narrowest C++ access of its members, or 255
    /// when one of them is private to another file.
    priv fn _edge_names(self,
                        b:     unsafe *Decl,
                        fid:   u32,
                        names: unsafe *cxx::std::vector<string>,
                        acc:   unsafe *cxx::std::vector<u8>,
                        seen:  unsafe *cxx::std::vector<unsafe *Decl>,
                        depth: u32) {
        if b == &null || depth > 64 || !isa<Declarations::ClassDecl>(b) {
            return
        }

        for var i: usize = 0; i < seen->size(); ++i {
            if (*seen)[i] == b {
                return
            }
        }

        seen->push_back(b)
        var unsafe *cd     = cast<Declarations::ClassDecl>(b)
        var        own     = self._spell->leaf(b)
        var        members = cxx::std::vector<unsafe *Decl>()
        for var i: usize = 0; i < cd->fields.size(); ++i {
            if cd->fields[i] != &null {
                members.push_back(unsafe (cd->fields[i] as unsafe *Decl))
            }
        }

        for var i: usize = 0; i < cd->methods.size(); ++i {
            if cd->methods[i] != &null {
                members.push_back(cd->methods[i])
            }
        }

        for var i: usize = 0; i < members.size(); ++i {
            var unsafe *m = members[i]
            if m->is_implicit {
                continue
            }

            var unsafe *fd = dyn_cast<Declarations::FieldDecl>(m)
            if fd != &null && fd->is_anonymous_union {
                continue
            }

            var nm = self._spell->leaf(m)
            if nm.size() == 0 || nm == own || nm[0] == ('~' as u8) {
                continue
            }

            var a = self._spell->cxx_access(m)
            if a == VIS_PRIV() && Speller::fid_of(m) != fid {
                a = 255
            }

            var at = names->size()
            for var k: usize = 0; k < names->size(); ++k {
                if (*names)[k] == nm {
                    at = k
                    break
                }
            }

            if at == names->size() {
                names->push_back(nm)
                acc->push_back(a)
                continue
            }

            if (*acc)[at] == 255 || a == 255 {
                (*acc)[at] = 255
                continue
            }

            if a < (*acc)[at] {
                (*acc)[at] = a
            }
        }

        for var j: usize = 0; j < cd->derives_list.size(); ++j {
            var unsafe *e = cd->derives_list.get(j)
            if e == &null || e->visibility == VIS_PRIV() || e->visibility == VIS_PROT() {
                continue
            }

            self._edge_names(
                self._edge_decl(e),
                fid,
                names,
                acc,
                seen,
                depth + 1,
            )
        }
    }

    /// The record a base edge names, as the pattern whose members are
    /// declared (an implicit instance's own list may still be empty).
    priv fn _edge_decl(self, e: unsafe *Declarations::InheritEdge) -> unsafe *Decl {
        if e->base == &null || e->base->canonical == &null {
            return &null
        }

        var unsafe *r = dyn_cast<RecordType>(canon_unqual(e->base->canonical))
        if r == &null {
            // `derives A`, A the class's own type parameter: the names its
            // body shares with its base are the ones A's `derives` bound
            // declares, and `using A::m;` finds them in every argument.
            r = Speller::param_bound(
                dyn_cast<Types::GenericParamType>(
                    canon_unqual(e->base->canonical),
                ),
            )
        }

        if r == &null || r->decl == &null {
            return &null
        }

        return Speller::rep(DeclFacts::decl_pattern(Speller::rep(r->decl)))
    }

    /// Whether class \p b or a base of it has a method spelled \p nm, and at
    /// what C++ access a using-declaration in a class of file \p fid may
    /// bring them in: 0 none; VIS_PUB / VIS_PROT / VIS_PRIV, the narrowest
    /// of the overloads (one using takes the whole set at one level); 255
    /// one the deriving class cannot name -- private, in another file, so
    /// not befriended -- and a using naming it is clang's access error.
    priv fn _base_method_named(self,
                               b:        unsafe *Decl,
                               const nm: string,
                               seen:     unsafe *cxx::std::vector<unsafe *Decl>,
                               depth:    u32,
                               fid:      u32) -> u8 {
        if b == &null || depth > 64 || !isa<Declarations::ClassDecl>(b) {
            return 0
        }

        for var i: usize = 0; i < seen->size(); ++i {
            if (*seen)[i] == b {
                return 0
            }
        }

        seen->push_back(b)
        var unsafe *cd     = cast<Declarations::ClassDecl>(b)
        var        hit: u8 = 0
        for var i: usize = 0; i < cd->methods.size(); ++i {
            var unsafe *m = cd->methods[i]
            if m == &null || m->is_implicit {
                continue
            }

            if self._spell->leaf(m) != nm {
                continue
            }

            var a = self._spell->cxx_access(m)
            if a == VIS_PRIV() && Speller::fid_of(m) != fid {
                return 255
            }

            // VIS_PRIV < VIS_PROT < VIS_PUB: the narrowest is the smallest.
            if hit == 0 || a < hit {
                hit = a
            }
        }

        if hit != 0 {
            return hit
        }

        for var j: usize = 0; j < cd->derives_list.size(); ++j {
            var unsafe *e = cd->derives_list.get(j)
            if e == &null {
                continue
            }

            var r = self._base_method_named(
                self._edge_decl(e),
                nm,
                seen,
                depth + 1,
                fid,
            )

            if r != 0 {
                return r
            }
        }

        return 0
    }

    /// Friends: every same-file extension scope of the record, so an
    /// extension member written beside the type can reach its privates.
    /// One line per scope covers every member, generic or not, and each
    /// struct was declared in tier 0, so its qualified name needs no other
    /// prior declaration. A record's and an ADT's (_adt_def) alike.
    ///
    /// Then, for a record with a non-public member, the rest of its file
    /// (EmitPlan::file_friends, which says what each line needs declared
    /// first and what is left out): its records, its other extension
    /// scopes, its functions, the witnesses of what it declares it
    /// implements, and `main`. That is C++'s spelling of Kairo's `priv`:
    /// the class and every function of its file.
    prot fn _friends(self, d: unsafe *Decl) {
        var fs = cxx::std::vector<unsafe *ExtScope>()
        self._plan->friend_scopes_of(d, &fs)
        for var i: usize = 0; i < fs.size(); ++i {
            self._cg->sink->spell(
                self._at(unsafe (fs[i]->anchor as unsafe *Decl)),
                "friend struct " + self._scope_qual(fs[i]) + ";",
            )
        }

        if fs.size() > 0 && self._cg->opts.extension_member_wrappers {
            self._ice(
                self._at(d),
                "InterfaceEmitter: extension_member_wrappers is on but wrapper emission is not written; leave it off",
            )
        }

        var ff = FileFriends()
        self._plan->file_friends(d, unsafe &ff)
        if !ff.needed {
            return
        }

        var at = self._at(d)
        for var i: usize = 0; i < ff.records.size(); ++i {
            var unsafe *r = ff.records[i]
            var        q  = self._spell->qual_name(r)
            if Speller::template_params(r).size() == 0 {
                // The friend-type form: no class-key to disagree with the
                // definition's (a mismatch is in the mangling on MSVC).
                self._cg->sink->spell(at, "friend " + q + ";")
                continue
            }

            var key = if (isa<Declarations::ClassDecl>(r)) => ("class")
                      else => (if (isa<Declarations::UnionDecl>(r)) => ("union") else => "struct")
            // Its own parameter names could redeclare d's: spelled as
            // __kairo_ft<i>, requires-clause included (rename_tparams).
            self._spell->rename_tparams = r
            var head = self._spell->template_head(r)
            self._spell->rename_tparams = &null
            self._cg->sink->spell(at, head + "friend " + key + " " + q + ";")
        }

        for var i: usize = 0; i < ff.scopes.size(); ++i {
            self._cg->sink->spell(
                at,
                "friend struct " + self._spell->ext_scope_name(ff.scopes[i]) + ";",
            )
        }

        for var i: usize = 0; i < ff.fns.size(); ++i {
            self._spell->rename_tparams = unsafe (ff.fns[i] as unsafe *Decl)
            var ft = self._friend_fn_text(ff.fns[i], (ff.far[i] != 0))
            self._spell->rename_tparams = &null
            self._cg->sink->spell(at, ft)
        }

        for var i: usize = 0; i < ff.ifaces.size(); ++i {
            var unsafe *iface = ff.ifaces[i]
            var h   = "template <class " + LowerTargets::friend_tparam(0)
            var gps = DeclFacts::decl_generic_params(iface)
            for var k: usize = 0; k < gps.size(); ++k {
                h += ", class " + LowerTargets::friend_tparam(k + 1)
            }

            self._cg->sink->spell(
                at,
                h + "> friend struct " + self._spell->witness_name(iface) + ";",
            )
        }

        for var i: usize = 0; i < ff.globals.size(); ++i {
            self._cg->sink->spell(
                at,
                "friend " + self._spell->ginit_decl(ff.globals[i]) + ";",
            )
        }

        if ff.main != &null {
            self._cg->sink->spell(
                at,
                "friend " + self._main_decl_text(ff.main, true),
            )
        }
    }

    /// `friend R f(P...) noexcept;`, or with its template head: the
    /// function's own declaration (_free_fn_text) as a friend may repeat it
    /// -- the head, `consteval` and `noexcept` kept (a redeclaration must
    /// agree on each), no attribute and no linkage (a friend declaration
    /// may carry neither; EmitPlan::file_friends leaves out a function that
    /// needs one). Unqualified, it names, or first declares, the function in
    /// the record's namespace, which file_friends made sure is its own;
    /// \p qualified, it names one declared ahead of the record
    /// (EmitPlan::friend_early).
    priv fn _friend_fn_text(self,
                            f:         unsafe *Declarations::FunctionDecl,
                            qualified: bool) -> string {
        var s = self._spell->template_head(unsafe (f as unsafe *Decl))
        s += "friend "
        // The calling convention is no attribute in that sense: it is part
        // of the function's type, so every redeclaration must repeat it.
        var cc = f->call_conv
        if cc == 0 && f->canonical_decl() != &null {
            cc = f->canonical_decl()->call_conv
        }

        s += Speller::call_conv_attr(cc)
        if f->is_eval() {
            s += "consteval "
        }

        s += self._spell->declared_return(f)
        s += " "
        s += if (qualified) => (self._spell->qual_name(
                 unsafe (f as unsafe *Decl),
             ))
             else => self._fn_name(f)
        s += "("
        s += self._params(f, false, &null)
        s += ")"
        if f->no_unwind {
            s += " noexcept"
        }

        return s + ";"
    }

    /// `int ::main(int argc, ...) noexcept;` (\p qualified) or the global
    /// declaration `int main(...) noexcept;` the friend line needs before
    /// it: the definition's own head (EmitIR::_free_fn).
    prot fn _main_decl_text(self,
                            f:         unsafe *Declarations::FunctionDecl,
                            qualified: bool) -> string {
        var s = if (qualified) => ("int ::" + entry_point_name() + "(")
                else => "int " + entry_point_name() + "("
        s += self._params(f, false, &null)
        s += ")"
        if f->no_unwind {
            s += " noexcept"
        }

        return s + ";"
    }

    /// The transfers ClassLifecycle chose for a record that writes a
    /// destructor and no transfer constructor; None for anything else.
    prot fn _implicit_transfer_of(self, d: unsafe *Decl) -> Declarations::ImplicitTransfer {
        if isa<Declarations::ClassDecl>(d) {
            return cast<Declarations::ClassDecl>(d)->implicit_transfer
        }

        if isa<Declarations::StructDecl>(d) {
            return cast<Declarations::StructDecl>(d)->implicit_transfer
        }

        return Declarations::ImplicitTransfer::None
    }

    /// The derived `op =` slots ClassLifecycle wrote on a record; Implicit
    /// and null for anything else.
    prot fn _assign_form_of(self, d: unsafe *Decl) -> Declarations::AssignForm {
        if isa<Declarations::ClassDecl>(d) {
            return cast<Declarations::ClassDecl>(d)->assign_form
        }

        if isa<Declarations::StructDecl>(d) {
            return cast<Declarations::StructDecl>(d)->assign_form
        }

        return Declarations::AssignForm::Implicit
    }

    prot fn _assign_from_of(self, d: unsafe *Decl) -> unsafe *Declarations::FunctionDecl {
        if isa<Declarations::ClassDecl>(d) {
            return cast<Declarations::ClassDecl>(d)->assign_from
        }

        if isa<Declarations::StructDecl>(d) {
            return cast<Declarations::StructDecl>(d)->assign_from
        }

        return &null
    }

    /// The value predicates generic record \p d's template head cannot
    /// carry (Speller::body_predicates), as static_asserts at the top of
    /// its body, asserted per instance: every instance Sema homed is
    /// explicitly instantiated, so each is checked, as a function's are by
    /// its body's asserts (EmitIR::_body). An ADT enum's go in the record it
    /// is written as (_adt_def).
    prot fn _body_predicate_asserts(self, d: unsafe *Decl) {
        var bps = self._spell->body_predicates(d)
        if bps.size() == 0 {
            return
        }

        var unsafe *pir   = self.ir
        var        own_ir = EmitIR(self._cg)
        if pir == &null {
            pir = unsafe &own_ir
        }

        for var i: usize = 0; i < bps.size(); ++i {
            self._cg->sink->spell(bps[i]->range, "static_assert(")
            pir->emit(bps[i])
            self._cg->sink->spell(
                bps[i]->range,
                ", \"requires clause of '" + self._spell->leaf(d) + "' not satisfied\");",
            )
        }
    }
}
