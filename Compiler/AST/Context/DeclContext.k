/// --- The Kairo Project -------------------- AST/Context/DeclContext.k --- ///
///
///   Mixin base for AST nodes that own a lexical scope of declarations.
///   TranslationUnit, ModuleDecl, ClassDecl, StructDecl, EnumDecl,
///   InterfaceDecl, FunctionDecl, and BlockStmt all derive this.
///
///   Provides uniform name lookup and child-decl enumeration.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Memory::ArenaList::*;
import AST::Context::ASTContext::*;
import AST::Node::Base::*;

/// \enum DeclContextKind
/// \brief Discriminates the kind of scope a DeclContext represents.
///
/// \details Every scope-owning AST node carries one of these. Used for
///          `enclosing(kind)` walks, lookup rules that differ by scope
///          (e.g. type scopes vs function scopes), and diagnostics that
///          report what kind of scope a name was or wasn't found in.
///
///          This is distinct from ScopeKind (LexicalScope.k): ScopeKind
///          drives parser-time lexical name resolution and shadowing;
///          DeclContextKind tags the persistent decl-owning AST node.
///          They overlap but are not 1:1 (e.g. GenericParams is a
///          ScopeKind only its params are owned by the enclosing
///          class/fn DeclContext, not a context of their own).
enum DeclContextKind derives u8 {
    /// The root context one per parsed file. Owns all top-level decls.
    TranslationUnit,

    /// module Foo { } | inline module Foo { } | anonymous module { }
    Module,

    // -- Type scopes (is_type_scope() returns true for all of these) -----

    /// class Foo<T> derives Bar impl Baz { }
    Class,

    /// struct Foo<T> impl Bar { }
    Struct,

    /// enum Direction derives u8 { } | enum <T> Result { ... }
    Enum,

    /// union Foo { }
    Union,

    /// interface Printable<T> { }
    Interface,

    /// extend Foo<T> impl Bar { } adds methods/conformance to an
    /// existing type. Owns the decls written inside the extend body.
    Extension,

    // -- Executable scopes -----------------------------------------------

    /// A free function or method body. Owns params (ParamDecl), local
    /// decls, and nested decls.
    Function,

    /// A closure body. Owns its params and any locals. Separate from
    /// Function so captures and lifetime analysis can distinguish a
    /// closure from a named function. (Fold into Function if this proves
    /// to be a distinction without a difference at the context level.)
    Lambda,

    /// A brace-delimited block scope: `{ stmt* }`, loop/if/match bodies.
    /// Owns any decls declared inside (DeclStmt-wrapped).
    Block,
}

/// A scope that owns declarations.
/// Mixed into concrete decl nodes (ClassDecl, FunctionDecl, etc).
class DeclContext {
    pub var dc_kind:   DeclContextKind;
    pub var dc_parent: obs::<DeclContext>;      // lexical parent scope
    pub var dc_owner:  obs::<Decl>;             // the Decl that owns this context (null for TU)
    pub var dc_decls:  ArenaList::<*Decl>;      // owned decls, in source order (parser ordering)
    pub var dc_scope:  obs::<DisambigNode>;        // hoisted scope node for lookup; populated by indexer

    fn init_dc(self, kind: DeclContextKind, ctx: *ASTContext, parent: *DeclContext, owner: *Decl) {
        self.dc_kind   = kind;
        self.dc_parent = parent;
        self.dc_owner  = owner;
        self.dc_decls.set_allocator(&(ctx->nodes));
        self.dc_scope  = &null;
    }

    /// Wire the hoisted scope node in after the index pass. The indexer
    /// owns population of the DisambigNode; the parser links it here so
    /// lookup_local() can delegate.
    fn set_scope(self, scope: *DisambigNode) {
        self.dc_scope = scope;
    }

    /// Append a child decl in source order. NOTE: this updates the flat
    /// ordered list only the lookup index (dc_scope) is populated by the
    /// indexer during hoisting, not here. The two containers serve
    /// different roles: dc_decls preserves order for codegen/printing,
    /// dc_scope answers name queries in O(1).
    fn add_decl(self, d: *Decl) {
        self.dc_decls.push(d);
    }

    fn parent_context(self) -> *DeclContext { return self.dc_parent; }
    fn owner_decl(self)     -> *Decl        { return self.dc_owner;  }
    fn context_kind(self)   -> DeclContextKind { return self.dc_kind; }

    /// Looks up a name in THIS scope only (no parent walk). Delegates to
    /// the hoisted scope node. Returns not_found if the scope isn't wired
    /// or the name isn't present.
    ///
    /// \warning the hoisted table holds PARSER-RELEVANT entries only: all
    ///          type decls, and generic functions/operators. Variables,
    ///          non-generic callables, and macros are never hoisted. Sema
    ///          must not use this as a member table; it builds its own.
    fn lookup_local(self, name: u32) -> LookupResult {
        if self.dc_scope == &null { return LookupResult::not_found(); }
        var entries = self.dc_scope->lookup(name);
        if entries == &null { return LookupResult::not_found(); }
        var r = LookupResult{};
        r.entries = entries;
        r.node    = self.dc_scope;
        return r;
    }

    /// Walks up the parent chain looking for a context of the given kind.
    fn enclosing(self, kind: DeclContextKind) -> *DeclContext {
        var c = self.dc_parent;
        while c != &null {
            if c->dc_kind == kind { return c; }
            c = c->dc_parent;
        }
        return &null;
    }

    fn is_translation_unit(self) -> bool { return self.dc_kind == DeclContextKind::TranslationUnit; }
    fn is_function(self)        -> bool { return self.dc_kind == DeclContextKind::Function; }
    fn is_type_scope(self)      -> bool {
        return self.dc_kind == DeclContextKind::Class
            || self.dc_kind == DeclContextKind::Struct
            || self.dc_kind == DeclContextKind::Enum
            || self.dc_kind == DeclContextKind::Union
            || self.dc_kind == DeclContextKind::Interface
            || self.dc_kind == DeclContextKind::Extension;
    }
}