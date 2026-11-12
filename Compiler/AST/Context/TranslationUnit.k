/// --- The Kairo Project ---------------- AST/Context/TranslationUnit.k --- ///
///
///   Root AST node for a single file. Wraps a Program (the item list) with
///   file-level metadata: attributes, imports, diagnostic stats, lazy body
///   tracking slots for future incremental work.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// -------------------------------------------------------------------------- ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::{
    DeclContext,
    DeclContextKind,
}
import AST::Context::DepLog::DepLog
import AST::Context::DisambigTable::{
    DisambigEntry,
    DisambigTable,
}
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::Context::ImportOverlay::ImportOverlay
import AST::Node::Base::{
    Decl,
    Expr,
    Stmt,
    Type,
}
import AST::Node::Declarations::{
    ImportDecl,
    ModuleDecl,
}
import AST::Node::Program::Program
import Driver::TUStage::TUStage // standalone enum, no imports of its own; no cycle
import Location::SourceLocation::SourceLocation
import Location::SourceRange::SourceRange
import Memory::ArenaList::ArenaList
import Resolution::ModulePath::ModulePath
import Token::Token::Token

/// One panic site of a TU (TranslationUnit::panic_sites): its id, the
/// 64-bit hash of its (path, byte offset) that names its table record, and
/// where it is, which EmitIR renders as file, line and column.
pub class PanicSiteRec {
    pub var id:  u32            = 0
    pub var key: u64            = 0
    pub var at:  SourceLocation
    pub fn PanicSiteRec(self) { }
}

pub enum ParentKind derives u8 {
    None,
    Expr,
    Stmt,
    Decl,
    Type,
    TranslationUnit,
    Hoisted,
}

/// Tagged pointer to the parent of an AST node.
/// Covers every node kind that can legally contain another node.
/// Sentinel: `ParentKind::None` with null pointer = no parent (root or orphan).
pub class ParentRef {
    pub var kind: ParentKind   = ParentKind::None
    pub var ptr:  unsafe *void

    fn ParentRef(self) {
        self.kind = ParentKind::None
        self.ptr  = &null
    }

    pub static fn none() -> ParentRef {
        var r = ParentRef()
        return r
    }

    static fn from_expr(e: *Expr) -> ParentRef {
        var r = ParentRef()
        r.kind = ParentKind::Expr
        r.ptr  = unsafe (e as unsafe *void)
        return r
    }

    static fn from_stmt(s: *Stmt) -> ParentRef {
        var r = ParentRef()
        r.kind = ParentKind::Stmt
        r.ptr  = unsafe (s as unsafe *void)
        return r
    }

    pub static fn from_decl(d: *Decl) -> ParentRef {
        var r = ParentRef()
        r.kind = ParentKind::Decl
        r.ptr  = unsafe (d as unsafe *void)
        return r
    }

    static fn from_type(t: *Type) -> ParentRef {
        var r = ParentRef()
        r.kind = ParentKind::Type
        r.ptr  = unsafe (t as unsafe *void)
        return r
    }

    static fn from_tu(tu: *TranslationUnit) -> ParentRef {
        var r = ParentRef()
        r.kind = ParentKind::TranslationUnit
        r.ptr  = unsafe (tu as unsafe *void)
        return r
    }

    pub static fn from_hoisted(e: unsafe *DisambigEntry) -> ParentRef {
        var r = ParentRef()
        r.kind = ParentKind::Hoisted
        r.ptr  = unsafe (e as unsafe *void)
        return r
    }

    fn is_none(self) -> bool {
        return self.kind == ParentKind::None
    }

    fn as_hoisted(self) -> unsafe *DisambigEntry {
        eval if defined!(DEBUG) {
            if !(self.kind == ParentKind::Hoisted) {
                kairo::std::ice_fail(
                    "assertion failed: self.kind == ParentKind::Hoisted",
                )
            }
        }

        return unsafe (self.ptr as unsafe *DisambigEntry)
    }

    fn as_expr(self) -> unsafe *Expr {
        eval if defined!(DEBUG) {
            if !(self.kind == ParentKind::Expr) {
                kairo::std::ice_fail(
                    "assertion failed: self.kind == ParentKind::Expr",
                )
            }
        }

        return unsafe (self.ptr as unsafe *Expr)
    }

    fn as_stmt(self) -> unsafe *Stmt {
        eval if defined!(DEBUG) {
            if !(self.kind == ParentKind::Stmt) {
                kairo::std::ice_fail(
                    "assertion failed: self.kind == ParentKind::Stmt",
                )
            }
        }

        return unsafe (self.ptr as unsafe *Stmt)
    }

    fn as_decl(self) -> unsafe *Decl {
        eval if defined!(DEBUG) {
            if !(self.kind == ParentKind::Decl) {
                kairo::std::ice_fail(
                    "assertion failed: self.kind == ParentKind::Decl",
                )
            }
        }

        return unsafe (self.ptr as unsafe *Decl)
    }

    fn as_type(self) -> unsafe *Type {
        eval if defined!(DEBUG) {
            if !(self.kind == ParentKind::Type) {
                kairo::std::ice_fail(
                    "assertion failed: self.kind == ParentKind::Type",
                )
            }
        }

        return unsafe (self.ptr as unsafe *Type)
    }

    fn as_tu(self) -> unsafe *TranslationUnit {
        eval if defined!(DEBUG) {
            if !(self.kind == ParentKind::TranslationUnit) {
                kairo::std::ice_fail(
                    "assertion failed: self.kind == ParentKind::TranslationUnit",
                )
            }
        }

        return unsafe (self.ptr as unsafe *TranslationUnit)
    }

    /// Returns the parent's source range regardless of concrete kind.
    /// Used by PositionQuery and hover/definition walkers.
    fn get_range(self) -> SourceRange {
        match self.kind {
            case ParentKind::Expr {
                return self.as_expr()->range
            } case ParentKind::Stmt {
                return self.as_stmt()->range
            } case ParentKind::Decl {
                return self.as_decl()->range
            } case ParentKind::Type {
                return self.as_type()->range
            } case ParentKind::TranslationUnit {
                return SourceRange::invalid()
            } case ParentKind::Hoisted {
                return self.as_hoisted()->decl.origin
            } default {
                return SourceRange::invalid()
            }
        }
    }
}

pub struct BodyRange {
    pub var decl:      unsafe *unsafe *Decl
    pub var tok_start: SourceLocation
    pub var tok_end:   SourceLocation
}

/// One resolved import edge for this TU, in declaration order. Written ONLY by
/// the PP walk (FileImportIndex), read by the parser disambig fallback (Full
/// mode) and by Sema/ImportResolution. `target_fid` mirrors `decl`'s
/// `resolved_fid`: the source-module file the edge points at (0 = ffi/unres).
/// alias / items / wildcard / visibility all live on the node, not here.
pub struct ImportEdge {
    pub var target_fid: u32                = 0
    pub var decl:       unsafe *ImportDecl = &null
}

/// Root of a parsed file's AST. Derives DeclContext so it participates in
/// name lookup like any other scope.
pub class TranslationUnit derives DeclContext {
    pub var ctx:         unsafe *ASTContext
    pub var fid:         u32
    pub var module_path: ModulePath
    pub var program:     unsafe *Program
    pub var imports:     ArenaList<unsafe *Decl>
    pub var macros:      ArenaList<unsafe *Decl>
    pub var tu_attrs:    ArenaList<*Decl>
    pub var error_count: u32                     = 0
    pub var warn_count:  u32                     = 0
    pub var body_ranges: ArenaList<BodyRange>
    /// --check-past-syntax-errors only: each function whose block body had
    /// syntax errors the parser kept inside its braces (the body ends at the
    /// brace the text pairs with its opener), outermost bodies only, and how
    /// many errors those bodies held. When that is every error of the file,
    /// the file is checked without the bodies (Driver/CompilerRecovery.k).
    pub var recovered_bodies: ArenaList<unsafe *Decl>
    pub var recovered_errors: u32                     = 0

    pub var scope:          *DisambigTable
    pub var global_scope:   *GlobalDisambigTable
    pub var out_of_line:    ArenaList<unsafe *Decl>
    pub var import_overlay: unsafe *ImportOverlay   ///< built by phase I; null until then.
    /// What this TU's Sema read of other files, or null: only under
    /// --dump-deps / --dump-interface (SemaContext allocates it).
    pub var dep_log: unsafe *DepLog = &null

    /// The synthetic `cxx` module, built by phase I for a TU with any ffi
    /// import, or null. It owns one binding -- `std` -> every top-level `std`
    /// ModuleDecl in this TU's ffi closure -- so `cxx::std` names C++'s `std`
    /// while bare `std` is Kairo's, once `import std` binds it (Compiler/Spec/Interop.md#ffi-imports).
    ///
    /// A TRANSPARENT alias: the decls reached through it keep their own paths
    /// and codegen spells them `::std::…`. Nothing downstream reads this
    /// field except the two diagnostics for `cxx` used alone, which compare
    /// against it by identity.
    pub var cxx_module: unsafe *Decl = &null

    /// Synthetic per-file module node: a real ModuleDecl whose dc_symbols is
    /// SHARED with this TU (A2 model), created at parse exit. Gives plain
    /// imports a genuine *Decl to bind (no TU->Decl reinterpret) and unifies
    /// file-modules with `module foo {}` blocks under one lookup path. Null
    /// for an anonymous root file.
    pub var module_self: unsafe *ModuleDecl = &null

    /// Resolved import edges, in declaration order. One writer: the PP walk
    /// (FileImportIndex). Readers: parser disambig fallback + ImportResolution.
    pub var import_edges: ArenaList<ImportEdge>

    /// A C++ header imported through Sema/Foreign: decls come from clang,
    /// there is no Kairo token stream behind this fid. Set by
    /// HeaderIndex::_target. Never parsed, never run through sema; lives as
    /// long as the build (CompilerInstance::release refuses it).
    pub var is_foreign: bool = false

    /// The parser met an `eval if` or a DefinedExpr in this file (any
    /// position), so EvalIfFolding has something to fold. One writer: the
    /// parser.
    pub var has_eval_if: bool = false
    /// The parser met an `eval for` (InterfaceEmitter writes the eval
    /// helpers, Compiler/Spec/Eval.md#eval-for). One writer: the parser.
    pub var has_eval_for: bool = false
    /// The parser met `<primitive>::NAME` (`i32::MAX`), so
    /// PrimitiveLimitDesugar has something to mint. One writer: the parser.
    pub var has_prim_member: bool = false
    /// The parser met `@create` or `@destroy` in expression position, so
    /// AllocSugarDesugar has something to rewrite. One writer: the parser.
    pub var has_alloc_sugar: bool = false
    /// The driver proved this TU declares no extension anywhere
    /// (FrontendAction::_sema_parallel), so MemberLookup's build-wide
    /// extension index skips it without reading its declaration lists,
    /// which its own Sema may be rewriting on another thread.
    pub var no_extensions: bool = false
    /// StringLowering spelled a string literal C++ reads at compile time
    /// (Compiler/Spec/Eval.md#strings-at-compile-time), so InterfaceEmitter writes `__kairo_estr`. One writer:
    /// StringLowering.
    pub var has_eval_string: bool = false

    /// The HeaderSet this file's ffi imports requested (PPWalker::_finalize),
    /// or null. Typed *void: TranslationUnit cannot name Interop. Owned by the
    /// CompilerInstance's HeaderSetCache, never by the TU.
    pub var header_set: unsafe *void = &null

    /// Codegen, pathless (entry) TU only (CXXSpell::is_entry_tu): the
    /// priv/internal decls an inline or template body of this file names.
    /// Such a body is compiled wherever this file is included, so what it
    /// names keeps external linkage rather than go in the unnamed namespace
    /// (CXXSpell::is_anon). Filled once, by this
    /// TU's first EmitPlan (EmitPlan::_find_escaping), from the file alone,
    /// so every run spells them the same.
    pub var cxx_escaping:      cxx::std::vector<unsafe *Decl>
    pub var cxx_escaping_done: bool                           = false

    /// Compiler/Spec/Panic.md#site-ids: this TU's panic sites, in registration order, ids
    /// unique within the TU. One writer, PanicSites::site_id (Sema); one
    /// reader, EmitIR, which writes them to the `__kairo_panic_sites` table.
    pub var panic_sites: cxx::std::vector<PanicSiteRec>

    /// The path of this file's bare `module a::b` declaration, one token per
    /// segment, or empty. Recorded by the parser in any file; read by
    /// ModulePinCheck, whose pin_allowed decides where one may appear. In a
    /// module.k it pins the directory as library `a::b`, and the resolver
    /// reads that from the file itself, before any parse
    /// (ImportProbe::read_module_pin). `pin_range` spans the declaration.
    pub var pin_segments: ArenaList<Token>
    pub var pin_range:    SourceRange      = SourceRange::invalid()
    /// A SECOND bare pin in the same file, if any (the first beyond
    /// pin_range): a file names at most one library, and the parser keeps
    /// only the first, so ModulePinCheck reports this one rather than let it
    /// vanish.
    pub var pin_extra_range: SourceRange = SourceRange::invalid()

    /// `@set_global_allocator(A)`: the private TypeAliasDecl the parser made
    /// of it (ASTParse::_parse_global_allocator), so A resolves as any
    /// written type does; null when the file sets none. EmitIR writes the
    /// strong `kairo_global_*` forwarders from it, and the driver rejects a
    /// second file of one link that sets one too. `global_alloc_at` spans
    /// the attribute.
    pub var global_alloc:    unsafe *Decl = &null
    pub var global_alloc_at: SourceRange  = SourceRange::invalid()
    /// Visibility facts (AST/VisibilityFacts.k): the directory of the
    /// nearest module.k above the file ("" in no module), and whether the
    /// file is builtin or std. Written once per build by the driver before
    /// Sema, since parallel Sema reads them from any worker; unstamped,
    /// readers recompute instead.
    pub var vis_stamped: bool   = false
    pub var is_lib_tu:   bool   = false
    pub var module_dir:  string

    /// How far this tree has gone: Preprocessing (the PP built the TU),
    /// Parsing (a parse, or the AST reader, gave it its program), Sema (a
    /// Sema began writing on it). The serializer holds only a parsed tree
    /// (AST/Serialize/Serializer.k), and this says so in one place instead
    /// of the per-slot checks alone: a Sema field missing from those lists
    /// would otherwise be written as if the parser had set it.
    ///
    /// Per TU, not the driver's FrontendAction stage, which is one for a
    /// whole batch and is skipped by parse_one, the live check and the
    /// parse API. Forward only (advance), except the one rewind a reparse
    /// takes (rewind_to_preprocessed). The other progress facts on this
    /// class (vis_stamped, cxx_escaping_done, import_overlay) are separate
    /// one-shot facts, not stages of this.
    priv var _stage: TUStage = TUStage::Preprocessing

    fn TranslationUnit(self,
                       ctx:     unsafe *ASTContext,
                       fid:     u32,
                       scope:   *DisambigTable,
                       g_scope: *GlobalDisambigTable) {
        self.init_dc(DeclContextKind::TranslationUnit, ctx, &null, &null)
        // init_dc puts a scope's decl list in ast_alloc, which is right for
        // every scope but this one: the TU lives in pp_alloc and SURVIVES
        // release_from(Parsing) / reset_for_reparse, which reset ast_alloc.
        // The list's chunk table and slabs would dangle into the reset arena
        // and the reparse's first push would write into whatever the new AST
        // put there (GH #71). Its storage lives as long as the TU; its
        // CONTENTS are the parse's, dropped by ASTParse::parse.
        self.dc_decls.set_allocator(unsafe &ctx->pp_alloc, 64)
        self.ctx          = ctx
        self.fid          = fid
        self.scope        = scope
        self.global_scope = g_scope
        // EVERY ArenaList below must name an arena. The default ctor eagerly
        // builds a self-owned one, reclaimed only by ~ArenaList   `macros` was
        // missing this call and leaked a block per TU per parse.
        self.imports.set_allocator(unsafe &ctx->pp_alloc, 16)
        self.macros.set_allocator(unsafe &ctx->pp_alloc, 16)
        self.tu_attrs.set_allocator(unsafe &ctx->pp_alloc, 4)
        self.body_ranges.set_allocator(unsafe &ctx->pp_alloc, 64)
        self.recovered_bodies.set_allocator(unsafe &ctx->pp_alloc, 4)
        self.out_of_line.set_allocator(unsafe &ctx->pp_alloc, 8)
        self.import_overlay = &null
        self.import_edges.set_allocator(unsafe &ctx->pp_alloc, 16)
        self.pin_segments.set_allocator(unsafe &ctx->pp_alloc, 4)
        self.global_alloc    = &null
        self.global_alloc_at = SourceRange::invalid()
    }

    pub fn stage(self) -> TUStage {
        return self._stage
    }

    /// The forward transitions: the parser's (and the AST reader's) to
    /// Parsing, Sema's to Sema. Repeating one is fine (a re-entrant Sema run,
    /// a second parse of a released tree); going back is a missing release:
    /// a parse over a tree Sema wrote on would keep Sema's slots.
    pub fn advance(self, to: TUStage) {
        eval if defined!(DEBUG) {
            if (to as u8) < (self._stage as u8) {
                kairo::std::ice_fail(
                    r"TranslationUnit: stage moved backward without a release",
                )
            }
        }

        if (to as u8) > (self._stage as u8) {
            self._stage = to
        }
    }

    /// The one backward transition: ASTContext::release_from(Parsing) (a
    /// reparse) dropped the tree, and this TU, which lives in pp_alloc,
    /// survives it with only the preprocessor's work.
    pub fn rewind_to_preprocessed(self) {
        self._stage = TUStage::Preprocessing
    }
}
