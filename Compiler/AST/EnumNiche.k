/// --- The Kairo Project ------------------------------- AST/EnumNiche.k --- ///
///
///   \brief The niche facts both halves of the compiler must agree on: how
///          many tag values a word holds, and which plain enums carry a
///          C++ niche trait and how many invalid values it reports.
///
///   \detail
///     A niche-filled ADT (EnumLayoutLowering) stores its dataless variants
///     as values its one field can never hold. Sema predicts the layout C++
///     will pick -- to read and test values directly, and to pin sizes --
///     and C++ picks it from `__kairo_niche<T>` (InterfaceEmitter). Both
///     read these functions, so the count Sema assumes for a plain enum or
///     an ADT's tag is the count the trait reports, by construction.
///
///     A plain enum holds a niche only when it is closed (not `@open`,
///     EnumDecl::is_open: a closed enum never holds a value no variant has,
///     because `as` into it is checked -- CastTyping), its values are
///     exactly `0..N-1` (every other value of its underlying type is then
///     free) and it is declared at namespace scope (the trait's explicit
///     specialization follows the enum's definition, which for a nested
///     enum is inside its record). An `@open` enum never: `3 as Color`
///     is a value it may hold, which a niche at 3 would read back as null.
///     An imported enum never: clang owns it (it is open) and it is never
///     emitted. `Byte` (no variants) never.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::Context::DeclContext::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;

/// The most patterns any count reports. A count only ever meets a variant
/// count (u16 at most) or another count, so 2^32 is "unbounded" and keeps
/// every sum and difference far from wrapping.
fn niche_count_cap() -> u64 { return u64(1) << u64(32); }

/// How many non-negative values a word of builtin kind \p b holds, capped
/// (niche_count_cap). A target-width integer (bits 0 in the table) is at
/// least 32 bits.
fn niche_word_values(b: BuiltinKind) -> u64 {
    var bi   = builtin_info(b);
    var bits = bi->bits;
    if bi->is_signed() && (bits > 0) { bits = bits - 1; }
    if (bits == 0) || (bits >= 32) { return niche_count_cap(); }
    return u64(1) << u64(bits);
}

/// The builtin kind \p t canonicalizes to, when it is an integer.
fn niche_int_kind(t: *Type, out: *BuiltinKind) -> bool {
    if (t == &null) || (t->canonical == &null) { return false; }
    var c = canon_unqual(t->canonical);
    if (c == &null) || (!isa::<BuiltinType>(c)) { return false; }
    var b = cast::<BuiltinType>(c)->builtin;
    if !builtin_info(b)->is_integer() { return false; }
    (*out) = b;
    return true;
}

/// A plain enum's underlying word: its `derives` type, else u32.
fn enum_niche_kind(en: *EnumDecl) -> BuiltinKind {
    var b = BuiltinKind::U32;
    if (en->underlying != &null) && (!en->underlying->is_poisoned()) {
        var k = BuiltinKind::U32;
        if niche_int_kind(en->underlying, &k) { b = k; }
    }
    return b;
}

/// Plain enum \p en carries `__kairo_niche<E>` (file header).
fn enum_has_niche_trait(en: *EnumDecl) -> bool {
    if (en == &null) || en->is_adt || en->is_open || en->is_poisoned() { return false; }
    var d = static_cast::<*Decl>(en);
    if decl_is_imported(d) || (en->variants.size() == 0) { return false; }
    var dc = reinterpret_cast::<*DeclContext>(d->semantic_dc);
    if (dc == &null) || ((dc->dc_kind != DeclContextKind::TranslationUnit) && (dc->dc_kind != DeclContextKind::Module)) { return false; }
    for var i: usize = 0; i < en->variants.size(); ++i {
        var v = en->variants[i];
        if (v == &null) || (!v->value.ok) || v->value.neg || (v->value.mag != u64(i)) { return false; }
    }
    return niche_word_values(enum_niche_kind(en)) > u64(en->variants.size());
}

/// The trait's count for plain enum \p en: every value of its word past
/// its N variants. 0 without the trait.
fn enum_niche_count(en: *EnumDecl) -> u64 {
    if !enum_has_niche_trait(en) { return 0; }
    return niche_word_values(enum_niche_kind(en)) - u64(en->variants.size());
}

/// ADT \p en's tag word, read off its layout's tag field.
fn adt_tag_kind(en: *EnumDecl) -> BuiltinKind {
    var b = BuiltinKind::U8;
    if (en == &null) || (en->adt_tag_field == &null) { return b; }
    var tt = en->adt_tag_field->type_;
    if (tt == &null) || (tt->canonical == &null) { return b; }
    var c = canon_unqual(tt->canonical);
    if (c == &null) || (!isa::<RecordType>(c)) { return b; }
    var te = dyn_cast::<EnumDecl>(cast::<RecordType>(c)->decl);
    if (te == &null) || (te->underlying == &null) { return b; }
    var k = BuiltinKind::U8;
    if niche_int_kind(te->underlying, &k) { b = k; }
    return b;
}

/// A tagged ADT's niche: the tag values past its N variants. None when the
/// tags are explicit values: "past N" may be a live tag then.
fn adt_tag_niche_count(en: *EnumDecl) -> u64 {
    if en->adt_explicit_tags { return 0; }
    // A pack-expanded variant takes as many tags as its instance has
    // elements, so "past N" is per instance: none is promised.
    if adt_pack_variant(en) != &null { return 0; }
    var n = u64(en->variants.size());
    var w = niche_word_values(adt_tag_kind(en));
    if w <= n { return 0; }
    return w - n;
}

/// The tag of a tagged ADT's niche pattern 0: the first value past its
/// variants, pattern i being this plus i. The one place that arithmetic
/// lives (EnumLayoutQuery's tests, InterfaceEmitter's niche constructor
/// and test). Only meaningful while adt_tag_niche_count is nonzero, which
/// rules out explicit (type-id) tags and pack-expanded variants, whose
/// tags are not `0..N-1`.
fn adt_first_spare_tag(en: *EnumDecl) -> u64 {
    return u64(en->variants.size());
}

/// The variant that carries the payload of a niche-shaped ADT, and the
/// position among the dataless ones of each other variant (its pattern).
fn adt_niche_payload_variant(en: *EnumDecl) -> u32 {
    for var i: usize = 0; i < en->variants.size(); ++i {
        var v = en->variants[i];
        if (v != &null) && (v->payload.size() > 0) { return u32(i); }
    }
    return 0;
}

/// Variant \p index's pattern: how many dataless variants precede it.
fn adt_niche_pattern_of(en: *EnumDecl, index: u32) -> u64 {
    var k: u64 = 0;
    for var i: usize = 0; (i < en->variants.size()) && (i < usize(index)); ++i {
        var v = en->variants[i];
        if (v != &null) && (v->payload.size() == 0) { k += 1; }
    }
    return k;
}

/// How many dataless variants \p en has: the patterns it uses.
fn adt_niche_dataless(en: *EnumDecl) -> u64 {
    var k: u64 = 0;
    for var i: usize = 0; i < en->variants.size(); ++i {
        var v = en->variants[i];
        if (v != &null) && (v->payload.size() == 0) { k += 1; }
    }
    return k;
}
