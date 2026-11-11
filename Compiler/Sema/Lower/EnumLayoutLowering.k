/// --- The Kairo Project -------------- Sema/Lower/EnumLayoutLowering.k --- ///
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
///           Opt(::__kairo_vt<0>, T v) noexcept requires (<T trivial>)   // AdtCtorForm
///               : __kairo_tag(__kairo_Tag::Some), __kairo_Some{static_cast<T&&>(v)} {}
///           template <class F> Opt(::__kairo_vt<0>, F&& f) noexcept
///               : __kairo_tag(__kairo_Tag::Some), __kairo_Some(static_cast<F&&>(f)()) {}
///           Opt(::__kairo_vt<1>) noexcept : __kairo_tag(__kairo_Tag::None) {}
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
///   \par The tag
///     The enum's `derives` type, else u8 (u16 past 256 variants): the tag
///     sits before the union, so each byte past what it needs is padding a
///     small payload pays. Its values are the variant positions, dense, in
///     declaration order: the match switch and its jump table index by them.
///
///   \par The tag in the common prefix
///     A non-generic ADT that is not niche-filled, whose payload fields are
///     all builtins, pointers or plain enums (_prefix_ok), keeps its tag in
///     its payloads instead of beside them: each payload struct starts with
///     `__kairo_Tag __kairo_tag`, the union gains a first member `__kairo_t`
///     holding only that tag, and the tag is read as `x.__kairo_t.__kairo_tag`
///     (EnumDecl::adt_tag_member / adt_prefix_tag). Every payload struct is
///     standard-layout, so the common-initial-sequence rule defines that
///     read whichever payload is live, and the payload's padding absorbs
///     the tag (`{u8, u16} | {u8}` is 4 bytes, not 6). Its fields are
///     trivial, so the special members are the defaulted ones and no
///     helper switches on a tag that is no longer a member of its own.
///     A generic ADT keeps the external tag: whether its payloads are
///     standard-layout is per instance.
///
///   \par Niche layout
///     An ADT with exactly one payload variant, whose payload is one field,
///     beside at least one dataless variant, is niche-shaped
///     (EnumDecl::adt_niche_shape). It is laid out with no tag and no union
///     -- the payload struct is the record's one member -- when the field
///     has at least as many invalid bit patterns as there are dataless
///     variants (EnumLayoutQuery::niche_of: a pointer's null, a dense plain
///     enum's or a tagged ADT's spare tag values, what a niche-filled ADT
///     leaves) and is trivially copied and destroyed, so every special
///     member stays the defaulted one. Dataless variant j (in declaration
///     order) is the field's pattern j. For `Opt<*Foo>` that is
///     `__kairo_Some.v == nullptr` for None, and `sizeof` is a pointer's.
///
///     A non-generic ADT is decided here (EnumDecl::adt_niche). A generic
///     one cannot be: Sema does not see every instance (a generic body's are
///     clang's), so InterfaceEmitter writes the niche-filled record as a
///     partial specialization constrained on the same rule, over the
///     `__kairo_niche<T>` trait, and C++ picks per instance -- the same pick
///     in every TU and C++ host. EnumLayoutQuery predicts it to read and
///     test values directly; where it cannot (a dependent type, facts only
///     an instance has) it asks `__kairo_which()`, which both forms answer.
///     sweep() records each instance's predicted shape and size, and the
///     static_asserts beside its instantiation make a wrong prediction a
///     compile error.
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KThread.hh" // sema_mint_rank
ffi "c++" import "vector"

import AST::ASTSupport::{
    FrozenList,
    create_empty_frozen_list,
}
import AST::AttrFacts::AttrFacts
import AST::Context::DeclContext::DeclContext
import AST::Context::InstantiationRegistry::InstanceEntry
import AST::DeclFacts::{
    adt_expansion_at,    adt_pack_param,   adt_pack_variant, adt_variant_at,       adt_variant_pos,
    decl_generic_params, decl_is_imported, decl_is_instance, decl_requires_clause,
}
import AST::EnumNiche::{
    adt_declared_tag_kind,
    adt_first_spare_tag,
    adt_niche_dataless,
    adt_niche_pattern_of,
    adt_niche_payload_variant,
    adt_tag_kind,
    adt_tag_niche_count,
    enum_niche_count,
    enum_niche_kind,
}
import AST::Kind::DeclKind::to_string
import AST::LangItems::{
    LowerTargets,
    WellKnownType,
    to_string,
}
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    RecordType,
    canon_quals,
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
    CallExpr,
    CastMode,
    PanicOp,
    PanicOpExpr,
    VariantInitExpr,
}
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
    NullLiteralExpr,
}
import AST::Node::Types::{
    FixedArrayType,
    FunctionPointerType,
    GenericParamType,
    NullableType,
    PointerType,
}
import AST::Visitor::ASTWriter::{
    ASTWriter,
    ListBuilder,
}
import Diagnostic::Registry::DiagID
import Location::SourceRange::SourceRange
import Sema::Check::ClassLifecycle::{
    LifecycleCategory,
    LifecycleTri,
    lifecycle_of,
    lifecycle_open,
}
import Sema::Lower::LowerSynth::LowerSynth
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::Type::PanicSets::PanicSets
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenKind::TokenKind

/// How an ADT value is laid out at one type (EnumLayoutQuery::shape_at).
///   Tagged  a tag field and a payload union: the tag is read directly.
///   Niche   no tag (EnumLayoutLowering's header, "Niche layout"): a
///           dataless variant is a value the payload's one field never
///           holds, so a test compares that field against it.
///   Opaque  a generic ADT whose instance C++ lays out -- a dependent type,
///           or one whose facts Sema cannot settle: the value is asked
///           through `__kairo_which()`, which both layouts answer.
pub enum AdtShape derives u8 {
    Tagged = 0,
    Niche,
    Opaque,
}

/// "No answer": a niche count that depends on what only C++ instantiates.
pub fn niche_unknown() -> u64 {
    return ~(0 as u64)
}

/// The layout's query surface: every pass that reads or tests an ADT value
/// goes through it, and none spells the layout itself. The layout is not
/// uniform -- the tag's width, its values and whether there is a tag at
/// all are this file's decisions -- so a consumer that wrote
/// `x.__kairo_tag` or `x.__kairo_<V>.f` by hand would be right only for
/// the shape it was written against. Every answer is for the value's own
/// type (`x->type_`): a generic ADT's instances need not share a shape.
///
///   tag_read(x)              the discriminant as stored, typed as the tag
///                            enum; null when the layout has no tag
///   tag_value(t, V)          the discriminant V is stored as at type t
///   variant_test(x, V)       bool: "x holds V"
///   payload_ref(x, V)        lvalue of V's payload struct
///   field_ref(x, V, f)       lvalue of one payload field
///   same_variant(a, b)       bool: an ADT's built-in `==` (no `op ==`)
///   is_exhaustive_dense(E)   tags are 0..N-1 in declaration order, so a
///                            switch or a table over them is complete
///   niche_of(T)              how many bit patterns T never holds (spec
///                            ENUMLAYOUT §5.1), the layout engine's input
///
/// Construction is the VariantInitExpr VariantInitLowering builds; how it
/// is rendered is read off the variant's facts by EmitIR, so no lowering
/// spells a constructor either.
///
/// Consumers: MatchLowering, OperatorLowering (an ADT's `==`), and
/// PanicLowering when it lands. The Nullable lang item's surface
/// (`is_null()`, `__value()`, its constructors) is layout-independent by
/// construction and is named through SemaContext::nullable_member.
pub class EnumLayoutQuery {
    pub var  sc:    unsafe *SemaContext
    priv var tu:    TypeUtil
    priv var synth: LowerSynth

    fn EnumLayoutQuery(self) {
        self.sc = &null
    }

    fn EnumLayoutQuery(self, sc: unsafe *SemaContext) {
        self.sc    = sc
        self.tu    = TypeUtil(sc)
        self.synth = LowerSynth(sc)
    }

    /// The ADT pattern behind the value type \p t (an instance answers its
    /// pattern: an instance shares its pattern's record), or null.
    fn adt_of(self, t: unsafe *Type) -> unsafe *Declarations::EnumDecl {
        if t == &null {
            return &null
        }

        var unsafe *d = self.tu.record_decl(self.tu.as_value(t))
        if d == &null {
            return &null
        }

        var unsafe *en = dyn_cast<Declarations::EnumDecl>(self.tu.pattern_of(d))
        if en == &null || !en->is_adt {
            return &null
        }

        return en
    }

    /// A payload field's type at an instance of \p en with arguments \p args:
    /// a parameter of the enum's is its argument, a type that names none is
    /// itself, and a pointer is a pointer whatever it points at -- which is
    /// all a layout question asks of one. Null for anything else built from
    /// a parameter: the question has no answer before C++ instantiates it.
    fn field_type_at(self,
                     en:         unsafe *Declarations::EnumDecl,
                     const args: FrozenList<unsafe *Type>,
                     ft:         unsafe *Type) -> unsafe *Type {
        if ft == &null || ft->canonical == &null {
            return &null
        }

        var unsafe *c = canon_unqual(ft->canonical)
        if c == &null {
            return &null
        }

        var unsafe *gp = dyn_cast<GenericParamType>(c)
        // A pack-expanded variant's field: one type per element, none here.
        if gp != &null && gp->is_pack {
            return &null
        }

        if gp != &null {
            var unsafe *owner = gp->owner
            if owner != &null {
                owner = NameLookup::representative(owner)
            }

            if owner != NameLookup::representative(unsafe (en as unsafe *Decl))
                || (gp->param_index as usize) >= args.size() {
                return &null
            }

            var unsafe *a = *args.get(gp->param_index as usize)
            if a == &null || a->is_dependent() || a->is_instantiation_dependent() {
                return &null
            }

            return a
        }

        if isa<PointerType>(c) {
            return ft
        }

        if c->is_dependent() || c->is_instantiation_dependent() {
            return &null
        }

        return ft
    }

    /// EnumLayoutLowering built \p en's record: every query below has an
    /// answer.
    fn has_layout(self, en: unsafe *Declarations::EnumDecl) -> bool {
        return en != &null && en->is_adt && en->adt_layout != &null
    }

    /// Whether variant \p index has a payload to read. Every \p index
    /// below is EXPANDED (adt_variant_at): a variant's position, or for
    /// element k of the pack-expanded variant at position p, p + k -- its
    /// tag. Without a pack-expanded variant the two are the same.
    fn has_payload(self, en: unsafe *Declarations::EnumDecl, index: u32) -> bool {
        var unsafe *v = adt_variant_at(en, index as usize)
        return v != &null && v->adt_member != &null
    }

    /// Tags are the positions `0..N-1`: a switch over them is complete and
    /// clang can index a table by them. Not with explicit tag values.
    fn is_exhaustive_dense(self, en: unsafe *Declarations::EnumDecl) -> bool {
        return self.has_layout(en) && !en->adt_explicit_tags
    }

    /// The discriminant variant \p index is stored as in a value of type
    /// \p t: an ordinary variant's position; element k of a pack-expanded
    /// variant, the variant's position plus k, or under type-id tags
    /// (AdtLayoutKnobs, the Panic lang item) the panic type id of the
    /// element's type at \p t (PanicSets). InterfaceEmitter's constructor
    /// and destroy / copy helpers store and read the same values: this is
    /// the one rule, and \p t must be concrete for an element's.
    fn tag_value(self, t: unsafe *Type, en: unsafe *Declarations::EnumDecl, index: u32) -> u64 {
        var unsafe *v = adt_variant_at(en, index as usize)
        if v == &null {
            kairo::std::ice_fail("EnumLayoutQuery: tag_value past the last variant")
        }

        var k = adt_expansion_at(en, index as usize)
        if k < 0 {
            return v->adt_tag_value
        }

        if !en->adt_explicit_tags {
            return v->adt_tag_value + (k as u64)
        }

        var args = self.tu.record_args(self.tu.as_value(t))
        var p    = adt_pack_param(en)
        if p == usize::MAX || p + (k as usize) >= args.size() {
            kairo::std::ice_fail(
                "EnumLayoutQuery: a type-id tag at a type without that element; the test reads a dependent instance",
            )
        }

        var id = PanicSets(self.sc).type_id(args[p + (k as usize)])
        if id == (0 as u32) {
            kairo::std::ice_fail(
                "EnumLayoutQuery: a type-id-tagged element whose type has no id; a dependent instance reached a test",
            )
        }

        return id
    }

    /// Where every payload of a value of type \p t starts, for an ADT
    /// whose union a lang item aligns (AdtLayoutKnobs::union_floor):
    /// `max(floor, alignof(payloads))`, which is also the union's own
    /// alignment, so the tag word before it never moves it further. The
    /// C++ record states the same as `__kairo_payload_offset`. False when
    /// a payload's alignment is not known here.
    fn payload_offset(self, t: unsafe *Type, off: unsafe *u64) -> bool {
        var        sz: u64 = 0
        var        al: u64 = 0
        var unsafe *en     = self.adt_of(t)
        if en == &null || en->adt_union_align == 0 {
            return false
        }

        if !self.size_of(t, unsafe &sz, unsafe &al) {
            return false
        }

        *off = al
        return true
    }

    /// # shape

    /// The layout of ADT values of type \p t. A non-generic ADT's is its
    /// declaration's. A generic one's is per instance and C++ picks it
    /// (InterfaceEmitter's constrained specialization); this predicts the
    /// pick from the same facts, and says Opaque where it cannot.
    fn shape_at(self, t: unsafe *Type) -> AdtShape {
        var unsafe *en = self.adt_of(t)
        if en == &null || !en->adt_niche_shape {
            return AdtShape::Tagged
        }

        if en->generic_params.size() == 0 {
            return if (en->adt_niche) => (AdtShape::Niche) else => AdtShape::Tagged
        }

        var unsafe *v = self.tu.as_value(t)
        if v == &null || v->is_dependent() || v->is_instantiation_dependent() {
            return AdtShape::Opaque
        }

        var        args = self.tu.record_args(v)
        var unsafe *pv  = en->variants[adt_niche_payload_variant(en) as usize]
        var unsafe *ft  = self.field_type_at(en, args, pv->payload[0]->type_)
        if ft == &null {
            return AdtShape::Opaque
        }

        var verdict = self.niche_verdict(en, ft)
        if verdict < 0 {
            return AdtShape::Opaque
        }

        return if (verdict > 0) => (AdtShape::Niche) else => AdtShape::Tagged
    }

    /// Whether a niche-shaped \p en whose one payload field has type \p ft
    /// is laid out niche-filled: 1 yes, 0 no, -1 unknown. The rule (spec
    /// ENUMLAYOUT §5.2): the field holds a niche of at least as many
    /// patterns as there are dataless variants, and is trivially copied and
    /// destroyed, which keeps every special member trivial. InterfaceEmitter
    /// writes C++'s side of it as the specialization's constraint.
    fn niche_verdict(self, en: unsafe *Declarations::EnumDecl, ft: unsafe *Type) -> i8 {
        var n = self.niche_of(ft)
        if n == niche_unknown() {
            return -1
        }

        if n < adt_niche_dataless(en) {
            return 0
        }

        return self.trivial(ft)
    }

    /// # niche_of

    /// How many bit patterns a value of type \p t never holds, as the C++
    /// trait `__kairo_niche<T>` counts them (InterfaceEmitter), or
    /// niche_unknown(). v1 rows (spec ENUMLAYOUT §5.1):
    ///
    ///   a pointer                              1: null
    ///   a plain enum with values 0..N-1        the rest of its word
    ///   a tagged ADT                           the tag values past its N
    ///   a niche-filled ADT                     its field's, less the
    ///                                          patterns its dataless use
    ///   anything else                          none
    ///
    /// `bool` is not a row: a C++ `bool` cannot hold 2, so it needs a
    /// storage override first. A record's first niche-bearing field (the
    /// spec's struct row) is answered by niche_of_record, which no layout
    /// reads yet: C++ can only build a record holding a pattern by
    /// aggregate initialization, which most Kairo records do not allow.
    fn niche_of(self, t: unsafe *Type) -> u64 {
        if t == &null || t->canonical == &null {
            return niche_unknown()
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c == &null {
            return niche_unknown()
        }

        if isa<NullableType>(c) {
            // Read through the lang item, not the lowered record: an ADT
            // laid out before NullableTypeLowering asks this of a `T?` field.
            var unsafe *nd = self.sc->nullable_enum()
            if !self.has_layout(nd) {
                return niche_unknown()
            }

            var unsafe *inner = cast<NullableType>(c)->inner
            var        v      = self.niche_verdict(nd, inner)
            if v < 0 {
                return niche_unknown()
            }

            if v == 0 {
                return adt_tag_niche_count(nd)
            }

            var n    = self.niche_of(inner)
            var used = adt_niche_dataless(nd)
            return if (n > used) => (n - used) else => 0
        }

        if isa<PointerType>(c) {
            return 1
        }

        if isa<FunctionPointerType>(c) {
            // A raw pointer's null is free; a `fn` value is a record.
            return if (cast<FunctionPointerType>(c)->is_unprototyped
                       || cast<FunctionPointerType>(c)->is_raw) => (1)
                   else => 0
        }

        if isa<RecordType>(c) {
            if c->is_dependent() || c->is_instantiation_dependent() {
                return niche_unknown()
            }

            var unsafe *d  = self.tu.pattern_of(cast<RecordType>(c)->decl)
            var unsafe *en = dyn_cast<Declarations::EnumDecl>(d)
            if en == &null {
                return 0
            }

            // A plain enum: the values past a closed one's variants; none for
            // an `@open` one, which `as` may fill with any value (EnumNiche).
            if !en->is_adt {
                return enum_niche_count(en)
            }

            if !self.has_layout(en) {
                return niche_unknown()
            }

            match self.shape_at(c) {
                case AdtShape::Tagged {
                    return adt_tag_niche_count(en)
                } case AdtShape::Niche {
                    var unsafe *inner = self._niche_field_type(c, en)
                    var        n      = self.niche_of(inner)
                    if n == niche_unknown() {
                        return n
                    }

                    var used = adt_niche_dataless(en)
                    return if (n > used) => (n - used) else => 0
                } default {
                    0
                }
            }

            return niche_unknown()
        }

        if c->is_dependent() || c->is_instantiation_dependent() {
            return niche_unknown()
        }

        return 0
    }

    /// The spec's struct row, answered but read by no layout (niche_of): a
    /// record's first field with a niche, at that field.
    fn niche_of_record(self, t: unsafe *Type) -> u64 {
        var n = self.niche_of(t)
        if n != 0 {
            return n
        }

        var unsafe *d  = self.tu.record_decl(self.tu.as_value(t))
        var unsafe *sd = dyn_cast<Declarations::StructDecl>(d)
        if sd == &null {
            return 0
        }

        for var i: usize = 0; i < sd->fields.size(); ++i {
            var unsafe *f = sd->fields[i]
            if f == &null || f->storage == Declarations::StorageClass::Eval {
                continue
            }

            var k = self.niche_of_record(f->type_)
            if k != 0 {
                return k
            }
        }

        return 0
    }

    /// A niche-filled ADT type \p c's one payload field type.
    priv fn _niche_field_type(self,
                              c:  unsafe *Type,
                              en: unsafe *Declarations::EnumDecl) -> unsafe *Type {
        var unsafe *pv = en->variants[adt_niche_payload_variant(en) as usize]
        if en->generic_params.size() == 0 {
            return pv->payload[0]->type_
        }

        var args = self.tu.record_args(c)
        return self.field_type_at(en, args, pv->payload[0]->type_)
    }

    /// \p t is trivially copied and destroyed: 1, 0, or -1 unknown. Read off
    /// the structure for what C++ decides by the structure (an ADT is
    /// trivial exactly when its payloads are: its special members are
    /// defaulted then), off ClassLifecycle for a record.
    fn trivial(self, t: unsafe *Type) -> i8 {
        if t == &null || t->canonical == &null {
            return -1
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c == &null {
            return -1
        }

        if isa<NullableType>(c) {
            return self.trivial(cast<NullableType>(c)->inner)
        }

        if isa<BuiltinType>(c) || isa<PointerType>(c) {
            return 1
        }

        if isa<FunctionPointerType>(c) {
            return if (cast<FunctionPointerType>(c)->is_unprototyped
                       || cast<FunctionPointerType>(c)->is_raw) => (1)
                   else => 0
        }

        if isa<FixedArrayType>(c) {
            return self.trivial(cast<FixedArrayType>(c)->element)
        }

        if c->is_dependent() || c->is_instantiation_dependent() {
            return -1
        }

        if isa<RecordType>(c) {
            var unsafe *d  = self.tu.pattern_of(cast<RecordType>(c)->decl)
            var unsafe *en = dyn_cast<Declarations::EnumDecl>(d)
            if en != &null && !en->is_adt {
                return 1
            }

            if en != &null && en->generic_params.size() > 0 {
                var args = self.tu.record_args(c)
                for var i: usize = 0; i < en->variants.size(); ++i {
                    var unsafe *v = en->variants[i]
                    for var j: usize = 0; j < v->payload.size(); ++j {
                        var unsafe *ft = self.field_type_at(en, args, v->payload[j]->type_)
                        if ft == &null {
                            return -1
                        }

                        var k = self.trivial(ft)
                        if k != 1 {
                            return k
                        }
                    }
                }

                return 1
            }
        }

        var f = lifecycle_of(self.sc)->facts_of_type(c)
        if f.trivially_copyable == LifecycleTri::Unknown
            || f.trivial_dtor == LifecycleTri::Unknown {
            return -1
        }

        return if (f.trivially_copyable == LifecycleTri::Yes
                   && f.trivial_dtor == LifecycleTri::Yes) => (1)
               else => 0
    }

    /// The size and alignment in bytes of a value of type \p t, for the
    /// types whose layout is plain arithmetic: builtins, pointers, plain
    /// enums, and ADTs made of them. False for anything else; nothing then
    /// pins a size.
    fn size_of(self, t: unsafe *Type, size: unsafe *u64, align: unsafe *u64) -> bool {
        if t == &null || t->canonical == &null {
            return false
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c == &null {
            return false
        }

        if isa<NullableType>(c) {
            var unsafe *lw = cast<NullableType>(c)->lowered
            if lw == &null {
                return false
            }

            return self.size_of(lw, size, align)
        }

        if isa<BuiltinType>(c) || isa<PointerType>(c) {
            if isa<BuiltinType>(c) && cast<BuiltinType>(c)->lang_decl != &null {
                return false
            }

            if c->size_bits == 0 || c->align_bits == 0 || c->size_bits % 8 != 0 {
                return false
            }

            *size  = ((c->size_bits / 8) as u64)
            *align = ((c->align_bits / 8) as u64)
            return true
        }

        if isa<FixedArrayType>(c) {
            // N elements back to back: a C++ array has no padding of its own.
            var unsafe *fa = cast<FixedArrayType>(c)
            if fa->is_incomplete || fa->extent_param != &null {
                return false
            }

            var es: u64 = 0
            var ea: u64 = 0
            if !self.size_of(fa->element, unsafe &es, unsafe &ea) {
                return false
            }

            *size  = es * (fa->size_bits as u64)
            *align = ea
            return true
        }

        if !isa<RecordType>(c) || c->is_dependent() || c->is_instantiation_dependent() {
            return false
        }

        var unsafe *en = dyn_cast<Declarations::EnumDecl>(
            self.tu.pattern_of(cast<RecordType>(c)->decl),
        )

        if en == &null {
            return self._plain_record_size(cast<RecordType>(c)->decl, size, align)
        }

        if !en->is_adt {
            if decl_is_imported(en) {
                return false
            }

            return self.size_of(self.sc->builtin(enum_niche_kind(en)), size, align)
        }

        if !self.has_layout(en) {
            return false
        }

        var shape = self.shape_at(c)
        if shape == AdtShape::Opaque {
            return false
        }

        var args     = self.tu.record_args(c)
        var ts:  u64 = 0
        var ta:  u64 = 0
        if !self.size_of(self.sc->builtin(adt_tag_kind(en)), unsafe &ts, unsafe &ta) {
            return false
        }

        var prefix = en->adt_tag_member != &null
        // The payload union: each variant's struct laid out field by field,
        // after its own tag in the common prefix. A pack-expanded variant is
        // one struct per element of this instance.
        var usz: u64 = if (prefix) => (ts) else => 0
        var ual: u64 = if (prefix) => (ta) else => 1
        var pp       = adt_pack_param(en)
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v->payload.size() == 0 {
                continue
            }

            var nel: usize = 1
            if v->is_pack_expansion {
                if pp == usize::MAX || args.size() < pp {
                    return false
                }

                nel = args.size() - pp
            }

            for var e: usize = 0; e < nel; ++e {
                var off: u64 = if (prefix) => (ts) else => 0
                var sal: u64 = if (prefix) => (ta) else => 1
                for var j: usize = 0; j < v->payload.size(); ++j {
                    var unsafe *ft = v->payload[j]->type_
                    var unsafe *pg = dyn_cast<GenericParamType>(canon_unqual(ft->canonical))
                    if v->is_pack_expansion && pg != &null && pg->is_pack {
                        ft = args[pp + e]
                    } else if en->generic_params.size() > 0 {
                        ft = self.field_type_at(en, args, ft)
                    }

                    var fs: u64 = 0
                    var fa: u64 = 0
                    // `Panic<void, E...>`'s Ok holds an empty struct
                    // (AdtLayoutKnobs::void_payload): one byte.
                    var vu = en->adt_void_unit && ft != &null && self.tu.is_void(ft)
                    if vu {
                        fs = 1
                        fa = 1
                    }

                    if !vu && (ft == &null || !self.size_of(ft, unsafe &fs, unsafe &fa)) {
                        return false
                    }

                    off = self._round(off, fa) + fs
                    if fa > sal {
                        sal = fa
                    }
                }

                var ssz = self._round(off, sal)
                if ssz > usz {
                    usz = ssz
                }

                if sal > ual {
                    ual = sal
                }
            }
        }

        if shape == AdtShape::Niche || prefix {
            *size  = usz
            *align = ual
            return true
        }

        // A lang item's knobs (AdtLayoutKnobs): the u32 site slot after the
        // tag, and the union's own alignment.
        if en->adt_site_field != &null {
            ts = self._round(ts, 4) + 4
            if ta < 4 {
                ta = 4
            }
        }

        if (en->adt_union_align as u64) > ual {
            ual = (en->adt_union_align)
            usz = self._round(usz, ual)
        }

        var al = if (ta > ual) => (ta) else => ual
        *size  = self._round(self._round(ts, ual) + usz, al)
        *align = al
        return true
    }

    /// A plain Kairo struct or class laid out as C++ lays out its fields:
    /// in declaration order, each at its alignment, the whole rounded to
    /// the widest; empty is one byte. Only the shape that rule covers -- no
    /// generic parameters, no base, no virtual method, not from C++ --
    /// anything else is not answered. What reads this pins it: an ADT
    /// instance's predicted size is a static_assert beside it.
    priv fn _plain_record_size(self,
                               d_in:  unsafe *Decl,
                               size:  unsafe *u64,
                               align: unsafe *u64) -> bool {
        var unsafe *d = NameLookup::representative(d_in)
        if d == &null || decl_is_imported(d) || decl_is_instance(d) {
            return false
        }

        if decl_generic_params(d).size() > 0 {
            return false
        }

        var fields:  unsafe *FrozenList<unsafe *Declarations::FieldDecl>    = &null
        var methods: unsafe *FrozenList<unsafe *Declarations::FunctionDecl> = &null
        var unsafe *sd = dyn_cast<Declarations::StructDecl>(d)
        var unsafe *cd = dyn_cast<Declarations::ClassDecl>(d)
        if sd != &null {
            if sd->adt_of != &null || sd->tuple_arity > 0 {
                return false
            }

            fields  = unsafe &sd->fields
            methods = unsafe &sd->methods
        } else if cd != &null {
            if cd->derives_list.size() > 0 {
                return false
            }

            fields  = unsafe &cd->fields
            methods = unsafe &cd->methods
        } else {
            return false
        }

        for var i: usize = 0; i < methods->size(); ++i {
            var unsafe *m = (*methods)[i]
            if m != &null
                && (m->abi == Declarations::AbiKind::Virtual
                    || m->abi == Declarations::AbiKind::Override
                    || m->body_kind == Declarations::FnBodyKind::Virtual) {
                return false
            }
        }

        // `@packed` / `@align(N)` (AttrFacts), as clang lays out the
        // `__attribute__((packed, aligned(N)))` CXXSpell writes: a packed
        // record's members sit at alignment 1 unless a member's own
        // `@align` says otherwise; a member's `@align` raises its alignment
        // (in a packed record it IS its alignment); the record's `@align`
        // raises the whole, and the size rounds up to it.
        var packed     = AttrFacts::is_packed(d)
        var want       = AttrFacts::align_of(d)
        var off:   u64 = 0
        var al:    u64 = 1
        var any        = false
        for var i: usize = 0; i < fields->size(); ++i {
            var unsafe *f = (*fields)[i]
            if f == &null || f->is_static() {
                continue
            }

            var fs: u64 = 0
            var fa: u64 = 0
            if !self.size_of(f->type_, unsafe &fs, unsafe &fa) {
                return false
            }

            var fal = AttrFacts::align_of(f)
            if packed {
                fa = if (fal != 0) => (fal) else => 1
            } else if fal > fa {
                fa = fal
            }

            off = self._round(off, fa) + fs
            if fa > al {
                al = fa
            }

            any = true
        }

        if want > al {
            al = want
        }

        *size  = if (any) => (self._round(off, al)) else => self._round(1, al)
        *align = al
        return true
    }

    priv fn _round(self, n: u64, a: u64) -> u64 {
        if a <= 1 {
            return n
        }

        return (n + a - 1) / a * a
    }

    /// Every generic ADT instance the registry holds gets the shape and size
    /// predicted for it (InstanceEntry::adt_shape / adt_size), which
    /// InterfaceEmitter pins with static_asserts. Run once, after the last
    /// lowering: an instance minted late (a `T?` NullableTypeLowering gives
    /// its record) is in the registry by then.
    fn sweep(self) {
        if self.sc->instances == &null {
            return
        }

        // Only entries keyed at or before this group's rank (P850): a later
        // group's front may be minting and TYPING the records an entry it
        // minted names (size_of walks their fields) on another thread right
        // now. Its own sweep, after its front, sees them whole, and nothing
        // before it reads adt_shape (InterfaceEmitter, after all of Sema).
        // A one-thread run holds nothing past the group: same output. The
        // whole of this group's rank (high 32 bits; the low ones are the
        // schedule step, sema_sub): every member of it is on this thread.
        var cap: u64 = *kairo::sema_mint_rank()
        if cap != u64::MAX {
            cap = cap | 0xFFFFFFFF
        }

        var all = cxx::std::vector<unsafe *InstanceEntry>()
        self.sc->instances->collect_upto(cap, &all)
        for var i: usize = 0; i < all.size(); ++i {
            var unsafe *e  = all[i]
            var unsafe *en = dyn_cast<Declarations::EnumDecl>(e->primary)
            if en == &null || !self.has_layout(en) || e->decl == &null {
                continue
            }

            var unsafe *t = self.sc->types->record(e->decl, unsafe &e->args) // an instance's type names its shell and its arguments.
            if t == &null || t->is_dependent() || t->is_instantiation_dependent() {
                continue
            }

            var shape = self.shape_at(t)
            if shape == AdtShape::Opaque {
                continue
            }

            e->adt_shape = if (shape == AdtShape::Niche) => (2) else => 1
            var sz: u64 = 0
            var al: u64 = 0
            if self.size_of(t, unsafe &sz, unsafe &al) {
                e->adt_size = sz
            }

            if en->adt_explicit_tags {
                self._sweep_type_ids(e, en, t, sz)
            }

            if en->adt_union_align > 0 {
                var po: u64 = 0
                if self.payload_offset(t, unsafe &po) {
                    e->payload_offset = po
                }
            }
        }
    }

    /// A type-id-tagged instance (the Panic lang item): its elements' ids
    /// and spelling keys, which InterfaceEmitter writes as `__kairo_tid`
    /// specializations -- C++ reads the ids Sema computed, never hashes. And
    /// the register cliff (Compiler/Spec/Panic.md#layout): past 16 bytes the result is
    /// returned through memory, which only a remark tells the user, at the
    /// set's formation (InstanceEntry::formed_at), in that TU only.
    priv fn _sweep_type_ids(self,
                            e:    unsafe *InstanceEntry,
                            en:   unsafe *Declarations::EnumDecl,
                            t:    unsafe *Type,
                            size: u64) {
        var p = adt_pack_param(en)
        if p == usize::MAX {
            return
        }

        // Every TU's sweep visits every instance: the first fills the ids;
        // the remark is the forming TU's, whichever sweeps first.
        if e->type_ids.size() == 0 {
            var ps    = PanicSets(self.sc)
            var ids   = cxx::std::vector<u32>()
            var keys  = cxx::std::vector<u64>()
            var names = cxx::std::vector<string>()
            for var i: usize = p; i < e->args.size(); ++i {
                var id = ps.type_id(e->args[i])
                if id == (0 as u32) {
                    return
                }

                ids.push_back(id)
                keys.push_back(ps.type_key(e->args[i]))
                names.push_back(self.tu.str(e->args[i]))
            }

            for var i: usize = 0; i < ids.size(); ++i {
                e->type_ids.push_back(ids[i])
                e->type_keys.push_back(keys[i])
                e->type_names.push_back(names[i])
            }
        }

        if size <= 16 || e->formed_fid != self.sc->ctx->fid || !e->formed_at.is_valid() {
            return
        }

        // The payload that pushed it over: the widest.
        var widest: unsafe *Type = &null
        var wsz:    u64          = 0
        for var i: usize = 0; i < e->args.size(); ++i {
            var        fs: u64 = 0
            var        fa: u64 = 0
            var unsafe *a      = e->args[i]
            if i == 0 && self.tu.is_void(a) {
                continue
            }

            if self.size_of(a, unsafe &fs, unsafe &fa) && fs > wsz {
                wsz    = fs
                widest = a
            }
        }

        var ts  = self.tu.str(t)
        var why = ""
        if widest != &null {
            var wn = self.tu.str(widest)
            why = f"; its widest payload, '{wn}', is {wsz} bytes"
        }

        var b = self.sc->diag->report(
            DiagID::OPT002R,
            e->formed_at.start,
            f"'{ts}' is {size} bytes, so a function returning it returns through memory, not in two registers" + why,
        )

        b.first(e->formed_at, "every payload at most 8 bytes keeps it at 16")
        b.emit()
    }

    /// # reads and tests

    /// The tag as stored, typed as the tag enum: `x.__kairo_tag`, or
    /// `x.__kairo_which()` where C++ picks the layout. Null when the layout
    /// has no tag.
    fn tag_read(self,
                at: SourceRange,
                x:  unsafe *Expr,
                en: unsafe *Declarations::EnumDecl) -> unsafe *Expr {
        var unsafe *tag = en->adt_tag_field
        if tag == &null {
            kairo::std::ice_fail(
                "EnumLayoutQuery: tag_read on an ADT with no layout; EnumLayoutLowering runs first",
            )
        }

        match self.shape_at(x->type_) {
            case AdtShape::Niche {
                return &null
            } case AdtShape::Opaque {
                return self._which(at, x, en)
            } default {
                0
            }
        }

        return self._tag_lvalue(at, x, en)
    }

    /// The stored tag of a tagged \p en value \p x: `x.__kairo_tag`, or in
    /// the common prefix, `x.__kairo_t.__kairo_tag`.
    priv fn _tag_lvalue(self,
                        at: SourceRange,
                        x:  unsafe *Expr,
                        en: unsafe *Declarations::EnumDecl) -> unsafe *Expr {
        var unsafe *tag = en->adt_tag_field
        if en->adt_tag_member != &null {
            var unsafe *tm = en->adt_tag_member
            var unsafe *t  = self.synth.field_of(at, x, tm, tm->type_)
            return self.synth.field_of(at, t, en->adt_prefix_tag, tag->type_)
        }

        return self.synth.field_of(at, x, tag, tag->type_)
    }

    /// The tag as a `u32`, which is what a switch dispatches on and a case
    /// label is written in (tag_case). Null when the layout has no tag: a
    /// match then tests each variant in turn (variant_test).
    fn tag_word(self,
                at: SourceRange,
                x:  unsafe *Expr,
                en: unsafe *Declarations::EnumDecl) -> unsafe *Expr {
        var unsafe *t = self.tag_read(at, x, en)
        if t == &null {
            return &null
        }

        return self.synth.cast_to(at, t, self.sc->builtin(BuiltinKind::U32), CastMode::Default)
    }

    /// Variant \p index's discriminant in a value of type \p t, as a case
    /// label of tag_word.
    fn tag_case(self,
                at:    SourceRange,
                t:     unsafe *Type,
                en:    unsafe *Declarations::EnumDecl,
                index: u32) -> unsafe *Expr {
        return self.synth.int_literal(at, self.tag_value(t, en, index), BuiltinKind::U32)
    }

    /// `x` holds variant \p index. Niche-filled: a dataless variant is its
    /// pattern in the field (`x.__kairo_Value.v == nullptr`), the payload
    /// variant every pattern's absence.
    fn variant_test(self,
                    at:    SourceRange,
                    x:     unsafe *Expr,
                    en:    unsafe *Declarations::EnumDecl,
                    index: u32) -> unsafe *Expr {
        var unsafe *w = self.tag_word(at, x, en)
        if w != &null {
            return self._bin(at, w, self.tag_case(at, x->type_, en, index), TokenKind::OpEqualEqual)
        }

        var        p   = adt_niche_payload_variant(en)
        var unsafe *pv = en->variants[p as usize]
        var unsafe *f  = pv->payload[0]
        var unsafe *ft = self._niche_field_type(self.tu.as_value(x->type_), en)
        if ft == &null {
            kairo::std::ice_fail(
                "EnumLayoutQuery: a niche-filled ADT whose field type has no answer; shape_at said Niche",
            )
        }

        if index != p {
            return self._pattern_test(
                at,
                self.field_ref(at, x, en, p, f, ft),
                ft,
                adt_niche_pattern_of(en, index),
                false,
            )
        }

        var c: unsafe *Expr = &null
        var d               = adt_niche_dataless(en)
        for var k: u64 = 0; k < d; ++k {
            var unsafe *one = self._pattern_test(
                at,
                self.field_ref(at, x, en, p, f, ft),
                ft,
                k,
                true,
            )

            c = if (c == &null) => (one) else => self._bin(at, c, one, TokenKind::OpAmpAmp)
        }

        return c
    }

    /// `x.__kairo_<V>`. A variant with no payload has nothing to read.
    fn payload_ref(self,
                   at:    SourceRange,
                   x:     unsafe *Expr,
                   en:    unsafe *Declarations::EnumDecl,
                   index: u32) -> unsafe *Expr {
        if !self.has_payload(en, index) {
            kairo::std::ice_fail("EnumLayoutQuery: payload_ref of a variant with no payload")
        }

        var unsafe *m = adt_variant_at(en, index as usize)->adt_member
        var unsafe *r = self.synth.field_of(at, x, m, m->type_)
        // Element k's payload is the member's k-th (EmitIR spells the getter).
        var k = adt_expansion_at(en, index as usize)
        if k >= 0 {
            cast<ChainExpr>(r)->steps.get(0)->pack_index = k
        }

        return r
    }

    /// `x.__kairo_<V>.<field>`, typed \p ty (the occurrence's type: an
    /// instance's field type, not the pattern's).
    fn field_ref(self,
                 at:    SourceRange,
                 x:     unsafe *Expr,
                 en:    unsafe *Declarations::EnumDecl,
                 index: u32,
                 field: unsafe *Declarations::FieldDecl,
                 ty:    unsafe *Type) -> unsafe *Expr {
        return self.synth.field_of(at, self.payload_ref(at, x, en, index), field, ty)
    }

    /// An ADT's built-in `==` / `!=`: the variants compared, under the
    /// written token. Each operand appears once, so each runs once. Without
    /// a tag, each side's variant is asked of it (`__kairo_which()`).
    fn same_variant(self,
                    at:  SourceRange,
                    a:   unsafe *Expr,
                    b:   unsafe *Expr,
                    en:  unsafe *Declarations::EnumDecl,
                    tok: Token) -> unsafe *Expr {
        var unsafe *l = self.tag_read(a->range, a, en)
        var unsafe *r = self.tag_read(b->range, b, en)
        if l == &null {
            l = self._which(a->range, a, en)
        }

        if r == &null {
            r = self._which(b->range, b, en)
        }

        var unsafe *cmp = BinaryOperatorExpr::create(self.sc->ctx, at, l, r, tok)
        return cmp
    }

    /// `x.__kairo_which()`, typed as the tag enum.
    priv fn _which(self,
                   at: SourceRange,
                   x:  unsafe *Expr,
                   en: unsafe *Declarations::EnumDecl) -> unsafe *Expr {
        if en->adt_which == &null {
            kairo::std::ice_fail(
                "EnumLayoutQuery: no __kairo_which() on an ADT whose layout needs it; EnumLayoutLowering mints it",
            )
        }

        var args = ListBuilder<unsafe *Expr>(self.sc->ctx)
        return self.synth.member_call(
            at,
            x,
            unsafe (en->adt_which as unsafe *Decl),
            &args,
            en->adt_tag_field->type_,
        )
    }

    /// The lvalue \p e of type \p ft holds its niche pattern \p i (or, \p
    /// neg, does not). Each row is the C++ trait's `test` for the same type
    /// (InterfaceEmitter), written out so a reader of the C++ sees the
    /// compare: null for a pointer, `N + i` for a plain enum or a tagged
    /// ADT's tag, and a niche-filled ADT's own field at its pattern past
    /// the ones its dataless variants use.
    priv fn _pattern_test(self,
                          at:  SourceRange,
                          e:   unsafe *Expr,
                          ft:  unsafe *Type,
                          i:   u64,
                          neg: bool) -> unsafe *Expr {
        var        cmp_op = if (neg) => (TokenKind::OpExclaimEqual) else => TokenKind::OpEqualEqual
        var unsafe *c     = canon_unqual(ft->canonical)
        if isa<NullableType>(c) {
            return self._pattern_test(at, e, cast<NullableType>(c)->lowered, i, neg)
        }

        if isa<PointerType>(c) || isa<FunctionPointerType>(c) {
            var unsafe *nul = NullLiteralExpr::create(self.sc->ctx, at, true)
            nul->type_          = ft
            nul->value_category = Expr::ValueCategory::RValue
            return self._bin(at, e, nul, cmp_op)
        }

        var unsafe *en = dyn_cast<Declarations::EnumDecl>(
            self.tu.pattern_of(cast<RecordType>(c)->decl),
        )

        if en == &null {
            kairo::std::ice_fail("EnumLayoutQuery: a niche pattern in a type niche_of gives none")
        }

        // A plain enum's niche is the values past its variants; an ADT's,
        // its first spare tag (EnumNiche), the one place that arithmetic is.
        var n = if (en->is_adt) => (adt_first_spare_tag(en)) else => (en->variants.size() as u64)
        if !en->is_adt {
            var unsafe *lit = self.synth.int_literal(at, n + i, enum_niche_kind(en))
            return self._bin(at, e, self.synth.cast_to(at, lit, ft, CastMode::Default), cmp_op)
        }

        if self.shape_at(c) == AdtShape::Tagged {
            var unsafe *tw = self.synth.cast_to(
                at,
                self._tag_lvalue(at, e, en),
                self.sc->builtin(BuiltinKind::U32),
                CastMode::Default,
            )

            return self._bin(at, tw, self.synth.int_literal(at, n + i, BuiltinKind::U32), cmp_op)
        }

        var        p   = adt_niche_payload_variant(en)
        var unsafe *f  = en->variants[p as usize]->payload[0]
        var unsafe *it = self._niche_field_type(c, en)
        return self._pattern_test(
            at,
            self.field_ref(at, e, en, p, f, it),
            it,
            adt_niche_dataless(en) + i,
            neg,
        )
    }

    /// # the Panic lang item (Compiler/Spec/Panic.md#layout; PanicLowering)

    /// The Panic lang item a result type \p t is an instance of, or null.
    fn panic_adt(self, t: unsafe *Type) -> unsafe *Declarations::EnumDecl {
        var unsafe *en = self.adt_of(t)
        if en == &null || !PanicSets(self.sc).is_panic(en) {
            return &null
        }

        if !self.has_layout(en) {
            kairo::std::ice_fail(
                "EnumLayoutQuery: a panic result before EnumLayoutLowering built the lang item's record",
            )
        }

        return en
    }

    /// The expanded index of error type \p e in the panic result type \p t:
    /// the pack variant's position plus e's place in t's canonical set
    /// (§1.3). The set is the FORMED type's, so the index is the one C++
    /// reads (`__kairo_get<K>`). ICE when \p e is not in it: every caller
    /// tests a type the set was checked to hold.
    fn panic_elem_index(self, t: unsafe *Type, e: unsafe *Type) -> u32 {
        var unsafe *en = self.panic_adt(t)
        if en == &null {
            kairo::std::ice_fail(
                "EnumLayoutQuery: panic_elem_index on a type that is no panic result",
            )
        }

        var        p     = adt_pack_param(en)
        var        args  = self.tu.record_args(self.tu.as_value(t))
        var unsafe *want = canon_unqual(e)
        var        pos   = adt_variant_pos(en, adt_pack_variant(en))
        for var i: usize = p; i < args.size(); ++i {
            if canon_unqual(args[i]) == want {
                return (pos + (i - p)) as u32
            }
        }

        kairo::std::ice_fail(
            "EnumLayoutQuery: '" + self.tu.str(e) + "' is outside the panic result '" + self.tu.str(
                t,
            ) + "'; PanicEffectChecking routed it here",
        )
    }

    /// `x` is Ok: its tag is 0 (§1.1a).
    fn panic_is_ok(self, at: SourceRange, x: unsafe *Expr) -> unsafe *Expr {
        var unsafe *en = self.panic_adt(x->type_)
        if en == &null {
            kairo::std::ice_fail("EnumLayoutQuery: panic_is_ok on a value that is no panic result")
        }

        return self.variant_test(at, x, en, adt_variant_pos(en, self._panic_ok(en)) as u32)
    }

    /// `x` holds error \p e: the tag compared with e's type id, the one
    /// compare a `catch e: E` is in every set that holds E.
    fn panic_holds(self, at: SourceRange, x: unsafe *Expr, e: unsafe *Type) -> unsafe *Expr {
        var unsafe *en = self.panic_adt(x->type_)
        if en == &null {
            kairo::std::ice_fail("EnumLayoutQuery: panic_holds on a value that is no panic result")
        }

        // A dependent set (a generic body, Compiler/Spec/Panic.md#generic-bodies): e's id, and where
        // C++ put it, are the instance's. C++ answers (`::builtin::is<E>`).
        if self._panic_dependent(x->type_) {
            return self._panic_op(
                at,
                PanicOp::Holds,
                x,
                e,
                self.sc->builtin(BuiltinKind::Bool),
                Expr::ValueCategory::RValue,
            )
        }

        return self.variant_test(at, x, en, self.panic_elem_index(x->type_, e))
    }

    /// \p t names a type parameter among its elements: its canonical order
    /// is C++'s to compute at each instance (CXXSpell spells it through the
    /// sorting alias), so no element index or tag of Sema's applies.
    priv fn _panic_dependent(self, t: unsafe *Type) -> bool {
        var args = self.tu.record_args(self.tu.as_value(t))
        for var i: usize = 1; i < args.size(); ++i {
            var unsafe *a = args[i]
            if a != &null && (a->is_dependent() || a->is_instantiation_dependent()) {
                return true
            }
        }

        return false
    }

    priv fn _panic_op(self,
                      at: SourceRange,
                      k:  PanicOp,
                      x:  unsafe *Expr,
                      e:  unsafe *Type,
                      ty: unsafe *Type,
                      vc: Expr::ValueCategory) -> unsafe *Expr {
        var unsafe *n = PanicOpExpr::create(self.sc->ctx, at, k, x, &null)
        n->elem           = canon_unqual(e)
        n->type_          = ty
        n->value_category = vc
        return n
    }

    /// The Ok value of \p x, an lvalue of \p ty (the result's T).
    fn panic_value_ref(self, at: SourceRange, x: unsafe *Expr, ty: unsafe *Type) -> unsafe *Expr {
        var unsafe *en = self.panic_adt(x->type_)
        if en == &null {
            kairo::std::ice_fail(
                "EnumLayoutQuery: panic_value_ref on a value that is no panic result",
            )
        }

        var unsafe *ok = self._panic_ok(en)
        return self.field_ref(at, x, en, adt_variant_pos(en, ok) as u32, ok->payload[0], ty)
    }

    /// Error \p e held by \p x, an lvalue of \p e: the union's element at
    /// e's place in the set.
    fn panic_error_ref(self, at: SourceRange, x: unsafe *Expr, e: unsafe *Type) -> unsafe *Expr {
        var unsafe *en = self.panic_adt(x->type_)
        if en == &null {
            kairo::std::ice_fail(
                "EnumLayoutQuery: panic_error_ref on a value that is no panic result",
            )
        }

        if self._panic_dependent(x->type_) {
            return self._panic_op(
                at,
                PanicOp::ErrorRef,
                x,
                e,
                canon_unqual(e),
                Expr::ValueCategory::LValue,
            )
        }

        var unsafe *pv = adt_pack_variant(en)
        return self.field_ref(at, x, en, self.panic_elem_index(x->type_, e), pv->payload[0], e)
    }

    /// The site word of \p x (§1.4), an lvalue `u32`.
    fn panic_site_ref(self, at: SourceRange, x: unsafe *Expr) -> unsafe *Expr {
        var unsafe *en = self.panic_adt(x->type_)
        if en == &null || en->adt_site_field == &null {
            kairo::std::ice_fail("EnumLayoutQuery: panic_site_ref on a value with no site slot")
        }

        var unsafe *sf = en->adt_site_field
        return self.synth.field_of(at, x, sf, sf->type_)
    }

    /// `Ok { value: v }` as the panic result \p t; \p v null for a `void`
    /// T, whose unit payload is built empty (§1.6).
    fn panic_ok(self, at: SourceRange, t: unsafe *Type, v: unsafe *Expr) -> unsafe *Expr {
        var unsafe *en = self.panic_adt(t)
        if en == &null {
            kairo::std::ice_fail("EnumLayoutQuery: panic_ok of a type that is no panic result")
        }

        var unsafe *ok = self._panic_ok(en)
        var unsafe *n = VariantInitExpr::create(
            self.sc->ctx,
            at,
            unsafe (en as unsafe *Decl),
            adt_variant_pos(en, ok) as u32,
        )

        var fs = ListBuilder<unsafe *Expr>(self.sc->ctx)
        var so = ListBuilder<u32>(self.sc->ctx)
        if v != &null {
            fs.push(v)
            so.push(0 as u32)
        }

        fs.freeze_into(&n->fields)
        so.freeze_into(&n->source_order)
        n->type_          = t
        n->value_category = Expr::ValueCategory::RValue
        return n
    }

    /// `Err { error: v }` holding error type \p e, as the panic result \p t,
    /// with site id \p site in its word 0 (§1.4; 0 for none).
    fn panic_err(self,
                 at:   SourceRange,
                 t:    unsafe *Type,
                 e:    unsafe *Type,
                 site: u32,
                 v:    unsafe *Expr) -> unsafe *Expr {
        var unsafe *en = self.panic_adt(t)
        if en == &null {
            kairo::std::ice_fail("EnumLayoutQuery: panic_err of a type that is no panic result")
        }

        var unsafe *pv = adt_pack_variant(en)
        var        pos = adt_variant_pos(en, pv)
        var        idx = self.panic_elem_index(t, e)
        var unsafe *n  = VariantInitExpr::create(self.sc->ctx, at, en, pos as u32)
        var        fs  = ListBuilder<unsafe *Expr>(self.sc->ctx)
        var        so  = ListBuilder<u32>(self.sc->ctx)
        fs.push(v)
        so.push(0 as u32)
        fs.freeze_into(&n->fields)
        so.freeze_into(&n->source_order)
        n->pack_index     = ((idx - (pos as u32)) as i32)
        n->pack_elem      = canon_unqual(e)
        n->site           = site
        n->type_          = t
        n->value_category = Expr::ValueCategory::RValue
        return n
    }

    /// The lang item's ordinary variant: Ok.
    priv fn _panic_ok(self,
                      en: unsafe *Declarations::EnumDecl) -> unsafe *Declarations::EnumVariantDecl {
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v != &null && !v->is_pack_expansion {
                return v
            }
        }

        kairo::std::ice_fail("EnumLayoutQuery: the Panic lang item without its Ok variant")
    }

    priv fn _bin(self,
                 at: SourceRange,
                 l:  unsafe *Expr,
                 r:  unsafe *Expr,
                 k:  TokenKind) -> unsafe *Expr {
        var unsafe *b = BinaryOperatorExpr::create(self.sc->ctx, at, l, r, self.synth.punct(at, k))
        b->type_          = self.sc->builtin(BuiltinKind::Bool)
        b->value_category = Expr::ValueCategory::RValue
        return b
    }
}

/// Lang-item overrides of an ADT's layout (spec ENUMLAYOUT §7), keyed on
/// the decl by EnumLayoutLowering::_knobs. Every default is the layout every
/// other ADT gets; the Panic lang item (Compiler/Spec/Panic.md#layout) sets all of them.
/// Any knob also rules out the niche and the common-prefix layouts: word 0
/// is the tag and the site, which neither keeps.
pub class AdtLayoutKnobs {
    /// A pack-expanded variant's elements are tagged by their panic type id
    /// (Compiler/Spec/Panic.md#canonical-sets) rather than by position; ordinary variants keep
    /// their positions (Panic's Ok is 0, which no id is). Per instance, so
    /// it is a rule (EnumLayoutQuery::tag_value), not a list of values.
    pub var type_id_tags: bool        = false
    pub var tag_kind_set: bool        = false
    pub var tag_kind:     BuiltinKind = BuiltinKind::U32
    /// The payload union is aligned to at least this, and to every
    /// payload's alignment: `max(floor, alignof(P)...)`, per instance, so
    /// C++ computes it (`__kairo_payload_offset`) and Sema predicts it
    /// (EnumLayoutQuery::size_of). 0 = natural.
    pub var union_floor: u32  = 0
    pub var site_slot:   bool = false ///< a u32 `__kairo_site` between the tag and the union.
    /// A payload field whose type is a bare type parameter holds an empty
    /// struct when the argument is `void` (`Panic<void, E...>`'s Ok), and
    /// every variant is built through its lambda constructor, which never
    /// takes the field by value.
    pub var void_payload: bool = false

    fn AdtLayoutKnobs(self) { }

    fn any(self) -> bool {
        return self.type_id_tags
            || self.tag_kind_set
            || self.union_floor > 0
            || self.site_slot
            || self.void_payload
    }
}

pub class EnumLayoutLowering derives ASTWriter<EnumLayoutLowering> {
    pub var  sc:    unsafe *SemaContext
    priv var tu:    TypeUtil
    priv var synth: LowerSynth

    fn EnumLayoutLowering(self, sc: unsafe *SemaContext) {
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

        ASTWriter<EnumLayoutLowering>::run(self, self.sc->tu)
    }

    /// # entry point

    /// Wherever the walk finds one: at file scope, in a module, nested in a
    /// record.
    fn transform_enum_decl(self,
                           n: unsafe *Declarations::EnumDecl) -> cxx::std::vector<unsafe *Decl> {
        var out = ASTWriter<EnumLayoutLowering>::transform_enum_decl(self, n)
        if self._wants_layout(n) {
            self._build(n)
        }

        return out
    }

    /// A construction: a generic variant built both ways (AdtCtorForm::Both)
    /// calls its field constructor where the instance is concrete and every
    /// field moves. The layout is built first if the walk has not reached
    /// the enum yet, so a construction above its enum is decided the same
    /// way as one below it.
    fn transform_variant_init_expr(self, n: unsafe *VariantInitExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<EnumLayoutLowering>::transform_variant_init_expr(self, n)
        var unsafe *en  = dyn_cast<Declarations::EnumDecl>(n->en)
        if en == &null || !en->is_adt || (n->variant as usize) >= en->variants.size() {
            return out
        }

        if self._wants_layout(en) {
            self._build(en)
        }

        var unsafe *v = en->variants[n->variant as usize]
        if v == &null || v->adt_ctor != Declarations::AdtCtorForm::Both || n->type_ == &null {
            return out
        }

        if n->type_->is_dependent() || n->type_->is_instantiation_dependent() {
            return out
        }

        var q    = EnumLayoutQuery(self.sc)
        var args = self.tu.record_args(n->type_)
        for var i: usize = 0; i < v->payload.size(); ++i {
            var unsafe *ft = q.field_type_at(en, args, v->payload[i]->type_)
            if ft == &null || !self._moves(ft) {
                return out
            }
        }

        n->field_ctor = true
        return out
    }

    /// `__builtin_niche_of<T>()` -> the count, a `u64` literal (the lang
    /// item's own body is never what answers). The layouts T holds are
    /// built first, so the answer is the one a layout reading it would get.
    fn transform_call_expr(self, n: unsafe *CallExpr) -> unsafe *Expr {
        var unsafe *out = ASTWriter<EnumLayoutLowering>::transform_call_expr(self, n)
        if out != n {
            return out
        }

        var unsafe *callee = dyn_cast<NamedIdentExpr>(n->callee)
        if callee == &null || callee->resolved_decl == &null {
            return out
        }

        var unsafe *cd = NameLookup::representative(callee->resolved_decl)
        if self._is_lang(cd, WellKnownType::TypeIdOf) {
            return self._type_id_of(n)
        }

        if self._is_lang(cd, WellKnownType::PanicSiteOf) {
            return self._panic_site_of(n)
        }

        var tk = self._kairo_trait_kind(cd)
        if tk != WellKnownType::COUNT {
            return self._kairo_trait(n, tk)
        }

        if !self._is_lang(cd, WellKnownType::NicheOf) {
            return out
        }

        // A dependent call (a generic body's) has no instance entry: its T is
        // the instance's, which is the case reported below.
        var unsafe *ie = n->instance
        if ie != &null && ie->args.size() != 1 {
            kairo::std::ice_fail(
                "EnumLayoutLowering: __builtin_niche_of instance without its one argument",
            )
        }

        var cnt = niche_unknown()
        if ie != &null {
            self._prebuild(ie->args[0])
            cnt = EnumLayoutQuery(self.sc).niche_of_record(ie->args[0])
        }

        if cnt == niche_unknown() {
            // A generic body's T: the count is the instance's, and nothing
            // here can name it (the call is answered before C++ instantiates).
            var b = self.sc->diag->report(
                DiagID::SC233E,
                n->range.start,
                "'" + to_string(
                    WellKnownType::NicheOf,
                ) + "' needs a type whose layout is known here; this one depends on a generic parameter",
            )

            b.first(n->range, "answered at compile time, before any instantiation")
            b.emit()
            cnt = 0
        }

        var unsafe *lit = self.synth.int_literal(n->range, cnt, BuiltinKind::U64)
        lit->adopt_sema(unsafe (n as unsafe *Expr))
        return lit
    }

    priv fn _is_lang(self, d: unsafe *Decl, k: WellKnownType) -> bool {
        var unsafe *ld = self.sc->well_known->get(k)
        return ld != &null && d == NameLookup::representative(ld)
    }

    /// `__builtin_type_id<T>()` -> T's panic type id, a `u32` literal
    /// (Compiler/Spec/Panic.md#canonical-sets; PanicSets is the one place an id is computed). A
    /// compiler test hook: what a `catch e: T` will compare the tag with.
    priv fn _type_id_of(self, n: unsafe *CallExpr) -> unsafe *Expr {
        var unsafe *ie = n->instance
        if ie != &null && ie->args.size() != 1 {
            kairo::std::ice_fail(
                "EnumLayoutLowering: __builtin_type_id instance without its one argument",
            )
        }

        var id: u32 = 0
        if ie != &null {
            id = PanicSets(self.sc).type_id(ie->args[0])
        }

        if id == (0 as u32) {
            var b = self.sc->diag->report(
                DiagID::SC233E,
                n->range.start,
                "'" + to_string(
                    WellKnownType::TypeIdOf,
                ) + "' needs a type every TU spells the same way; this one depends on a generic parameter or has no C++ type",
            )

            b.first(n->range, "answered at compile time, before any instantiation")
            b.emit()
        }

        var unsafe *lit = self.synth.int_literal(n->range, id, BuiltinKind::U32)
        lit->adopt_sema(unsafe (n as unsafe *Expr))
        return lit
    }

    /// Which Kairo-only type query \p d is, or COUNT.
    priv fn _kairo_trait_kind(self, d: unsafe *Decl) -> WellKnownType {
        if self._is_lang(d, WellKnownType::IsSafePointer) {
            return WellKnownType::IsSafePointer
        }

        if self._is_lang(d, WellKnownType::IsUnsafePointer) {
            return WellKnownType::IsUnsafePointer
        }

        if self._is_lang(d, WellKnownType::IsNullable) {
            return WellKnownType::IsNullable
        }

        if self._is_lang(d, WellKnownType::IsAdtEnum) {
            return WellKnownType::IsAdtEnum
        }

        if self._is_lang(d, WellKnownType::IsClass) {
            return WellKnownType::IsClass
        }

        if self._is_lang(d, WellKnownType::IsStruct) {
            return WellKnownType::IsStruct
        }

        if self._is_lang(d, WellKnownType::IsTuple) {
            return WellKnownType::IsTuple
        }

        if self._is_lang(d, WellKnownType::TupleArity) {
            return WellKnownType::TupleArity
        }

        return WellKnownType::COUNT
    }

    /// A Kairo-only type query -> a literal. Only Sema knows the answer (C++
    /// spells a safe and an unsafe pointer, a class, a struct and an ADT
    /// alike), so a T that depends on a generic parameter has none here: the
    /// call is answered before any instantiation, as NicheOf's is.
    priv fn _kairo_trait(self, n: unsafe *CallExpr, k: WellKnownType) -> unsafe *Expr {
        var unsafe *ie              = n->instance
        var        t:  unsafe *Type = &null
        if ie != &null && ie->args.size() == 1 {
            t = ie->args[0]
        }

        if t != &null && t->canonical != &null {
            t = t->canonical
        }

        if t == &null || t->is_dependent() || t->is_instantiation_dependent() {
            var b = self.sc->diag->report(
                DiagID::SC233E,
                n->range.start,
                "'" + to_string(
                    k,
                ) + "' needs a concrete type; this one depends on a generic parameter",
            )

            b.first(n->range, "answered at compile time, before any instantiation")
            b.emit()
            t = &null
        }

        var arity: usize = 0
        if t != &null {
            arity = self.tu.tuple_arity(t)
        }

        if k == WellKnownType::TupleArity {
            var unsafe *lit = self.synth.int_literal(n->range, arity as u64, BuiltinKind::USize)
            lit->adopt_sema(unsafe (n as unsafe *Expr))
            return lit
        }

        var v = false
        if t != &null {
            var unsafe *u  = canon_unqual(t)
            var unsafe *rd = self.tu.record_decl(u)
            if k == WellKnownType::IsSafePointer {
                v = isa<PointerType>(u) && !self.tu.is_unsafe_ptr(u)
            }

            if k == WellKnownType::IsUnsafePointer {
                v = self.tu.is_unsafe_ptr(u)
            }

            if k == WellKnownType::IsNullable {
                v = isa<NullableType>(u)
            }

            if k == WellKnownType::IsTuple {
                v = arity > 0
            }

            if rd != &null {
                var unsafe *pd = self.tu.pattern_of(NameLookup::representative(rd))
                if k == WellKnownType::IsAdtEnum {
                    v = isa<Declarations::EnumDecl>(pd) && cast<Declarations::EnumDecl>(pd)->is_adt
                }

                if k == WellKnownType::IsClass {
                    v = isa<Declarations::ClassDecl>(pd)
                }

                if k == WellKnownType::IsStruct {
                    v = isa<Declarations::StructDecl>(pd) && arity == 0
                }
            }
        }

        var unsafe *bl = self.synth.bool_literal(n->range, v)
        bl->adopt_sema(unsafe (n as unsafe *Expr))
        return bl
    }

    /// `__builtin_panic_site()` -> the id of the site this call is at, a
    /// `u32` literal, registered in the TU's site table as a `panic` is
    /// (Compiler/Spec/Panic.md#site-ids). A compiler test hook until PanicLowering exists.
    priv fn _panic_site_of(self, n: unsafe *CallExpr) -> unsafe *Expr {
        var        id   = PanicSets(self.sc).site_id(n->range.start)
        var unsafe *lit = self.synth.int_literal(n->range, id, BuiltinKind::U32)
        lit->adopt_sema(unsafe (n as unsafe *Expr))
        return lit
    }

    /// An ADT's pattern, once. An instance shares its pattern's record; a
    /// redeclaration chain is built at its representative, the decl every
    /// RecordType names; a decl the walk reaches twice (a visibility group
    /// lists its members again) already has its record. A poisoned enum or
    /// an unresolved payload type was reported, and an error keeps the
    /// lowerings from running at all, so that test is only a guard.
    priv fn _wants_layout(self, en: unsafe *Declarations::EnumDecl) -> bool {
        if !en->is_adt || en->is_poisoned() {
            return false
        }

        var unsafe *d = unsafe (en as unsafe *Decl)
        if decl_is_instance(d) {
            return false
        }

        if NameLookup::representative(d) != d {
            return false
        }

        if en->adt_layout != &null {
            return false
        }

        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v == &null || v->is_poisoned() {
                return false
            }

            for var j: usize = 0; j < v->payload.size(); ++j {
                var unsafe *f = v->payload[j]
                if f == &null || f->is_poisoned() {
                    return false
                }

                if f->type_ == &null || f->type_->canonical == &null {
                    return false
                }
            }
        }

        return true
    }

    /// # the record

    priv fn _build(self, en: unsafe *Declarations::EnumDecl) {
        var        at      = en->name.range
        var unsafe *edc    = unsafe (en as unsafe *DeclContext)
        var        generic = en->generic_params.size() > 0

        // The enum's own name and generic parameters: to C++ this record IS
        // the enum, so anything that asks it for either gets the enum's.
        var unsafe *lay = Declarations::StructDecl::create(self.ctx, en->range, en->name, edc)
        // Synthesized whole, so a definition (decl_only_forward reads a
        // record with no defining link as only forward-declared).
        lay->mark_definition()
        self._place(lay, edc, VisibilityKind::Public, at)
        self._no_members(lay)
        lay->generic_params = en->generic_params
        lay->adt_of         = en
        var unsafe *ldc = unsafe (lay as unsafe *DeclContext)

        var        knobs = self._knobs(en)
        var unsafe *tag  = self._tag_enum(en, at, edc, &knobs)
        ldc->add_decl(unsafe (tag as unsafe *Decl))

        // The layout's shape, decided before anything is minted: a
        // niche-filled ADT has no tag at all, a prefix-tagged one keeps it
        // inside each payload (file header).
        var shaped = !knobs.any() && self._niche_shaped(en)
        var niche  = false
        if shaped && !generic {
            var unsafe *npv = en->variants[adt_niche_payload_variant(en) as usize]
            self._prebuild(npv->payload[0]->type_)
            niche = EnumLayoutQuery(self.sc).niche_verdict(en, npv->payload[0]->type_) == 1
        }

        var        prefix = !generic && !niche && !knobs.any() && self._prefix_ok(en)
        var unsafe *ttype = self._type_of(tag)

        // A struct and a union member for each variant that has a payload.
        var members = self.list_builder<unsafe *Declarations::FieldDecl>()
        var mvec    = cxx::std::vector<unsafe *Declarations::FieldDecl>()
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v->payload.is_empty() {
                continue
            }

            var        vn  = self.tu.decl_name(unsafe (v as unsafe *Decl))
            var unsafe *ps = self._payload_struct(v, vn, edc, if (prefix) => (ttype) else => &null)
            // `Err { e: E }...`: the struct is a template over one element,
            // and its union member holds one per element (InterfaceEmitter).
            if v->is_pack_expansion {
                ps->adt_pack_param = en->generic_params[adt_pack_param(en)]
            }

            ldc->add_decl(ps)
            var unsafe *m = Declarations::FieldDecl::create(
                self.ctx,
                v->name.range,
                self.synth.ident(v->name.range, LowerTargets::adt_payload_field(vn)),
                Declarations::StorageClass::Var,
                self._type_of(ps),
                members.size() as u32,
            )

            self._place(m, edc, VisibilityKind::Public, v->name.range)
            members.push(m)
            mvec.push_back(m)
            v->adt_member = m
            v->adt_ctor = if (v->is_pack_expansion
                              || knobs.void_payload) => (Declarations::AdtCtorForm::Lambda)
                          else => self._ctor_form(v, generic)
        }

        var fields = self.list_builder<unsafe *Declarations::FieldDecl>()
        var unsafe *tf = Declarations::FieldDecl::create(
            self.ctx,
            at,
            self.synth.ident(at, LowerTargets::adt_tag_field()),
            Declarations::StorageClass::Var,
            self._type_of(tag),
            0,
        )

        self._place(tf, edc, VisibilityKind::Public, at)
        ldc->add_decl(tf)
        fields.push(tf)
        if knobs.site_slot {
            var unsafe *sf = Declarations::FieldDecl::create(
                self.ctx,
                at,
                self.synth.ident(at, LowerTargets::adt_site_field()),
                Declarations::StorageClass::Var,
                self.sc->builtin(BuiltinKind::U32),
                1,
            )

            self._place(sf, edc, VisibilityKind::Public, at)
            ldc->add_decl(sf)
            fields.push(sf)
            en->adt_site_field = sf
        }

        en->adt_union_align = knobs.union_floor
        en->adt_void_unit   = knobs.void_payload
        if knobs.union_floor > 0 {
            // The union's alignment, which is where every payload starts
            // (Compiler/Spec/Panic.md#layout, §4.6: read from here, never assumed to be 8).
            // Before the union: its `alignas` names it.
            var unsafe *po = Declarations::FieldDecl::create(
                self.ctx,
                at,
                self.synth.ident(at, LowerTargets::adt_payload_offset()),
                Declarations::StorageClass::Eval,
                self.sc->builtin(BuiltinKind::U32),
                fields.size() as u32,
            )

            self._place(po, edc, VisibilityKind::Public, at)
            ldc->add_decl(po)
            fields.push(po)
            en->adt_payload_offset = po
        }

        // No name, and declared only by the field that holds it: its members
        // are the record's to C++, and that field is in no field_of chain
        // (FieldDecl::is_anonymous_union).
        var unsafe *un = Declarations::UnionDecl::create(self.ctx, at, Token(), edc)
        un->mark_definition()
        self._place(un, edc, VisibilityKind::Public, at)
        un->is_anonymous   = true
        un->methods        = create_empty_frozen_list<unsafe *Declarations::FunctionDecl>()
        un->generic_params = create_empty_frozen_list<unsafe *Declarations::GenericParamDecl>()
        un->spec_args      = create_empty_frozen_list<unsafe *Type>()
        if prefix {
            // The tag-only member, first: reading the tag through it is the
            // common-initial-sequence read every payload struct allows.
            var unsafe *ts = Declarations::StructDecl::create(
                self.ctx,
                at,
                self.synth.ident(at, LowerTargets::adt_tag_only_type()),
                edc,
            )

            ts->mark_definition()
            self._place(ts, edc, VisibilityKind::Public, at)
            self._no_members(ts)
            ts->is_adt_payload = true
            var tsl = self.list_builder<unsafe *Declarations::FieldDecl>()
            var unsafe *pt = Declarations::FieldDecl::create(
                self.ctx,
                at,
                self.synth.ident(at, LowerTargets::adt_tag_field()),
                Declarations::StorageClass::Var,
                ttype,
                0,
            )

            self._place(pt, ts, VisibilityKind::Public, at)
            tsl.push(pt)
            tsl.freeze_into(&ts->fields)
            ldc->add_decl(ts)
            var unsafe *tm = Declarations::FieldDecl::create(
                self.ctx,
                at,
                self.synth.ident(at, LowerTargets::adt_tag_member()),
                Declarations::StorageClass::Var,
                self._type_of(ts),
                0,
            )

            self._place(tm, edc, VisibilityKind::Public, at)
            var all = self.list_builder<unsafe *Declarations::FieldDecl>()
            all.push(tm)
            for var i: usize = 0; i < mvec.size(); ++i {
                all.push(mvec[i])
            }

            all.freeze_into(&un->fields)
            en->adt_tag_member = tm
            en->adt_prefix_tag = pt
        } else {
            members.freeze_into(&un->fields)
        }

        ldc->add_decl(un)

        var unsafe *uf = Declarations::FieldDecl::create(
            self.ctx,
            at,
            Token(),
            Declarations::StorageClass::Var,
            self._type_of(un),
            fields.size() as u32,
        )

        uf->is_anonymous_union = true
        self._place(uf, edc, VisibilityKind::Public, at)
        ldc->add_decl(uf)
        fields.push(uf)

        // What a generic ADT's constraints test. No expression stands behind
        // a flag: InterfaceEmitter writes its initializer from the payload
        // structs, so the field only names it.
        if generic {
            self._flag(LowerTargets::adt_trivial_dtor(), at, edc, ldc, &fields)
            self._flag(LowerTargets::adt_trivial_copy(), at, edc, ldc, &fields)
            self._flag(LowerTargets::adt_destructible(), at, edc, ldc, &fields)
            self._flag(LowerTargets::adt_copyable(), at, edc, ldc, &fields)
            self._flag(LowerTargets::adt_movable(), at, edc, ldc, &fields)
        }

        fields.freeze_into(&lay->fields)

        var methods = self.list_builder<unsafe *Declarations::FunctionDecl>()
        for var i: usize = 0; i < en->variants.size(); ++i {
            self._member(
                ldc,
                &methods,
                self._role(
                    en,
                    en->name,
                    Declarations::AdtRole::VariantCtor,
                    Declarations::AdtForm::Body,
                    i as u32,
                    VisibilityKind::Public,
                ),
            )
        }

        if generic {
            self._three(ldc, &methods, en, Declarations::AdtRole::CopyCtor)
            self._three(ldc, &methods, en, Declarations::AdtRole::MoveCtor)
            self._three(ldc, &methods, en, Declarations::AdtRole::CopyAssign)
            self._three(ldc, &methods, en, Declarations::AdtRole::MoveAssign)
            self._three(ldc, &methods, en, Declarations::AdtRole::Dtor)
        } else {
            self._chosen(ldc, &methods, en)
        }

        // What the bodies above call; nothing outside the record may.
        self._member(
            ldc,
            &methods,
            self._role(
                en,
                self.synth.ident(at, LowerTargets::adt_destroy()),
                Declarations::AdtRole::Destroy,
                Declarations::AdtForm::Body,
                0,
                VisibilityKind::Private,
            ),
        )

        self._member(
            ldc,
            &methods,
            self._role(
                en,
                self.synth.ident(at, LowerTargets::adt_construct_from()),
                Declarations::AdtRole::ConstructFrom,
                Declarations::AdtForm::Body,
                0,
                VisibilityKind::Private,
            ),
        )

        if self._is_nullable(en) {
            self._nullable_surface(ldc, &methods, en)
        }

        // Niche layout (file header). The facts are set before which() is
        // minted: a generic ADT may be laid out either way per instance, a
        // niche-filled one has no tag to read, and both answer which().
        en->adt_tag_field   = tf
        en->adt_niche_shape = shaped
        en->adt_niche       = niche
        if generic || en->adt_niche {
            var unsafe *w = self._role(
                en,
                self.synth.ident(at, LowerTargets::adt_which()),
                Declarations::AdtRole::Which,
                Declarations::AdtForm::Body,
                0,
                VisibilityKind::Public,
            )

            self._member(ldc, &methods, w)
            en->adt_which = w
        }

        methods.freeze_into(&lay->methods)

        en->adt_layout    = lay
        en->adt_tag_field = tf
    }

    /// `enum class __kairo_Tag : u8 { V0, V1, ... }`: every variant, payload
    /// or not, by its own name and in order. No discriminants, so each value
    /// is the variant's position and InterfaceEmitter writes the names bare.
    /// The narrowest word that holds them (_tag_kind): the tag sits before
    /// the union, so every byte past it is padding a small payload pays.
    priv fn _tag_enum(self,
                      en:    unsafe *Declarations::EnumDecl,
                      at:    SourceRange,
                      edc:   unsafe *DeclContext,
                      knobs: *AdtLayoutKnobs) -> unsafe *Declarations::EnumDecl {
        var unsafe *tag = Declarations::EnumDecl::create(
            self.ctx,
            at,
            self.synth.ident(at, LowerTargets::adt_tag_type()),
            edc,
        )

        self._place(tag, edc, VisibilityKind::Public, at)
        tag->underlying = self.sc->builtin(
            if (knobs->tag_kind_set) => (knobs->tag_kind) else => self._tag_kind(en),
        )

        tag->generic_params = create_empty_frozen_list<unsafe *Declarations::GenericParamDecl>()
        tag->spec_args      = create_empty_frozen_list<unsafe *Type>()
        var unsafe *tdc = unsafe (tag as unsafe *DeclContext)
        var        vs   = self.list_builder<unsafe *Declarations::EnumVariantDecl>()
        // The tag enum is nested in the record, which C++ writes inside
        // `template <class T>`: an enumerator named like a type parameter
        // shadows it, which is ill-formed (P539). Such a one gets `_`
        // appended, repeated while the name is still a parameter's or a
        // variant's; the tag is positional (InterfaceEmitter::_tag_leaf
        // reads the enumerator by position), so the Kairo variant keeps its
        // name and nothing else sees the change.
        var taken = cxx::std::vector<string>()
        for var i: usize = 0; i < en->generic_params.size(); ++i {
            taken.push_back(self.tu.decl_name(unsafe (en->generic_params[i] as unsafe *Decl)))
        }

        var nparams = taken.size()
        for var i: usize = 0; i < en->variants.size(); ++i {
            taken.push_back(self.tu.decl_name(unsafe (en->variants[i] as unsafe *Decl)))
        }

        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            var        nm = v->name
            var        vn = self.tu.decl_name(unsafe (v as unsafe *Decl))
            var        clash = false
            for var k: usize = 0; k < nparams; ++k {
                if taken[k] == vn {
                    clash = true
                }
            }

            if clash {
                var fresh = vn + "_"
                var again = true
                while again {
                    again = false
                    for var k: usize = 0; k < taken.size(); ++k {
                        if taken[k] == fresh {
                            again = true
                        }
                    }

                    if again {
                        fresh = fresh + "_"
                    }
                }

                taken.push_back(fresh)
                nm = self.synth.ident(v->name.range, fresh)
            }

            var unsafe *tv = Declarations::EnumVariantDecl::create(
                self.ctx,
                v->range,
                nm,
                i as u32,
            )

            self._place(tv, tdc, VisibilityKind::Public, v->name.range)
            tv->payload = create_empty_frozen_list<unsafe *Declarations::FieldDecl>()
            vs.push(tv)
        }

        vs.freeze_into(&tag->variants)
        // Type-id tags: a pack element's tag is no enumerator (it is its
        // type's id, per instance); the pack variant's enumerator only
        // names the variant, and nothing stores or compares it.
        en->adt_explicit_tags = knobs->type_id_tags
        return tag
    }

    /// \p en's layout overrides (AdtLayoutKnobs), by identity with the lang
    /// item that wants them -- never by name: a user may declare an enum
    /// called Panic. The Panic lang item (Compiler/Spec/Panic.md#layout): type-id tags in
    /// a u32, the u32 site beside it (word 0, one 64-bit store), the union
    /// at `max(8, alignof(...))`, and a `void` Ok.
    priv fn _knobs(self, en: unsafe *Declarations::EnumDecl) -> AdtLayoutKnobs {
        var k = AdtLayoutKnobs()
        if PanicSets(self.sc).panic_enum() == en {
            if adt_pack_variant(en) == &null {
                kairo::std::ice_fail(
                    "EnumLayoutLowering: the Panic lang item without its pack-expanded Err; Lib/builtin declares it",
                )
            }

            k.type_id_tags = true
            k.tag_kind_set = true
            k.tag_kind     = BuiltinKind::U32
            k.union_floor  = 8
            k.site_slot    = true
            k.void_payload = true
        }

        return k
    }

    /// \p en can keep its tag in its payloads' common prefix (spec
    /// ENUMLAYOUT §6): every payload field a builtin, a pointer or a plain
    /// enum, so every payload struct is standard-layout -- the
    /// common-initial-sequence read needs that -- and trivially copied, so
    /// the special members are the defaulted ones and no body switches on
    /// a tag that is no longer a member of its own. Anything else keeps the
    /// external tag. v1: non-generic only; a generic ADT's payloads are
    /// standard-layout per instance, which only a third C++ form could ask.
    priv fn _prefix_ok(self, en: unsafe *Declarations::EnumDecl) -> bool {
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            for var j: usize = 0; j < v->payload.size(); ++j {
                var unsafe *t = v->payload[j]->type_
                if t == &null || t->canonical == &null {
                    return false
                }

                var unsafe *c = canon_unqual(t->canonical)
                if c == &null || canon_quals(t->canonical) != 0 {
                    return false
                }

                // The variant constructor is then the field one (_ctor_form
                // asks the same), which is the only form the prefix renders.
                if !self._moves(t) {
                    return false
                }

                if isa<BuiltinType>(c) || isa<PointerType>(c) {
                    continue
                }

                if isa<RecordType>(c) {
                    var unsafe *pe = dyn_cast<Declarations::EnumDecl>(cast<RecordType>(c)->decl)
                    if pe != &null && !pe->is_adt {
                        continue
                    }
                }

                return false
            }
        }

        return true
    }

    /// \p en could be laid out without a tag (spec ENUMLAYOUT §5.2): exactly
    /// one variant carries a payload, that payload is one field (v1: a
    /// record's first-field niche, which would lift this, is answered but
    /// not laid out -- EnumLayoutQuery::niche_of), at least one variant has
    /// none, and no generic parameter is a pack. Whether it IS is the
    /// field's niche and triviality, per instance for a generic enum.
    priv fn _niche_shaped(self, en: unsafe *Declarations::EnumDecl) -> bool {
        var payloads: usize = 0
        var dataless: usize = 0
        for var i: usize = 0; i < en->variants.size(); ++i {
            var unsafe *v = en->variants[i]
            if v->payload.size() == 0 {
                dataless += 1
                continue
            }

            payloads += 1
            if v->payload.size() != 1 {
                return false
            }
        }

        if payloads != 1 || dataless == 0 {
            return false
        }

        // The specialization's head carries the niche constraint; a declared
        // one beside it would be a second requires-clause.
        if decl_requires_clause(en) != &null {
            return false
        }

        for var i: usize = 0; i < en->generic_params.size(); ++i {
            var unsafe *gp = en->generic_params[i]
            if gp == &null || gp->is_pack {
                return false
            }
        }

        return true
    }

    /// Build the layout of every ADT \p t holds by value first, so a
    /// non-generic enum's verdict reads its field's real shape whatever
    /// order the walk meets the declarations in. By-value ADT cycles are
    /// TypeCycleCheck's to reject, so this terminates.
    priv fn _prebuild(self, t: unsafe *Type) {
        if t == &null || t->canonical == &null {
            return
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c == &null {
            return
        }

        if isa<NullableType>(c) {
            var unsafe *nd = self.sc->nullable_enum()
            if nd != &null && self._wants_layout(nd) {
                self._build(nd)
            }

            self._prebuild(cast<NullableType>(c)->inner)
            return
        }

        if !isa<RecordType>(c) {
            return
        }

        var unsafe *r = cast<RecordType>(c)
        var unsafe *en = dyn_cast<Declarations::EnumDecl>(
            NameLookup::representative(self.tu.pattern_of(r->decl)),
        )

        if en != &null && en->is_adt && self._wants_layout(en) {
            self._build(en)
        }

        for var i: usize = 0; i < r->args.size(); ++i {
            self._prebuild(*r->args.get(i))
        }
    }

    /// The tag word (EnumNiche: adt_declared_tag_kind, which TypeExport's
    /// phase-A stand-in reads too, before this pass has run).
    priv fn _tag_kind(self, en: unsafe *Declarations::EnumDecl) -> BuiltinKind {
        return adt_declared_tag_kind(en)
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
    priv fn _ctor_form(self,
                       v:       unsafe *Declarations::EnumVariantDecl,
                       generic: bool) -> Declarations::AdtCtorForm {
        for var j: usize = 0; j < v->payload.size(); ++j {
            var unsafe *t = v->payload[j]->type_
            if t == &null
                || t->canonical == &null
                || isa<FixedArrayType>(canon_unqual(t->canonical)) {
                return Declarations::AdtCtorForm::Lambda
            }
        }

        if generic {
            return Declarations::AdtCtorForm::Both
        }

        for var j: usize = 0; j < v->payload.size(); ++j {
            if !self._moves(v->payload[j]->type_) {
                return Declarations::AdtCtorForm::Lambda
            }
        }

        return Declarations::AdtCtorForm::Fields
    }

    /// \p t moves as its bytes and is destroyed as nothing, and is no array
    /// (_ctor_form).
    priv fn _moves(self, t: unsafe *Type) -> bool {
        if t == &null || t->canonical == &null {
            return false
        }

        if isa<FixedArrayType>(canon_unqual(t->canonical)) {
            return false
        }

        // A non-generic ADT's payload: concrete, so an open fact would pick
        // the Lambda form silently (Asked too early, ClassLifecycle).
        var f = lifecycle_of(self.sc)->facts_of_type_concrete(
            t->canonical,
            "EnumLayoutLowering::_moves",
        )

        return f.movable == LifecycleTri::Yes
            && f.trivially_copyable == LifecycleTri::Yes
            && f.trivial_dtor == LifecycleTri::Yes
    }

    /// `struct __kairo_<V>_t` over the variant's own payload FieldDecls (file
    /// header). is_adt_payload is what gives it its placement operator new.
    /// A prefix-tagged ADT's (\p prefix_tag, the tag enum's type) starts
    /// with a tag of its own: the common initial sequence the union's
    /// tag-only member reads.
    priv fn _payload_struct(self,
                            v:          unsafe *Declarations::EnumVariantDecl,
                            const vn:   string,
                            edc:        unsafe *DeclContext,
                            prefix_tag: unsafe *Type) -> unsafe *Declarations::StructDecl {
        var unsafe *ps = Declarations::StructDecl::create(
            self.ctx,
            v->range,
            self.synth.ident(v->name.range, LowerTargets::adt_payload_type(vn)),
            edc,
        )

        ps->mark_definition()
        self._place(ps, edc, VisibilityKind::Public, v->name.range)
        self._no_members(ps)
        ps->is_adt_payload = true
        var unsafe *pdc = unsafe (ps as unsafe *DeclContext)
        var        fs   = self.list_builder<unsafe *Declarations::FieldDecl>()
        if prefix_tag != &null {
            var unsafe *pt = Declarations::FieldDecl::create(
                self.ctx,
                v->name.range,
                self.synth.ident(v->name.range, LowerTargets::adt_tag_field()),
                Declarations::StorageClass::Var,
                prefix_tag,
                0,
            )

            self._place(pt, ps, VisibilityKind::Public, v->name.range)
            fs.push(pt)
        }

        for var j: usize = 0; j < v->payload.size(); ++j {
            var unsafe *f = v->payload[j]
            fs.push(f)
            // A variant is not a DeclContext, so the parser leaves its
            // payload fields with no scope at all. To C++ they are members
            // of this struct, and that is where a spelling of one
            // (CXXSpell::leaf reads the name in its scope's TU) and a use of
            // one (EmitPlan::_member_owner) must find it. This is the only
            // writer: a scope already here means a second one exists, and
            // whichever ran last would silently decide where the field lives.
            var unsafe *fd = unsafe (f as unsafe *Decl)
            if fd->semantic_dc != &null || fd->lexical_dc != &null {
                kairo::std::ice_fail(
                    "EnumLayoutLowering: payload field already has a scope; this pass is its only writer",
                )
            }

            fd->semantic_dc = pdc
            fd->lexical_dc  = pdc
        }

        fs.freeze_into(&ps->fields)
        return ps
    }

    /// A generic ADT's flag: a compile-time bool (eval, C++'s `static
    /// constexpr`) whose initializer InterfaceEmitter writes.
    priv fn _flag(self,
                  const name: string,
                  at:         SourceRange,
                  edc:        unsafe *DeclContext,
                  ldc:        unsafe *DeclContext,
                  fields:     *ListBuilder<unsafe *Declarations::FieldDecl>) {
        var unsafe *f = Declarations::FieldDecl::create(
            self.ctx,
            at,
            self.synth.ident(at, name),
            Declarations::StorageClass::Eval,
            self.sc->builtin(BuiltinKind::Bool),
            fields->size() as u32,
        )

        self._place(f, edc, VisibilityKind::Public, at)
        ldc->add_decl(f)
        fields->push(f)
    }

    /// # the Nullable lang item

    /// By identity with the lang item, never by name: a user may declare an
    /// enum called Nullable.
    priv fn _is_nullable(self, en: unsafe *Declarations::EnumDecl) -> bool {
        var unsafe *nd = self.sc->nullable_enum()
        return nd != &null && nd == en
    }

    /// `T?`'s C++ surface on top of the ADT (Compiler/Spec/Nullables.md#the-library-type): the ADT
    /// already holds a real T only while present and transfers it as T
    /// does; these are the constructors every implicit conversion into a
    /// nullable is, and the primitives the desugars and a C++ host call.
    /// The null constructor's parameter is a real ParamDecl so its null_t is
    /// spelled like any type; the rest are rendered from the payload.
    priv fn _nullable_surface(self,
                              ldc:     unsafe *DeclContext,
                              methods: *ListBuilder<unsafe *Declarations::FunctionDecl>,
                              en:      unsafe *Declarations::EnumDecl) {
        var at = en->name.range
        self._member(
            ldc,
            methods,
            self._role(
                en,
                en->name,
                Declarations::AdtRole::NullDefault,
                Declarations::AdtForm::Body,
                0,
                VisibilityKind::Public,
            ),
        )

        var unsafe *from = self._role(
            en,
            en->name,
            Declarations::AdtRole::NullFrom,
            Declarations::AdtForm::Body,
            0,
            VisibilityKind::Public,
        )

        var unsafe *nt = self.sc->well_known->get(WellKnownType::NullT)
        if nt == &null {
            kairo::std::ice_fail(
                "EnumLayoutLowering: the Nullable lang item without null_t; Lib/builtin declares both",
            )
        }

        var ps = self.list_builder<unsafe *Declarations::ParamDecl>()
        ps.push(
            Declarations::ParamDecl::create(
                self.ctx,
                at,
                self.synth.ident(at, LowerTargets::nullable_null_param()),
                self._type_of(NameLookup::representative(nt)),
                0,
            ),
        )

        ps.freeze_into(&from->params)
        self._member(ldc, methods, from)
        self._member(
            ldc,
            methods,
            self._role(
                en,
                en->name,
                Declarations::AdtRole::ValueCopy,
                Declarations::AdtForm::Body,
                0,
                VisibilityKind::Public,
            ),
        )

        self._member(
            ldc,
            methods,
            self._role(
                en,
                en->name,
                Declarations::AdtRole::ValueMove,
                Declarations::AdtForm::Body,
                0,
                VisibilityKind::Public,
            ),
        )

        var is_null = self.synth.ident(at, LowerTargets::nullable_is_null())
        var value   = self.synth.ident(at, LowerTargets::nullable_value())
        self._member(
            ldc,
            methods,
            self._role(
                en,
                is_null,
                Declarations::AdtRole::IsNull,
                Declarations::AdtForm::Body,
                0,
                VisibilityKind::Public,
            ),
        )

        self._member(
            ldc,
            methods,
            self._role(
                en,
                value,
                Declarations::AdtRole::ValueRef,
                Declarations::AdtForm::Body,
                0,
                VisibilityKind::Public,
            ),
        )

        self._member(
            ldc,
            methods,
            self._role(
                en,
                value,
                Declarations::AdtRole::ValueCref,
                Declarations::AdtForm::Body,
                0,
                VisibilityKind::Public,
            ),
        )

        self._member(
            ldc,
            methods,
            self._role(
                en,
                en->name,
                Declarations::AdtRole::Equal,
                Declarations::AdtForm::Body,
                0,
                VisibilityKind::Public,
            ),
        )
    }

    /// # the special members

    /// The one form of each special member a non-generic ADT's facts select
    /// (file header). Each assignment takes its constructor's form.
    priv fn _chosen(self,
                    ldc:     unsafe *DeclContext,
                    methods: *ListBuilder<unsafe *Declarations::FunctionDecl>,
                    en:      unsafe *Declarations::EnumDecl) {
        var unsafe *f = lifecycle_of(self.sc)->facts_of(en)
        // Nothing in a non-generic enum's own declaration waits on a
        // parameter. An Unknown comes from a payload whose facts do -- an
        // instance of a generic record reads its pattern's until facts are
        // computed per instance -- and a form picked for it would be a guess.
        // FeatureGateCheck reports exactly this case (the same
        // lifecycle_open), so reaching it means that gate has a hole.
        if lifecycle_open(f) {
            kairo::std::ice_fail("EnumLayoutLowering: non-generic ADT with unknown lifecycle facts")
        }

        var copy_form = Declarations::AdtForm::Trivial
        var move_form = Declarations::AdtForm::Trivial
        var dtor_form = Declarations::AdtForm::Trivial
        if f->trivially_copyable != LifecycleTri::Yes {
            copy_form = if (f->category == LifecycleCategory::Copy) => (Declarations::AdtForm::Body)
                        else => Declarations::AdtForm::Deleted
            move_form = if (f->category == LifecycleCategory::NonTransfer) => (Declarations::AdtForm::Deleted)
                        else => Declarations::AdtForm::Body
        }

        if f->trivial_dtor != LifecycleTri::Yes {
            dtor_form = if (f->destructible == LifecycleTri::Yes) => (Declarations::AdtForm::Body)
                        else => Declarations::AdtForm::Deleted
        }

        self._member(
            ldc,
            methods,
            self._role(
                en,
                en->name,
                Declarations::AdtRole::CopyCtor,
                copy_form,
                0,
                VisibilityKind::Public,
            ),
        )

        self._member(
            ldc,
            methods,
            self._role(
                en,
                en->name,
                Declarations::AdtRole::MoveCtor,
                move_form,
                0,
                VisibilityKind::Public,
            ),
        )

        self._member(
            ldc,
            methods,
            self._role(
                en,
                en->name,
                Declarations::AdtRole::CopyAssign,
                copy_form,
                0,
                VisibilityKind::Public,
            ),
        )

        self._member(
            ldc,
            methods,
            self._role(
                en,
                en->name,
                Declarations::AdtRole::MoveAssign,
                move_form,
                0,
                VisibilityKind::Public,
            ),
        )

        self._member(
            ldc,
            methods,
            self._role(
                en,
                en->name,
                Declarations::AdtRole::Dtor,
                dtor_form,
                0,
                VisibilityKind::Public,
            ),
        )
    }

    /// A generic ADT's three forms of \p role, in the order InterfaceEmitter
    /// writes them.
    priv fn _three(self,
                   ldc:     unsafe *DeclContext,
                   methods: *ListBuilder<unsafe *Declarations::FunctionDecl>,
                   en:      unsafe *Declarations::EnumDecl,
                   role:    Declarations::AdtRole) {
        self._member(
            ldc,
            methods,
            self._role(
                en,
                en->name,
                role,
                Declarations::AdtForm::Trivial,
                0,
                VisibilityKind::Public,
            ),
        )

        self._member(
            ldc,
            methods,
            self._role(en, en->name, role, Declarations::AdtForm::Body, 0, VisibilityKind::Public),
        )

        self._member(
            ldc,
            methods,
            self._role(
                en,
                en->name,
                role,
                Declarations::AdtForm::Deleted,
                0,
                VisibilityKind::Public,
            ),
        )
    }

    /// A function with no Kairo body, rendered from \p role and \p form.
    /// Never an operator, whatever C++ it becomes (`~E`, `operator=`): its
    /// name is an identifier token, which is all a minted decl can spell. A
    /// defaulted or deleted form carries that body kind; the others none.
    priv fn _role(self,
                  en:      unsafe *Declarations::EnumDecl,
                  name:    Token,
                  role:    Declarations::AdtRole,
                  form:    Declarations::AdtForm,
                  variant: u32,
                  vis:     VisibilityKind) -> unsafe *Declarations::FunctionDecl {
        var unsafe *edc = unsafe (en as unsafe *DeclContext)
        var unsafe *f   = Declarations::FunctionDecl::create(self.ctx, name.range, name, edc)
        self._place(f, edc, vis, name.range)
        f->params          = create_empty_frozen_list<unsafe *Declarations::ParamDecl>()
        f->op_token        = create_empty_frozen_list<Token>()
        f->generic_params  = create_empty_frozen_list<unsafe *Declarations::GenericParamDecl>()
        f->spec_args       = create_empty_frozen_list<unsafe *Type>()
        f->requires_clause = &null
        f->is_implicit     = true
        f->body_kind       = Declarations::FnBodyKind::None
        if form == Declarations::AdtForm::Trivial {
            f->body_kind = Declarations::FnBodyKind::Default
        }

        if form == Declarations::AdtForm::Deleted {
            f->body_kind = Declarations::FnBodyKind::Delete
        }

        f->adt_role    = role
        f->adt_form    = form
        f->adt_variant = variant
        return f
    }

    priv fn _member(self,
                    ldc:     unsafe *DeclContext,
                    methods: *ListBuilder<unsafe *Declarations::FunctionDecl>,
                    f:       unsafe *Declarations::FunctionDecl) {
        ldc->add_decl(unsafe (f as unsafe *Decl))
        methods->push(f)
    }

    /// # minting

    /// Every minted decl belongs to the enum, so it is spelled and planned as
    /// a member of it (a tag enum's variants belong to the tag enum). None
    /// joins a symbol table: nothing finds them by name.
    priv fn _place(self,
                   d:   unsafe *Decl,
                   dc:  unsafe *DeclContext,
                   vis: VisibilityKind,
                   at:  SourceRange) {
        d->semantic_dc = dc
        d->lexical_dc  = dc
        d->set_visibility(vis, at)
    }

    priv fn _no_members(self, s: unsafe *Declarations::StructDecl) {
        s->fields         = create_empty_frozen_list<unsafe *Declarations::FieldDecl>()
        s->methods        = create_empty_frozen_list<unsafe *Declarations::FunctionDecl>()
        s->implements     = create_empty_frozen_list<Declarations::InheritEdge>()
        s->generic_params = create_empty_frozen_list<unsafe *Declarations::GenericParamDecl>()
        s->spec_args      = create_empty_frozen_list<unsafe *Type>()
    }

    priv fn _type_of(self, d: unsafe *Decl) -> unsafe *Type {
        return self.sc->types->record(d, &null)
    }
}
