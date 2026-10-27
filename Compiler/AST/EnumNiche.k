/// --- The Kairo Project ------------------------------- AST/EnumNiche.k --- ///
///
///   \brief The niche facts both halves of the compiler must agree on: how
///          many tag values a word holds, and how many of them an ADT's
///          tag leaves free.
///
///   \detail
///     A niche-filled ADT (EnumLayoutLowering) stores its dataless variants
///     as values its one field can never hold. Sema predicts the layout C++
///     will pick -- to read and test values directly, and to pin sizes --
///     and C++ picks it from `__kairo_niche<T>` (InterfaceEmitter). Both
///     read these functions, so the count Sema assumes for an ADT's tag is
///     the count the trait reports, by construction.
///
///     A plain enum never holds a niche (USER 2026-10-27): `as` from its
///     underlying type never fails, so `3 as Color` is a value the program
///     may hold, and a niche at 3 would read it back as null. An ADT's tag
///     can't be written that way, so only an ADT has free values.
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

/// A plain enum's underlying word (its size): its `derives` type, else u32.
fn enum_niche_kind(en: *EnumDecl) -> BuiltinKind {
    var b = BuiltinKind::U32;
    if (en->underlying != &null) && (!en->underlying->is_poisoned()) {
        var k = BuiltinKind::U32;
        if niche_int_kind(en->underlying, &k) { b = k; }
    }
    return b;
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
    var n = u64(en->variants.size());
    var w = niche_word_values(adt_tag_kind(en));
    if w <= n { return 0; }
    return w - n;
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
