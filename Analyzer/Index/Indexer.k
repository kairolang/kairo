/// --- The Kairo Project ---------------------- Analyzer/Index/Indexer.k --- ///
///
///   Turns one type-checked file into what an editor asks for.
///
///   Runs inside the compiler, at SemaPhase::Checked (Tooling/SemaObserver.k):
///   names and types are resolved and the tree is still the one the user
///   wrote. One walk produces, for one file:
///
///     tokens   semantic highlighting, already delta-encoded for LSP
///     refs     every name use and declaration -> where it is declared, with
///              the hover text; definition, hover, highlight, references and
///              rename all read this one table
///     symbols  the outline
///     inlays   the types of declarations that did not spell one
///     items    completion items, when the buffer carries a completion marker
///
///   EVERYTHING LEAVES IN LSP COORDINATES (0-based line, UTF-16 column). The
///   server never converts a position on the way out; it only looks rows up.
///
///   RANGES COME FROM NAME TOKENS, never from node ranges: a node's range is
///   not faithful to its text (P534), a name token's is.
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
import AST::AttrFacts::AttrFacts
import AST::DeclFacts::{
    decl_extension_of,
    decl_is_ffi,
    decl_pattern,
    decl_name_tok,
    decl_requires_clause,
}
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    RecordType,
    canon_unqual,
}
import AST::Node::Casting::{
    cast,
    dyn_cast,
    isa,
}
import AST::Node::Declarations
import AST::Node::Expressions
import AST::Node::PrimaryExpressions::{
    ChainExpr,
    NamedIdentExpr,
}
import AST::Node::Patterns::BindingPattern
import AST::Node::Program::TopLevelKind
import AST::Node::Statements
import AST::Node::Types
import AST::OperatorFacts::OperatorFacts
import AST::Visitor::RecursiveASTVisitor::RecursiveASTVisitor
import AST::LangItems::LangAttrs
import Diagnostic::Engine::DiagEngine
import DocumentStore::LineMap
import Json::JsonWriter
import Lexer::Immediate::ImmediateTable
import Lexer::Lexer::Lexer
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Sema::Resolve::AccessCheck::AccessCheck
import Sema::Resolve::MemberLookup::MemberLookup
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
import Index::Inlays::*
import Index::Legend::*
import Index::Macros::*
import Index::Refs::*
import Index::Tables::*
import Index::Tokens::*
import Index::Writer::*

/// \class IndexWalker
/// \brief the walk over one TU.
pub class IndexWalker derives RecursiveASTVisitor<IndexWalker> {
    pub var sc:  unsafe *SemaContext
    pub var sm:  unsafe *SourceManager
    pub var fid: u32 = u32::MAX

    pub var toks:   [SemTok]
    pub var refs:   [RefRow]
    pub var syms:   [SymRow]
    pub var inlays: [InlayRow]
    pub var items:  [ItemRow]
    pub var hovers: [string]
    pub var links:  [LinkRow]
    pub var bases:  [BaseRow]

    /// A marker was found: `items` is the answer to a completion request.
    pub var completed: bool = false

    /// Files rows point into, the indexed file first.
    pub var files: [FileText]

    /// decl address -> index into `hovers`: a declaration's hover is built
    /// once however many times it is used.
    var hover_of_: {u64: u32}

    /// Hovers that end their code block with a type's layout line, filled
    /// once the TU is lowered (fill_layouts_): the hover's index, where the
    /// line goes, and the type.
    var layout_hover_: [u32]
    var layout_at_:    [usize]
    var layout_decl_:  [unsafe *Decl]
    /// Parallel: the type a use named (`Pair<i64>`, `vector<i32>`, an
    /// alias's target) for a hover of that use, else null and the type is
    /// layout_decl_'s own; and how the line names it ("" for the decl's).
    var layout_type_:  [unsafe *Type]
    var layout_name_:  [string]

    /// The worker's: this file was named by the editor (an open buffer),
    /// not only found under the root.
    pub var named_: bool = false

    /// The worker's: the file's path, for a walk whose rows are kept by
    /// file (IndexObserver::keep).
    pub var path_: string = ""

    /// byte offset of a callee name -> modifiers its call site adds. Filled
    /// by the call and operator visits, merged when tokens are written; the
    /// name itself is classified by the identifier visit, which may run
    /// before or after.
    var extra_mods_: {u32: u32}

    /// Locals and parameters seen so far, in walk order: what an unqualified
    /// completion offers before the file's own names.
    var locals_: [unsafe *Decl]

    /// File-, module- and type-level declarations seen so far. A top-level
    /// `const` is in no DeclContext list a completion can read, so the walk
    /// keeps its own.
    var globals_: [unsafe *Decl]

    /// The function whose body the walk is in, for its enclosing type.
    var cur_fn_: unsafe *Declarations::FunctionDecl = &null

    // --- Tables.k ---------------------------------------------------------

    /// This file's declaration table, a JSON object (Snapshot.k, SK_DECLS).
    pub var table: string = ""

    /// What the file's imports bring in, the files those rows name, and the
    /// files whose extensions the file sees: the block's `scope`, `sfiles`
    /// and `sees`.
    pub var scope_rows:  [ScopeRow]
    pub var scope_files: [string]
    pub var sees:        [string]

    /// The check's shared ScopeFacts (the observer's), or null: each
    /// declaration is then described by this walk.
    pub var facts: unsafe *ScopeFacts = &null

    var scope_fids_: [u32]
    var scope_seen_: {u64: u32}  ///< a name's hash -> its first row
    var t_fids_:     [u32]       ///< the files the table's rows name
    var t_count_:    i64 = 0
    var t_bases_:    [i64]       ///< TB_* rows, flat
    var t_seen_:     {u64: u32}
    var t_ac_:       unsafe *AccessCheck = &null  ///< while the table is built: reads a row's visibility

    // --- CompletionItems.k: a completion's access filter ------------------

    /// Set while the members of a receiver, or of the enclosing type, are
    /// listed: a member the use site may not name is not offered.
    var ac_:         unsafe *AccessCheck = &null
    var ac_through_: unsafe *Type        = &null
    /// The extensions this file sees, for the receiver's.
    var ml_: unsafe *MemberLookup = &null

    var tu_: TypeUtil

    pub fn IndexWalker(self, sc: unsafe *SemaContext) {
        self.sc  = sc
        self.tu_ = TypeUtil(sc)
        self.ctx = sc->ctx
        self.sm  = sc->ctx->sm
    }

    // --- driver ----------------------------------------------------------

    /// The visitor's context, for the walker's `extend` files: an extension
    /// of a derived class is not granted the base's `prot` members (only the
    /// class body is), so they read it through here.
    fn ast_(const self) -> unsafe *ASTContext {
        return self.ctx
    }

    pub fn run(self, fid: u32) {
        self.fid = fid
        var unsafe *tu = self.sc->tu
        if tu == &null || tu->program == &null {
            return
        }

        self.file_(fid)
        self.build_table_()
        self.build_scope_()

        for var i: usize = 0; i < tu->imports.size(); ++i {
            self.import_(*tu->imports.get(i))
        }

        var *items = &tu->program->items
        for var i: usize = 0; i < items->size(); i++ {
            var item = *items->get(i)
            match item.kind {
                case TopLevelKind::Decl {
                    self.dispatch_decl(item.as_decl())
                } case TopLevelKind::Stmt {
                    self.dispatch_stmt(item.as_stmt())
                } case TopLevelKind::Expr {
                    self.dispatch_expr(item.as_expr())
                }
            }
        }
    }

    /// Drops the locals of the declaration the walk has left: all of them
    /// before a type at file level, and before a function all but the type
    /// parameters of the types around it (\p keep_type_params).
    fn leave_locals_(self, keep_type_params: bool) {
        var kept: [unsafe *Decl]
        if keep_type_params {
            for var i: usize = 0; i < self.locals_.size(); ++i {
                var unsafe *l = self.locals_[i]
                if isa<Declarations::GenericParamDecl>(l) && (l->semantic_dc != &null) && l->semantic_dc->is_type_scope() {
                    kept.push_back(l)
                }
            }
        }

        self.locals_ = kept
    }

    // --- locations -------------------------------------------------------

    /// The FileText for \p fid, loading it on first use. Index into `files`.
    fn file_(self, fid: u32) -> usize {
        for var i: usize = 0; i < self.files.size(); ++i {
            if self.files[i].fid == fid {
                return i
            }
        }

        var f = FileText()
        f.fid  = fid
        f.path = self.sm->get_filename(fid)
        var size = self.sm->get_file_size(fid)
        if size > 0 {
            // The raw bytes. get_text() decodes UTF-8 and keeps one byte per
            // code point (P800), which both corrupts the text and shifts
            // every offset after the first non-ASCII character.
            var view = self.sm->get_view(self.sm->get_range(fid, 0, size))
            f.text = string(unsafe ((view.data() as unsafe *const u8) as *const u8), view.size())
        }

        f.lines.build(f.text)
        self.files.push_back(f)
        return self.files.size() - 1
    }

    /// Byte offset of \p loc when it lies in the indexed file, else u32::MAX.
    /// A token that came out of a macro body, or from an imported template,
    /// lies elsewhere and has no place in this file's tables.
    fn own_off_(self, loc: SourceLocation) -> u32 {
        if !loc.is_valid() {
            return u32::MAX
        }

        var r = self.sm->resolve(loc)
        if (r.fid as u32) != self.fid {
            return u32::MAX
        }

        return r.offset as u32
    }

    // --- classification --------------------------------------------------

    fn kind_of_(self, d: unsafe *Decl) -> u32 {
        if d == &null {
            return TT_NONE()
        }

        if isa<Declarations::FunctionDecl>(d) {
            var unsafe *f = cast<Declarations::FunctionDecl>(d)
            if f->is_method() {
                return TT_METHOD()
            }

            if (d->semantic_dc != &null) && d->semantic_dc->is_type_scope() {
                return TT_METHOD()
            }

            return TT_FUNCTION()
        }

        if isa<Declarations::VariableDecl>(d) {
            return TT_VARIABLE()
        }

        if isa<Declarations::ParamDecl>(d) {
            if cast<Declarations::ParamDecl>(d)->is_self {
                return TT_SELF()
            }

            return TT_PARAMETER()
        }

        if isa<Declarations::FieldDecl>(d) {
            return TT_PROPERTY()
        }

        if isa<Declarations::GenericParamDecl>(d) {
            return TT_TYPE_PARAM()
        }

        if isa<Declarations::ClassDecl>(d) {
            return TT_CLASS()
        }

        if isa<Declarations::StructDecl>(d) {
            return TT_STRUCT()
        }

        if isa<Declarations::UnionDecl>(d) {
            return TT_UNION()
        }

        if isa<Declarations::InterfaceDecl>(d) {
            return TT_INTERFACE()
        }

        if isa<Declarations::EnumDecl>(d) {
            return TT_ENUM()
        }

        if isa<Declarations::EnumVariantDecl>(d) {
            return TT_ENUM_MEMBER()
        }

        if isa<Declarations::TypeAliasDecl>(d) {
            return TT_TYPE_ALIAS()
        }

        if isa<Declarations::ModuleDecl>(d) {
            return TT_NAMESPACE()
        }

        if isa<Declarations::MacroDecl>(d) || isa<Declarations::ProcedureMacroDecl>(d) {
            return TT_MACRO()
        }

        return TT_NONE()
    }

    fn mods_of_(self, d: unsafe *Decl) -> u32 {
        var m: u32 = 0
        if d == &null {
            return m
        }

        if isa<Declarations::VariableDecl>(d) {
            var unsafe *v = cast<Declarations::VariableDecl>(d)
            if (v->storage == Declarations::StorageClass::Const) || (v->storage == Declarations::StorageClass::Eval) {
                m = m | TM_READONLY() | TM_CONSTANT()
            } else if v->const_binding {
                m = m | TM_READONLY()
            } else {
                m = m | TM_MUTABLE()
            }

            if v->storage == Declarations::StorageClass::Static {
                m = m | TM_STATIC()
            }
        } else if isa<Declarations::FieldDecl>(d) {
            var unsafe *f = cast<Declarations::FieldDecl>(d)
            if (f->storage == Declarations::StorageClass::Const) || (f->storage == Declarations::StorageClass::Eval) {
                m = m | TM_READONLY() | TM_CONSTANT()
            }

            if f->is_static() {
                m = m | TM_STATIC()
            }
        } else if isa<Declarations::ParamDecl>(d) {
            if cast<Declarations::ParamDecl>(d)->is_const {
                m = m | TM_READONLY()
            }
        } else if isa<Declarations::FunctionDecl>(d) {
            var unsafe *f = cast<Declarations::FunctionDecl>(d)
            if f->where_lead != &null {
                m = m | TM_DISPATCHED()
            }

            if (d->semantic_dc != &null) && d->semantic_dc->is_type_scope() && (!f->is_method()) {
                m = m | TM_STATIC()
            }
        } else if isa<Declarations::ClassDecl>(d) {
            if cast<Declarations::ClassDecl>(d)->is_abstract {
                m = m | TM_ABSTRACT()
            }
        }

        if decl_is_ffi(d) {
            m = m | TM_FFI()
        }

        if self.deprecated_(d) {
            m = m | TM_DEPRECATED()
        }

        return m
    }

    /// \p d carries `@deprecated`, read as AttributeCheck::_deprecation
    /// reads it from the decl and its pattern (an instance). Its third link,
    /// NameLookup::representative, is `prot` to the compiler module.
    fn deprecated_(self, d: unsafe *Decl) -> bool {
        var nm = LangAttrs::deprecated()
        if AttrFacts::find(d, nm) != &null {
            return true
        }

        var unsafe *p = decl_pattern(d)
        return (p != &null) && (p != d) && (AttrFacts::find(p, nm) != &null)
    }

    /// LSP SymbolKind for the outline.
    fn symbol_kind_(self, d: unsafe *Decl) -> u32 {
        var k = self.kind_of_(d)
        if k == TT_FUNCTION() {
            return SYM_FUNCTION as u32
        }

        if k == TT_METHOD() {
            return SYM_METHOD as u32
        }

        if k == TT_VARIABLE() {
            if (self.mods_of_(d) & TM_CONSTANT()) != 0 {
                return SYM_CONSTANT as u32
            }

            return SYM_VARIABLE as u32
        }

        if k == TT_PROPERTY() {
            return SYM_FIELD as u32
        }

        if k == TT_CLASS() {
            return SYM_CLASS as u32
        }

        if (k == TT_STRUCT()) || (k == TT_UNION()) {
            return SYM_STRUCT as u32
        }

        if k == TT_INTERFACE() {
            return SYM_INTERFACE as u32
        }

        if k == TT_ENUM() {
            return SYM_ENUM as u32
        }

        if k == TT_ENUM_MEMBER() {
            return SYM_ENUM_MEMBER as u32
        }

        if k == TT_NAMESPACE() {
            return SYM_NAMESPACE as u32
        }

        if k == TT_TYPE_ALIAS() {
            return SYM_CLASS as u32
        }

        if k == TT_TYPE_PARAM() {
            return SYM_TYPE_PARAMETER as u32
        }

        return 0
    }

    /// LSP CompletionItemKind.
    fn item_kind_(self, d: unsafe *Decl) -> u32 {
        var k = self.kind_of_(d)
        if k == TT_FUNCTION() {
            return CIK_FUNCTION as u32
        }

        if k == TT_METHOD() {
            return CIK_METHOD as u32
        }

        if (k == TT_VARIABLE()) || (k == TT_PARAMETER()) || (k == TT_SELF()) {
            if (self.mods_of_(d) & TM_CONSTANT()) != 0 {
                return CIK_CONSTANT as u32
            }

            return CIK_VARIABLE as u32
        }

        if k == TT_PROPERTY() {
            return CIK_FIELD as u32
        }

        if k == TT_CLASS() {
            return CIK_CLASS as u32
        }

        if (k == TT_STRUCT()) || (k == TT_UNION()) {
            return CIK_STRUCT as u32
        }

        if k == TT_INTERFACE() {
            return CIK_INTERFACE as u32
        }

        if k == TT_ENUM() {
            return CIK_ENUM as u32
        }

        if k == TT_ENUM_MEMBER() {
            return CIK_ENUM_MEMBER as u32
        }

        if k == TT_NAMESPACE() {
            return CIK_MODULE as u32
        }

        if k == TT_TYPE_PARAM() {
            return CIK_TYPE_PARAMETER as u32
        }

        if k == TT_MACRO() {
            return CIK_SNIPPET as u32
        }

        return CIK_TEXT as u32
    }

    // --- hover -----------------------------------------------------------

    fn tok_(self, off: u32, len: u32, kind: u32, mods: u32) {
        if (off == u32::MAX) || (len == 0) || (kind == TT_NONE()) {
            return
        }

        var t = SemTok{}
        t.off  = off
        t.len  = len
        t.kind = kind
        t.mods = mods
        self.toks.push_back(t)
    }

    /// Is \p d (of token kind \p kd) a type declared in the builtin library?
    fn builtin_type_(self, d: unsafe *Decl, kd: u32) -> bool {
        if !((kd == TT_CLASS()) || (kd == TT_STRUCT()) || (kd == TT_ENUM()) || (kd == TT_INTERFACE())
            || (kd == TT_UNION()) || (kd == TT_TYPE_ALIAS()) || (kd == TT_TYPE())) {
            return false
        }

        if (d == &null) || (!d->range.start.is_valid()) || (self.sc == &null) || (self.sc->g == &null) {
            return false
        }

        return self.sc->g->is_builtin_fid(self.sm->resolve(d->range.start).fid as u32)
    }

    /// Records a use of \p d at \p tok: a token, and an edge to the declaration.
    fn use_(self, tok_in: Token, d: unsafe *Decl, extra: u32) {
        if d == &null {
            return
        }

        var tok = self.ctx->unwrap_token(tok_in)
        var off = self.own_off_(tok.range.start)
        if off == u32::MAX {
            return
        }

        var len = tok.range.size() as u32
        var kd  = self.kind_of_(d)
        var md  = self.mods_of_(d) | extra
        // A type of the builtin library (`string`, `vector`) reads as part
        // of the language, like a primitive: the keyword colour, marked
        // defaultLibrary. Only the token: the reference row below keeps the
        // declaration's real kind (symbols, hierarchies).
        if self.builtin_type_(d, kd) {
            kd = TT_KEYWORD()
            md = md | TM_DEFAULT_LIB()
        }

        self.tok_(off, len, kd, md)

        var r = RefRow{}
        r.off = off
        r.len = len
        self.target_(d, &r)
        self.refs.push_back(r)
    }

    pub fn visit_decl(self, n: *Decl) -> bool {
        var unsafe *d = unsafe (n as unsafe *Decl)
        // A function or a type declared at file, module or type level
        // starts a scope of its own: the locals of the one before it are
        // not in it. (A type parameter of an enclosing type still is.)
        var outer = (d->semantic_dc == &null) || (d->semantic_dc->dc_kind == DeclContextKind::TranslationUnit)
            || (d->semantic_dc->dc_kind == DeclContextKind::Module) || (d->semantic_dc->dc_kind == DeclContextKind::Extension)
            || d->semantic_dc->is_type_scope()
        if isa<Declarations::FunctionDecl>(d) {
            self.cur_fn_ = cast<Declarations::FunctionDecl>(d)
            if outer {
                self.leave_locals_(true)
            }
        } else if outer && (self.context_of_decl_(d) != &null) && (!d->semantic_dc->is_type_scope()) {
            self.leave_locals_(false)
        }

        self.declare_(d)

        // A declaration whose type was inferred shows it as an inlay hint.
        // Sema writes the inferred type back with no source range, which is
        // how an inferred slot is told from a written one.
        if isa<Declarations::VariableDecl>(d) {
            var unsafe *v = cast<Declarations::VariableDecl>(d)
            if (v->type_ != &null) && (!v->type_->range.is_valid()) && (!d->is_implicit) {
                var name = self.ctx->unwrap_token(v->name)
                var off  = self.own_off_(name.range.end)
                var txt  = self.type_str_(v->type_, self.ctx)
                if (off != u32::MAX) && (!txt.empty()) {
                    var row = InlayRow{}
                    row.off   = off
                    row.label = ": " + txt
                    self.inlays.push_back(row)
                }
            }
        }

        self.bases_of_(d)
        return true
    }

    /// `for x in xs`, `for var (k, const v) in m`: each binder declares a
    /// local. The visitor does not dispatch a binder's declaration (it is
    /// in no table and no statement), so it had no row: no hover on it, no
    /// "declaration" among its references, and it was no local to complete.
    pub fn visit_ranged_for_stmt(self, n: *Statements::RangedForStmt) -> bool {
        for var i: usize = 0; i < n->bindings.size(); ++i {
            var unsafe *b = n->bindings.get(i)
            if (!b->is_discard) && (b->decl != &null) {
                self.declare_(unsafe (b->decl as unsafe *Decl))
            }
        }

        return true
    }

    /// `case var n`, `case Some(x)`: the pattern's binder, as above.
    pub fn visit_binding_pattern(self, n: *BindingPattern) -> bool {
        if n->decl != &null {
            self.declare_(n->decl)
        }

        return true
    }

    pub fn visit_named_ident_expr(self, n: *NamedIdentExpr) -> bool {
        var unsafe *e = unsafe (n as unsafe *NamedIdentExpr)
        if self.is_marker_(e) {
            self.complete_scope_()
            return true
        }

        if e->is_bound() {
            self.use_(e->name, e->resolved_decl, 0)
        } else if e->variant_decl != &null {
            self.use_(e->name, e->variant_decl, 0)
        }

        return true
    }

    pub fn visit_chain_expr(self, n: *ChainExpr) -> bool {
        var unsafe *c = unsafe (n as unsafe *ChainExpr)
        for var i: usize = 0; i < c->steps.size(); ++i {
            var unsafe *st = c->steps.get(i)
            if st->name == &null {
                continue
            }

            if self.is_marker_(st->name) {
                // What is to the left of the cursor: the previous step, or the
                // chain's base when this is the first step.
                var rt: unsafe *Type = &null
                var rd: unsafe *Decl = &null
                if i > 0 {
                    var unsafe *prev = c->steps.get(i - 1)
                    rt = prev->resolved_type
                    rd = prev->resolved_decl
                } else if c->base != &null {
                    rt = c->base->type_
                    if isa<NamedIdentExpr>(c->base) {
                        rd = cast<NamedIdentExpr>(c->base)->resolved_decl
                    }
                }

                self.complete_member_(rt, rd)
                continue
            }

            if st->resolved_decl != &null {
                self.use_(st->name->name, st->resolved_decl, 0)
            }
        }

        return true
    }

    pub fn visit_chain_type(self, n: *Types::ChainType) -> bool {
        var unsafe *c = unsafe (n as unsafe *Types::ChainType)
        for var i: usize = 0; i < c->segments.size(); ++i {
            var unsafe *sg = c->segments.get(i)
            if sg->name == &null {
                continue
            }

            if self.is_marker_(sg->name) {
                if i > 0 {
                    var unsafe *prev = c->segments.get(i - 1)
                    self.complete_member_(prev->resolved_type, prev->resolved_decl)
                } else {
                    self.complete_scope_()
                }

                continue
            }

            if sg->resolved_decl != &null {
                var before = self.refs.size()
                self.use_(sg->name->name, sg->resolved_decl, 0)
                // The last segment names the whole type: when that is an
                // instance (`Pair<i64>`, `vector<i32>`) or an alias's
                // target, its hover carries that type's layout.
                if (i + 1 == c->segments.size()) && (self.refs.size() == before + 1) {
                    var typed = self.hover_typed_(sg->resolved_decl, c->canonical)
                    if typed != u32::MAX {
                        self.refs[before].hover = typed
                    }
                }
            }
        }

        return true
    }

    pub fn visit_call_expr(self, n: *Expressions::CallExpr) -> bool {
        var unsafe *c = unsafe (n as unsafe *Expressions::CallExpr)
        if c->callee == &null {
            return true
        }

        var callee: unsafe *Decl = &null
        if isa<NamedIdentExpr>(c->callee) {
            var unsafe *id = cast<NamedIdentExpr>(c->callee)
            self.mark_call_(id->name, id->resolved_decl)
            callee = id->resolved_decl
        } else if isa<ChainExpr>(c->callee) {
            var unsafe *ch = cast<ChainExpr>(c->callee)
            if ch->steps.size() > 0 {
                var unsafe *last = ch->steps.get(ch->steps.size() - 1)
                if last->name != &null {
                    self.mark_call_(last->name->name, last->resolved_decl)
                }

                callee = last->resolved_decl
            }
        }

        // `Point(1, 2)` names the type; the constructor it picked is on the call.
        if (callee == &null) || (!isa<Declarations::FunctionDecl>(callee)) {
            callee = c->ctor_decl
        }

        self.param_hints_(c, callee)
        self.mark_mutates_(c, callee)

        return true
    }

    pub fn visit_binary_operator_expr(self, n: *Expressions::BinaryOperatorExpr) -> bool {
        self.user_op_(n->op_token, n->resolved_op)
        return true
    }

    pub fn visit_assign_operator_expr(self, n: *Expressions::AssignOperatorExpr) -> bool {
        self.user_op_(n->op_token, n->resolved_op)
        return true
    }

    pub fn visit_unary_operator_expr(self, n: *Expressions::UnaryOperatorExpr) -> bool {
        self.user_op_(n->op_token, n->resolved_op)
        return true
    }

    /// `x[i]` through a user `op []` / `op []=`: the `[` reads as a call of
    /// the form Sema selected (P880: a split subscript's read or place form
    /// is the one that runs) and jumps to it; a place form marks the use
    /// `mutates`. SubscriptExpr keeps no bracket token: the `[` is the byte
    /// after the base, where OperatorLowering puts it too.
    pub fn visit_subscript_expr(self, n: *Expressions::SubscriptExpr) -> bool {
        if (n->resolved_op == &null) || (n->base == &null) || n->base->range.is_invalid() {
            return true
        }

        var t = Token()
        t.set_kind(TokenKind::OpLSquare)
        t.set_range(SourceRange::from_bounds(n->base->range.end, 1 as u32))
        self.user_op_(t, n->resolved_op)
        var unsafe *f = dyn_cast<Declarations::FunctionDecl>(n->resolved_op)
        if (f != &null) && OperatorFacts::is_subscript_set(f) {
            self.op_mod_(t, TM_MUTATES())
        }

        return true
    }

    /// `unsafe &x`, `unsafe *p`: the operator the block permits is bold too.
    pub fn visit_unsafe_expr(self, n: *Expressions::UnsafeExpr) -> bool {
        var unsafe *e = n->operand
        if (e != &null) && isa<Expressions::UnaryOperatorExpr>(e) {
            self.op_mod_(cast<Expressions::UnaryOperatorExpr>(e)->op_token, TM_UNSAFE())
        }

        return true
    }

    // --- output ----------------------------------------------------------
}
