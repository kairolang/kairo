/// --- The Kairo Project ----------------- Sema/Lower/EnumLayoutLowering.k --- ///
///
///   \brief An ADT enum gets the record C++ sees: a tag, its payloads in an
///          anonymous union, a constructor per variant, and the special
///          members its payloads allow.
///
///   \detail
///     Every ADT pattern gets one StructDecl, EnumDecl::adt_layout, which
///     InterfaceEmitter writes under the enum's own name and template head
///     in place of an `enum class`. For `enum <T> Opt { Some { v: T }, None }`:
///
///       template <class T> struct Opt {
///           enum class __kairo_Tag : u32 { Some, None };
///           struct __kairo_Some_t { <placement operator new>  T v; };
///           __kairo_Tag __kairo_tag;
///           union { __kairo_Some_t __kairo_Some; };
///           static constexpr bool __kairo_trivial_copy = __is_trivially_copyable(__kairo_Some_t);
///           ...                                       // four more flags
///           template <class F> Opt(::__kairo_vt<0>, F&& f)
///               : __kairo_tag(__kairo_Tag::Some), __kairo_Some(static_cast<F&&>(f)()) {}
///           Opt(::__kairo_vt<1>) : __kairo_tag(__kairo_Tag::None) {}
///           Opt(const Opt&) requires __kairo_trivial_copy = default;
///           Opt(const Opt& o) requires (!__kairo_trivial_copy && __kairo_copyable)
///               : __kairo_tag(o.__kairo_tag) { __kairo_construct_from(o); }
///           Opt(const Opt&) requires (!__kairo_trivial_copy && !__kairo_copyable) = delete;
///           ...                                       // move, both assignments, destructor
///       private:
///           void __kairo_destroy() noexcept;          // a switch on the tag
///           template <class O> void __kairo_construct_from(O&& o);
///       };
///
///     The tag enum has no discriminants: a tag is its variant's position,
///     which is what MatchLowering switches on. A variant with no payload
///     gets no struct and no union member, and its adt_member stays null.
///     A payload struct's fields are the variant's own payload FieldDecls,
///     not copies: PatternCompilation's occurrences and MatchLowering's
///     `s.__kairo_<V>.<field>` chains name those decls, and that identity is
///     what makes a match read the union member. Every minted decl belongs
///     to the enum (its semantic_dc), because to C++ the record IS the
///     enum. Nothing is retargeted: every RecordType keeps naming the
///     EnumDecl, and codegen reaches the record only through adt_layout.
///
///   \par The special members
///     A generic ADT cannot know what its payloads allow until clang
///     instantiates it, so it declares all three forms of each special
///     member -- defaulted, with a body, deleted -- and constraints on the
///     five flags select exactly one. A non-generic ADT declares only the
///     form its lifecycle facts (ClassLifecycle) select, and has no flags:
///
///       trivially copyable   copy, move and both assignments defaulted
///       COPY                 copy and move with a body
///       MOVE                 move with a body, copy deleted
///       NON_TRANSFER         copy and move deleted
///
///     Each assignment takes its constructor's form; a body destroys the
///     old payload and builds the new one, and does nothing on
///     self-assignment. The destructor is defaulted when trivial, a body
///     when destructible, deleted otherwise.
///
///   \par Roles, not bodies
///     None of these members has a Kairo spelling: a forwarding reference,
///     a union member initialized from a prvalue, placement new into a union
///     member, a constraint over a C++ type trait. So each is a FunctionDecl
///     with no Kairo body, marked with its adt_role and adt_form, and
///     InterfaceEmitter renders the C++ from those. The constraints are C++
///     mechanics, not Kairo constraints: no role function has a
///     requires_clause.
///
///   Phase: LOWER, before every body rewrite: every later pass and EmitPlan
///   must see the record's members (MatchLowering reads adt_tag_field and
///   adt_member). It touches no body, so its place beside
///   VariantInitLowering, which reads nothing it builds, is free.
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
import Sema::Check::ClassLifecycle::*;
import Sema::Lower::LowerSynth::*;
import AST::Visitor::ASTWriter::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::LangItems::*;
import AST::Mixin::Annotation::*;
import AST::Context::DeclContext::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import Token::Token::*;
import Location::SourceRange::*;

__inline_cpp("
#define ASTWriter_EnumLayoutLowering ASTWriter<EnumLayoutLowering>
");

class EnumLayoutLowering derives ASTWriter::<EnumLayoutLowering> {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var synth: LowerSynth;

    fn EnumLayoutLowering(self, sc: *SemaContext) {
        self.sc    = sc;
        self.ctx   = sc->ctx;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    fn run(self) {
        self.sc->require_phase(SemaPhase::Checked);
        if self.sc->tu == &null { return; }
        ASTWriter_EnumLayoutLowering::run(self.sc->tu);
    }

    // --- entry point --------------------------------------------------------------

    /// Wherever the walk finds one: at file scope, in a module, nested in a
    /// record.
    fn transform_enum_decl(self, n: *EnumDecl) -> vec::<*Decl> {
        var out = ASTWriter_EnumLayoutLowering::transform_enum_decl(n);
        if self._wants_layout(n) { self._build(n); }
        return out;
    }

    /// An ADT's pattern, once. An instance shares its pattern's record; a
    /// redeclaration chain is built at its representative, the decl every
    /// RecordType names; a decl the walk reaches twice (a visibility group
    /// lists its members again) already has its record. A poisoned enum or
    /// an unresolved payload type was reported, and an error keeps the
    /// lowerings from running at all, so that test is only a guard.
    priv fn _wants_layout(self, en: *EnumDecl) -> bool {
        if (!en->is_adt) || en->is_poisoned() { return false; }
        var d = static_cast::<*Decl>(en);
        if decl_is_instance(d) { return false; }
        if NameLookup::representative(d) != d { return false; }
        if en->adt_layout != &null { return false; }
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if (v == &null) || v->is_poisoned() { return false; }
            for var j: usize = 0; j < v->payload.size(); ++j {
                var f = v->payload[j];
                if (f == &null) || f->is_poisoned() { return false; }
                if (f->type_ == &null) || (f->type_->canonical == &null) { return false; }
            }
        }
        return true;
    }

    // --- the record ---------------------------------------------------------------

    priv fn _build(self, en: *EnumDecl) {
        var at      = en->name.range;
        var edc     = static_cast::<*DeclContext>(en);
        var generic = en->generic_params.size() > 0;

        // The enum's own name and generic parameters: to C++ this record IS
        // the enum, so anything that asks it for either gets the enum's.
        var lay = StructDecl::create(self.ctx, en->range, en->name, edc);
        self._place(static_cast::<*Decl>(lay), edc, VisibilityKind::Public, at);
        self._no_members(lay);
        lay->generic_params = en->generic_params;
        lay->adt_of         = static_cast::<*Decl>(en);
        var ldc = static_cast::<*DeclContext>(lay);

        var tag = self._tag_enum(en, at, edc);
        ldc->add_decl(static_cast::<*Decl>(tag));

        // A struct and a union member for each variant that has a payload.
        var members = self.list_builder::<*FieldDecl>();
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if v->payload.is_empty() { continue; }
            var vn = self.tu.decl_name(static_cast::<*Decl>(v));
            var ps = self._payload_struct(v, vn, edc);
            ldc->add_decl(static_cast::<*Decl>(ps));
            var m = FieldDecl::create(self.ctx, v->name.range,
                                      self.synth.ident(v->name.range, LowerTargets::adt_payload_field(vn)),
                                      StorageClass::Var, self._type_of(static_cast::<*Decl>(ps)), u32(members.size()));
            self._place(static_cast::<*Decl>(m), edc, VisibilityKind::Public, v->name.range);
            members.push(m);
            v->adt_member = m;
        }

        var fields = self.list_builder::<*FieldDecl>();
        var tf = FieldDecl::create(self.ctx, at, self.synth.ident(at, LowerTargets::adt_tag_field()),
                                   StorageClass::Var, self._type_of(static_cast::<*Decl>(tag)), 0);
        self._place(static_cast::<*Decl>(tf), edc, VisibilityKind::Public, at);
        ldc->add_decl(static_cast::<*Decl>(tf));
        fields.push(tf);

        // No name, and declared only by the field that holds it: its members
        // are the record's to C++, and that field is in no field_of chain
        // (FieldDecl::is_anonymous_union).
        var un = UnionDecl::create(self.ctx, at, Token(), edc);
        self._place(static_cast::<*Decl>(un), edc, VisibilityKind::Public, at);
        un->is_anonymous   = true;
        un->methods        = create_empty_frozen_list::<*FunctionDecl>();
        un->generic_params = create_empty_frozen_list::<*GenericParamDecl>();
        un->spec_args      = create_empty_frozen_list::<*Type>();
        members.freeze_into(&(un->fields));
        ldc->add_decl(static_cast::<*Decl>(un));

        var uf = FieldDecl::create(self.ctx, at, Token(), StorageClass::Var, self._type_of(static_cast::<*Decl>(un)), 1);
        uf->is_anonymous_union = true;
        self._place(static_cast::<*Decl>(uf), edc, VisibilityKind::Public, at);
        ldc->add_decl(static_cast::<*Decl>(uf));
        fields.push(uf);

        // What a generic ADT's constraints test. No expression stands behind
        // a flag: InterfaceEmitter writes its initializer from the payload
        // structs, so the field only names it.
        if generic {
            self._flag(LowerTargets::adt_trivial_dtor(), at, edc, ldc, &fields);
            self._flag(LowerTargets::adt_trivial_copy(), at, edc, ldc, &fields);
            self._flag(LowerTargets::adt_destructible(), at, edc, ldc, &fields);
            self._flag(LowerTargets::adt_copyable(),     at, edc, ldc, &fields);
            self._flag(LowerTargets::adt_movable(),      at, edc, ldc, &fields);
        }
        fields.freeze_into(&(lay->fields));

        var methods = self.list_builder::<*FunctionDecl>();
        for var i: usize = 0; i < en->variants.size(); ++i {
            self._member(ldc, &methods, self._role(en, en->name, AdtRole::VariantCtor, AdtForm::Body, u32(i), VisibilityKind::Public));
        }
        if generic {
            self._three(ldc, &methods, en, AdtRole::CopyCtor);
            self._three(ldc, &methods, en, AdtRole::MoveCtor);
            self._three(ldc, &methods, en, AdtRole::CopyAssign);
            self._three(ldc, &methods, en, AdtRole::MoveAssign);
            self._three(ldc, &methods, en, AdtRole::Dtor);
        } else {
            self._chosen(ldc, &methods, en);
        }
        // What the bodies above call; nothing outside the record may.
        self._member(ldc, &methods, self._role(en, self.synth.ident(at, LowerTargets::adt_destroy()),
                                               AdtRole::Destroy, AdtForm::Body, 0, VisibilityKind::Private));
        self._member(ldc, &methods, self._role(en, self.synth.ident(at, LowerTargets::adt_construct_from()),
                                               AdtRole::ConstructFrom, AdtForm::Body, 0, VisibilityKind::Private));
        methods.freeze_into(&(lay->methods));

        en->adt_layout    = static_cast::<*Decl>(lay);
        en->adt_tag_field = tf;
    }

    /// `enum class __kairo_Tag : u32 { V0, V1, ... }`: every variant, payload
    /// or not, by its own name and in order. No discriminants, so each value
    /// is the variant's position and InterfaceEmitter writes the names bare.
    priv fn _tag_enum(self, en: *EnumDecl, at: SourceRange, edc: *DeclContext) -> *EnumDecl {
        var tag = EnumDecl::create(self.ctx, at, self.synth.ident(at, LowerTargets::adt_tag_type()), edc);
        self._place(static_cast::<*Decl>(tag), edc, VisibilityKind::Public, at);
        tag->underlying     = self.sc->builtin(BuiltinKind::U32);
        tag->generic_params = create_empty_frozen_list::<*GenericParamDecl>();
        tag->spec_args      = create_empty_frozen_list::<*Type>();
        var tdc = static_cast::<*DeclContext>(tag);
        var vs  = self.list_builder::<*EnumVariantDecl>();
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v  = en->variants[i];
            var tv = EnumVariantDecl::create(self.ctx, v->range, v->name, u32(i));
            self._place(static_cast::<*Decl>(tv), tdc, VisibilityKind::Public, v->name.range);
            tv->payload = create_empty_frozen_list::<*FieldDecl>();
            vs.push(tv);
        }
        vs.freeze_into(&(tag->variants));
        return tag;
    }

    /// `struct __kairo_<V>_t` over the variant's own payload FieldDecls (file
    /// header). is_adt_payload is what gives it its placement operator new.
    priv fn _payload_struct(self, v: *EnumVariantDecl, vn: string, edc: *DeclContext) -> *StructDecl {
        var ps = StructDecl::create(self.ctx, v->range, self.synth.ident(v->name.range, LowerTargets::adt_payload_type(vn)), edc);
        self._place(static_cast::<*Decl>(ps), edc, VisibilityKind::Public, v->name.range);
        self._no_members(ps);
        ps->is_adt_payload = true;
        var pdc = reinterpret_cast::<*void>(static_cast::<*DeclContext>(ps));
        var fs  = self.list_builder::<*FieldDecl>();
        for var j: usize = 0; j < v->payload.size(); ++j {
            var f = v->payload[j];
            fs.push(f);
            // A variant is not a DeclContext, so the parser leaves its
            // payload fields with no scope at all. To C++ they are members
            // of this struct, and that is where a spelling of one
            // (CXXSpell::leaf reads the name in its scope's TU) and a use of
            // one (EmitPlan::_member_owner) must find it.
            var fd = static_cast::<*Decl>(f);
            if fd->semantic_dc == &null { fd->semantic_dc = pdc; }
            if fd->lexical_dc == &null  { fd->lexical_dc  = pdc; }
        }
        fs.freeze_into(&(ps->fields));
        return ps;
    }

    /// A generic ADT's flag: a compile-time bool (eval, C++'s `static
    /// constexpr`) whose initializer InterfaceEmitter writes.
    priv fn _flag(self, name: string, at: SourceRange, edc: *DeclContext, ldc: *DeclContext,
                  fields: *ListBuilder::<*FieldDecl>) {
        var f = FieldDecl::create(self.ctx, at, self.synth.ident(at, name), StorageClass::Eval,
                                  self.sc->builtin(BuiltinKind::Bool), u32(fields->size()));
        self._place(static_cast::<*Decl>(f), edc, VisibilityKind::Public, at);
        ldc->add_decl(static_cast::<*Decl>(f));
        fields->push(f);
    }

    // --- the special members ------------------------------------------------------

    /// The one form of each special member a non-generic ADT's facts select
    /// (file header). Each assignment takes its constructor's form.
    priv fn _chosen(self, ldc: *DeclContext, methods: *ListBuilder::<*FunctionDecl>, en: *EnumDecl) {
        var f = lifecycle_of(self.sc)->facts_of(static_cast::<*Decl>(en));
        // Nothing in a non-generic enum's own declaration waits on a
        // parameter. An Unknown comes from a payload whose facts do -- an
        // instance of a generic record reads its pattern's until facts are
        // computed per instance -- and a form picked for it would be a guess.
        // FeatureGateCheck reports exactly this case (the same
        // lifecycle_open), so reaching it means that gate has a hole.
        ICE_IF(lifecycle_open(f), "EnumLayoutLowering: non-generic ADT with unknown lifecycle facts");
        var copy_form = AdtForm::Trivial;
        var move_form = AdtForm::Trivial;
        var dtor_form = AdtForm::Trivial;
        if f->trivially_copyable != LifecycleTri::Yes {
            copy_form = (AdtForm::Body) if (f->category == LifecycleCategory::Copy) else (AdtForm::Deleted);
            move_form = (AdtForm::Deleted) if (f->category == LifecycleCategory::NonTransfer) else (AdtForm::Body);
        }
        if f->trivial_dtor != LifecycleTri::Yes {
            dtor_form = (AdtForm::Body) if (f->destructible == LifecycleTri::Yes) else (AdtForm::Deleted);
        }
        self._member(ldc, methods, self._role(en, en->name, AdtRole::CopyCtor,   copy_form, 0, VisibilityKind::Public));
        self._member(ldc, methods, self._role(en, en->name, AdtRole::MoveCtor,   move_form, 0, VisibilityKind::Public));
        self._member(ldc, methods, self._role(en, en->name, AdtRole::CopyAssign, copy_form, 0, VisibilityKind::Public));
        self._member(ldc, methods, self._role(en, en->name, AdtRole::MoveAssign, move_form, 0, VisibilityKind::Public));
        self._member(ldc, methods, self._role(en, en->name, AdtRole::Dtor,       dtor_form, 0, VisibilityKind::Public));
    }

    /// A generic ADT's three forms of \p role, in the order InterfaceEmitter
    /// writes them.
    priv fn _three(self, ldc: *DeclContext, methods: *ListBuilder::<*FunctionDecl>, en: *EnumDecl, role: AdtRole) {
        self._member(ldc, methods, self._role(en, en->name, role, AdtForm::Trivial, 0, VisibilityKind::Public));
        self._member(ldc, methods, self._role(en, en->name, role, AdtForm::Body,    0, VisibilityKind::Public));
        self._member(ldc, methods, self._role(en, en->name, role, AdtForm::Deleted, 0, VisibilityKind::Public));
    }

    /// A function with no Kairo body, rendered from \p role and \p form.
    /// Never an operator, whatever C++ it becomes (`~E`, `operator=`): its
    /// name is an identifier token, which is all a minted decl can spell. A
    /// defaulted or deleted form carries that body kind; the others none.
    priv fn _role(self, en: *EnumDecl, name: Token, role: AdtRole, form: AdtForm, variant: u32,
                  vis: VisibilityKind) -> *FunctionDecl {
        var edc = static_cast::<*DeclContext>(en);
        var f   = FunctionDecl::create(self.ctx, name.range, name, edc);
        self._place(static_cast::<*Decl>(f), edc, vis, name.range);
        f->params          = create_empty_frozen_list::<*ParamDecl>();
        f->op_token        = create_empty_frozen_list::<Token>();
        f->generic_params  = create_empty_frozen_list::<*GenericParamDecl>();
        f->spec_args       = create_empty_frozen_list::<*Type>();
        f->requires_clause = &null;
        f->is_implicit     = true;
        f->body_kind       = FnBodyKind::None;
        if form == AdtForm::Trivial { f->body_kind = FnBodyKind::Default; }
        if form == AdtForm::Deleted { f->body_kind = FnBodyKind::Delete; }
        f->adt_role    = role;
        f->adt_form    = form;
        f->adt_variant = variant;
        return f;
    }

    priv fn _member(self, ldc: *DeclContext, methods: *ListBuilder::<*FunctionDecl>, f: *FunctionDecl) {
        ldc->add_decl(static_cast::<*Decl>(f));
        methods->push(f);
    }

    // --- minting ------------------------------------------------------------------

    /// Every minted decl belongs to the enum, so it is spelled and planned as
    /// a member of it (a tag enum's variants belong to the tag enum). None
    /// joins a symbol table: nothing finds them by name.
    priv fn _place(self, d: *Decl, dc: *DeclContext, vis: VisibilityKind, at: SourceRange) {
        d->semantic_dc = reinterpret_cast::<*void>(dc);
        d->lexical_dc  = reinterpret_cast::<*void>(dc);
        d->set_visibility(vis, at);
    }

    priv fn _no_members(self, s: *StructDecl) {
        s->fields         = create_empty_frozen_list::<*FieldDecl>();
        s->methods        = create_empty_frozen_list::<*FunctionDecl>();
        s->implements     = create_empty_frozen_list::<InheritEdge>();
        s->generic_params = create_empty_frozen_list::<*GenericParamDecl>();
        s->spec_args      = create_empty_frozen_list::<*Type>();
    }

    priv fn _type_of(self, d: *Decl) -> *Type {
        return self.sc->types->record(d, &null);
    }
}

__inline_cpp("
#undef ASTWriter_EnumLayoutLowering
");
