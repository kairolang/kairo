/// --- The Kairo Project ---------------------- Analyzer/Index/Tables.k --- ///
///
///   Declaration tables and scope rows: what completion is answered from.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


import Index::Snapshot::*
import Protocol::*
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::ImportOverlay::{
    ImportOverlay,
    OverlayVisibility,
}
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::SymbolTable::{
    DeclName,
    OverloadCell,
    SymbolTable,
}
import AST::Context::TranslationUnit::TranslationUnit
import AST::Mixin::Annotation::VisibilityKind
import AST::VisibilityFacts::{
    default_visibility_of,
    tu_module_dir,
}
import AST::DeclFacts::{
    decl_extension_of,
    decl_is_ffi,
    decl_name_tok,
    decl_requires_clause,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinType,
    RecordType,
    canon_unqual,
}
import Index::Primitives::primitive_spelling
import AST::Node::Casting::{
    cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Program::TopLevelKind
import AST::Node::Types
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import Diagnostic::Engine::DiagEngine
import DocumentStore::{
    LineMap,
    fnv1a,
}
import Json::JsonWriter
import Lexer::Immediate::ImmediateTable
import Lexer::Lexer::Lexer
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Sema::Resolve::AccessCheck::AccessCheck
import Sema::Resolve::NameLookup::NameLookup
import Sema::SemaContext::{
    SemaContext,
    SemaPhase,
}
import Sema::SemaDump::sema_dump_decl_name
import Sema::Type::TypeUtil::TypeUtil
import Token::Token::Token
import Token::TokenText::TokenText
import Token::TokenKind::{
    TokenKind,
    is_keyword,
}
import Index::Bases::*
import Index::CompletionItems::*
import Index::Hovers::*
import Index::Indexer::*
import Index::Legend::*
import Index::Macros::*
import Index::Refs::*
import Index::Tokens::*
import Index::Writer::*

extend IndexWalker {
    // The tables are what completion is answered from with no compile
    // (LanguageServer.md section 8): one per file of the graph, the file's
    // own declarations with what each needs to be offered (kind, signature,
    // visibility) and followed (the record its type is). A file's block
    // adds what its imports bring in (`scope`) and whose extensions it sees
    // (`sees`): the two things that depend on WHO asks. Rows name each
    // other by file and byte offset of the declared name, which costs no
    // line map of the other file.

    /// Index of \p fid among the files this table's rows name.
    fn tfile_(self, fid: u32) -> i64 {
        for var i: usize = 0; i < self.t_fids_.size(); ++i {
            if self.t_fids_[i] == fid {
                return i as i64
            }
        }

        self.t_fids_.push_back(fid)
        return (self.t_fids_.size() - 1) as i64
    }

    /// \p d's visibility as a VIS_* word, the default applied: as
    /// AccessCheck reads it (its own reading, `visibility_of`).
    fn vis_of_(self, d: unsafe *Decl) -> i64 {
        var v = d->visibility
        if self.t_ac_ != &null {
            v = self.t_ac_->visibility_of(d)
        } else if v == VisibilityKind::None {
            v = default_visibility_of(d)
        }

        if v == VisibilityKind::Private {
            return VIS_PRIV
        }

        if (v == VisibilityKind::Protected) || (v == VisibilityKind::Internal) {
            return VIS_PROT
        }

        return VIS_PUB
    }

    /// Whether the walk has written \p d already: a method is in its
    /// class's typed list and in its DeclContext.
    fn t_once_(self, d: unsafe *Decl) -> bool {
        var key = (d as usize) as u64
        if self.t_seen_.get(key) != null {
            return false
        }

        self.t_seen_[key] = 1
        return true
    }

    /// Where record \p td is declared, as a table key. False for none.
    fn t_key_(self, td: unsafe *Decl, fi: *i64, off: *i64) -> bool {
        if td == &null {
            return false
        }

        var tn = decl_name_tok(td).range
        if !tn.start.is_valid() {
            return false
        }

        var res = self.sm->resolve(tn.start)
        (*fi)  = self.tfile_(res.fid as u32)
        (*off) = res.offset as i64
        return true
    }

    fn t_put_(self,
              w:            *JsonWriter,
              const name:   string,
              kind:         i64,
              parent:       i64,
              off:          i64,
              vis:          i64,
              flags:        i64,
              const detail: string,
              tfi:          i64,
              toff:         i64,
              efi:          i64,
              eoff:         i64) -> i64 {
        var line: usize = 0
        var ch:   usize = 0
        if off >= 0 {
            line = self.files[0].lines.line_of(off as usize)
            ch   = self.files[0].lines.character(self.files[0].text, off as usize, false)
        }

        // the DC_* columns of Snapshot.k, in that order
        w->begin_array()
        w->str(name)
        w->integer(kind)
        w->integer(parent)
        w->integer(off)
        w->uint(line)
        w->uint(ch)
        w->integer(vis)
        w->integer(flags)
        w->str(detail)
        w->integer(tfi)
        w->integer(toff)
        w->integer(efi)
        w->integer(eoff)
        w->end_array()
        self.t_count_ += 1
        return self.t_count_ - 1
    }

    /// The spelling of the primitive an `extend` block's target is
    /// (`i32`), "" for anything else (a record, `[T]`, `T?`, a pointer).
    fn ext_primitive_(self, t_in: unsafe *Type) -> string {
        if t_in == &null {
            return ""
        }

        var unsafe *t = t_in
        if t->canonical != &null {
            t = t->canonical
        }

        t = canon_unqual(t)
        if (t == &null) || (!isa<BuiltinType>(t)) {
            return ""
        }

        return primitive_spelling(cast<BuiltinType>(t)->builtin)
    }

    /// One declaration's row, and under it what it declares. -1: no row.
    fn t_decl_(self, w: *JsonWriter, d: unsafe *Decl, parent: i64, depth: u32) -> i64 {
        if (d == &null) || (depth > 6) || (!self.t_once_(d)) {
            return -1
        }

        if isa<Declarations::ExtensionDecl>(d) {
            var unsafe *e = cast<Declarations::ExtensionDecl>(d)
            var tfi:  i64 = -1
            var toff: i64 = -1
            self.t_key_(self.type_decl_(e->target, 0), &tfi, &toff)
            // A primitive has no record to point at (`extend i32`): the
            // row's detail spells it, which is how `i32::` finds the
            // block's statics (P1004).
            var row = self.t_put_(w, "", 0, parent, -1, VIS_PUB, DF_EXT, self.ext_primitive_(e->target), tfi, toff, -1, -1)
            for var i: usize = 0; i < e->methods.size(); ++i {
                self.t_decl_(w, unsafe (e->methods[i] as unsafe *Decl), row, depth + 1)
            }

            return row
        }

        if d->is_implicit {
            return -1
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx == &null {
            ctx = self.ast_()
        }

        var name = sema_dump_decl_name(ctx, d)
        if name.empty() || name.starts_with("op ") || (name == completion_marker()) {
            return -1
        }

        // Another FILE, bound here as the module it is (`pub import io` in
        // a module.k): the row names the file.
        var unsafe *mctx = NameLookup::ctx_of(d)
        if isa<Declarations::ModuleDecl>(d) && (mctx != &null) && (mctx->tu != &null)
            && (unsafe (mctx->tu->module_self as unsafe *Decl) == d) {
            if mctx->fid == self.fid {
                return -1
            }

            return self.t_put_(w, name, CIK_MODULE, parent, -1, VIS_PUB, DF_ALIAS | DF_SCOPE, "", self.tfile_(mctx->fid), -1, -1, -1)
        }

        var tok = decl_name_tok(d).range
        if !tok.start.is_valid() {
            return -1
        }

        var res  = self.sm->resolve(tok.start)
        var kind = self.item_kind_(d) as i64
        if (res.fid as u32) != self.fid {
            // Bound in this file, declared in another (what an import
            // leaves in the file's own context): the row names it there.
            return self.t_put_(w, name, kind, parent, -1, VIS_PUB, DF_ALIAS, "", self.tfile_(res.fid as u32), res.offset as i64, -1, -1)
        }

        var flags: i64 = DF_STATIC
        if isa<Declarations::FunctionDecl>(d) {
            if cast<Declarations::FunctionDecl>(d)->is_method() {
                flags = DF_METHOD
            }
        } else if isa<Declarations::FieldDecl>(d) {
            if !cast<Declarations::FieldDecl>(d)->is_static() {
                flags = 0
            }
        }

        var unsafe *dc = self.context_of_decl_(d)
        if dc != &null {
            flags = flags | DF_SCOPE
        }

        var tfi:  i64 = -1
        var toff: i64 = -1
        self.t_key_(self.type_decl_(self.value_type_(d), 0), &tfi, &toff)
        var efi:  i64 = -1
        var eoff: i64 = -1
        self.t_key_(self.type_decl_(self.elem_type_(self.value_type_(d)), 0), &efi, &eoff)
        var kids: [unsafe *Decl]
        if dc != &null {
            self.own_members_(d, &kids)
            // A type's row: what a subscript of a value of it is, the
            // record its `op []` overloads agree on (P1002). Their rows are
            // not in the table (no completion offers an operator).
            var seen = false
            for var i: usize = 0; i < kids.size(); ++i {
                if (!isa<Declarations::FunctionDecl>(kids[i])) || (sema_dump_decl_name(ctx, kids[i]) != "op []") {
                    continue
                }

                var ofi:  i64 = -1
                var ooff: i64 = -1
                self.t_key_(self.type_decl_(cast<Declarations::FunctionDecl>(kids[i])->return_type, 0), &ofi, &ooff)
                if !seen {
                    efi  = ofi
                    eoff = ooff
                    seen = true
                } else if (ofi != efi) || (ooff != eoff) {
                    efi  = -1
                    eoff = -1
                }
            }
        }

        var row = self.t_put_(w, name, kind, parent, res.offset as i64, self.vis_of_(d), flags, self.signature_(d), tfi, toff, efi, eoff)
        if dc == &null {
            return row
        }

        for var i: usize = 0; i < kids.size(); ++i {
            self.t_decl_(w, kids[i], row, depth + 1)
        }

        if isa<Declarations::ClassDecl>(d) {
            var unsafe *c = cast<Declarations::ClassDecl>(d)
            for var i: usize = 0; i < c->derives_list.size(); ++i {
                var bfi:  i64 = -1
                var boff: i64 = -1
                if self.t_key_(self.type_decl_(c->derives_list[i].base, 0), &bfi, &boff) {
                    self.t_bases_.push_back(row)
                    self.t_bases_.push_back(bfi)
                    self.t_bases_.push_back(boff)
                    self.t_bases_.push_back(c->derives_list[i].visibility as i64)
                }
            }
        }

        return row
    }

    /// `macro name!(a, b = d, ...rest)`: its row, the invocation as its detail.
    fn t_macro_(self, w: *JsonWriter, d: unsafe *Decl) {
        if (d == &null) || (!isa<Declarations::MacroDecl>(d)) || (!self.t_once_(d)) {
            return
        }

        var unsafe *m = cast<Declarations::MacroDecl>(d)
        var off = self.own_off_(m->name.range.start)
        var name = self.ast_()->get_spelling(m->name)
        if name.ends_with("!") {
            name = name.subslice(0, name.size() - 1)
        }

        if (off == u32::MAX) || name.empty() {
            return
        }

        var use = name + "!"
        if m->accepts_params {
            use += "("
            for var i: usize = 0; i < m->params_spec.size(); ++i {
                if i > 0 {
                    use += ", "
                }

                var unsafe *p = m->params_spec.get(i)
                if p->variadic != 0 {
                    use += "..."
                }

                use += self.ast_()->get_spelling(p->name)
            }

            use += ")"
        }

        var vis = VIS_PUB
        if d->visibility == VisibilityKind::Private {
            vis = VIS_PRIV
        } else if d->visibility == VisibilityKind::Protected {
            vis = VIS_PROT
        }

        self.t_put_(w, name, CIK_SNIPPET, -1, off as i64, vis, DF_MACRO | DF_STATIC, use, -1, -1, -1, -1)
    }

    /// Builds `table`: this file's declarations (Snapshot.k, DC_* / TB_*).
    fn build_table_(self) {
        var unsafe *tu = self.sc->tu
        var ac = AccessCheck(self.sc)
        self.t_ac_ = unsafe &ac
        finally {
            self.t_ac_ = &null
        }

        var w = JsonWriter()
        w.begin_object()
        w.field(SK_PATH, self.files[0].path)
        w.field(SK_MOD, tu_module_dir(tu))
        w.field_bool(SK_BUILTIN, (self.sc->g != &null) && self.sc->g->is_builtin_fid(self.fid))
        w.key(SK_DECLS)
        w.begin_array()
        // Macros first: one that is also among the items is then a macro row.
        for var i: usize = 0; i < tu->macros.size(); ++i {
            self.t_macro_(&w, *tu->macros.get(i))
        }

        var all: [unsafe *Decl]
        self.tu_decls_(tu, &all)
        for var i: usize = 0; i < all.size(); ++i {
            self.t_decl_(&w, all[i], -1, 0)
        }

        w.end_array()
        w.key(SK_TBASES)
        w.begin_array()
        var b: usize = 0
        while (b + 3) < self.t_bases_.size() {
            w.begin_array()
            w.integer(self.t_bases_[b])
            w.integer(self.t_bases_[b + 1])
            w.integer(self.t_bases_[b + 2])
            w.integer(self.t_bases_[b + 3])
            w.end_array()
            b += 4
        }

        w.end_array()
        w.key(SK_FILES)
        w.begin_array()
        for var i: usize = 0; i < self.t_fids_.size(); ++i {
            w.str(self.sm->get_filename(self.t_fids_[i]))
        }

        w.end_array()
        w.end_object()
        self.table = w.out
    }

    /// A walk for the table alone: a file outside the indexed root (the
    /// library) has no rows of its own to ask about, but its types are the
    /// receivers and its names the candidates.
    pub fn run_table(self, fid: u32) {
        self.fid = fid
        var unsafe *tu = self.sc->tu
        if (tu == &null) || tu->is_foreign {
            return
        }

        self.file_(fid)
        self.build_table_()
    }

    /// What a scope row says of \p d (Snapshot.k, ScopeFact): the same for
    /// every file that imports it.
    fn scope_fact_(self, d: unsafe *Decl) -> ScopeFact {
        var f = ScopeFact{}
        if d->is_implicit {
            return f
        }

        var unsafe *ctx = NameLookup::ctx_of(d)
        if ctx != &null {
            f.home = ctx->fid
        } else {
            ctx = self.ast_()
        }

        f.name = sema_dump_decl_name(ctx, d)
        if f.name.empty() || f.name.starts_with("op ") || (f.name == completion_marker()) {
            return f
        }

        f.ok   = true
        f.kind = self.item_kind_(d)
        // A file IS a module: the name stands for the file.
        var unsafe *mctx = NameLookup::ctx_of(d)
        if isa<Declarations::ModuleDecl>(d) && (mctx != &null) && (mctx->tu != &null)
            && (unsafe (mctx->tu->module_self as unsafe *Decl) == d) {
            f.fid = mctx->fid
            f.off = -1
            return f
        }

        var tok = decl_name_tok(d).range
        if tok.start.is_valid() {
            var res = self.sm->resolve(tok.start)
            f.fid = res.fid as u32
            f.off = res.offset as i64
        }

        // No table has a C or C++ declaration: its row says what it is.
        if decl_is_ffi(d) || (!tok.start.is_valid()) || ((mctx != &null) && (mctx->tu != &null) && mctx->tu->is_foreign) {
            f.detail = self.signature_(d)
        }

        return f
    }

    /// One name the overlay brings in, as a scope row. The filters are
    /// item_'s: the same names are offered whichever way the list is made.
    fn scope_row_(self, d: unsafe *Decl, sort: u32) {
        if d == &null {
            return
        }

        var f = ScopeFact{}
        var key = (d as usize) as u64
        var loc = decl_name_tok(d).range.start.id
        var tag = (d->kind as u8) as u32
        if (self.facts == &null) || (!self.facts->get(key, loc, tag, &f)) {
            f = self.scope_fact_(d)
            f.loc = loc
            f.tag = tag
            if self.facts != &null {
                self.facts->put(key, f)
            }
        }

        if !f.ok {
            return
        }

        if (f.name.starts_with("_") || f.name.ends_with("_")) && (f.home != self.fid) {
            return
        }

        // One row per name, the first: by the name's hash, then the name.
        var h   = fnv1a(f.name)
        var hit = self.scope_seen_.get(h)
        if hit != null {
            if self.scope_rows[(*hit) as usize].name == f.name {
                return
            }

            for var i: usize = 0; i < self.scope_rows.size(); ++i {
                if self.scope_rows[i].name == f.name {
                    return
                }
            }
        }

        var r = ScopeRow{}
        r.name   = f.name
        r.kind   = f.kind
        r.sort   = sort
        r.off    = f.off
        r.detail = f.detail
        if f.fid != u32::MAX {
            r.file = self.sfile_(f.fid)
        }

        if hit == null {
            self.scope_seen_[h] = self.scope_rows.size() as u32
        }

        self.scope_rows.push_back(r)
    }

    /// Builds `scope_rows` and `sees`: what depends on the file that asks.
    fn build_scope_(self) {
        var unsafe *tu = self.sc->tu
        if tu->import_overlay != &null {
            self.overlay_rows_(tu, false)
        }

        if self.sc->g == &null {
            return
        }

        // Every Kairo file it sees, whether or not the file has an
        // `extend` block today (the tables say which do): the list is then
        // the same for a first check and for a re-check in place. In the
        // order of the paths' hashes, which no load order changes.
        var paths: [string]
        var keys:  [u64]
        var fids = self.sc->g->all_fids()
        for var i: usize = 0; i < fids.size(); ++i {
            var f = fids[i]
            if (f == self.fid) || self.sc->g->is_builtin_fid(f) {
                continue // every file sees its own and the builtin library's
            }

            var unsafe *ctx = self.sc->g->get_context(f)
            if (ctx == &null) || (ctx->tu == &null) || ctx->tu->is_foreign {
                continue
            }

            if self.sc->sees_extension_file(f) {
                var path = self.sm->get_filename(f)
                keys.push_back((fnv1a(path) << 16) | ((paths.size() as u64) & 0xFFFF))
                paths.push_back(path)
            }
        }

        sort_u64(&keys)
        for var i: usize = 0; i < keys.size(); ++i {
            self.sees.push_back(paths[(keys[i] & 0xFFFF) as usize])
        }
    }

    /// Index of \p fid among the files the scope rows name.
    fn sfile_(self, fid: u32) -> i64 {
        for var i: usize = 0; i < self.scope_fids_.size(); ++i {
            if self.scope_fids_[i] == fid {
                return i as i64
            }
        }

        self.scope_fids_.push_back(fid)
        self.scope_files.push_back(self.sm->get_filename(fid))
        return (self.scope_fids_.size() - 1) as i64
    }

    /// Writes the block's scope members (Snapshot.k, SCOPE_*).
    fn write_scope_(self, w: *JsonWriter) {
        w->key(SK_SCOPE)
        w->begin_array()
        for var i: usize = 0; i < self.scope_rows.size(); ++i {
            var *r = &self.scope_rows[i]
            w->begin_array()
            w->str(r->name)
            w->uint(r->kind as usize)
            w->uint(r->sort as usize)
            w->integer(r->file)
            w->integer(r->off)
            if !r->detail.empty() {
                w->str(r->detail)
            }

            w->end_array()
        }

        w->end_array()
        w->key(SK_SFILES)
        w->begin_array()
        for var i: usize = 0; i < self.scope_files.size(); ++i {
            w->str(self.scope_files[i])
        }

        w->end_array()
        w->key(SK_SEES)
        w->begin_array()
        for var i: usize = 0; i < self.sees.size(); ++i {
            w->str(self.sees[i])
        }

        w->end_array()
    }
}
