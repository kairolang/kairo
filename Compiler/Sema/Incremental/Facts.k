/// --- The Kairo Project ------------------- Sema/Incremental/Facts.k --- ///
///
/// Incremental Sema, phase 1: a declaration's identity (DeclId), a
/// file's interface hashes at SemaPhase::Checked, and its
/// dependency rows. Compiler/Spec/IncrementalSema.md is the design
/// and defines every term used here.
///
///   Nothing here feeds back into Sema: this file reads the checked tree and
///   the TU's DepLog and produces strings for --dump-interface / --dump-deps.
///   No reuse happens yet (that is phase 2).
///
///   Three rules every function below keeps:
///     - nothing process-dependent reaches a string: no address, fid or imm
///       index, and a path only relative to the dump's root;
///     - a declaration is spelled through ITS OWN file's context;
///     - the interface is read at Checked, before a lowering rewrites the
///       nodes it describes.
///
///   Phase: after the late checks (FrontendAction::_sema_finish, where
///   --print-sema dumps); the dependency rows are resolved at the end of the
///   frontend, while every tree is alive.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "llvm/ADT/STLExtras.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::ASTSupport::FrozenList
import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::DepLog::DepLog
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::Context::ImportOverlay::ImportOverlay
import AST::Context::SymbolTable::{
    DeclName,
    DeclNameKind,
    OverloadCell,
    SymbolTable,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::DeclFacts::{
    decl_bases,
    decl_fields,
    decl_generic_params,
    decl_implements,
    decl_in_generic_owner,
    decl_is_instance,
    decl_methods,
    decl_pattern,
    decl_requires_clause,
    decl_spec_args,
}
import AST::Kind::TypeKind::TypeKind
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    AssocType,
    QualifiedType,
    RecordType,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Types
import AST::OperatorFacts::op_decl_name
import AST::VisibilityFacts::default_visibility_of
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Native::ObjCache::objcache_hash128
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::SemaDump::{
    sema_dump_decl_name,
    sema_dump_kind_str,
    sema_dump_phase_str,
}
import Sema::Type::TypeUtil::TypeUtil
import Support::Ascii::{
    copy_strings,
    has_at,
    string_less,
}
import Support::Escape::json_string

/// # Strings

/// A JSON string literal: Support::Escape::json_string, the escaper every
/// dump and module record spells its strings with.
pub fn incr_json(const s: string) -> string {
    return json_string(s)
}

/// Source text with every run of whitespace as one space and none at the
/// ends: re-indenting a declaration must not move its hash.
pub fn incr_norm(const s: string) -> string {
    var o:    string = ""
    var space        = false
    var i:    usize  = 0
    var n            = s.size()
    while i < n {
        if incr_is_space(s.data()[i]) {
            space = true
            i += 1
            continue
        }

        // Runs between whitespace are copied whole: the cuts are at ASCII
        // bytes and never split a character.
        var start = i
        while i < n && !incr_is_space(s.data()[i]) {
            i += 1
        }

        if space && o.size() > 0 {
            o += " "
        }

        space = false
        o += s[start..i]
    }

    return o
}

fn incr_is_space(c: u8) -> bool {
    return c == (' ' as u8) || c == (9 as u8) || c == (10 as u8) || c == (13 as u8)
}

/// xxh3-128 as 32 hex digits: the hash the object cache and the AST
/// serializer use.
pub fn incr_hash(const s: string) -> string {
    return kairo::std::from_std_string<string>(objcache_hash128(kairo::sref(s)))
}

/// The text of [a, b) in `ctx`'s sources, or "" when the bounds are not an
/// ordered pair in one buffer (a synthesized node, an imported C++ one).
pub fn incr_text(ctx: unsafe *ASTContext, a: SourceLocation, b: SourceLocation) -> string {
    if ctx == &null || (!a.is_valid()) || (!b.is_valid()) {
        return ""
    }

    if b.raw() <= a.raw() || (b.raw() - a.raw()) > (1 << 22) {
        return ""
    }

    return ctx->get_spelling(SourceRange(a, b))
}

pub fn incr_range_text(ctx: unsafe *ASTContext, r: SourceRange) -> string {
    return incr_norm(incr_text(ctx, r.start, r.end))
}

/// # Identity

/// A file's module path, spelled: `Sema::Resolve::NameLookup`. The segments
/// are preprocessor SymbolIDs, which mean nothing outside this process, so
/// they are resolved to text here and never stored. A file outside every
/// root has no path; it is named by its stem behind `~`, which no module
/// path can start with.
pub fn incr_module(ctx: unsafe *ASTContext, psym: unsafe *PreprocessorSymbolTable) -> string {
    var out: string = ""
    if ctx == &null {
        return out
    }

    if psym != &null {
        for var i: usize = 0; i < ctx->module_base.segments.size(); ++i {
            var unsafe *seg = psym->resolve(ctx->module_base.segments[i].name)
            if i > 0 {
                out += "::"
            }

            if seg != &null {
                out += *seg
            }
        }
    }

    if out.size() > 0 || ctx->sm == &null {
        return out
    }

    var path       = ctx->sm->get_filename(ctx->fid)
    var lo:  usize = 0
    var hi         = path.size()
    for var i: usize = 0; i < path.size(); ++i {
        if path.data()[i] == ('/' as u8) || path.data()[i] == ('\\' as u8) {
            lo = i + 1
        }
    }

    for var i: usize = lo; i < path.size(); ++i {
        if path.data()[i] == ('.' as u8) {
            hi = i
        }
    }

    out = "~"
    out += path[lo..hi]

    return out
}

/// A lookup key as a name: the identifier, `op#<kinds>` for an operator (a
/// key packs token kinds, which are fixed by the compiler and not reversible
/// to a spelling), `<ctor>`, `<dtor>`. The interface's name sets and the
/// dependency rows both use this, so a row finds its declarations by string
/// equality.
pub fn incr_key_name(ctx: unsafe *ASTContext, name: DeclName) -> string {
    match name.kind {
        case DeclNameKind::Identifier {
            if ctx == &null {
                return "?"
            }

            var unsafe *tbl = ctx->get_imm_table()
            if tbl == &null {
                return "?"
            }

            return tbl->get_ident(name.payload)
        } case DeclNameKind::Operator {
            return f"op#{name.payload}"
        } case DeclNameKind::Constructor {
            return "<ctor>"
        } case DeclNameKind::Destructor {
            return "<dtor>"
        }
    }

    return "?"
}

/// The key name a declaration is found under, from the declaration: for the
/// ones no table holds (an out-of-line definition) and for an overlay hit,
/// whose key may be an import alias and not the declared name. An operator's
/// is its table key (op_decl_name), without the `l` / `r` fixity marker:
/// `op l++` and `op r++` are found under the name `op ++` is.
pub fn incr_decl_key_name(ctx: unsafe *ASTContext, d: unsafe *Decl) -> string {
    var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
    if f != &null && f->is_operator {
        return incr_key_name(ctx, op_decl_name(f))
    }

    return sema_dump_decl_name(ctx, d)
}

/// One scope of a DeclId: `<kind>:<name>`, with what tells same-named
/// declarations apart: the number of generic parameters, the specialization
/// arguments as written, and for a function its parameter types AS WRITTEN
/// (`self` for the receiver). As written, not as resolved, so the id exists
/// before Sema and survives an edit elsewhere; two spellings of one type are
/// then two ids, which costs a re-check and nothing else.
fn _incr_seg(ctx: unsafe *ASTContext, d: unsafe *Decl) -> string {
    if isa<Declarations::ExtensionDecl>(d) {
        var unsafe *e = cast<Declarations::ExtensionDecl>(d)
        var t = if (e->target != &null) => (incr_range_text(ctx, e->target->range)) else => ""
        return "ext:" + t
    }

    var s  = sema_dump_kind_str(d->kind) + ":" + sema_dump_decl_name(ctx, d)
    var gp = decl_generic_params(d)
    if gp.size() > 0 {
        s += f"<{gp.size()}>"
    }

    var sa = decl_spec_args(d)
    if sa.size() > 0 {
        s += "<"
        for var i: usize = 0; i < sa.size(); ++i {
            if i > 0 {
                s += ","
            }

            if sa[i] != &null {
                s += incr_range_text(ctx, sa[i]->range)
            }
        }

        s += ">"
    }

    var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
    if f == &null {
        return s
    }

    s += "("
    for var i: usize = 0; i < f->params.size(); ++i {
        var unsafe *p = f->params[i]
        if i > 0 {
            s += ","
        }

        if p == &null {
            continue
        }

        if p->is_self {
            s += "self"
        } else if p->type_ == &null {
            s += "_"
        } else {
            var t = incr_range_text(ctx, p->type_->range)
            // A pointer type's range starts at its `*`: the `unsafe` before
            // it is the one written token the text misses, and `f(p: *T)`
            // and `f(p: unsafe *T)` are two overloads.
            if isa<Types::PointerType>(p->type_)
                && cast<Types::PointerType>(p->type_)->is_unsafe
                && !has_at(t, 0, "unsafe") {
                t = "unsafe " + t
            }

            s += if (t.size() > 0) => (t) else => "_"
        }

        if p->is_pack {
            s += "..."
        }
    }

    s += ")"
    // A conversion operator is overloaded on its RESULT: `op as` to i32 and
    // to string take the same parameters.
    if f->is_operator && f->return_type != &null && sema_dump_decl_name(ctx, d) == "op as" {
        s += "->" + incr_range_text(ctx, f->return_type->range)
    }

    return s
}

/// A declaration's DeclId: `<module>#<scope>/.../<decl>`.
///
/// The module is the path of the file the declaration's scope chain ends in,
/// so a member defined out of line in another file has its class's id. An
/// implicit instance is named as its pattern: instances are not identities,
/// (pattern, arguments) is. A C++ declaration has no DeclId (it has a USR);
/// `c++:<name>` only keeps a type string readable.
pub fn incr_decl_id(d_in: unsafe *Decl, psym: unsafe *PreprocessorSymbolTable) -> string {
    var unsafe *d = d_in
    if d == &null {
        return "?"
    }

    if decl_is_instance(d) {
        var unsafe *p = decl_pattern(d)
        if p != &null {
            d = p
        }
    }

    var unsafe *ctx = NameLookup::ctx_of(d)
    if ctx == &null || ctx->tu == &null {
        return "?"
    }

    if ctx->tu->is_foreign {
        return "c++:" + sema_dump_decl_name(ctx, d)
    }

    var        chain                         = _incr_seg(ctx, d)
    var unsafe *self_mod                     = unsafe (ctx->tu->module_self as unsafe *Decl)
    var        dc:       unsafe *DeclContext = d->semantic_dc
    if dc == &null {
        dc = d->lexical_dc
    }

    var depth: usize = 0
    while dc != &null && dc->dc_kind != DeclContextKind::TranslationUnit && depth < 64 {
        var unsafe *o = dc->dc_owner
        // The file's implicit module is the file scope by another handle.
        if o != &null && o != self_mod && o != d {
            chain = _incr_seg(ctx, o) + "/" + chain
        }

        dc = dc->dc_parent
        depth += 1
    }

    return incr_module(ctx, psym) + "#" + chain
}

/// The scope id of `dc` as rows and name sets spell it: "" for a file
/// scope, else its owner's DeclId.
pub fn incr_scope_id(dc: unsafe *DeclContext, psym: unsafe *PreprocessorSymbolTable) -> string {
    if dc == &null || dc->dc_kind == DeclContextKind::TranslationUnit {
        return ""
    }

    var unsafe *o = dc->dc_owner
    if o == &null {
        return ""
    }

    var unsafe *tu = NameLookup::tu_of(dc)
    if tu != &null && o == unsafe (tu->module_self as unsafe *Decl) {
        return ""
    }

    return incr_decl_id(o, psym)
}

/// Every record declaration the canonical type `c_in` mentions, depth
/// first, in the order they appear: a record, then its arguments, then the
/// type it is nested in. A type's structural string, a layout row and a
/// retraction all read records in this order.
pub fn incr_type_records(c_in:  unsafe *Type,
                         depth: u32,
                         out:   unsafe *cxx::std::vector<unsafe *Decl>) {
    if c_in == &null || depth > 24 {
        return
    }

    var unsafe *c = c_in
    if c->canonical != &null {
        c = c->canonical
    }

    match c->kind {
        case TypeKind::RecordType {
            var unsafe *r = cast<RecordType>(c)
            if r->decl != &null {
                out->push_back(r->decl)
            }

            for var i: usize = 0; i < r->args.size(); ++i {
                incr_type_records(r->args[i], depth + 1, out)
            }

            incr_type_records(r->outer, depth + 1, out)
        } case TypeKind::QualifiedType {
            incr_type_records(cast<QualifiedType>(c)->inner, depth + 1, out)
        } case TypeKind::PointerType {
            incr_type_records(
                cast<Types::PointerType>(c)->pointee,
                depth + 1,
                out,
            )
        } case TypeKind::NullableType {
            incr_type_records(
                cast<Types::NullableType>(c)->inner,
                depth + 1,
                out,
            )
        } case TypeKind::FixedArrayType {
            incr_type_records(
                cast<Types::FixedArrayType>(c)->element,
                depth + 1,
                out,
            )
        } case TypeKind::VectorType {
            incr_type_records(
                cast<Types::VectorType>(c)->element,
                depth + 1,
                out,
            )
        } case TypeKind::SetType {
            incr_type_records(cast<Types::SetType>(c)->element, depth + 1, out)
        } case TypeKind::MapType {
            var unsafe *m = cast<Types::MapType>(c)
            incr_type_records(m->key, depth + 1, out)
            incr_type_records(m->value, depth + 1, out)
        } case TypeKind::CXXLValueRefType {
            incr_type_records(
                cast<Types::CXXLValueRefType>(c)->referee,
                depth + 1,
                out,
            )
        } case TypeKind::CXXRValueRefType {
            incr_type_records(
                cast<Types::CXXRValueRefType>(c)->referee,
                depth + 1,
                out,
            )
        } case TypeKind::FunctionPointerType {
            var unsafe *f = cast<Types::FunctionPointerType>(c)
            for var i: usize = 0; i < f->params.size(); ++i {
                incr_type_records(f->params[i], depth + 1, out)
            }

            incr_type_records(f->return_type, depth + 1, out)
        } case TypeKind::AssocType {
            var unsafe *a = cast<AssocType>(c)
            incr_type_records(a->base, depth + 1, out)
            for var i: usize = 0; i < a->args.size(); ++i {
                incr_type_records(a->args[i], depth + 1, out)
            }
        } default {
            return
        }
    }
}

/// # A file's facts

/// What phase 1 knows about one file, as the strings the dumps print.
pub class FileFacts {
    pub var fid:      u32    = 0
    pub var mod_path: string = ""
    pub var path:     string = "" ///< absolute; the dump writes it relative to its root.
    pub var phase:    string = ""
    pub var hash:     string = "" ///< I(m).
    /// Hash of the file's macro definitions, or "". A macro is expanded in
    /// the importer before it is parsed, so no declaration row can stand for
    /// it: a change here re-checks every file the macros reach.
    pub var macros: string = ""
    /// One JSON object per exported declaration, sorted (each starts with
    /// its id, so the order is the id's).
    pub var decls: cxx::std::vector<string>
    /// One JSON object per scope with its names, sorted.
    pub var scopes: cxx::std::vector<string>
    /// Declaration rows of the dependency log found by reading the checked
    /// tree: `<part>\t<DeclId>`, sorted, unique.
    pub var rows: cxx::std::vector<string>
    /// `decls` and `scopes` again, as the tab-separated lines a plan record
    /// stores and the invalidation rules read (Sema/Incremental/Plan.k):
    /// `id, scope, name, I, body, ext, refs` and `scope, ext, names`, sorted.
    pub var plain_decls:  cxx::std::vector<string>
    pub var plain_scopes: cxx::std::vector<string>
    /// The TU's own diagnostics as the run rendered them, in delivery
    /// order, and the files they name a position in besides this one. The
    /// driver fills both when it drains the TU's sink.
    pub var diag:       string                   = ""
    pub var diag_files: cxx::std::vector<string>

    /// A copy of every field; the strings and string vectors are not
    /// copyable by assignment.
    pub fn copy(const self) -> FileFacts {
        var o = FileFacts()
        o.fid          = self.fid
        o.mod_path     = self.mod_path.copy()
        o.path         = self.path.copy()
        o.phase        = self.phase.copy()
        o.hash         = self.hash.copy()
        o.macros       = self.macros.copy()
        o.decls        = copy_strings(self.decls)
        o.scopes       = copy_strings(self.scopes)
        o.rows         = copy_strings(self.rows)
        o.plain_decls  = copy_strings(self.plain_decls)
        o.plain_scopes = copy_strings(self.plain_scopes)
        o.diag         = self.diag.copy()
        o.diag_files   = copy_strings(self.diag_files)
        return o
    }
}

/// Builds one TU's FileFacts at Checked.
///
/// The interface is every declaration a scope's symbol table names
/// (so the name sets and the declarations cannot disagree), every
/// extension's members, and the out-of-line definitions. Visibility
/// does not filter: an importer's lookup finds a `priv` name and
/// reports it, and overload resolution ranks a `priv` candidate
/// before access is checked, so both are facts an importer reads.
pub class IncrFacts derives RecursiveASTVisitor<IncrFacts> {
    pub var  sc:   unsafe *SemaContext
    pub var  ctx:  unsafe *ASTContext
    pub var  psym: unsafe *PreprocessorSymbolTable
    priv var _tu:  TypeUtil
    priv var _out: unsafe *FileFacts               = &null
    priv var _ids: llvm::DenseMap<u64, u32>
    priv var _idv: cxx::std::vector<string>
    /// DeclIds of the records the type strings of the entry being built
    /// name: its `refs`, which is what closes a layout row over the layouts
    /// it contains by value.
    priv var _refs:  cxx::std::vector<string>
    priv var _rows:  llvm::StringMap<u8>
    priv var _lines: cxx::std::vector<string> ///< `id\tI\tbody`, what I(m) hashes.

    pub fn IncrFacts(self, sc: unsafe *SemaContext, psym: unsafe *PreprocessorSymbolTable) {
        self.sc   = sc
        self.ctx  = sc->ctx
        self.psym = psym
        self._tu  = TypeUtil(sc)
    }

    pub fn run(self, out: unsafe *FileFacts) {
        var unsafe *tu = self.sc->tu
        if tu == &null || out == &null {
            return
        }

        self._out     = out
        out->fid      = self.ctx->fid
        out->mod_path = incr_module(self.ctx, self.psym)
        out->phase    = sema_dump_phase_str(self.sc->phase)
        if self.ctx->sm != &null {
            out->path = self.ctx->sm->get_filename(self.ctx->fid)
        }

        var unsafe *root = unsafe (tu as unsafe *DeclContext)
        self._scope(root, "", "")
        self._extensions(root)
        for var i: usize = 0; i < tu->out_of_line.size(); ++i {
            var unsafe *d = *tu->out_of_line.get(i)
            if d != &null {
                self._entry(
                    d,
                    incr_scope_id(d->semantic_dc, self.psym),
                    incr_decl_key_name(self.ctx, d),
                    "",
                )
            }
        }

        llvm::sort(out->decls.begin(), out->decls.end(), string_less)
        llvm::sort(out->scopes.begin(), out->scopes.end(), string_less)
        llvm::sort(
            out->plain_decls.begin(),
            out->plain_decls.end(),
            string_less,
        )

        llvm::sort(
            out->plain_scopes.begin(),
            out->plain_scopes.end(),
            string_less,
        )

        llvm::sort(self._lines.begin(), self._lines.end(), string_less)
        var mac: string = ""
        for var i: usize = 0; i < tu->macros.size(); ++i {
            var unsafe *md = *tu->macros.get(i)
            if md == &null {
                continue
            }

            // The body is a raw token span of its own, outside the range.
            mac += incr_range_text(self.ctx, md->range)
            var unsafe *mm = dyn_cast<Declarations::MacroDecl>(md)
            if mm != &null {
                mac += "|" + incr_range_text(self.ctx, mm->body_span)
            }

            mac += "\n"
        }

        if mac.size() > 0 {
            out->macros = incr_hash(mac)
        }

        var all: string = out->mod_path.copy() + "\n" + out->macros + "\n"
        for var i: usize = 0; i < self._lines.size(); ++i {
            all += self._lines[i]
            all += "\n"
        }

        for var i: usize = 0; i < out->scopes.size(); ++i {
            all += out->scopes[i]
            all += "\n"
        }

        out->hash = incr_hash(all)

        // The declaration rows: only when this TU is being logged, and only
        // over a tree whose types exist.
        if tu->dep_log != &null && tu->program != &null {
            RecursiveASTVisitor<IncrFacts>::run(self, tu)
            llvm::sort(out->rows.begin(), out->rows.end(), string_less)
        }
    }

    /// # Identity, cached

    priv fn _id(self, d: unsafe *Decl) -> string {
        var it = self._ids.find(d as usize as u64)
        if it != self._ids.end() {
            return self._idv[it->second as usize].copy()
        }

        var s = incr_decl_id(d, self.psym)
        self._ids[d as usize as u64] = (self._idv.size() as u32)
        self._idv.push_back(s.copy())
        return s
    }

    /// # Types, structurally

    /// A type's structural string: the canonical type as Kairo writes it,
    /// then the DeclId of every record in it, in the order they appear. The
    /// printed half gives the shape and the arguments; the ids are what make
    /// two records of one name in two modules two strings. Canonical, so an
    /// alias is its target and a change of the target moves every hash that
    /// reads the alias.
    priv fn _tstr(self, t: unsafe *Type) -> string {
        if t == &null {
            return "<none>"
        }

        var unsafe *c = t->canonical
        if c == &null {
            c = t
        }

        var decls = cxx::std::vector<unsafe *Decl>()
        incr_type_records(c, 0, unsafe &decls)
        var s = self._tu.str(c) + "@"
        for var i: usize = 0; i < decls.size(); ++i {
            if i > 0 {
                s += ","
            }

            var id = self._id(decls[i])
            s += id
            self._refs.push_back(id)
        }

        return s
    }

    priv fn _canon(self, t: unsafe *Type) -> unsafe *Type {
        if t == &null {
            return &null
        }

        if t->canonical != &null {
            return t->canonical
        }

        return t
    }

    /// # The interface

    priv fn _vis(self, d: unsafe *Decl) -> string {
        var v = d->visibility
        if v == VisibilityKind::None {
            v = default_visibility_of(d)
        }

        return f"v{v as u8}"
    }

    /// Every name `dc` declares, each declaration under it, and the scopes
    /// those own. `ext` is the extended type when `dc` is an extension's.
    priv fn _scope(self, dc: unsafe *DeclContext, const scope: string, const ext: string) {
        if dc == &null || dc->dc_symbols == &null {
            return
        }

        var entries = cxx::std::vector<SymbolTable::Entry>()
        dc->dc_symbols->collect_entries(&entries)
        var names = cxx::std::vector<string>()
        for var i: usize = 0; i < entries.size(); ++i {
            var nm = incr_key_name(self.ctx, entries[i].name)
            names.push_back(nm.copy())
            var unsafe *cell = entries[i].cell
            if cell == &null {
                continue
            }

            for var j: usize = 0; j < cell->size(); ++j {
                var unsafe *d = cell->get(j)
                // A table can name a declaration of another file (a C++
                // binding); that file's interface lists it.
                if d == &null || NameLookup::ctx_of(d) != self.ctx {
                    continue
                }

                self._entry(d, scope, nm, ext)
                var unsafe *sub = NameLookup::context_of(d)
                // The implicit module shares the file's table: same scope.
                if sub != &null
                    && sub != dc
                    && sub->dc_symbols != dc->dc_symbols
                    && !isa<Declarations::ExtensionDecl>(d) {
                    self._scope(sub, self._id(d), "")
                }
            }
        }

        llvm::sort(names.begin(), names.end(), string_less)
        var s = "{\"scope\": " + incr_json(scope) + ", \"ext\": " + incr_json(
            ext,
        ) + ", \"names\": ["
        for var i: usize = 0; i < names.size(); ++i {
            if i > 0 {
                s += ", "
            }

            s += incr_json(names[i])
        }

        s += "]}"
        self._out->scopes.push_back(s)
        var pn = ""
        for var i: usize = 0; i < names.size(); ++i {
            if i > 0 {
                pn += "\x1f"
            }

            pn += names[i]
        }

        self._out->plain_scopes.push_back(scope.copy() + "\t" + ext + "\t" + pn)
    }

    /// Extensions are in no table (an `extend` has no name), so they are
    /// found the way MemberLookup indexes them: in declaration order, through
    /// modules, visibility groups and eval blocks.
    priv fn _extensions(self, dc: unsafe *DeclContext) {
        if dc == &null {
            return
        }

        for var i: usize = 0; i < dc->dc_decls.size(); ++i {
            var unsafe *d = *dc->dc_decls.get(i)
            if d != &null {
                self._extension_in(d)
            }
        }
    }

    priv fn _extension_in(self, d: unsafe *Decl) {
        if isa<Declarations::ExtensionDecl>(d) {
            var unsafe *e  = cast<Declarations::ExtensionDecl>(d)
            var        ext = "type:?"
            var unsafe *c  = self._canon(e->target)
            if c != &null {
                if isa<QualifiedType>(c) {
                    c = self._canon(cast<QualifiedType>(c)->inner)
                }

                // A record is extended by DECLARATION (`extend <T> Vec<T>`
                // adds to every Vec<X>), anything else by its exact type.
                if c != &null && isa<RecordType>(c) && cast<RecordType>(c)->decl != &null {
                    ext = self._id(cast<RecordType>(c)->decl)
                } else if c != &null {
                    ext = "type:" + self._tu.str(c)
                }
            }

            self._scope(unsafe (e as unsafe *DeclContext), self._id(d), ext)
            return
        }

        if isa<Declarations::ModuleDecl>(d) {
            self._extensions(
                unsafe (cast<Declarations::ModuleDecl>(d) as unsafe *DeclContext),
            )

            return
        }

        if isa<Declarations::VisibilityGroupDecl>(d) {
            var unsafe *g = cast<Declarations::VisibilityGroupDecl>(d)
            for var i: usize = 0; i < g->members.size(); ++i {
                if g->members[i] != &null {
                    self._extension_in(g->members[i])
                }
            }

            return
        }

        if isa<Declarations::EvalBlockDecl>(d) {
            var unsafe *b = cast<Declarations::EvalBlockDecl>(d)
            for var i: usize = 0; i < b->body.size(); ++i {
                if b->body[i] != &null {
                    self._extension_in(b->body[i])
                }
            }
        }
    }

    /// Where a function's body starts, or its end when it has none.
    priv fn _body_start(self, f: unsafe *Declarations::FunctionDecl) -> SourceLocation {
        if f->body_kind == Declarations::FnBodyKind::Block && f->body_block != &null {
            return f->body_block->range.start
        }

        if f->body_kind == Declarations::FnBodyKind::Expr && f->body_expr != &null {
            return f->body_expr->range.start
        }

        return f->range.end
    }

    /// A function's signature: its header as written (generic parameters and
    /// bounds, parameter names, modes and defaults, `requires`, the declared
    /// panic set), then what Sema resolved or inferred of it: each
    /// parameter's and the return's canonical type, the solved panic set,
    /// the modifiers and the generator bits.
    priv fn _fn_sig(self, f: unsafe *Declarations::FunctionDecl) -> string {
        var s = incr_norm(
            incr_text(self.ctx, f->range.start, self._body_start(f)),
        )

        s += f"|m{f->modifiers as u16}|k{f->body_kind as u8}|t{f->transfer as u8}|c{f->call_conv}"
        s += f"|g{f->is_generator as u8}{f->has_yield as u8}{f->is_noreturn as u8}{f->is_variadic as u8}{f->no_unwind as u8}"
        for var i: usize = 0; i < f->params.size(); ++i {
            var unsafe *p = f->params[i]
            if p == &null {
                continue
            }

            s += f"|p{p->mode as u8}{p->is_const as u8}:" + self._tstr(p->type_)
        }

        s += "|->" + self._tstr(f->return_type)
        s += f"|panic{f->panic_state as u8}"
        for var i: usize = 0; i < f->panic_set.size(); ++i {
            s += "," + self._tstr(f->panic_set[i])
        }

        s += "/"
        for var i: usize = 0; i < f->panic_eff.size(); ++i {
            s += "," + self._tstr(f->panic_eff[i])
        }

        return s
    }

    priv fn _fn_body(self, f: unsafe *Declarations::FunctionDecl) -> string {
        var at = self._body_start(f)
        var t  = incr_norm(incr_text(self.ctx, at, f->range.end))
        if t.size() == 0 {
            return ""
        }

        return incr_hash(t)
    }

    priv fn _field(self, fd: unsafe *Declarations::FieldDecl) -> string {
        return sema_dump_decl_name(self.ctx, fd) + "|" + self._vis(
            fd,
        ) + f"|s{fd->storage as u8}|" + incr_range_text(self.ctx, fd->range) + "|" + self._tstr(
            fd->type_,
        )
    }

    priv fn _edges(self,
                   const tag:    string,
                   @inout edges: FrozenList<Declarations::InheritEdge>) -> string {
        var s: string = ""
        for var i: usize = 0; i < edges.size(); ++i {
            var e = edges[i]
            s += "|" + tag + f"{e.visibility}{e.is_virtual as u8}:" + self._tstr(
                e.base,
            )
        }

        return s
    }

    /// A type's layout: everything an importer reads of it WITHOUT a name
    /// lookup in its scope. Generic parameters and bounds, bases and
    /// implemented interfaces, fields in order, variants with their folded
    /// values and payloads, and the members found by role and not by name
    /// (constructors, the destructor, operators, and methods that are pure
    /// virtual, defaulted or deleted). A method found by name is a name
    /// row's business and is not here: adding one must not invalidate every
    /// file that holds a value of the type.
    priv fn _layout(self, d: unsafe *Decl) -> string {
        var s: string = ""
        var gp        = decl_generic_params(d)
        for var i: usize = 0; i < gp.size(); ++i {
            if gp[i] != &null {
                s += "|g:" + incr_range_text(self.ctx, gp[i]->range)
            }
        }

        var unsafe *rq = decl_requires_clause(d)
        if rq != &null {
            s += "|rq:" + incr_range_text(self.ctx, rq->range)
        }

        var bases = decl_bases(d)
        s += self._edges("b", &bases)
        var fields  = decl_fields(d)
        var methods = decl_methods(d)
        if isa<Declarations::ClassDecl>(d) {
            var unsafe *c = cast<Declarations::ClassDecl>(d)
            s += self._edges("i", &c->implements)
            s += f"|cf{c->is_final as u8}{c->is_abstract as u8}"
        } else if isa<Declarations::StructDecl>(d) || isa<Declarations::UnionDecl>(d) {
            var impls = decl_implements(d)
            s += self._edges("i", &impls)
        } else if isa<Declarations::InterfaceDecl>(d) {
            // A requirement is read by every conformer, whether or not it
            // names it: all of them are layout.
            var unsafe *c = cast<Declarations::InterfaceDecl>(d)
            for var i: usize = 0; i < c->methods.size(); ++i {
                if c->methods[i] != &null {
                    s += "|r:" + self._fn_sig(c->methods[i])
                }
            }
        } else if isa<Declarations::EnumDecl>(d) {
            var unsafe *en = cast<Declarations::EnumDecl>(d)
            s += "|u:" + self._tstr(en->underlying) + f"|ef{en->is_adt as u8}{en->is_open as u8}"
            for var i: usize = 0; i < en->variants.size(); ++i {
                var unsafe *v = en->variants[i]
                if v == &null {
                    continue
                }

                s += "|v:" + self._variant(v)
            }
        }

        for var i: usize = 0; i < fields.size(); ++i {
            if fields[i] != &null {
                s += "|f:" + self._field(fields[i])
            }
        }

        for var i: usize = 0; i < methods.size(); ++i {
            var unsafe *m = methods[i]
            if m == &null {
                continue
            }

            var by_role = m->is_operator
                || m->body_kind == Declarations::FnBodyKind::Virtual
                || m->body_kind == Declarations::FnBodyKind::Default
                || m->body_kind == Declarations::FnBodyKind::Delete
                || sema_dump_decl_name(self.ctx, m) == sema_dump_decl_name(
                    self.ctx,
                    d,
                )

            if by_role {
                s += "|m:" + self._fn_sig(m)
            }
        }

        return s
    }

    priv fn _variant(self, v: unsafe *Declarations::EnumVariantDecl) -> string {
        var s = incr_range_text(
            self.ctx,
            v->range,
        ) + f"|{v->value.ok as u8}{v->value.neg as u8}:{v->value.mag}"
        for var i: usize = 0; i < v->payload.size(); ++i {
            if v->payload[i] != &null {
                s += "," + self._tstr(v->payload[i]->type_)
            }
        }

        return s
    }

    /// One exported declaration: its row in the interface.
    priv fn _entry(self,
                   d:           unsafe *Decl,
                   const scope: string,
                   const name:  string,
                   const ext:   string) {
        self._refs.clear()
        var kind         = sema_dump_kind_str(d->kind)
        var facts        = kind.copy() + "|" + name + "|" + self._vis(d)
        var body: string = ""
        if isa<Declarations::FunctionDecl>(d) {
            var unsafe *f = cast<Declarations::FunctionDecl>(d)
            facts += "|" + self._fn_sig(f)
            body = self._fn_body(f)
            // `inline` asks every importer to compile the body: it is
            // interface, whoever calls it.
            if ((f->modifiers as u16) & (Declarations::FnModifier::IsInline as u16)) != 0 {
                facts += "|inline:" + body
            }
        } else if isa<Declarations::VariableDecl>(d) {
            // The initializer is in the text: an importer folds a constant
            // through it.
            var unsafe *v = cast<Declarations::VariableDecl>(d)
            facts += f"|s{v->storage as u8}{v->const_binding as u8}|" + incr_range_text(
                self.ctx,
                v->range,
            ) + "|" + self._tstr(v->type_)
        } else if isa<Declarations::FieldDecl>(d) {
            facts += "|" + self._field(cast<Declarations::FieldDecl>(d))
        } else if isa<Declarations::EnumVariantDecl>(d) {
            facts += "|" + self._variant(cast<Declarations::EnumVariantDecl>(d))
        } else if isa<Declarations::TypeAliasDecl>(d) {
            var unsafe *a = cast<Declarations::TypeAliasDecl>(d)
            facts += "|" + incr_range_text(self.ctx, a->range) + "|" + self._tstr(
                a->aliased,
            )
        } else if !isa<Declarations::ModuleDecl>(d) {
            facts += self._layout(d)
        }

        var id = self._id(d)
        var ih = incr_hash(facts)
        var row = "{\"id\": " + incr_json(id) + ", \"scope\": " + incr_json(
            scope,
        ) + ", \"name\": " + incr_json(name) + ", \"kind\": " + incr_json(
            kind,
        ) + ", \"I\": " + incr_json(ih) + ", \"body\": " + incr_json(body)
        if ext.size() > 0 {
            row += ", \"ext\": " + incr_json(ext)
        }

        llvm::sort(self._refs.begin(), self._refs.end(), string_less)
        row += ", \"refs\": ["
        var last:  string = ""
        var first         = true
        var prefs: string = ""
        for var i: usize = 0; i < self._refs.size(); ++i {
            if self._refs[i] == last || self._refs[i] == id {
                continue
            }

            last = self._refs[i].copy()
            if !first {
                row += ", "
                prefs += "\x1f"
            }

            first = false
            row += incr_json(last)
            prefs += last
        }

        self._out->decls.push_back(row.copy() + "]}")
        self._out->plain_decls.push_back(
            id.copy() + "\t" + scope + "\t" + name + "\t" + ih + "\t" + body + "\t" + ext + "\t" + prefs,
        )

        self._lines.push_back(id.copy() + "\t" + ih + "\t" + body)
    }

    /// # Declaration rows, from the checked tree

    priv fn _row(self, const part: string, d: unsafe *Decl) {
        if d == &null {
            return
        }

        var unsafe *dctx = NameLookup::ctx_of(d)
        if dctx == &null || dctx == self.ctx || dctx->tu == &null || dctx->tu->is_foreign {
            return
        }

        var k = part.copy() + "\t" + self._id(d)
        if self._rows.count(kairo::sref(k)) > 0 {
            return
        }

        self._rows.try_emplace(kairo::sref(k), (1 as u8))
        self._out->rows.push_back(k)
    }

    /// A value of a type is a read of the type's layout: its size, whether
    /// it copies, what initializes it, which variants a match must cover.
    priv fn _note_type(self, t: unsafe *Type) {
        if t == &null {
            return
        }

        var decls = cxx::std::vector<unsafe *Decl>()
        incr_type_records(t, 0, unsafe &decls)
        for var i: usize = 0; i < decls.size(); ++i {
            self._row("layout", decls[i])
        }
    }

    /// A resolved reference reads the declaration's signature, and its body
    /// when an importer compiles the body: a generic, a member of a generic
    /// type, an `inline` or `eval` function.
    priv fn _note_decl(self, d: unsafe *Decl) {
        if d == &null {
            return
        }

        self._row("sig", d)
        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(d)
        if f == &null {
            return
        }

        var m = f->modifiers as u16
        var reads = (Declarations::FnModifier::IsInline as u16) | (Declarations::FnModifier::IsEval as u16) | (Declarations::FnModifier::IsConstexpr as u16)
        if (m & reads) != 0
            || decl_generic_params(d).size() > 0
            || decl_in_generic_owner(d)
            || decl_is_instance(d) {
            self._row("body", d)
        }
    }

    fn visit_type(self, n: unsafe *Type) -> bool {
        self._note_type(n)
        return true
    }

    fn visit_expr(self, n: unsafe *Expr) -> bool {
        if n != &null {
            self._note_type(n->type_)
        }

        return true
    }

    fn visit_decl(self, n: unsafe *Decl) -> bool {
        if n == &null {
            return true
        }

        // The inferred slots hold canonical nodes no type walk reaches.
        if isa<Declarations::VariableDecl>(n) {
            self._note_type(cast<Declarations::VariableDecl>(n)->type_)
        } else if isa<Declarations::FunctionDecl>(n) {
            self._note_type(cast<Declarations::FunctionDecl>(n)->return_type)
        }

        return true
    }

    fn visit_named_ident_expr(self, n: unsafe *NamedIdentExpr) -> bool {
        if n != &null {
            self._note_decl(n->resolved_decl)
            self._note_decl(n->variant_decl)
        }

        return true
    }

    fn traverse_chain_expr(self, n: unsafe *ChainExpr) -> unsafe *ChainExpr {
        if n == &null {
            return n
        }

        var unsafe *out = RecursiveASTVisitor<IncrFacts>::traverse_chain_expr(
            self,
            n,
        )

        for var i: usize = 0; i < n->steps.size(); ++i {
            var unsafe *st = n->steps.get(i)
            if st == &null {
                continue
            }

            self._note_decl(st->resolved_decl)
            self._note_type(st->resolved_type)
        }

        return out
    }
}

/// # A file's dependency rows

/// One file's resolved dependency log, as the strings --dump-deps
/// prints. Everything is sorted and unique.
pub class FileDeps {
    /// `{"module", "scope", "name"}` objects: a lookup that consulted that
    /// scope of that file, found or not.
    pub var names: cxx::std::vector<string>
    /// `names` again as `<module>\t<scope>\t<name>`, for a plan record.
    pub var plain_names: cxx::std::vector<string>
    /// Overlay probes: `<module of the overlay's file>\t<name>`. The overlay
    /// of a file stands for the file scope of every file in its `surface`.
    pub var overlay: cxx::std::vector<string>
    /// `<part>\t<DeclId>` rows the hooks logged (bodies).
    pub var rows: cxx::std::vector<string>
    /// The modules whose file scopes this file's overlay folds: its imports,
    /// and what they re-export, transitively.
    pub var surface: cxx::std::vector<string>
}

fn _incr_unique(@inout v: cxx::std::vector<string>) {
    llvm::sort(v.begin(), v.end(), string_less)
    var out = cxx::std::vector<string>()
    for var i: usize = 0; i < v.size(); ++i {
        if i == 0 || v[i] != v[i - 1] {
            out.push_back(v[i].copy())
        }
    }

    v = out
}

fn _incr_name_row(const mod_name: string, const scope: string, const name: string) -> string {
    return "{\"module\": " + incr_json(mod_name) + ", \"scope\": " + incr_json(
        scope,
    ) + ", \"name\": " + incr_json(name) + "}"
}

/// The files whose file scope `tu`'s overlay can hold names of: everything
/// it imports, and from there on only what is re-exported.
fn _incr_surface(tu:   unsafe *TranslationUnit,
                 g:    unsafe *GlobalDisambigTable,
                 psym: unsafe *PreprocessorSymbolTable,
                 out:  unsafe *cxx::std::vector<string>) {
    var seen  = llvm::DenseSet<u64>()
    var work  = cxx::std::vector<unsafe *TranslationUnit>()
    var first = true
    work.push_back(tu)
    seen.insert(tu as usize as u64)
    while work.size() > 0 {
        var unsafe *cur = work.back()
        work.pop_back()
        var fids = cxx::std::vector<u32>()
        for var i: usize = 0; i < cur->import_edges.size(); ++i {
            var unsafe *e = cur->import_edges.get(i)
            if first || e->decl == &null || e->decl->is_public() || e->decl->is_protected() {
                fids.push_back(e->target_fid)
            }
        }

        for var i: usize = 0; i < cur->imports.size(); ++i {
            var unsafe *imp = dyn_cast<Declarations::ImportDecl>(
                *cur->imports.get(i),
            )

            if imp == &null || imp->resolved_fid == 0 {
                continue
            }

            if first || imp->is_public() || imp->is_protected() || imp->is_prelude {
                fids.push_back(imp->resolved_fid)
            }
        }

        first = false
        for var i: usize = 0; i < fids.size(); ++i {
            var unsafe *c = g->get_context(fids[i])
            if c == &null || c->tu == &null || c->tu->is_foreign {
                continue
            }

            if seen.contains(c->tu as usize as u64) {
                continue
            }

            seen.insert(c->tu as usize as u64)
            work.push_back(c->tu)
            out->push_back(incr_module(c, psym))
        }
    }

    _incr_unique(&*out)
}

/// Turns `tu`'s raw DepLog into rows. `overlays` maps an overlay's address
/// to the TU it belongs to (the log holds the address only).
pub fn incr_resolve_deps(tu:       unsafe *TranslationUnit,
                         g:        unsafe *GlobalDisambigTable,
                         psym:     unsafe *PreprocessorSymbolTable,
                         overlays: unsafe *llvm::DenseMap<u64, unsafe *TranslationUnit>,
                         out:      unsafe *FileDeps) {
    if tu == &null || out == &null {
        return
    }

    _incr_surface(tu, g, psym, unsafe &out->surface)
    var unsafe *log = tu->dep_log
    if log == &null {
        return
    }

    for var i: usize = 0; i < log->tables.size(); ++i {
        var unsafe *tbl = unsafe (log->tables[i] as usize as unsafe *SymbolTable)
        var unsafe *dc  = unsafe (tbl->dep_scope as unsafe *DeclContext)
        var unsafe *src = NameLookup::tu_of(dc)
        // A C++ header's scope: a header is keyed by its own hash, whole.
        if src == &null || src == tu || src->is_foreign {
            continue
        }

        var key  = log->table_keys[i]
        var name = DeclName::ident(0)
        name.kind    = (((key >> 32 & 0xFF) as u8) as DeclNameKind)
        name.payload = ((key & 0xFFFFFFFF) as u32)
        out->names.push_back(
            _incr_name_row(
                incr_module(src->ctx, psym),
                incr_scope_id(dc, psym),
                incr_key_name(src->ctx, name),
            ),
        )

        out->plain_names.push_back(
            incr_module(src->ctx, psym) + "\t" + incr_scope_id(dc, psym) + "\t" + incr_key_name(
                src->ctx,
                name,
            ),
        )
    }

    for var i: usize = 0; i < log->spelled_tables.size(); ++i {
        var unsafe *tbl = unsafe (log->spelled_tables[i] as usize as unsafe *SymbolTable)
        var unsafe *dc  = unsafe (tbl->dep_scope as unsafe *DeclContext)
        var unsafe *src = NameLookup::tu_of(dc)
        if src == &null || src == tu || src->is_foreign {
            continue
        }

        out->names.push_back(
            _incr_name_row(
                incr_module(src->ctx, psym),
                incr_scope_id(dc, psym),
                log->spelled_names[i],
            ),
        )

        out->plain_names.push_back(
            incr_module(src->ctx, psym) + "\t" + incr_scope_id(
                dc,
                psym,
            ) + "\t" + log->spelled_names[i],
        )
    }

    for var i: usize = 0; i < log->overlays.size(); ++i {
        var it = overlays->find(log->overlays[i])
        if it == overlays->end() {
            continue
        }

        var unsafe *home = it->second
        if home == &null || home->ctx == &null || home->import_overlay == &null {
            continue
        }

        var unsafe *imms = home->ctx->get_imm_table()
        var        key   = (log->overlay_keys[i] & 0xFFFFFFFF) as u32
        if imms == &null || key == u32::MAX {
            continue
        }

        out->overlay.push_back(
            incr_module(home->ctx, psym) + "\t" + imms->get_ident(key),
        )

        // A hit also reads what it found, under the DECLARED name: the key
        // may be an import alias, which the sources' name sets do not hold.
        var unsafe *cell = home->import_overlay->lookup_ident(key)
        if cell == &null {
            continue
        }

        for var j: usize = 0; j < cell->size(); ++j {
            var unsafe *d    = cell->get(j)
            var unsafe *dctx = NameLookup::ctx_of(d)
            if d == &null
                || dctx == &null
                || dctx->tu == &null
                || dctx->tu == tu
                || dctx->tu->is_foreign {
                continue
            }

            var unsafe *sdc = d->semantic_dc
            if sdc == &null {
                sdc = d->lexical_dc
            }

            out->names.push_back(
                _incr_name_row(
                    incr_module(dctx, psym),
                    incr_scope_id(sdc, psym),
                    incr_decl_key_name(dctx, d),
                ),
            )

            out->plain_names.push_back(
                incr_module(dctx, psym) + "\t" + incr_scope_id(
                    sdc,
                    psym,
                ) + "\t" + incr_decl_key_name(dctx, d),
            )
        }
    }

    for var i: usize = 0; i < log->bodies.size(); ++i {
        var unsafe *d    = unsafe (log->bodies[i] as usize as unsafe *Decl)
        var unsafe *dctx = NameLookup::ctx_of(d)
        if dctx == &null || dctx->tu == &null || dctx->tu == tu || dctx->tu->is_foreign {
            continue
        }

        out->rows.push_back("body\t" + incr_decl_id(d, psym))
    }

    _incr_unique(&out->names)
    _incr_unique(&out->plain_names)
    _incr_unique(&out->overlay)
    _incr_unique(&out->rows)
}
