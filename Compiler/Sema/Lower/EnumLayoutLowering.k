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
import AST::EnumNiche::*;
import AST::Context::InstantiationRegistry::*;
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
import Diagnostic::Registry::*;
import Token::TokenKind::*;
import Location::SourceRange::*;

/// How an ADT value is laid out at one type (EnumLayoutQuery::shape_at).
///   Tagged  a tag field and a payload union: the tag is read directly.
///   Niche   no tag (EnumLayoutLowering's header, "Niche layout"): a
///           dataless variant is a value the payload's one field never
///           holds, so a test compares that field against it.
///   Opaque  a generic ADT whose instance C++ lays out -- a dependent type,
///           or one whose facts Sema cannot settle: the value is asked
///           through `__kairo_which()`, which both layouts answer.
enum AdtShape derives u8 {
    Tagged = 0,
    Niche,
    Opaque,
}

/// "No answer": a niche count that depends on what only C++ instantiates.
fn niche_unknown() -> u64 { return ~u64(0); }

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
///   tag_value(V)             the discriminant V is stored as
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

    /// Tags are the positions `0..N-1`: a switch over them is complete and
    /// clang can index a table by them. Not with explicit tag values.
    fn is_exhaustive_dense(self, en: *EnumDecl) -> bool {
        return self.has_layout(en) && (!en->adt_explicit_tags);
    }

    /// The discriminant variant \p index is stored as: its position, or the
    /// explicit value a lang item gave it (AdtLayoutKnobs).
    fn tag_value(self, en: *EnumDecl, index: u32) -> u64 {
        return en->variants[usize(index)]->adt_tag_value;
    }

    // --- shape --------------------------------------------------------------------

    /// The layout of ADT values of type \p t. A non-generic ADT's is its
    /// declaration's. A generic one's is per instance and C++ picks it
    /// (InterfaceEmitter's constrained specialization); this predicts the
    /// pick from the same facts, and says Opaque where it cannot.
    fn shape_at(self, t: *Type) -> AdtShape {
        var en = self.adt_of(t);
        if (en == &null) || (!en->adt_niche_shape) { return AdtShape::Tagged; }
        if en->generic_params.size() == 0 {
            return (AdtShape::Niche) if (en->adt_niche) else (AdtShape::Tagged);
        }
        var v = self.tu.as_value(t);
        if (v == &null) || v->is_dependent() || v->is_instantiation_dependent() { return AdtShape::Opaque; }
        var args = self.tu.record_args(v);
        var pv   = en->variants[usize(adt_niche_payload_variant(en))];
        var ft   = self.field_type_at(en, &args, pv->payload[0]->type_);
        if ft == &null { return AdtShape::Opaque; }
        var verdict = self.niche_verdict(en, ft);
        if verdict < 0 { return AdtShape::Opaque; }
        return (AdtShape::Niche) if (verdict > 0) else (AdtShape::Tagged);
    }

    /// Whether a niche-shaped \p en whose one payload field has type \p ft
    /// is laid out niche-filled: 1 yes, 0 no, -1 unknown. The rule (spec
    /// ENUMLAYOUT §5.2): the field holds a niche of at least as many
    /// patterns as there are dataless variants, and is trivially copied and
    /// destroyed, which keeps every special member trivial. InterfaceEmitter
    /// writes C++'s side of it as the specialization's constraint.
    fn niche_verdict(self, en: *EnumDecl, ft: *Type) -> i8 {
        var n = self.niche_of(ft);
        if n == niche_unknown() { return -1; }
        if n < adt_niche_dataless(en) { return 0; }
        return self.trivial(ft);
    }

    // --- niche_of -------------------------------------------------------------------

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
    fn niche_of(self, t: *Type) -> u64 {
        if (t == &null) || (t->canonical == &null) { return niche_unknown(); }
        var c = canon_unqual(t->canonical);
        if c == &null { return niche_unknown(); }
        if isa::<NullableType>(c) {
            // Read through the lang item, not the lowered record: an ADT
            // laid out before NullableTypeLowering asks this of a `T?` field.
            var nd = self.sc->nullable_enum();
            if !self.has_layout(nd) { return niche_unknown(); }
            var inner = cast::<NullableType>(c)->inner;
            var v = self.niche_verdict(nd, inner);
            if v < 0 { return niche_unknown(); }
            if v == 0 { return adt_tag_niche_count(nd); }
            var n = self.niche_of(inner);
            var used = adt_niche_dataless(nd);
            return (n - used) if (n > used) else (0);
        }
        if isa::<PointerType>(c) { return 1; }
        if isa::<FunctionPointerType>(c) {
            return (1) if (cast::<FunctionPointerType>(c)->is_unprototyped) else (0);
        }
        if isa::<RecordType>(c) {
            if c->is_dependent() || c->is_instantiation_dependent() { return niche_unknown(); }
            var d  = self.tu.pattern_of(cast::<RecordType>(c)->decl);
            var en = dyn_cast::<EnumDecl>(d);
            if en == &null { return 0; }
            if !en->is_adt { return enum_niche_count(en); }
            if !self.has_layout(en) { return niche_unknown(); }
            switch self.shape_at(c) {
                case AdtShape::Tagged { return adt_tag_niche_count(en); }
                case AdtShape::Niche {
                    var inner = self._niche_field_type(c, en);
                    var n = self.niche_of(inner);
                    if n == niche_unknown() { return n; }
                    var used = adt_niche_dataless(en);
                    return (n - used) if (n > used) else (0);
                }
                default { 0; }
            }
            return niche_unknown();
        }
        if c->is_dependent() || c->is_instantiation_dependent() { return niche_unknown(); }
        return 0;
    }

    /// The spec's struct row, answered but read by no layout (niche_of): a
    /// record's first field with a niche, at that field.
    fn niche_of_record(self, t: *Type) -> u64 {
        var n = self.niche_of(t);
        if n != 0 { return n; }
        var d = self.tu.record_decl(self.tu.as_value(t));
        var sd = dyn_cast::<StructDecl>(d);
        if sd == &null { return 0; }
        for var i: usize = 0; i < sd->fields.size(); ++i {
            var f = sd->fields[i];
            if (f == &null) || (f->storage == StorageClass::Eval) { continue; }
            var k = self.niche_of_record(f->type_);
            if k != 0 { return k; }
        }
        return 0;
    }

    /// A niche-filled ADT type \p c's one payload field type.
    priv fn _niche_field_type(self, c: *Type, en: *EnumDecl) -> *Type {
        var pv = en->variants[usize(adt_niche_payload_variant(en))];
        if en->generic_params.size() == 0 { return pv->payload[0]->type_; }
        var args = self.tu.record_args(c);
        return self.field_type_at(en, &args, pv->payload[0]->type_);
    }

    /// \p t is trivially copied and destroyed: 1, 0, or -1 unknown. Read off
    /// the structure for what C++ decides by the structure (an ADT is
    /// trivial exactly when its payloads are: its special members are
    /// defaulted then), off ClassLifecycle for a record.
    fn trivial(self, t: *Type) -> i8 {
        if (t == &null) || (t->canonical == &null) { return -1; }
        var c = canon_unqual(t->canonical);
        if c == &null { return -1; }
        if isa::<NullableType>(c) { return self.trivial(cast::<NullableType>(c)->inner); }
        if isa::<BuiltinType>(c) || isa::<PointerType>(c) { return 1; }
        if isa::<FunctionPointerType>(c) { return (1) if (cast::<FunctionPointerType>(c)->is_unprototyped) else (0); }
        if isa::<FixedArrayType>(c) { return self.trivial(cast::<FixedArrayType>(c)->element); }
        if c->is_dependent() || c->is_instantiation_dependent() { return -1; }
        if isa::<RecordType>(c) {
            var d  = self.tu.pattern_of(cast::<RecordType>(c)->decl);
            var en = dyn_cast::<EnumDecl>(d);
            if (en != &null) && (!en->is_adt) { return 1; }
            if (en != &null) && (en->generic_params.size() > 0) {
                var args = self.tu.record_args(c);
                for var i: usize = 0; i < en->variants.size(); ++i {
                    var v = en->variants[i];
                    for var j: usize = 0; j < v->payload.size(); ++j {
                        var ft = self.field_type_at(en, &args, v->payload[j]->type_);
                        if ft == &null { return -1; }
                        var k = self.trivial(ft);
                        if k != 1 { return k; }
                    }
                }
                return 1;
            }
        }
        var f = lifecycle_of(self.sc)->facts_of_type(c);
        if (f.trivially_copyable == LifecycleTri::Unknown) || (f.trivial_dtor == LifecycleTri::Unknown) { return -1; }
        return (1) if ((f.trivially_copyable == LifecycleTri::Yes) && (f.trivial_dtor == LifecycleTri::Yes)) else (0);
    }

    /// The size and alignment in bytes of a value of type \p t, for the
    /// types whose layout is plain arithmetic: builtins, pointers, plain
    /// enums, and ADTs made of them. False for anything else; nothing then
    /// pins a size.
    fn size_of(self, t: *Type, size: *u64, align: *u64) -> bool {
        if (t == &null) || (t->canonical == &null) { return false; }
        var c = canon_unqual(t->canonical);
        if c == &null { return false; }
        if isa::<NullableType>(c) {
            var lw = cast::<NullableType>(c)->lowered;
            if lw == &null { return false; }
            return self.size_of(lw, size, align);
        }
        if isa::<BuiltinType>(c) || isa::<PointerType>(c) {
            if isa::<BuiltinType>(c) && (cast::<BuiltinType>(c)->lang_decl != &null) { return false; }
            if (c->size_bits == 0) || (c->align_bits == 0) || ((c->size_bits % 8) != 0) { return false; }
            (*size)  = u64(c->size_bits / 8);
            (*align) = u64(c->align_bits / 8);
            return true;
        }
        if (!isa::<RecordType>(c)) || c->is_dependent() || c->is_instantiation_dependent() { return false; }
        var en = dyn_cast::<EnumDecl>(self.tu.pattern_of(cast::<RecordType>(c)->decl));
        if en == &null { return false; }
        if !en->is_adt {
            if decl_is_imported(static_cast::<*Decl>(en)) { return false; }
            return self.size_of(self.sc->builtin(enum_niche_kind(en)), size, align);
        }
        if !self.has_layout(en) { return false; }
        var shape = self.shape_at(c);
        if shape == AdtShape::Opaque { return false; }
        var args = self.tu.record_args(c);
        var ts: u64 = 0;
        var ta: u64 = 0;
        if !self.size_of(self.sc->builtin(adt_tag_kind(en)), &ts, &ta) { return false; }
        var prefix = en->adt_tag_member != &null;
        // The payload union: each variant's struct laid out field by field,
        // after its own tag in the common prefix.
        var usz: u64 = (ts) if (prefix) else (0);
        var ual: u64 = (ta) if (prefix) else (1);
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if v->payload.size() == 0 { continue; }
            var off: u64 = (ts) if (prefix) else (0);
            var sal: u64 = (ta) if (prefix) else (1);
            for var j: usize = 0; j < v->payload.size(); ++j {
                var ft = v->payload[j]->type_;
                if en->generic_params.size() > 0 { ft = self.field_type_at(en, &args, ft); }
                var fs: u64 = 0;
                var fa: u64 = 0;
                if (ft == &null) || (!self.size_of(ft, &fs, &fa)) { return false; }
                off = self._round(off, fa) + fs;
                if fa > sal { sal = fa; }
            }
            var ssz = self._round(off, sal);
            if ssz > usz { usz = ssz; }
            if sal > ual { ual = sal; }
        }
        if (shape == AdtShape::Niche) || prefix {
            (*size)  = usz;
            (*align) = ual;
            return true;
        }
        // A lang item's knobs (AdtLayoutKnobs): the u32 site slot after the
        // tag, and the union's own alignment.
        if en->adt_site_field != &null {
            ts = self._round(ts, 4) + 4;
            if ta < 4 { ta = 4; }
        }
        if u64(en->adt_union_align) > ual {
            ual = u64(en->adt_union_align);
            usz = self._round(usz, ual);
        }
        var al = (ta) if (ta > ual) else (ual);
        (*size)  = self._round(self._round(ts, ual) + usz, al);
        (*align) = al;
        return true;
    }

    priv fn _round(self, n: u64, a: u64) -> u64 {
        if a <= 1 { return n; }
        return ((n + a - 1) / a) * a;
    }

    /// Every generic ADT instance the registry holds gets the shape and size
    /// predicted for it (InstanceEntry::adt_shape / adt_size), which
    /// InterfaceEmitter pins with static_asserts. Run once, after the last
    /// lowering: an instance minted late (a `T?` NullableTypeLowering gives
    /// its record) is in the registry by then.
    fn sweep(self) {
        if self.sc->instances == &null { return; }
        var all = vec::<*InstanceEntry>();
        self.sc->instances->collect(all);
        for var i: usize = 0; i < all.size(); ++i {
            var e  = all[i];
            var en = dyn_cast::<EnumDecl>(e->primary);
            if (en == &null) || (!self.has_layout(en)) || (e->decl == &null) { continue; }
            var t = self.sc->types->record(e->decl, &(e->args));   // an instance's type names its shell and its arguments.
            if (t == &null) || t->is_dependent() || t->is_instantiation_dependent() { continue; }
            var shape = self.shape_at(t);
            if shape == AdtShape::Opaque { continue; }
            e->adt_shape = (2) if (shape == AdtShape::Niche) else (1);
            var sz: u64 = 0;
            var al: u64 = 0;
            if self.size_of(t, &sz, &al) { e->adt_size = sz; }
        }
    }

    // --- reads and tests ---------------------------------------------------------------

    /// The tag as stored, typed as the tag enum: `x.__kairo_tag`, or
    /// `x.__kairo_which()` where C++ picks the layout. Null when the layout
    /// has no tag.
    fn tag_read(self, at: SourceRange, x: *Expr, en: *EnumDecl) -> *Expr {
        var tag = en->adt_tag_field;
        ICE_IF(tag == &null, "EnumLayoutQuery: tag_read on an ADT with no layout; EnumLayoutLowering runs first");
        switch self.shape_at(x->type_) {
            case AdtShape::Niche  { return &null; }
            case AdtShape::Opaque { return self._which(at, x, en); }
            default { 0; }
        }
        return self._tag_lvalue(at, x, en);
    }

    /// The stored tag of a tagged \p en value \p x: `x.__kairo_tag`, or in
    /// the common prefix, `x.__kairo_t.__kairo_tag`.
    priv fn _tag_lvalue(self, at: SourceRange, x: *Expr, en: *EnumDecl) -> *Expr {
        var tag = en->adt_tag_field;
        if en->adt_tag_member != &null {
            var tm = en->adt_tag_member;
            var t  = self.synth.field_of(at, x, static_cast::<*Decl>(tm), tm->type_);
            return self.synth.field_of(at, t, static_cast::<*Decl>(en->adt_prefix_tag), tag->type_);
        }
        return self.synth.field_of(at, x, static_cast::<*Decl>(tag), tag->type_);
    }

    /// The tag as a `u32`, which is what a switch dispatches on and a case
    /// label is written in (tag_case). Null when the layout has no tag: a
    /// match then tests each variant in turn (variant_test).
    fn tag_word(self, at: SourceRange, x: *Expr, en: *EnumDecl) -> *Expr {
        var t = self.tag_read(at, x, en);
        if t == &null { return &null; }
        return self.synth.cast_to(at, t, self.sc->builtin(BuiltinKind::U32), CastMode::Default);
    }

    /// Variant \p index's discriminant as a case label of tag_word.
    fn tag_case(self, at: SourceRange, en: *EnumDecl, index: u32) -> *Expr {
        return self.synth.int_literal(at, self.tag_value(en, index), BuiltinKind::U32);
    }

    /// `x` holds variant \p index. Niche-filled: a dataless variant is its
    /// pattern in the field (`x.__kairo_Value.v == nullptr`), the payload
    /// variant every pattern's absence.
    fn variant_test(self, at: SourceRange, x: *Expr, en: *EnumDecl, index: u32) -> *Expr {
        var w = self.tag_word(at, x, en);
        if w != &null { return self._bin(at, w, self.tag_case(at, en, index), TokenKind::OpEqualEqual); }
        var p  = adt_niche_payload_variant(en);
        var pv = en->variants[usize(p)];
        var f  = pv->payload[0];
        var ft = self._niche_field_type(self.tu.as_value(x->type_), en);
        ICE_IF(ft == &null, "EnumLayoutQuery: a niche-filled ADT whose field type has no answer; shape_at said Niche");
        if index != p {
            return self._pattern_test(at, self.field_ref(at, x, en, p, f, ft), ft, adt_niche_pattern_of(en, index), false);
        }
        var c: *Expr = &null;
        var d = adt_niche_dataless(en);
        for var k: u64 = 0; k < d; ++k {
            var one = self._pattern_test(at, self.field_ref(at, x, en, p, f, ft), ft, k, true);
            c = (one) if (c == &null) else (self._bin(at, c, one, TokenKind::OpAmpAmp));
        }
        return c;
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
    /// written token. Each operand appears once, so each runs once. Without
    /// a tag, each side's variant is asked of it (`__kairo_which()`).
    fn same_variant(self, at: SourceRange, a: *Expr, b: *Expr, en: *EnumDecl, tok: Token) -> *Expr {
        var l = self.tag_read(a->range, a, en);
        var r = self.tag_read(b->range, b, en);
        if l == &null { l = self._which(a->range, a, en); }
        if r == &null { r = self._which(b->range, b, en); }
        var cmp = BinaryOperatorExpr::create(self.sc->ctx, at, l, r, tok);
        return static_cast::<*Expr>(cmp);
    }

    /// `x.__kairo_which()`, typed as the tag enum.
    priv fn _which(self, at: SourceRange, x: *Expr, en: *EnumDecl) -> *Expr {
        ICE_IF(en->adt_which == &null, "EnumLayoutQuery: no __kairo_which() on an ADT whose layout needs it; EnumLayoutLowering mints it");
        var args = ListBuilder::<*Expr>(self.sc->ctx);
        return self.synth.member_call(at, x, static_cast::<*Decl>(en->adt_which), &args, en->adt_tag_field->type_);
    }

    /// The lvalue \p e of type \p ft holds its niche pattern \p i (or, \p
    /// neg, does not). Each row is the C++ trait's `test` for the same type
    /// (InterfaceEmitter), written out so a reader of the C++ sees the
    /// compare: null for a pointer, `N + i` for a plain enum or a tagged
    /// ADT's tag, and a niche-filled ADT's own field at its pattern past
    /// the ones its dataless variants use.
    priv fn _pattern_test(self, at: SourceRange, e: *Expr, ft: *Type, i: u64, neg: bool) -> *Expr {
        var cmp_op = (TokenKind::OpExclaimEqual) if (neg) else (TokenKind::OpEqualEqual);
        var c  = canon_unqual(ft->canonical);
        if isa::<NullableType>(c) { return self._pattern_test(at, e, cast::<NullableType>(c)->lowered, i, neg); }
        if isa::<PointerType>(c) || isa::<FunctionPointerType>(c) {
            var nul = NullLiteralExpr::create(self.sc->ctx, at, true);
            nul->type_          = ft;
            nul->value_category = Expr::ValueCategory::RValue;
            return self._bin(at, e, static_cast::<*Expr>(nul), cmp_op);
        }
        var en = dyn_cast::<EnumDecl>(self.tu.pattern_of(cast::<RecordType>(c)->decl));
        ICE_IF(en == &null, "EnumLayoutQuery: a niche pattern in a type niche_of gives none");
        var n = u64(en->variants.size());
        if !en->is_adt {
            var lit = self.synth.int_literal(at, n + i, enum_niche_kind(en));
            return self._bin(at, e, self.synth.cast_to(at, lit, ft, CastMode::Default), cmp_op);
        }
        if self.shape_at(c) == AdtShape::Tagged {
            var tw  = self.synth.cast_to(at, self._tag_lvalue(at, e, en), self.sc->builtin(BuiltinKind::U32), CastMode::Default);
            return self._bin(at, tw, self.synth.int_literal(at, n + i, BuiltinKind::U32), cmp_op);
        }
        var p  = adt_niche_payload_variant(en);
        var f  = en->variants[usize(p)]->payload[0];
        var it = self._niche_field_type(c, en);
        return self._pattern_test(at, self.field_ref(at, e, en, p, f, it), it, adt_niche_dataless(en) + i, neg);
    }

    priv fn _bin(self, at: SourceRange, l: *Expr, r: *Expr, k: TokenKind) -> *Expr {
        var b = BinaryOperatorExpr::create(self.sc->ctx, at, l, r, self.synth.punct(at, k));
        b->type_          = self.sc->builtin(BuiltinKind::Bool);
        b->value_category = Expr::ValueCategory::RValue;
        return static_cast::<*Expr>(b);
    }
}

/// Lang-item overrides of an ADT's layout (spec ENUMLAYOUT §7), keyed on
/// the decl by EnumLayoutLowering::_knobs. Every default is the layout every
/// other ADT gets; PANIC.md §1.1a is the first user (type-id tags, a u32
/// tag word, an aligned union, a call-site slot).
class AdtLayoutKnobs {
    /// One per variant, in declaration order, or empty: positions.
    pub var tag_values:   vec::<u64>;
    pub var tag_kind_set: bool = false;
    pub var tag_kind:     BuiltinKind = BuiltinKind::U32;
    pub var union_align:  u32  = 0;        ///< `alignas(N)` on the payload union; 0 = natural.
    pub var site_slot:    bool = false;    ///< a u32 `__kairo_site` between the tag and the union.

    fn AdtLayoutKnobs(self) { }

    fn any(self) -> bool {
        return (self.tag_values.size() > 0) || self.tag_kind_set || (self.union_align > 0) || self.site_slot;
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

    /// `__builtin_niche_of<T>()` -> the count, a `u64` literal (the lang
    /// item's own body is never what answers). The layouts T holds are
    /// built first, so the answer is the one a layout reading it would get.
    fn transform_call_expr(self, n: *CallExpr) -> *Expr {
        var out = ASTWriter::<EnumLayoutLowering>::transform_call_expr(n);
        var nd  = self.sc->well_known->get(WellKnownType::NicheOf);
        if (nd == &null) || (out != static_cast::<*Expr>(n)) { return out; }
        var callee = dyn_cast::<NamedIdentExpr>(n->callee);
        if (callee == &null) || (callee->resolved_decl == &null) { return out; }
        if NameLookup::representative(callee->resolved_decl) != NameLookup::representative(nd) { return out; }
        // A dependent call (a generic body's) has no instance entry: its T is
        // the instance's, which is the case reported below.
        var ie = reinterpret_cast::<*InstanceEntry>(n->instance);
        ICE_IF((ie != &null) && (ie->args.size() != 1), "EnumLayoutLowering: __builtin_niche_of instance without its one argument");
        var cnt = niche_unknown();
        if ie != &null {
            self._prebuild(ie->args[0]);
            cnt = EnumLayoutQuery(self.sc).niche_of_record(ie->args[0]);
        }
        if cnt == niche_unknown() {
            // A generic body's T: the count is the instance's, and nothing
            // here can name it (the call is answered before C++ instantiates).
            var b = self.sc->diag->report(DiagID::SC001E, n->range.start,
                "'__builtin_niche_of' needs a type whose layout is known here; this one depends on a generic parameter");
            b.first(n->range, "answered at compile time, before any instantiation");
            b.emit();
            cnt = 0;
        }
        var lit = self.synth.int_literal(n->range, cnt, BuiltinKind::U64);
        lit->adopt_sema(static_cast::<*Expr>(n));
        return lit;
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

        var knobs = self._knobs(en);
        var tag = self._tag_enum(en, at, edc, &knobs);
        ldc->add_decl(static_cast::<*Decl>(tag));

        // The layout's shape, decided before anything is minted: a
        // niche-filled ADT has no tag at all, a prefix-tagged one keeps it
        // inside each payload (file header).
        var shaped = (!knobs.any()) && self._niche_shaped(en);
        var niche  = false;
        if shaped && (!generic) {
            var npv = en->variants[usize(adt_niche_payload_variant(en))];
            self._prebuild(npv->payload[0]->type_);
            niche = EnumLayoutQuery(self.sc).niche_verdict(en, npv->payload[0]->type_) == 1;
        }
        var prefix = (!generic) && (!niche) && (!knobs.any()) && self._prefix_ok(en);
        var ttype  = self._type_of(static_cast::<*Decl>(tag));

        // A struct and a union member for each variant that has a payload.
        var members = self.list_builder::<*FieldDecl>();
        var mvec    = vec::<*FieldDecl>();
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if v->payload.is_empty() { continue; }
            var vn = self.tu.decl_name(static_cast::<*Decl>(v));
            var ps = self._payload_struct(v, vn, edc, (ttype) if (prefix) else (&null));
            ldc->add_decl(static_cast::<*Decl>(ps));
            var m = FieldDecl::create(self.ctx, v->name.range,
                                      self.synth.ident(v->name.range, LowerTargets::adt_payload_field(vn)),
                                      StorageClass::Var, self._type_of(static_cast::<*Decl>(ps)), u32(members.size()));
            self._place(static_cast::<*Decl>(m), edc, VisibilityKind::Public, v->name.range);
            members.push(m);
            mvec.push_back(m);
            v->adt_member = m;
            v->adt_ctor   = self._ctor_form(v, generic);
        }

        var fields = self.list_builder::<*FieldDecl>();
        var tf = FieldDecl::create(self.ctx, at, self.synth.ident(at, LowerTargets::adt_tag_field()),
                                   StorageClass::Var, self._type_of(static_cast::<*Decl>(tag)), 0);
        self._place(static_cast::<*Decl>(tf), edc, VisibilityKind::Public, at);
        ldc->add_decl(static_cast::<*Decl>(tf));
        fields.push(tf);
        if knobs.site_slot {
            var sf = FieldDecl::create(self.ctx, at, self.synth.ident(at, LowerTargets::adt_site_field()),
                                       StorageClass::Var, self.sc->builtin(BuiltinKind::U32), 1);
            self._place(static_cast::<*Decl>(sf), edc, VisibilityKind::Public, at);
            ldc->add_decl(static_cast::<*Decl>(sf));
            fields.push(sf);
            en->adt_site_field = sf;
        }
        en->adt_union_align = knobs.union_align;

        // No name, and declared only by the field that holds it: its members
        // are the record's to C++, and that field is in no field_of chain
        // (FieldDecl::is_anonymous_union).
        var un = UnionDecl::create(self.ctx, at, Token(), edc);
        self._place(static_cast::<*Decl>(un), edc, VisibilityKind::Public, at);
        un->is_anonymous   = true;
        un->methods        = create_empty_frozen_list::<*FunctionDecl>();
        un->generic_params = create_empty_frozen_list::<*GenericParamDecl>();
        un->spec_args      = create_empty_frozen_list::<*Type>();
        if prefix {
            // The tag-only member, first: reading the tag through it is the
            // common-initial-sequence read every payload struct allows.
            var ts = StructDecl::create(self.ctx, at, self.synth.ident(at, LowerTargets::adt_tag_only_type()), edc);
            self._place(static_cast::<*Decl>(ts), edc, VisibilityKind::Public, at);
            self._no_members(ts);
            ts->is_adt_payload = true;
            var tsl = self.list_builder::<*FieldDecl>();
            var pt  = FieldDecl::create(self.ctx, at, self.synth.ident(at, LowerTargets::adt_tag_field()), StorageClass::Var, ttype, 0);
            self._place(static_cast::<*Decl>(pt), static_cast::<*DeclContext>(ts), VisibilityKind::Public, at);
            tsl.push(pt);
            tsl.freeze_into(&(ts->fields));
            ldc->add_decl(static_cast::<*Decl>(ts));
            var tm = FieldDecl::create(self.ctx, at, self.synth.ident(at, LowerTargets::adt_tag_member()),
                                       StorageClass::Var, self._type_of(static_cast::<*Decl>(ts)), 0);
            self._place(static_cast::<*Decl>(tm), edc, VisibilityKind::Public, at);
            var all = self.list_builder::<*FieldDecl>();
            all.push(tm);
            for var i: usize = 0; i < mvec.size(); ++i { all.push(mvec[i]); }
            all.freeze_into(&(un->fields));
            en->adt_tag_member = tm;
            en->adt_prefix_tag = pt;
        } else {
            members.freeze_into(&(un->fields));
        }
        ldc->add_decl(static_cast::<*Decl>(un));

        var uf = FieldDecl::create(self.ctx, at, Token(), StorageClass::Var, self._type_of(static_cast::<*Decl>(un)), u32(fields.size()));
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

        // Niche layout (file header). The facts are set before which() is
        // minted: a generic ADT may be laid out either way per instance, a
        // niche-filled one has no tag to read, and both answer which().
        en->adt_tag_field   = tf;
        en->adt_niche_shape = shaped;
        en->adt_niche       = niche;
        if generic || en->adt_niche {
            var w = self._role(en, self.synth.ident(at, LowerTargets::adt_which()), AdtRole::Which, AdtForm::Body, 0, VisibilityKind::Public);
            self._member(ldc, &methods, w);
            en->adt_which = w;
        }
        methods.freeze_into(&(lay->methods));

        en->adt_layout    = static_cast::<*Decl>(lay);
        en->adt_tag_field = tf;
    }

    /// `enum class __kairo_Tag : u8 { V0, V1, ... }`: every variant, payload
    /// or not, by its own name and in order. No discriminants, so each value
    /// is the variant's position and InterfaceEmitter writes the names bare.
    /// The narrowest word that holds them (_tag_kind): the tag sits before
    /// the union, so every byte past it is padding a small payload pays.
    priv fn _tag_enum(self, en: *EnumDecl, at: SourceRange, edc: *DeclContext, knobs: *AdtLayoutKnobs) -> *EnumDecl {
        var tag = EnumDecl::create(self.ctx, at, self.synth.ident(at, LowerTargets::adt_tag_type()), edc);
        self._place(static_cast::<*Decl>(tag), edc, VisibilityKind::Public, at);
        tag->underlying     = self.sc->builtin((knobs->tag_kind) if (knobs->tag_kind_set) else (self._tag_kind(en)));
        tag->generic_params = create_empty_frozen_list::<*GenericParamDecl>();
        tag->spec_args      = create_empty_frozen_list::<*Type>();
        var tdc = static_cast::<*DeclContext>(tag);
        var vs  = self.list_builder::<*EnumVariantDecl>();
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v  = en->variants[i];
            var tv = EnumVariantDecl::create(self.ctx, v->range, v->name, u32(i));
            self._place(static_cast::<*Decl>(tv), tdc, VisibilityKind::Public, v->name.range);
            tv->payload = create_empty_frozen_list::<*FieldDecl>();
            // An explicit tag is the enumerator's value, which _enum_def
            // writes because it is not the position.
            if knobs->tag_values.size() > 0 {
                tv->value.ok  = true;
                tv->value.mag = knobs->tag_values[i];
                v->adt_tag_value = knobs->tag_values[i];
            }
            vs.push(tv);
        }
        vs.freeze_into(&(tag->variants));
        en->adt_explicit_tags = knobs->tag_values.size() > 0;
        return tag;
    }

    /// \p en's layout overrides (AdtLayoutKnobs), by identity with the lang
    /// item that wants them -- never by name. None today: PanicLowering's
    /// lang item will be the first, and every ADT gets the defaults.
    priv fn _knobs(self, en: *EnumDecl) -> AdtLayoutKnobs {
        var k = AdtLayoutKnobs();
        ICE_IF((k.tag_values.size() != 0) && (k.tag_values.size() != en->variants.size()),
               "EnumLayoutLowering: explicit tag values, not one per variant");
        return k;
    }

    /// \p en can keep its tag in its payloads' common prefix (spec
    /// ENUMLAYOUT §6): every payload field a builtin, a pointer or a plain
    /// enum, so every payload struct is standard-layout -- the
    /// common-initial-sequence read needs that -- and trivially copied, so
    /// the special members are the defaulted ones and no body switches on
    /// a tag that is no longer a member of its own. Anything else keeps the
    /// external tag. v1: non-generic only; a generic ADT's payloads are
    /// standard-layout per instance, which only a third C++ form could ask.
    priv fn _prefix_ok(self, en: *EnumDecl) -> bool {
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            for var j: usize = 0; j < v->payload.size(); ++j {
                var t = v->payload[j]->type_;
                if (t == &null) || (t->canonical == &null) { return false; }
                var c = canon_unqual(t->canonical);
                if (c == &null) || (canon_quals(t->canonical) != 0) { return false; }
                if isa::<BuiltinType>(c) || isa::<PointerType>(c) { continue; }
                if isa::<RecordType>(c) {
                    var pe = dyn_cast::<EnumDecl>(cast::<RecordType>(c)->decl);
                    if (pe != &null) && (!pe->is_adt) { continue; }
                }
                return false;
            }
        }
        return true;
    }

    /// \p en could be laid out without a tag (spec ENUMLAYOUT §5.2): exactly
    /// one variant carries a payload, that payload is one field (v1: a
    /// record's first-field niche, which would lift this, is answered but
    /// not laid out -- EnumLayoutQuery::niche_of), at least one variant has
    /// none, and no generic parameter is a pack. Whether it IS is the
    /// field's niche and triviality, per instance for a generic enum.
    priv fn _niche_shaped(self, en: *EnumDecl) -> bool {
        var payloads: usize = 0;
        var dataless: usize = 0;
        for var i: usize = 0; i < en->variants.size(); ++i {
            var v = en->variants[i];
            if v->payload.size() == 0 { dataless += 1; continue; }
            payloads += 1;
            if v->payload.size() != 1 { return false; }
        }
        if (payloads != 1) || (dataless == 0) { return false; }
        // The specialization's head carries the niche constraint; a declared
        // one beside it would be a second requires-clause.
        if decl_requires_clause(static_cast::<*Decl>(en)) != &null { return false; }
        for var i: usize = 0; i < en->generic_params.size(); ++i {
            var gp = en->generic_params[i];
            if (gp == &null) || gp->is_pack { return false; }
        }
        return true;
    }

    /// Build the layout of every ADT \p t holds by value first, so a
    /// non-generic enum's verdict reads its field's real shape whatever
    /// order the walk meets the declarations in. By-value ADT cycles are
    /// TypeCycleCheck's to reject, so this terminates.
    priv fn _prebuild(self, t: *Type) {
        if (t == &null) || (t->canonical == &null) { return; }
        var c = canon_unqual(t->canonical);
        if c == &null { return; }
        if isa::<NullableType>(c) {
            var nd = self.sc->nullable_enum();
            if (nd != &null) && self._wants_layout(nd) { self._build(nd); }
            self._prebuild(cast::<NullableType>(c)->inner);
            return;
        }
        if !isa::<RecordType>(c) { return; }
        var r  = cast::<RecordType>(c);
        var en = dyn_cast::<EnumDecl>(NameLookup::representative(self.tu.pattern_of(r->decl)));
        if (en != &null) && en->is_adt && self._wants_layout(en) { self._build(en); }
        for var i: usize = 0; i < r->args.size(); ++i { self._prebuild(*(r->args.get(i))); }
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
    /// A prefix-tagged ADT's (\p prefix_tag, the tag enum's type) starts
    /// with a tag of its own: the common initial sequence the union's
    /// tag-only member reads.
    priv fn _payload_struct(self, v: *EnumVariantDecl, vn: string, edc: *DeclContext, prefix_tag: *Type) -> *StructDecl {
        var ps = StructDecl::create(self.ctx, v->range, self.synth.ident(v->name.range, LowerTargets::adt_payload_type(vn)), edc);
        self._place(static_cast::<*Decl>(ps), edc, VisibilityKind::Public, v->name.range);
        self._no_members(ps);
        ps->is_adt_payload = true;
        var pdc = reinterpret_cast::<*void>(static_cast::<*DeclContext>(ps));
        var fs  = self.list_builder::<*FieldDecl>();
        if prefix_tag != &null {
            var pt = FieldDecl::create(self.ctx, v->name.range, self.synth.ident(v->name.range, LowerTargets::adt_tag_field()),
                                       StorageClass::Var, prefix_tag, 0);
            self._place(static_cast::<*Decl>(pt), static_cast::<*DeclContext>(ps), VisibilityKind::Public, v->name.range);
            fs.push(pt);
        }
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
