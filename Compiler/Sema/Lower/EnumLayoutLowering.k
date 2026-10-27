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
///           enum class __kairo_Tag : u8 { Some, None };
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
///   adt_member, OperatorLowering adt_tag_field). It touches no body, so its
///   place beside
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
import AST::Node::Expressions::*;
import AST::Node::PrimaryExpressions::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import Token::Token::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

/// The layout's query surface: every pass that reads or tests an ADT value
/// goes through it, and none spells the layout itself. The layout is not
/// uniform -- the tag's width, its values and whether there is a tag at
/// all are this file's decisions -- so a consumer that wrote
/// `x.__kairo_tag` or `x.__kairo_<V>.f` by hand would be right only for
/// the shape it was written against.
///
///   tag_read(x)              the discriminant as stored, typed as the tag
///                            enum; null when the layout has no tag
///   tag_value(V)             the discriminant V is stored as
///   variant_test(x, V)       bool: "x holds V"
///   payload_ref(x, V)        lvalue of V's payload struct
///   field_ref(x, V, f)       lvalue of one payload field
///   same_variant(a, b)       bool: an ADT's built-in `==` (no `op ==`)
///   is_exhaustive_dense(E)   tags are 0..N-1 in declaration order, so a
///                            switch or a table over them is complete
///
/// Construction is the VariantInitExpr VariantInitLowering builds; how it
/// is rendered is read off the variant's facts by EmitIR, so no lowering
/// spells a constructor either.
///
/// Consumers: MatchLowering, OperatorLowering (an ADT's `==`), and
/// PanicLowering when it lands. The Nullable lang item's surface
/// (`is_null()`, `__value()`, its constructors) is layout-independent by
/// construction and is named through SemaContext::nullable_member.
class EnumLayoutQuery {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var synth: LowerSynth;

    fn EnumLayoutQuery(self) { self.sc = &null; }

    fn EnumLayoutQuery(self, sc: *SemaContext) {
        self.sc    = sc;
        self.tu    = TypeUtil(sc);
        self.synth = LowerSynth(sc);
    }

    /// The ADT pattern behind the value type \p t (an instance answers its
    /// pattern: an instance shares its pattern's record), or null.
    fn adt_of(self, t: *Type) -> *EnumDecl {
        if t == &null { return &null; }
        var d = self.tu.record_decl(self.tu.as_value(t));
        if d == &null { return &null; }
        var en = dyn_cast::<EnumDecl>(self.tu.pattern_of(d));
        if (en == &null) || (!en->is_adt) { return &null; }
        return en;
    }

    /// A payload field's type at an instance of \p en with arguments \p args:
    /// a parameter of the enum's is its argument, a type that names none is
    /// itself, and a pointer is a pointer whatever it points at -- which is
    /// all a layout question asks of one. Null for anything else built from
    /// a parameter: the question has no answer before C++ instantiates it.
    fn field_type_at(self, en: *EnumDecl, args: *FrozenList::<*Type>, ft: *Type) -> *Type {
        if (ft == &null) || (ft->canonical == &null) { return &null; }
        var c = canon_unqual(ft->canonical);
        if c == &null { return &null; }
        var gp = dyn_cast::<GenericParamType>(c);
        if gp != &null {
            var owner = gp->owner;
            if owner != &null { owner = NameLookup::representative(owner); }
            if (owner != NameLookup::representative(static_cast::<*Decl>(en))) || (usize(gp->param_index) >= args->size()) { return &null; }
            var a = *(args->get(usize(gp->param_index)));
            if (a == &null) || a->is_dependent() || a->is_instantiation_dependent() { return &null; }
            return a;
        }
        if isa::<PointerType>(c) { return ft; }
        if c->is_dependent() || c->is_instantiation_dependent() { return &null; }
        return ft;
    }

    /// EnumLayoutLowering built \p en's record: every query below has an
    /// answer.
    fn has_layout(self, en: *EnumDecl) -> bool {
        return (en != &null) && en->is_adt && (en->adt_layout != &null);
    }

    /// Whether variant \p index has a payload to read.
    fn has_payload(self, en: *EnumDecl, index: u32) -> bool {
        if (en == &null) || (usize(index) >= en->variants.size()) { return false; }
        var v = en->variants[usize(index)];
        return (v != &null) && (v->adt_member != &null);
    }

    fn is_exhaustive_dense(self, en: *EnumDecl) -> bool {
        return self.has_layout(en);
    }

    /// The discriminant variant \p index is stored as.
    fn tag_value(self, en: *EnumDecl, index: u32) -> u64 {
        return u64(index);
    }

    /// `x.__kairo_tag`, typed as the tag enum.
    fn tag_read(self, at: SourceRange, x: *Expr, en: *EnumDecl) -> *Expr {
        var tag = en->adt_tag_field;
        ICE_IF(tag == &null, "EnumLayoutQuery: tag_read on an ADT with no layout; EnumLayoutLowering runs first");
        return self.synth.field_of(at, x, static_cast::<*Decl>(tag), tag->type_);
    }

    /// The tag as a `u32`, which is what a switch dispatches on and a case
    /// label is written in (tag_case).
    fn tag_word(self, at: SourceRange, x: *Expr, en: *EnumDecl) -> *Expr {
        var t = self.tag_read(at, x, en);
        if t == &null { return &null; }
        return self.synth.cast_to(at, t, self.sc->builtin(BuiltinKind::U32), CastMode::Default);
    }

    /// Variant \p index's discriminant as a case label of tag_word.
    fn tag_case(self, at: SourceRange, en: *EnumDecl, index: u32) -> *Expr {
        return self.synth.int_literal(at, self.tag_value(en, index), BuiltinKind::U32);
    }

    fn variant_test(self, at: SourceRange, x: *Expr, en: *EnumDecl, index: u32) -> *Expr {
        return self._bin(at, self.tag_word(at, x, en), self.tag_case(at, en, index), TokenKind::OpEqualEqual);
    }

    /// `x.__kairo_<V>`. A variant with no payload has nothing to read.
    fn payload_ref(self, at: SourceRange, x: *Expr, en: *EnumDecl, index: u32) -> *Expr {
        ICE_IF(!self.has_payload(en, index), "EnumLayoutQuery: payload_ref of a variant with no payload");
        var m = en->variants[usize(index)]->adt_member;
        return self.synth.field_of(at, x, static_cast::<*Decl>(m), m->type_);
    }

    /// `x.__kairo_<V>.<field>`, typed \p ty (the occurrence's type: an
    /// instance's field type, not the pattern's).
    fn field_ref(self, at: SourceRange, x: *Expr, en: *EnumDecl, index: u32, field: *FieldDecl, ty: *Type) -> *Expr {
        return self.synth.field_of(at, self.payload_ref(at, x, en, index), static_cast::<*Decl>(field), ty);
    }

    /// An ADT's built-in `==` / `!=`: the variants compared, under the
    /// written token. Each operand appears once, so each runs once.
    fn same_variant(self, at: SourceRange, a: *Expr, b: *Expr, en: *EnumDecl, tok: Token) -> *Expr {
        var cmp = BinaryOperatorExpr::create(self.sc->ctx, at, self.tag_read(a->range, a, en), self.tag_read(b->range, b, en), tok);
        return static_cast::<*Expr>(cmp);
    }

    priv fn _bin(self, at: SourceRange, l: *Expr, r: *Expr, k: TokenKind) -> *Expr {
        var b = BinaryOperatorExpr::create(self.sc->ctx, at, l, r, self.synth.punct(at, k));
        b->type_          = self.sc->builtin(BuiltinKind::Bool);
        b->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(b);
    }
}

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
        ASTWriter::<EnumLayoutLowering>::run(self.sc->tu);
    }

    // --- entry point --------------------------------------------------------------

    /// Wherever the walk finds one: at file scope, in a module, nested in a
    /// record.
    fn transform_enum_decl(self, n: *EnumDecl) -> vec::<*Decl> {
        var out = ASTWriter::<EnumLayoutLowering>::transform_enum_decl(n);
        if self._wants_layout(n) { self._build(n); }
        return out;
    }

    /// A construction: a generic variant built both ways (AdtCtorForm::Both)
    /// calls its field constructor where the instance is concrete and every
    /// field moves. The layout is built first if the walk has not reached
    /// the enum yet, so a construction above its enum is decided the same
    /// way as one below it.
    fn transform_variant_init_expr(self, n: *VariantInitExpr) -> *Expr {
        var out = ASTWriter::<EnumLayoutLowering>::transform_variant_init_expr(n);
        var en  = dyn_cast::<EnumDecl>(n->en);
        if (en == &null) || (!en->is_adt) || (usize(n->variant) >= en->variants.size()) { return out; }
        if self._wants_layout(en) { self._build(en); }
        var v = en->variants[usize(n->variant)];
        if (v == &null) || (v->adt_ctor != AdtCtorForm::Both) || (n->type_ == &null) { return out; }
        if n->type_->is_dependent() || n->type_->is_instantiation_dependent() { return out; }
        var q    = EnumLayoutQuery(self.sc);
        var args = self.tu.record_args(n->type_);
        for var i: usize = 0; i < v->payload.size(); ++i {
            var ft = q.field_type_at(en, &args, v->payload[i]->type_);
            if (ft == &null) || (!self._moves(ft)) { return out; }
        }
        n->field_ctor = true;
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
            v->adt_ctor   = self._ctor_form(v, generic);
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
        if self._is_nullable(en) { self._nullable_surface(ldc, &methods, en); }
        methods.freeze_into(&(lay->methods));

        en->adt_layout    = static_cast::<*Decl>(lay);
        en->adt_tag_field = tf;
    }

    /// `enum class __kairo_Tag : u8 { V0, V1, ... }`: every variant, payload
    /// or not, by its own name and in order. No discriminants, so each value
    /// is the variant's position and InterfaceEmitter writes the names bare.
    /// The narrowest word that holds them (_tag_kind): the tag sits before
    /// the union, so every byte past it is padding a small payload pays.
    priv fn _tag_enum(self, en: *EnumDecl, at: SourceRange, edc: *DeclContext) -> *EnumDecl {
        var tag = EnumDecl::create(self.ctx, at, self.synth.ident(at, LowerTargets::adt_tag_type()), edc);
        self._place(static_cast::<*Decl>(tag), edc, VisibilityKind::Public, at);
        tag->underlying     = self.sc->builtin(self._tag_kind(en));
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

    /// The `derives` type when the enum declares one (TypeResolve checked
    /// it holds every tag), else `u8` up to 256 variants and `u16` past
    /// that. Tags stay dense `0..N-1` in declaration order whatever the
    /// width: MatchLowering's switch, and the jump table clang builds from
    /// it, index by them.
    priv fn _tag_kind(self, en: *EnumDecl) -> BuiltinKind {
        var u = en->underlying;
        if (u != &null) && (!u->is_poisoned()) && (u->canonical != &null) {
            var c = canon_unqual(u->canonical);
            if (c != &null) && isa::<BuiltinType>(c) && builtin_info(cast::<BuiltinType>(c)->builtin)->is_integer() {
                return cast::<BuiltinType>(c)->builtin;
            }
        }
        if en->variants.size() <= 256 { return BuiltinKind::U8; }
        return BuiltinKind::U16;
    }

    /// How variant \p v is constructed (AdtCtorForm). A non-generic ADT knows
    /// its fields' facts: every one trivially copied and destroyed, the field
    /// constructor alone, else the lambda one. A generic ADT's are per
    /// instance, so it gets both, the field constructor constrained on them.
    /// An array field is never passed by value: a C++ parameter of array
    /// type is a pointer.
    ///
    /// Trivial, not merely movable: the field constructor moves each
    /// argument out of its parameter into the payload, and then destroys the
    /// parameter. The lambda form builds the payload in place and does
    /// neither. A Kairo `@move` constructor or `op delete` is user code that
    /// can count (Codegen/adt/categories.k and smoke.k do), so only for a
    /// field whose move is its bytes and whose destruction is nothing are
    /// the two forms the same program.
    priv fn _ctor_form(self, v: *EnumVariantDecl, generic: bool) -> AdtCtorForm {
        for var j: usize = 0; j < v->payload.size(); ++j {
            var t = v->payload[j]->type_;
            if (t == &null) || (t->canonical == &null) || isa::<FixedArrayType>(canon_unqual(t->canonical)) {
                return AdtCtorForm::Lambda;
            }
        }
        if generic { return AdtCtorForm::Both; }
        for var j: usize = 0; j < v->payload.size(); ++j {
            if !self._moves(v->payload[j]->type_) { return AdtCtorForm::Lambda; }
        }
        return AdtCtorForm::Fields;
    }

    /// \p t moves as its bytes and is destroyed as nothing, and is no array
    /// (_ctor_form).
    priv fn _moves(self, t: *Type) -> bool {
        if (t == &null) || (t->canonical == &null) { return false; }
        if isa::<FixedArrayType>(canon_unqual(t->canonical)) { return false; }
        var f = lifecycle_of(self.sc)->facts_of_type(t->canonical);
        return (f.movable == LifecycleTri::Yes) && (f.trivially_copyable == LifecycleTri::Yes)
            && (f.trivial_dtor == LifecycleTri::Yes);
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
            // one (EmitPlan::_member_owner) must find it. This is the only
            // writer: a scope already here means a second one exists, and
            // whichever ran last would silently decide where the field lives.
            var fd = static_cast::<*Decl>(f);
            ICE_IF((fd->semantic_dc != &null) || (fd->lexical_dc != &null),
                   "EnumLayoutLowering: payload field already has a scope; this pass is its only writer");
            fd->semantic_dc = pdc;
            fd->lexical_dc  = pdc;
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

    // --- the Nullable lang item -----------------------------------------------------

    /// By identity with the lang item, never by name: a user may declare an
    /// enum called Nullable.
    priv fn _is_nullable(self, en: *EnumDecl) -> bool {
        var nd = self.sc->nullable_enum();
        return (nd != &null) && (nd == en);
    }

    /// `T?`'s C++ surface on top of the ADT (NULLABLE.md 1.2): the ADT
    /// already holds a real T only while present and transfers it as T
    /// does; these are the constructors every implicit conversion into a
    /// nullable is, and the primitives the desugars and a C++ host call.
    /// The null constructor's parameter is a real ParamDecl so its null_t is
    /// spelled like any type; the rest are rendered from the payload.
    priv fn _nullable_surface(self, ldc: *DeclContext, methods: *ListBuilder::<*FunctionDecl>, en: *EnumDecl) {
        var at = en->name.range;
        self._member(ldc, methods, self._role(en, en->name, AdtRole::NullDefault, AdtForm::Body, 0, VisibilityKind::Public));
        var from = self._role(en, en->name, AdtRole::NullFrom, AdtForm::Body, 0, VisibilityKind::Public);
        var nt   = self.sc->well_known->get(WellKnownType::NullT);
        ICE_IF(nt == &null, "EnumLayoutLowering: the Nullable lang item without null_t; Lib/builtin declares both");
        var ps = self.list_builder::<*ParamDecl>();
        ps.push(ParamDecl::create(self.ctx, at, self.synth.ident(at, LowerTargets::nullable_null_param()), self._type_of(NameLookup::representative(nt)), 0));
        ps.freeze_into(&(from->params));
        self._member(ldc, methods, from);
        self._member(ldc, methods, self._role(en, en->name, AdtRole::ValueCopy, AdtForm::Body, 0, VisibilityKind::Public));
        self._member(ldc, methods, self._role(en, en->name, AdtRole::ValueMove, AdtForm::Body, 0, VisibilityKind::Public));
        var is_null = self.synth.ident(at, LowerTargets::nullable_is_null());
        var value   = self.synth.ident(at, LowerTargets::nullable_value());
        self._member(ldc, methods, self._role(en, is_null, AdtRole::IsNull,    AdtForm::Body, 0, VisibilityKind::Public));
        self._member(ldc, methods, self._role(en, value,   AdtRole::ValueRef,  AdtForm::Body, 0, VisibilityKind::Public));
        self._member(ldc, methods, self._role(en, value,   AdtRole::ValueCref, AdtForm::Body, 0, VisibilityKind::Public));
        self._member(ldc, methods, self._role(en, en->name, AdtRole::Equal,    AdtForm::Body, 0, VisibilityKind::Public));
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
