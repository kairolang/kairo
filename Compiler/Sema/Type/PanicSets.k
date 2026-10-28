/// --- The Kairo Project -------------------------- Sema/Type/PanicSets.k --- ///
///
///   \brief The identities the panic system is built on (PANIC.md §1.3,
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
///     PANIC.md §1.3; nothing else may compute an id, and codegen reads the
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Sema::SemaContext::*;
import Sema::Resolve::NameLookup::*;
import Sema::Foreign::ForeignInstantiate::*;
import Preprocessor::PreprocessorSymbolTable::*;
import Sema::Type::TypeUtil::*;
import AST::ASTSupport::*;
import AST::DeclFacts::*;
import AST::LangItems::*;
import AST::Context::TranslationUnit::*;
import AST::Context::InstantiationRegistry::*;
import AST::Node::Base::*;
import AST::Node::Types::*;
import AST::Node::Declarations::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import Codegen::CodegenContext::*;
import Codegen::Emit::CXXSpell::*;
import Diagnostic::Registry::*;
import Location::SourceRange::*;
import Location::SourceLocation::*;

/// FNV-1a, 32 bits, over \p s, continuing from \p h (start: 2166136261).
fn panic_fnv32(h_in: u32, s: string) -> u32 {
    var h = h_in;
    for var i: usize = 0; i < s.size(); ++i {
        h = h ^ u32(u8(s[i]));
        h = h * u32(16777619);
    }
    return h;
}

/// FNV-1a, 64 bits, over \p s (the key of a minted name: a guard, a site
/// record). 64 bits so that two different spellings never share one.
fn panic_fnv64(s: string) -> u64 {
    var h: u64 = u64(14695981039346656037);
    for var i: usize = 0; i < s.size(); ++i {
        h = h ^ u64(u8(s[i]));
        h = h * u64(1099511628211);
    }
    return h;
}

/// The pinned id hash (PANIC.md §1.3): FNV-1a 32 of \p s, keeping the low
/// \p bits bits; while that is 0, one more byte 0xFF is hashed in. 0 is
/// never an id: it is Ok's tag, and "no id".
fn panic_id_of(s: string, bits: i32) -> u32 {
    var mask: u32 = (u32(-1)) if (bits >= 32) else ((u32(1) << u32(bits)) - u32(1));
    var h = panic_fnv32(u32(2166136261), s);
    var r = h & mask;
    while r == u32(0) {
        h = h ^ u32(255);
        h = h * u32(16777619);
        r = h & mask;
    }
    return r;
}

/// The type-id side of the Panic lang item, with no per-TU state: the one
/// object the build's CanonicalTypeStore and InstantiationRegistry hold as
/// their PackSetOrder, so `Panic<i32, B, A>` IS `Panic<i32, A, B>` wherever
/// a type is formed -- a written type, a `Panic<...>::Ok` path, a deduced
/// argument -- exactly as P0's dedup makes equal elements one. Installed by
/// the driver before any Sema pass; PanicSets builds one on the fly.
class PanicTypeIds derives PackSetOrder {
    pub var psym:       *PreprocessorSymbolTable = &null;
    pub var well_known: *WellKnownDecls = &null;
    pub var id_bits:    i32 = 32;

    fn PanicTypeIds(self) { }
    fn PanicTypeIds(self, psym: *PreprocessorSymbolTable, wk: *WellKnownDecls, bits: i32) {
        self.psym       = psym;
        self.well_known = wk;
        self.id_bits    = bits;
    }

    /// The Panic lang item's enum, by identity (never by name), or null.
    fn panic_enum(self) -> *EnumDecl {
        if self.well_known == &null { return &null; }
        var d = self.well_known->get(WellKnownType::Panic);
        if d == &null { return &null; }
        var en = dyn_cast::<EnumDecl>(NameLookup::representative(d));
        if (en == &null) || (!en->is_adt) { return &null; }
        return en;
    }

    /// \p d is the Panic lang item or an instance of it.
    fn is_panic(self, d: *Decl) -> bool {
        if d == &null { return false; }
        var pe = self.panic_enum();
        if pe == &null { return false; }
        var p = decl_instantiated_from(d);
        if p == &null { p = d; }
        return NameLookup::representative(p) == static_cast::<*Decl>(pe);
    }

    /// The spelling \p t's id hashes: its C++ spelling, written here rather
    /// than by CXXSpell::_type so that it is the same before and after the
    /// lowerings (a `T?` is its Nullable record either way), needs no emit
    /// state, and takes no lock (record() and the registry call it while
    /// forming a type). "" when \p t has no id: dependent, a reference, an
    /// interface, unresolved.
    fn spelling(self, t: *Type) -> string {
        if (t == &null) || (t->canonical == &null) { return ""; }
        var c = canon_unqual(t->canonical);
        if c == &null { return ""; }
        if c->is_dependent() || c->is_instantiation_dependent() { return ""; }
        switch c->kind {
            case TypeKind::BuiltinType {
                var b = cast::<BuiltinType>(c);
                if (b->builtin == BuiltinKind::Never) { return ""; }
                return b->cxx_emission();
            }
            case TypeKind::PointerType {
                var inner = self.spelling(cast::<PointerType>(c)->pointee);
                if inner.size() == 0 { return ""; }
                return inner + "*";
            }
            case TypeKind::NullableType {
                var inner = self.spelling(cast::<NullableType>(c)->inner);
                var nd = (self.well_known->get(WellKnownType::Nullable)) if (self.well_known != &null) else (&null);
                if (inner.size() == 0) || (nd == &null) { return ""; }
                var q = self._qual(NameLookup::representative(nd));
                if q.size() == 0 { return ""; }
                return q + "<" + inner + ">";
            }
            case TypeKind::FixedArrayType {
                var a = cast::<FixedArrayType>(c);
                if a->is_incomplete || (a->extent_param != &null) { return ""; }
                var e = self.spelling(a->element);
                if e.size() == 0 { return ""; }
                return e + f"[{a->size_bits}]";
            }
            case TypeKind::FunctionPointerType {
                var f = cast::<FunctionPointerType>(c);
                var r = ("void") if (f->return_type == &null) else (self.spelling(f->return_type));
                if r.size() == 0 { return ""; }
                var s = "::" + LowerTargets::fn_value() + "<" + r + "(";
                for var i: usize = 0; i < f->params.size(); ++i {
                    var p = self.spelling(f->params[i]);
                    if p.size() == 0 { return ""; }
                    if i > 0 { s += ","; }
                    s += p;
                }
                return s + ")>";
            }
            case TypeKind::RecordType {
                var r = cast::<RecordType>(c);
                var d = r->decl;
                if (d == &null) || isa::<InterfaceDecl>(d) { return ""; }
                if decl_is_imported(d) { return decl_cxx_spelling(d); }
                var p = decl_instantiated_from(d);
                if p == &null { p = d; }
                var s = self._qual(NameLookup::representative(p));
                if s.size() == 0 { return ""; }
                if r->args.size() > 0 {
                    s += "<";
                    for var i: usize = 0; i < r->args.size(); ++i {
                        var a = self.spelling(r->args[i]);
                        if a.size() == 0 { return ""; }
                        if i > 0 { s += ","; }
                        s += a;
                    }
                    s += ">";
                }
                return s;
            }
            default { 0; }
        }
        return "";
    }

    /// \p t's panic type id, or 0 when it has none (spelling).
    fn type_id(self, t: *Type) -> u32 {
        var s = self.spelling(t);
        if s.size() == 0 { return 0; }
        return panic_id_of(s, self.id_bits);
    }

    /// The 64-bit key of \p t's spelling: the guard of its `__kairo_tid`
    /// specialization (LowerTargets::type_id_guard). 0 when it has no id.
    fn type_key(self, t: *Type) -> u64 {
        var s = self.spelling(t);
        if s.size() == 0 { return 0; }
        return panic_fnv64(s);
    }

    /// `::ns::Outer::Name` for a Kairo record, through CXXSpell over a
    /// sink-less context (TypeExport's pattern): what every TU's C++ calls
    /// it. "" when the decl has no TU or the PP symbols are not wired.
    priv fn _qual(self, d: *Decl) -> string {
        var tu = CXXSpell::tu_of(d);
        if (tu == &null) || (tu->ctx == &null) || (self.psym == &null) { return ""; }
        var cg = CodegenContext(tu->ctx, &null, self.psym, &null);
        var sp = CXXSpell(&cg);
        return sp.qual_name(d);
    }

    /// PackSetOrder: \p args of the Panic lang item \p d, its pack sorted
    /// by type id (ties, which only a collision has, by key) -- the
    /// canonical order (PANIC.md §1.3). Unchanged when an element has no id
    /// (a dependent instance keeps the order it was written in: its set is
    /// not formed yet) or \p d is anything else.
    fn order(self, d: *Decl, args: *vec::<*Type>) {
        if !self.is_panic(d) { return; }
        var at = adt_pack_param(self.panic_enum());
        if (at == usize(-1)) || (args->size() <= at + 1) { return; }
        var els  = vec::<*Type>();
        var ids  = vec::<u32>();
        var kys  = vec::<u64>();
        for var i: usize = at; i < args->size(); ++i {
            var e = (*args)[i];
            var s = self.spelling(e);
            if s.size() == 0 { return; }
            var id = panic_id_of(s, self.id_bits);
            var ky = panic_fnv64(s);
            // Insertion sort: a set is a handful of types.
            var k = els.size();
            els.push_back(e);
            ids.push_back(id);
            kys.push_back(ky);
            while (k > 0) && ((ids[k - 1] > id) || ((ids[k - 1] == id) && (kys[k - 1] > ky))) {
                els[k] = els[k - 1];
                ids[k] = ids[k - 1];
                kys[k] = kys[k - 1];
                k -= 1;
            }
            els[k] = e;
            ids[k] = id;
            kys[k] = ky;
        }
        for var i: usize = 0; i < els.size(); ++i { (*args)[at + i] = els[i]; }
    }
}

class PanicSets {
    pub var sc: *SemaContext;
    priv var tu: TypeUtil;
    priv var ids: PanicTypeIds;

    fn PanicSets(self) { self.sc = &null; }
    fn PanicSets(self, sc: *SemaContext) {
        self.sc  = sc;
        self.tu  = TypeUtil(sc);
        var ps: *PreprocessorSymbolTable = &null;
        if sc->foreign != &null { ps = sc->foreign->psym; }
        self.ids = PanicTypeIds(ps, sc->well_known, sc->opts.test_panic_id_bits);
    }

    fn panic_enum(self) -> *EnumDecl { return self.ids.panic_enum(); }
    fn is_panic(self, d: *Decl) -> bool { return self.ids.is_panic(d); }
    fn spelling(self, t: *Type) -> string { return self.ids.spelling(t); }
    fn type_id(self, t: *Type) -> u32 { return self.ids.type_id(t); }
    fn type_key(self, t: *Type) -> u64 { return self.ids.type_key(t); }

    // --- sets -----------------------------------------------------------------------

    /// \p args (the Panic lang item's) in the canonical order: what every
    /// formation already gets (PanicTypeIds::order); for a caller holding a
    /// list it has not formed into a type yet. Dedup is the type store's.
    fn canonicalize(self, args: *vec::<*Type>) -> bool {
        var pe = self.panic_enum();
        if pe == &null { return false; }
        self.ids.order(static_cast::<*Decl>(pe), args);
        return true;
    }

    /// The per-set collision error (PANIC.md §1.3): two elements of the
    /// canonical \p args with one id. Reported at \p at, naming both types;
    /// true when the set is clean.
    fn check_collisions(self, at: SourceRange, args: *vec::<*Type>) -> bool {
        var pe = self.panic_enum();
        if pe == &null { return true; }
        var p = adt_pack_param(pe);
        if p == usize(-1) { return true; }
        var ok = true;
        for var i: usize = p; i + 1 < args->size(); ++i {
            var a = (*args)[i];
            var b = (*args)[i + 1];
            if a == b { continue; }   // one type twice is one element (the store dedups).
            var ia = self.type_id(a);
            if (ia == 0) || (ia != self.type_id(b)) { continue; }
            ok = false;
            var an = self.tu.str(a);
            var bn = self.tu.str(b);
            var hx = hex32(ia);
            var bld = self.sc->diag->report(DiagID::SC001E, at.start,
                f"'{an}' and '{bn}' cannot be in one panic set: both have type id 0x{hx}");
            bld.first(at, "the panic set formed here");
            var da = self.tu.record_decl(a);
            var db = self.tu.record_decl(b);
            if da != &null { bld.note(DiagID::SC001N, da->range.start, f"'{an}' declared here").first(da->range); }
            if db != &null { bld.note(DiagID::SC001N, db->range.start, f"'{bn}' declared here").first(db->range); }
            bld.emit();
        }
        return ok;
    }

    /// `Panic<T, E...>` with \p elems as its set: the one way the compiler
    /// forms a panic result type. Canonical (canonicalize) and checked
    /// (check_collisions, at \p at); null when there is no Panic lang item,
    /// an element is unresolved, or the set collides.
    fn form(self, at: SourceRange, t: *Type, elems: *vec::<*Type>) -> *Type {
        if (t == &null) || (self.panic_enum() == &null) { return &null; }
        var args = vec::<*Type>();
        args.push_back(t);
        for var i: usize = 0; i < elems->size(); ++i {
            if (*elems)[i] == &null { return &null; }
            args.push_back((*elems)[i]);
        }
        self.canonicalize(&args);
        if !self.check_collisions(at, &args) { return &null; }
        var r = self.sc->lang_record(WellKnownType::Panic, &args);
        self.note_formed(at, r);
        return r;
    }

    /// Record \p at as where \p t's set was formed, if no TU has yet: the
    /// register-cliff remark's anchor (InstanceEntry::formed_at).
    fn note_formed(self, at: SourceRange, t: *Type) {
        if (t == &null) || (self.sc->instances == &null) { return; }
        var d = self.tu.record_decl(t);
        if d == &null { return; }
        var e = self.sc->instances->entry_of(d);
        if (e == &null) || (e->formed_fid != u32(-1)) { return; }
        e->formed_fid = self.sc->ctx->fid;
        e->formed_at  = at;
    }

    // --- sites ----------------------------------------------------------------------

    /// The site id of a `panic` at \p loc (PANIC.md §1.4): FNV-1a 32 of the
    /// path and the byte offset (`<path>:<offset>`), nonzero, and unique in
    /// this TU -- a site whose id another site of the TU already has is
    /// rehashed (one more 0xFF byte) until it is free. The same location
    /// asked twice is the same site. Registered in the TU's table.
    fn site_id(self, loc: SourceLocation) -> u32 {
        var t = self.sc->tu;
        if (t == &null) || (self.sc->ctx == &null) || (self.sc->ctx->sm == &null) { return 0; }
        var sm  = self.sc->ctx->sm;
        var off = sm->get_offset(loc);
        var key_text = sm->get_filename(loc) + ":" + f"{off}";
        var key = panic_fnv64(key_text);
        for var i: usize = 0; i < t->panic_sites.size(); ++i {
            if t->panic_sites[i].key == key { return t->panic_sites[i].id; }
        }
        var h  = panic_fnv32(u32(2166136261), key_text);
        while true {
            var taken = h == u32(0);
            for var i: usize = 0; (!taken) && (i < t->panic_sites.size()); ++i {
                if t->panic_sites[i].id == h { taken = true; }
            }
            if !taken { break; }
            h = h ^ u32(255);
            h = h * u32(16777619);
        }
        var r = PanicSiteRec();
        r.id  = h;
        r.key = key;
        r.at  = loc;
        t->panic_sites.push_back(r);
        return h;
    }
}
