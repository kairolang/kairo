/// --- The Kairo Project ------------------------ Sema/Type/PanicSets.k --- ///
///
///   \brief The identities the panic system is built on (Compiler/Spec/Panic.md#canonical-sets,
///          §1.4): a type's panic type id, the canonical panic set, and a
///          panic site's id.
///
///   \detail
///     A type id is the tag an `Err` holding that type is stored as, in
///     every `Panic<...>` whose set holds it (§1.1a). Every TU of a program
///     must compute the same id with no coordination, so it is a hash of a
///     spelling every TU agrees on: the type's C++ spelling, the one C++
///     itself needs every TU to agree on (CXXSpell's qualified names for
///     records, the emitted name for builtins). The hash is pinned in
///     Compiler/Spec/Panic.md#canonical-sets; nothing else may compute an id, and codegen reads the
///     ids off InstanceEntry::type_ids (EnumLayoutQuery::sweep) rather than
///     hashing again.
///
///     A panic set is canonical: deduplicated, sorted by type id, built only
///     here (form / canonicalize). Two types whose ids collide cannot share
///     a set -- their tags would be equal -- which is an error at the set's
///     formation. Every widening has its source set inside its target, so
///     that check covers every later copy of a tag word.
///
///     A site id is a hash of (path, byte offset), unique within its TU:
///     a later site whose id is taken is rehashed until it is free. Each TU
///     writes its sites to the `__kairo_panic_sites` table (EmitIR), where
///     a record carries its id, so the lookup is a search.
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

import AST::Context::TranslationUnit::PanicSiteRec
import AST::DeclFacts::{
    PackSetOrder,
    adt_pack_param,
    decl_cxx_spelling,
    decl_instantiated_from,
    decl_is_imported,
}
import AST::Kind::TypeKind::TypeKind
import AST::LangItems::{
    LowerTargets,
    WellKnownDecls,
    WellKnownType,
    hex32,
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
import AST::Node::Declarations::{
    EnumDecl,
    InterfaceDecl,
}
import AST::Node::Types::{
    FixedArrayType,
    FunctionPointerType,
    NullableType,
    PointerType,
}
import Codegen::CodegenContext::CodegenContext
import Codegen::Emit::CXXSpell::CXXSpell
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::SemaContext
import Sema::Type::TypeUtil::TypeUtil
import Support::EvalHash::{
    FNV1A32_OFFSET,
    FNV1A32_PRIME,
    FNV1A64_OFFSET,
    FNV1A64_PRIME,
}

/// FNV-1a, 32 bits, over \p s, continuing from \p h (start: FNV1A32_OFFSET).
pub fn panic_fnv32(h_in: u32, const s: string) -> u32 {
    var h = h_in
    for var i: usize = 0; i < s.size(); ++i {
        h = h ^ ((s[i]) as u32)
        h = h * FNV1A32_PRIME
    }

    return h
}

/// FNV-1a, 64 bits, over \p s (the key of a minted name: a guard, a site
/// record). 64 bits so that two different spellings never share one.
pub fn panic_fnv64(const s: string) -> u64 {
    var h: u64 = FNV1A64_OFFSET
    for var i: usize = 0; i < s.size(); ++i {
        h = h ^ ((s[i]) as u64)
        h = h * FNV1A64_PRIME
    }

    return h
}

/// The pinned id hash (Compiler/Spec/Panic.md#canonical-sets): FNV-1a 32 of \p s, keeping the low
/// \p bits bits; while that is 0, one more byte 0xFF is hashed in. 0 is
/// never an id: it is Ok's tag, and "no id".
pub fn panic_id_of(const s: string, bits: i32) -> u32 {
    var mask: u32 = if (bits >= 32) => (u32::MAX) else => ((1 as u32) << (bits as u32)) - (1 as u32)
    var h         = panic_fnv32(FNV1A32_OFFSET, s)
    var r         = h & mask
    while r == (0 as u32) {
        h = h ^ (255 as u32)
        h = h * FNV1A32_PRIME
        r = h & mask
    }

    return r
}

/// The type-id side of the Panic lang item, with no per-TU state: the one
/// object the build's CanonicalTypeStore and InstantiationRegistry hold as
/// their PackSetOrder, so `Panic<i32, B, A>` IS `Panic<i32, A, B>` wherever
/// a type is formed -- a written type, a `Panic<...>::Ok` path, a deduced
/// argument -- exactly as the dedup makes equal elements one. Installed by
/// the driver before any Sema pass; PanicSets builds one on the fly.
pub class PanicTypeIds derives PackSetOrder {
    pub var psym:       unsafe *PreprocessorSymbolTable = &null
    pub var well_known: unsafe *WellKnownDecls          = &null
    pub var id_bits:    i32                             = 32
    /// The fixed-width builtin `usize` / `isize` IS in C++ on this target
    /// (size_types), or COUNT where it is a C++ type of its own.
    pub var usize_as: BuiltinKind = BuiltinKind::U64
    pub var isize_as: BuiltinKind = BuiltinKind::I64

    fn PanicTypeIds(self) { }
    fn PanicTypeIds(self,
                    psym: unsafe *PreprocessorSymbolTable,
                    wk:   unsafe *WellKnownDecls,
                    bits: i32) {
        self.psym       = psym
        self.well_known = wk
        self.id_bits    = bits
    }

    /// Which builtin `usize` and `isize` are one C++ type with, from the
    /// target: size_t / ptrdiff_t are the fixed-width integer of the pointer
    /// width wherever the target says so (target.usize_is_fixed, as
    /// RedeclMerge::_cxx_lowered reads it), and a type of their own on
    /// Darwin. \p pw 0 is a hand-built invocation: the 64-bit host.
    pub fn size_types(self, pw: usize, usize_fixed: bool, isize_fixed: bool) {
        var w = if (pw != (0 as usize)) => (pw) else => (64)
        self.usize_as = BuiltinKind::COUNT
        self.isize_as = BuiltinKind::COUNT
        if usize_fixed {
            if w == (16 as usize) {
                self.usize_as = BuiltinKind::U16
            }

            if w == (32 as usize) {
                self.usize_as = BuiltinKind::U32
            }

            if w == (64 as usize) {
                self.usize_as = BuiltinKind::U64
            }
        }

        if isize_fixed {
            if w == (16 as usize) {
                self.isize_as = BuiltinKind::I16
            }

            if w == (32 as usize) {
                self.isize_as = BuiltinKind::I32
            }

            if w == (64 as usize) {
                self.isize_as = BuiltinKind::I64
            }
        }
    }

    /// Order among elements whose spelling, and so id and key, is one: two
    /// builtins that are one C++ type (`usize` and `u64` on Linux). C++ sees
    /// one pack either way; this keeps Kairo's two orders of it one type, by
    /// the builtin's kind. 0 for anything else, which never ties.
    fn tie(self, t: unsafe *Type) -> u32 {
        if t == &null || t->canonical == &null {
            return 0
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c == &null || !isa<BuiltinType>(c) {
            return 0
        }

        return ((cast<BuiltinType>(c)->builtin as u8) as u32) + (1 as u32)
    }

    /// The Panic lang item's enum, by identity (never by name), or null.
    fn panic_enum(self) -> unsafe *EnumDecl {
        if self.well_known == &null {
            return &null
        }

        var unsafe *d = self.well_known->get(WellKnownType::Panic)
        if d == &null {
            return &null
        }

        var unsafe *en = dyn_cast<EnumDecl>(NameLookup::representative(d))
        if en == &null || !en->is_adt {
            return &null
        }

        return en
    }

    /// \p d is the Panic lang item or an instance of it.
    pub fn is_panic(self, d: unsafe *Decl) -> bool {
        if d == &null {
            return false
        }

        var unsafe *pe = self.panic_enum()
        if pe == &null {
            return false
        }

        var unsafe *p = decl_instantiated_from(d)
        if p == &null {
            p = d
        }

        return NameLookup::representative(p) == pe
    }

    /// The spelling \p t's id hashes: its C++ spelling, written here rather
    /// than by CXXSpell::_type so that it is the same before and after the
    /// lowerings (a `T?` is its Nullable record either way), needs no emit
    /// state, and takes no lock (record() and the registry call it while
    /// forming a type). "" when \p t has no id: dependent, a reference, an
    /// interface, unresolved.
    pub fn spelling(self, t: unsafe *Type) -> string {
        if t == &null || t->canonical == &null {
            return ""
        }

        var unsafe *c = canon_unqual(t->canonical)
        if c == &null {
            return ""
        }

        if c->is_dependent() || c->is_instantiation_dependent() {
            return ""
        }

        match c->kind {
            case TypeKind::BuiltinType {
                var unsafe *b = cast<BuiltinType>(c)
                if b->builtin == BuiltinKind::Never {
                    return ""
                }

                // One C++ type, one spelling, one id: `usize` is spelled
                // `decltype(sizeof(0))`, which on most targets IS `u64`'s
                // `unsigned long`, and two spellings of it would be two
                // `__kairo_tid` specializations of one type, a redefinition.
                if b->builtin == BuiltinKind::USize && self.usize_as != BuiltinKind::COUNT {
                    return builtin_info(self.usize_as)->cxx
                }

                if b->builtin == BuiltinKind::ISize && self.isize_as != BuiltinKind::COUNT {
                    return builtin_info(self.isize_as)->cxx
                }

                return b->cxx_emission()
            } case TypeKind::PointerType {
                var inner = self.spelling(cast<PointerType>(c)->pointee)
                if inner.size() == 0 {
                    return ""
                }

                return inner + "*"
            } case TypeKind::NullableType {
                var inner = self.spelling(cast<NullableType>(c)->inner)
                var unsafe *nd = if (self.well_known != &null) => (self.well_known->get(
                                     WellKnownType::Nullable,
                                 ))
                                 else => &null
                if inner.size() == 0 || nd == &null {
                    return ""
                }

                var q = self._qual(NameLookup::representative(nd))
                if q.size() == 0 {
                    return ""
                }

                return q + "<" + inner + ">"
            } case TypeKind::FixedArrayType {
                var unsafe *a = cast<FixedArrayType>(c)
                if a->is_incomplete || a->extent_param != &null {
                    return ""
                }

                var e = self.spelling(a->element)
                if e.size() == 0 {
                    return ""
                }

                return e + f"[{a->size_bits}]"
            } case TypeKind::FunctionPointerType {
                var unsafe *f = cast<FunctionPointerType>(c)
                var r = if (f->return_type == &null) => ("void")
                        else => self.spelling(f->return_type)
                if r.size() == 0 {
                    return ""
                }

                // A raw `unsafe fn` is `::__kairo_raw_fn<R(A...)>` (CXXSpell).
                var fv = if (f->is_raw) => (LowerTargets::raw_fn()) else => LowerTargets::fn_value()
                var s = "::" + fv + "<" + CXXSpell::call_conv_attr(f->call_conv) + r + "("
                for var i: usize = 0; i < f->params.size(); ++i {
                    var p = self.spelling(f->params[i])
                    if p.size() == 0 {
                        return ""
                    }

                    if i > 0 {
                        s += ","
                    }

                    s += p
                }

                return s + ")>"
            } case TypeKind::RecordType {
                var unsafe *r = cast<RecordType>(c)
                var unsafe *d = r->decl
                if d == &null || isa<InterfaceDecl>(d) {
                    return ""
                }

                if decl_is_imported(d) {
                    return decl_cxx_spelling(d)
                }

                var unsafe *p = decl_instantiated_from(d)
                if p == &null {
                    p = d
                }

                var s = self._qual(NameLookup::representative(p))
                if s.size() == 0 {
                    return ""
                }

                if r->args.size() > 0 {
                    s += "<"
                    for var i: usize = 0; i < r->args.size(); ++i {
                        var a = self.spelling(r->args[i])
                        if a.size() == 0 {
                            return ""
                        }

                        if i > 0 {
                            s += ","
                        }

                        s += a
                    }

                    s += ">"
                }

                return s
            } default {
                0
            }
        }

        return ""
    }

    /// \p t's panic type id, or 0 when it has none (spelling).
    fn type_id(self, t: unsafe *Type) -> u32 {
        var s = self.spelling(t)
        if s.size() == 0 {
            return 0
        }

        return panic_id_of(s, self.id_bits)
    }

    /// The 64-bit key of \p t's spelling: the guard of its `__kairo_tid`
    /// specialization (LowerTargets::type_id_guard). 0 when it has no id.
    fn type_key(self, t: unsafe *Type) -> u64 {
        var s = self.spelling(t)
        if s.size() == 0 {
            return 0
        }

        return panic_fnv64(s)
    }

    /// `::ns::Outer::Name` for a Kairo record, through CXXSpell over a
    /// sink-less context (TypeExport's pattern): what every TU's C++ calls
    /// it. "" when the decl has no TU or the PP symbols are not wired.
    priv fn _qual(self, d: unsafe *Decl) -> string {
        var unsafe *tu = CXXSpell::tu_of(d)
        if tu == &null || tu->ctx == &null || self.psym == &null {
            return ""
        }

        var cg = CodegenContext(tu->ctx, &null, self.psym, &null)
        var sp = CXXSpell(unsafe &cg)
        return sp.qual_name(d)
    }

    /// PackSetOrder: \p args of the Panic lang item \p d, its pack sorted
    /// by type id (ties, which only a collision has, by key) -- the
    /// canonical order (Compiler/Spec/Panic.md#canonical-sets). Unchanged when an element has no id
    /// (a dependent instance keeps the order it was written in: its set is
    /// not formed yet) or \p d is anything else.
    fn order(self, d: unsafe *Decl, args: unsafe *cxx::std::vector<unsafe *Type>) {
        if !self.is_panic(d) {
            return
        }

        var at = adt_pack_param(self.panic_enum())
        if at == usize::MAX || args->size() <= at + 1 {
            return
        }

        var els = cxx::std::vector<unsafe *Type>()
        var ids = cxx::std::vector<u32>()
        var kys = cxx::std::vector<u64>()
        var tis = cxx::std::vector<u32>()
        for var i: usize = at; i < args->size(); ++i {
            var unsafe *e = (*args)[i]
            var        s  = self.spelling(e)
            if s.size() == 0 {
                return
            }

            var id = panic_id_of(s, self.id_bits)
            var ky = panic_fnv64(s)
            var ti = self.tie(e)
            // Insertion sort: a set is a handful of types.
            var k = els.size()
            els.push_back(e)
            ids.push_back(id)
            kys.push_back(ky)
            tis.push_back(ti)
            while k > 0
                && (ids[k - 1] > id
                    || ids[k - 1] == id && kys[k - 1] > ky
                    || ids[k - 1] == id && kys[k - 1] == ky && tis[k - 1] > ti) {
                els[k] = els[k - 1]
                ids[k] = ids[k - 1]
                kys[k] = kys[k - 1]
                tis[k] = tis[k - 1]
                k -= 1
            }

            els[k] = e
            ids[k] = id
            kys[k] = ky
            tis[k] = ti
        }

        for var i: usize = 0; i < els.size(); ++i {
            (*args)[at + i] = els[i]
        }
    }
}

pub class PanicSets {
    pub var  sc:  unsafe *SemaContext
    priv var tu:  TypeUtil
    priv var ids: PanicTypeIds

    fn PanicSets(self) {
        self.sc = &null
    }

    fn PanicSets(self, sc: unsafe *SemaContext) {
        self.sc = sc
        self.tu = TypeUtil(sc)
        var ps: unsafe *PreprocessorSymbolTable = &null
        if sc->foreign != &null {
            ps = sc->foreign->psym
        }

        self.ids = PanicTypeIds(ps, sc->well_known, sc->opts.test_panic_id_bits)
        var unsafe *ci = sc->ctx->ci
        if ci != &null {
            self.ids.size_types(
                ci->target.pointer_width,
                ci->target.usize_is_fixed,
                ci->target.isize_is_fixed,
            )
        }
    }

    fn panic_enum(self) -> unsafe *EnumDecl {
        return self.ids.panic_enum()
    }

    fn is_panic(self, d: unsafe *Decl) -> bool {
        return self.ids.is_panic(d)
    }

    fn spelling(self, t: unsafe *Type) -> string {
        return self.ids.spelling(t)
    }

    fn type_id(self, t: unsafe *Type) -> u32 {
        return self.ids.type_id(t)
    }

    fn type_key(self, t: unsafe *Type) -> u64 {
        return self.ids.type_key(t)
    }

    /// # sets

    /// \p args (the Panic lang item's) in the canonical order: what every
    /// formation already gets (PanicTypeIds::order); for a caller holding a
    /// list it has not formed into a type yet. Dedup is the type store's.
    fn canonicalize(self, args: unsafe *cxx::std::vector<unsafe *Type>) -> bool {
        var unsafe *pe = self.panic_enum()
        if pe == &null {
            return false
        }

        self.ids.order(pe, args)
        return true
    }

    /// The per-set collision error (Compiler/Spec/Panic.md#canonical-sets): two elements of the
    /// canonical \p args with one id. Reported at \p at, naming both types;
    /// true when the set is clean.
    fn check_collisions(self, at: SourceRange, const args: cxx::std::vector<unsafe *Type>) -> bool {
        var unsafe *pe = self.panic_enum()
        if pe == &null {
            return true
        }

        var p = adt_pack_param(pe)
        if p == usize::MAX {
            return true
        }

        var ok = true
        for var i: usize = p; i + 1 < args.size(); ++i {
            var unsafe *a = (args)[i]
            var unsafe *b = (args)[i + 1]
            if a == b { // one type twice is one element (the store dedups).
                continue
            }

            var ia = self.type_id(a)
            if ia == 0 || ia != self.type_id(b) {
                continue
            }

            ok = false
            var an = self.tu.str(a)
            var bn = self.tu.str(b)
            var hx = hex32(ia)
            // Two builtins that are one C++ type (`usize` and `u64` where
            // size_t is uint64_t) share a spelling, so an id: not a hash
            // collision, and a different message says so.
            var sp  = self.spelling(a)
            var why = f"both have type id 0x{hx}"
            if sp == self.spelling(b) {
                why = f"on this target both are the C++ type '{sp}', so their tags are one"
            }

            var bld = self.sc->diag->report(
                DiagID::SC223E,
                at.start,
                f"'{an}' and '{bn}' cannot be in one panic set: {why}",
            )

            bld.first(at, "the panic set formed here")
            var unsafe *da = self.tu.record_decl(a)
            var unsafe *db = self.tu.record_decl(b)
            if da != &null {
                bld.note(
                    DiagCode(DiagID::SC223N),
                    da->range.start,
                    f"'{an}' declared here",
                )->child_first(da->range)
            }

            if db != &null {
                bld.note(
                    DiagCode(DiagID::SC223N),
                    db->range.start,
                    f"'{bn}' declared here",
                )->child_first(db->range)
            }

            bld.emit()
        }

        return ok
    }

    /// `Panic<T, E...>` with \p elems as its set: the one way the compiler
    /// forms a panic result type. Canonical (canonicalize) and checked
    /// (check_collisions, at \p at); null when there is no Panic lang item,
    /// an element is unresolved, or the set collides.
    fn form(self,
            at:    SourceRange,
            t:     unsafe *Type,
            elems: unsafe *cxx::std::vector<unsafe *Type>) -> unsafe *Type {
        if t == &null || self.panic_enum() == &null {
            return &null
        }

        var args = cxx::std::vector<unsafe *Type>()
        args.push_back(t)
        for var i: usize = 0; i < elems->size(); ++i {
            if (*elems)[i] == &null {
                return &null
            }

            args.push_back((*elems)[i])
        }

        self.canonicalize(unsafe &args)
        if !self.check_collisions(at, args) {
            return &null
        }

        var unsafe *r = self.sc->lang_record(WellKnownType::Panic, unsafe &args)
        self.note_formed(at, r)
        return r
    }

    /// Record \p at as where \p t's set was formed, if no TU has yet: the
    /// register-cliff remark's anchor (InstanceEntry::formed_at).
    fn note_formed(self, at: SourceRange, t: unsafe *Type) {
        if t == &null || self.sc->instances == &null {
            return
        }

        var unsafe *d = self.tu.record_decl(t)
        if d == &null {
            return
        }

        var unsafe *e = self.sc->instances->entry_of(d)
        if e == &null {
            return
        }

        // First in import order, not first in time: TUs that do not import
        // each other form sets side by side.
        self.sc->instances->note_formed(e, self.sc->ctx->fid, at)
    }

    /// # sites

    /// The site id of a `panic` at \p loc (Compiler/Spec/Panic.md#site-ids): FNV-1a 32 of the
    /// path and the byte offset (`<path>:<offset>`), nonzero, and unique in
    /// this TU -- a site whose id another site of the TU already has is
    /// rehashed (one more 0xFF byte) until it is free. The same location
    /// asked twice is the same site. Registered in the TU's table.
    fn site_id(self, loc: SourceLocation) -> u32 {
        var unsafe *t = self.sc->tu
        if t == &null || self.sc->ctx == &null || self.sc->ctx->sm == &null {
            return 0
        }

        var unsafe *sm      = self.sc->ctx->sm
        var        off      = sm->get_offset(loc)
        var        key_text = sm->get_filename(loc) + ":" + f"{off}"
        var        key      = panic_fnv64(key_text)
        for var i: usize = 0; i < t->panic_sites.size(); ++i {
            if t->panic_sites[i].key == key {
                return t->panic_sites[i].id
            }
        }

        var h = panic_fnv32(FNV1A32_OFFSET, key_text)
        while true {
            var taken = h == (0 as u32)
            for var i: usize = 0; !taken && i < t->panic_sites.size(); ++i {
                if t->panic_sites[i].id == h {
                    taken = true
                }
            }

            if !taken {
                break
            }

            h = h ^ (255 as u32)
            h = h * FNV1A32_PRIME
        }

        var r = PanicSiteRec()
        r.id  = h
        r.key = key
        r.at  = loc
        t->panic_sites.push_back(r)
        return h
    }
}
