/// --- The Kairo Project ------------------------------ AST/EnumNiche.k --- ///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import AST::Context::DeclContext::DeclContextKind
import AST::DeclFacts::{
    adt_pack_variant,
    decl_is_imported,
}
import AST::Node::Base::{
    Decl,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinKind,
    BuiltinType,
    RecordType,
    builtin_info,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations::EnumDecl

/// The most patterns any count reports. A count only ever meets a variant
/// count (u16 at most) or another count, so 2^32 is "unbounded" and keeps
/// every sum and difference far from wrapping.
pub fn niche_count_cap() -> u64 {
    return (1 as u64) << (32 as u64)
}

/// How many non-negative values a word of builtin kind \p b holds, capped
/// (niche_count_cap). A target-width integer (bits 0 in the table) is at
/// least 32 bits.
pub fn niche_word_values(b: BuiltinKind) -> u64 {
    var *bi  = builtin_info(b)
    var bits = bi->bits
    if bi->is_signed() && bits > 0 {
        bits = bits - 1
    }

    if bits == 0 || bits >= 32 {
        return niche_count_cap()
    }

    return (1 as u64) << (bits as u64)
}

/// The builtin kind \p t canonicalizes to, when it is an integer.
pub fn niche_int_kind(t: unsafe *Type, out: *BuiltinKind) -> bool {
    if t == &null || t->canonical == &null {
        return false
    }

    var unsafe *c = canon_unqual(t->canonical)
    if c == &null || !isa<BuiltinType>(c) {
        return false
    }

    var b = cast<BuiltinType>(c)->builtin
    if !builtin_info(b)->is_integer() {
        return false
    }

    *out = b
    return true
}

/// A plain enum's underlying word: its `derives` type, else u32.
pub fn enum_niche_kind(en: unsafe *EnumDecl) -> BuiltinKind {
    var b = BuiltinKind::U32
    if en->underlying != &null && !en->underlying->is_poisoned() {
        var k = BuiltinKind::U32
        if niche_int_kind(en->underlying, &k) {
            b = k
        }
    }

    return b
}

/// Plain enum \p en carries `__kairo_niche<E>` (file header).
pub fn enum_has_niche_trait(en: unsafe *EnumDecl) -> bool {
    if en == &null || en->is_adt || en->is_open || en->is_poisoned() {
        return false
    }

    var unsafe *d = unsafe (en as unsafe *Decl)
    if decl_is_imported(d) || en->variants.size() == 0 {
        return false
    }

    var unsafe *dc = d->semantic_dc
    if dc == &null
        || dc->dc_kind != DeclContextKind::TranslationUnit
            && dc->dc_kind != DeclContextKind::Module {
        return false
    }

    for var i: usize = 0; i < en->variants.size(); ++i {
        var unsafe *v = en->variants[i]
        if v == &null || !v->value.ok || v->value.neg || v->value.mag != (i as u64) {
            return false
        }
    }

    return niche_word_values(enum_niche_kind(en)) > (en->variants.size() as u64)
}

/// The trait's count for plain enum \p en: every value of its word past
/// its N variants. 0 without the trait.
pub fn enum_niche_count(en: unsafe *EnumDecl) -> u64 {
    if !enum_has_niche_trait(en) {
        return 0
    }

    return niche_word_values(enum_niche_kind(en)) - (en->variants.size() as u64)
}

/// The tag word ADT \p en is laid out with, from its declaration alone:
/// the `derives` type when the enum declares one (TypeResolve checked it
/// holds every tag), else `u8` up to 256 variants and `u16` past that. Tags
/// stay dense `0..N-1` in declaration order whatever the width:
/// MatchLowering's switch, and the jump table clang builds from it, index
/// by them. EnumLayoutLowering builds the tag from it (a lang item's knobs
/// may override), and TypeExport's stand-in reads it before that pass has
/// run, so the two cannot drift.
pub fn adt_declared_tag_kind(en: unsafe *EnumDecl) -> BuiltinKind {
    var unsafe *u = en->underlying
    if u != &null && !u->is_poisoned() && u->canonical != &null {
        var unsafe *c = canon_unqual(u->canonical)
        if c != &null
            && isa<BuiltinType>(c)
            && builtin_info(cast<BuiltinType>(c)->builtin)->is_integer() {
            return cast<BuiltinType>(c)->builtin
        }
    }

    if en->variants.size() <= 256 {
        return BuiltinKind::U8
    }

    return BuiltinKind::U16
}

/// ADT \p en's tag word, read off its layout's tag field.
pub fn adt_tag_kind(en: unsafe *EnumDecl) -> BuiltinKind {
    var b = BuiltinKind::U8
    if en == &null || en->adt_tag_field == &null {
        return b
    }

    var unsafe *tt = en->adt_tag_field->type_
    if tt == &null || tt->canonical == &null {
        return b
    }

    var unsafe *c = canon_unqual(tt->canonical)
    if c == &null || !isa<RecordType>(c) {
        return b
    }

    var unsafe *te = dyn_cast<EnumDecl>(cast<RecordType>(c)->decl)
    if te == &null || te->underlying == &null {
        return b
    }

    var k = BuiltinKind::U8
    if niche_int_kind(te->underlying, &k) {
        b = k
    }

    return b
}

/// A tagged ADT's niche: the tag values past its N variants. None when the
/// tags are explicit values: "past N" may be a live tag then.
pub fn adt_tag_niche_count(en: unsafe *EnumDecl) -> u64 {
    if en->adt_explicit_tags {
        return 0
    }

    // A pack-expanded variant takes as many tags as its instance has
    // elements, so "past N" is per instance: none is promised.
    if adt_pack_variant(en) != &null {
        return 0
    }

    var n = (en->variants.size() as u64)
    var w = niche_word_values(adt_tag_kind(en))
    if w <= n {
        return 0
    }

    return w - n
}

/// The tag of a tagged ADT's niche pattern 0: the first value past its
/// variants, pattern i being this plus i. The one place that arithmetic
/// lives (EnumLayoutQuery's tests, InterfaceEmitter's niche constructor
/// and test). Only meaningful while adt_tag_niche_count is nonzero, which
/// rules out explicit (type-id) tags and pack-expanded variants, whose
/// tags are not `0..N-1`.
pub fn adt_first_spare_tag(en: unsafe *EnumDecl) -> u64 {
    return en->variants.size() as u64
}

/// The variant that carries the payload of a niche-shaped ADT, and the
/// position among the dataless ones of each other variant (its pattern).
pub fn adt_niche_payload_variant(en: unsafe *EnumDecl) -> u32 {
    for var i: usize = 0; i < en->variants.size(); ++i {
        var unsafe *v = en->variants[i]
        if v != &null && v->payload.size() > 0 {
            return i as u32
        }
    }

    return 0
}

/// Variant \p index's pattern: how many dataless variants precede it.
pub fn adt_niche_pattern_of(en: unsafe *EnumDecl, index: u32) -> u64 {
    var k: u64 = 0
    for var i: usize = 0; i < en->variants.size() && i < (index as usize); ++i {
        var unsafe *v = en->variants[i]
        if v != &null && v->payload.size() == 0 {
            k += 1
        }
    }

    return k
}

/// How many dataless variants \p en has: the patterns it uses.
pub fn adt_niche_dataless(en: unsafe *EnumDecl) -> u64 {
    var k: u64 = 0
    for var i: usize = 0; i < en->variants.size(); ++i {
        var unsafe *v = en->variants[i]
        if v != &null && v->payload.size() == 0 {
            k += 1
        }
    }

    return k
}
