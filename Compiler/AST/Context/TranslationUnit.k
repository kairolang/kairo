/// --- The Kairo Project ---------------- AST/Context/TranslationUnit.k --- ///
///
///   Root AST node for a single file. Wraps a Program (the item list) with
///   file-level metadata: attributes, imports, diagnostic stats, lazy body
///   tracking slots for future incremental work.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// -------------------------------------------------------------------------- ///

import Memory::ArenaList::*;
import AST::Context::ASTContext::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Context::SymbolTable::*;
import AST::Context::DeclContext::*;
import AST::Node::Program::*;
import AST::Node::Base::*;
import Resolution::ModulePath::*;

class TranslationUnit; // forward decl for ParentRef

enum ParentKind derives u8 {
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
class ParentRef {
    pub var kind: ParentKind = ParentKind::None;
    pub var ptr:  obs::<void>;

    fn ParentRef(self) {
        self.kind = ParentKind::None;
        self.ptr  = &null;
    }

    static fn none() -> ParentRef {
        var r = ParentRef{};
        return r;
    }

    static fn from_expr(e: *Expr) -> ParentRef {
        var r = ParentRef{};
        r.kind = ParentKind::Expr;
        r.ptr  = reinterpret_cast::<*void>(e);
        return r;
    }

    static fn from_stmt(s: *Stmt) -> ParentRef {
        var r = ParentRef{};
        r.kind = ParentKind::Stmt;
        r.ptr  = reinterpret_cast::<*void>(s);
        return r;
    }

    static fn from_decl(d: *Decl) -> ParentRef {
        var r = ParentRef{};
        r.kind = ParentKind::Decl;
        r.ptr  = reinterpret_cast::<*void>(d);
        return r;
    }

    static fn from_type(t: *Type) -> ParentRef {
        var r = ParentRef{};
        r.kind = ParentKind::Type;
        r.ptr  = reinterpret_cast::<*void>(t);
        return r;
    }

    static fn from_tu(tu: *TranslationUnit) -> ParentRef {
        var r = ParentRef{};
        r.kind = ParentKind::TranslationUnit;
        r.ptr  = reinterpret_cast::<*void>(tu);
        return r;
    }

    static fn from_hoisted(e: *DisambigEntry) -> ParentRef {
        var r = ParentRef{};
        r.kind = ParentKind::Hoisted;
        r.ptr  = reinterpret_cast::<*void>(e);
        return r;
    }

    fn is_none(self) -> bool { return self.kind == ParentKind::None; }

    fn as_hoisted(self) -> *DisambigEntry {
        assert(self.kind == ParentKind::Hoisted);
        return reinterpret_cast::<*DisambigEntry>(self.ptr);
    }

    fn as_expr(self) -> *Expr {
        assert(self.kind == ParentKind::Expr);
        return reinterpret_cast::<*Expr>(self.ptr);
    }

    fn as_stmt(self) -> *Stmt {
        assert(self.kind == ParentKind::Stmt);
        return reinterpret_cast::<*Stmt>(self.ptr);
    }

    fn as_decl(self) -> *Decl {
        assert(self.kind == ParentKind::Decl);
        return reinterpret_cast::<*Decl>(self.ptr);
    }

    fn as_type(self) -> *Type {
        assert(self.kind == ParentKind::Type);
        return reinterpret_cast::<*Type>(self.ptr);
    }

    fn as_tu(self) -> *TranslationUnit {
        assert(self.kind == ParentKind::TranslationUnit);
        return reinterpret_cast::<*TranslationUnit>(self.ptr);
    }

    /// Returns the parent's source range regardless of concrete kind.
    /// Used by PositionQuery and hover/definition walkers.
    fn get_range(self) -> SourceRange {
        switch self.kind {
            case ParentKind::Expr            { return self.as_expr()->range;          }
            case ParentKind::Stmt            { return self.as_stmt()->range;          }
            case ParentKind::Decl            { return self.as_decl()->range;          }
            case ParentKind::Type            { return self.as_type()->range;          }
            case ParentKind::TranslationUnit { return SourceRange::invalid();         }
            case ParentKind::Hoisted         { return self.as_hoisted()->decl.origin; }
            default                          { return SourceRange::invalid();         }
        }
    }
}

struct BodyRange {
    pub var decl:      obs::<*Decl>;
    pub var tok_start: SourceLocation;
    pub var tok_end:   SourceLocation;
}

/// One resolved import edge for this TU, in declaration order. Written ONLY by
/// the PP walk (FileImportIndex), read by the parser disambig fallback (Full
/// mode) and by Sema/ImportResolution. `decl` is typed `*Decl` to dodge a
/// stage0 import cycle (same reason as `out_of_line`); it always points to an
/// ImportDecl and is downcast at use. `target_fid` mirrors that node's
/// `resolved_fid`: the source-module file the edge points at (0 = ffi/unres).
/// alias / items / wildcard / visibility all live on the node, not here.
struct ImportEdge {
    pub var target_fid: u32 = 0;
    pub var decl:       obs::<Decl> = &null;   ///< always an *ImportDecl; downcast at use.
}

/// Root of a parsed file's AST. Derives DeclContext so it participates in
/// name lookup like any other scope.
class TranslationUnit derives DeclContext {
    pub var ctx:         obs::<ASTContext>;
    pub var fid:         u32;
    pub var module_path: ModulePath;
    pub var program:     obs::<Program>;
    pub var imports:     ArenaList::<*Decl>;
    pub var macros:      ArenaList::<*Decl>;
    pub var tu_attrs:    ArenaList::<*Decl>;
    pub var error_count: u32 = 0;
    pub var warn_count:  u32 = 0;
    pub var body_ranges: ArenaList::<BodyRange>;

    pub var scope:          obs::<DisambigTable>;
    pub var global_scope:   obs::<GlobalDisambigTable>;
    pub var out_of_line:    ArenaList::<*Decl>;
    pub var import_overlay: obs::<SymbolTable>;

    /// Resolved import edges, in declaration order. One writer: the PP walk
    /// (FileImportIndex). Readers: parser disambig fallback + ImportResolution.
    pub var import_edges:   ArenaList::<ImportEdge>;

    fn TranslationUnit(self, ctx: *ASTContext, fid: u32, scope: *DisambigTable, g_scope: *GlobalDisambigTable) {
        self.init_dc(DeclContextKind::TranslationUnit, ctx, &null, &null);
        self.ctx          = ctx;
        self.fid          = fid;
        self.scope        = scope;
        self.global_scope = g_scope;
        self.imports.set_allocator(&(ctx->nodes), 16);
        self.tu_attrs.set_allocator(&(ctx->nodes), 4);
        self.body_ranges.set_allocator(&(ctx->nodes), 64);
        self.out_of_line.set_allocator(&(ctx->nodes), 8);
        self.import_overlay = &null;
        self.import_edges.set_allocator(&(ctx->nodes), 16);
    }
}