/// --- The Kairo Project -------------------- Sema/Foreign/DeclImport.k --- ///
///
///   \brief clang::Decl -> Kairo Decl, into the TU of the header it came
///          from. Two passes over the same decls, called by HeaderIndex:
///
///            declare(d)  mint the Kairo node, register its USR, put its
///                        NAME in the right table. No types, no members.
///            define(d)   fill types, params, fields, bases, layout, the
///                        FFILinkage facts. Every cross-decl reference
///                        resolves through the registry, which pass 1
///                        completed, so a field may name a record declared
///                        three headers later.
///
///   \par What the rest of sema sees
///     An ordinary Decl with every slot T would have filled already filled:
///     `type_` / `aliased` / `InheritEdge.base` / `return_type` hold the
///     CANONICAL node (self-canonical). `NameLookup::ctx_of(d)` is the
///     header's context, so `TypeResolution::_foreign` reads and never
///     dispatches; `lookup_foreign` re-interns through the header's imm
///     table. Nothing after N knows the decl was not parsed.
///
///   \par What is NOT imported (skipped, by design, for this shot)
///     friend classes and friend function templates (a friend FUNCTION is
///     imported, declare_friend), using-directives, static_assert, deduction guides,
///     variable templates, bit-field widths, default-argument EXPRESSIONS
///     (presence is recorded), implicit instantiations found in the header
///     (the registry mints them on demand), non-type template arguments.
///
///   \par Fill mode
///     ForeignInstantiate reuses both passes on ONE ClassTemplateSpecialization-
///     Decl clang just completed. `fill_target` pins every decl to the
///     primary's header (instantiated members carry the PATTERN's locations,
///     and that header is frozen); `fill_spec` -> `fill_scope` maps the
///     specialization to its registry shell; the tables a fill creates go to
///     `fill_scopes` for the fill to freeze, not to the target's `scopes`.
///     Only the decl moves: its name token is still minted in the header its
///     location is IN (_home_at), since a token's text is read back through
///     its range.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh";
ffi "c++" import "clang/AST/ASTContext.h";
ffi "c++" import "clang/AST/Attr.h";
ffi "c++" import "clang/AST/Decl.h";
ffi "c++" import "clang/AST/DeclBase.h";
ffi "c++" import "clang/AST/DeclCXX.h";
ffi "c++" import "clang/AST/DeclTemplate.h";
ffi "c++" import "clang/AST/RecordLayout.h";
ffi "c++" import "clang/Basic/OperatorKinds.h";
ffi "c++" import "clang/Basic/SourceManager.h";

import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Context::TranslationUnit::*;
import AST::Context::CanonicalTypes::*;
import AST::Context::InstantiationRegistry::*;
import AST::ASTSupport::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::DeclFacts::*;
import AST::Node::CanonicalNodes::*;
import AST::Node::Casting::*;
import AST::Kind::DeclKind::*;
import AST::Mixin::FFILinkage::*;
import Location::SourceManager::*;
import Location::SourceRange::*;
import Token::Token::*;
import Token::TokenKind::*;
import Sema::Resolve::NameLookup::*;
import Sema::Foreign::ForeignRegistry::*;
import Sema::Foreign::TypeImport::*;
import Interop::Clang::HeaderSet::*;

/// Per-header import state: the TU being filled, its context, and the
/// tables being built (frozen by HeaderIndex when the set is done).
class HeaderTarget {
    pub var fid:    u32 = 0;
    pub var ctx:    obs::<ASTContext>;
    pub var tu:     obs::<TranslationUnit>;
    pub var frozen: bool = false;              ///< already indexed by an earlier set: read-only.
    /// qualified namespace name -> this header's ModuleDecl for it.
    pub var namespaces: libcxx::unordered_map::<libcxx::string, *ModuleDecl>;
    /// every DeclContext this header owns whose table must be frozen at the end.
    pub var scopes: vec::<*DeclContext>;
    fn HeaderTarget(self) { }
}

class DeclImport {
    pub var _set:   obs::<HeaderSet>;
    pub var reg:   obs::<ForeignRegistry>;
    pub var ksm:   obs::<SourceManager>;
    pub var store: obs::<CanonicalTypeStore>;
    pub var instances: obs::<InstantiationRegistry>;
    pub var cctx:  obs::<clang::ASTContext>;
    pub var csm:   obs::<clang::SourceManager>;

    /// header fid -> target. Owned by HeaderIndex; borrowed here.
    pub var targets: obs::<libcxx::unordered_map::<u32, *HeaderTarget>>;

    // --- fill mode (ForeignInstantiate; all null for a header walk) ----------
    pub var fill_target: *HeaderTarget = &null;   ///< when set: every decl lands here.
    pub var fill_scope:  *DeclContext  = &null;   ///< the instance shell.
    pub var fill_spec:   *clang::Decl  = &null;   ///< the ClassTemplateSpecializationDecl it stands for.
    pub var fill_scopes: vec::<*DeclContext>;     ///< every table the fill created; the fill freezes them.
    /// declare_friend only: the class whose table the friend's NAME goes in.
    priv var _friend_scope: *clang::DeclContext = &null;

    pub var n_declared: usize = 0;
    pub var n_defined:  usize = 0;
    pub var n_skipped:  usize = 0;

    fn DeclImport(self) { }

    // === locations ==============================================================

    /// Kairo range for a clang range, or invalid when the loc is not in a
    /// file we minted a fid for (scratch buffers, <built-in>).
    fn range_of(self, d: const_obs::<clang::Decl>) -> SourceRange {
        var b = self.csm->getDecomposedExpansionLoc(d->getBeginLoc());
        var e = self.csm->getDecomposedExpansionLoc(d->getEndLoc());
        var kb = self._set->kfid_for(b.first);
        if kb == 0 { return SourceRange::invalid(); }
        var ke = self._set->kfid_for(e.first);
        var len: usize = 1;
        if (ke == kb) && (e.second >= b.second) { len = static_cast::<usize>(e.second - b.second) + 1; }
        return self.ksm->get_range(kb, static_cast::<usize>(b.second), len);
    }

    fn name_range_of(self, d: const_obs::<clang::NamedDecl>) -> SourceRange {
        var b = self.csm->getDecomposedExpansionLoc(d->getLocation());
        var kb = self._set->kfid_for(b.first);
        if kb == 0 { return SourceRange::invalid(); }
        var n = d->getNameAsString();
        var len = n.size();
        if len == 0 { len = 1; }
        return self.ksm->get_range(kb, static_cast::<usize>(b.second), len);
    }

    /// Where a decl LIVES: the header it was written in, as a target; null
    /// when it is in no file we track. Falls back through redecls so a
    /// definition in a file we never entered still lands next to its
    /// declaration. Scopes, tables and bindings follow this; the decl's name
    /// TOKEN does not (_home_at).
    fn target_of(self, d: const_obs::<clang::Decl>) -> *HeaderTarget {
        // Fill mode: an instantiated member carries its PATTERN's location, so
        // the path below would answer with the pattern's header -- frozen
        // since HeaderIndex finished it -- and the member would be dropped.
        if self.fill_target != &null { return self.fill_target; }
        var loc = self.csm->getDecomposedExpansionLoc(d->getLocation());
        return self._target_for(self._set->kfid_for(loc.first));
    }

    /// Which header's context owns the interner for a token ranged at \p at:
    /// the file the range is IN, always. Fill mode and `frozen` do not enter
    /// into it -- interning a spelling writes no table. Null for a range in
    /// no file we track.
    ///
    /// Not target_of, because TokenText finds a token's imm table from its
    /// RANGE (hard invariant #2, display side). A fill pins every decl to the
    /// primary's header, <__fwd/vector.h>, while `push_back` is written in
    /// <__vector/vector.h>: minting the name in the first and ranging it in
    /// the second read back whatever sat at that index in the second's table,
    /// and `.size` printed as `cend`. Keys never had the problem; _ident_key
    /// interns through the table's own TU.
    priv fn _home_at(self, at: SourceRange) -> *HeaderTarget {
        if !at.is_valid() { return &null; }
        return self._target_for(self.ksm->get_fid(at));
    }

    priv fn _target_for(self, kf: u32) -> *HeaderTarget {
        if kf == 0 { return &null; }
        var it = self.targets->find(kf);
        if it == self.targets->end() { return &null; }
        return it->second;
    }

    // === tokens ================================================================

    fn ident(self, t: *HeaderTarget, s: string, at: SourceRange) -> Token {
        return self._tok(t, at, TokenKind::LitIdentifier, s);
    }

    /// Every token DeclImport makes goes through here, so its text and its
    /// range agree on a TU (_home_at). \p t answers only for a range in no
    /// tracked file, where no TU can read it back by range anyway.
    priv fn _tok(self, t: *HeaderTarget, at: SourceRange, k: TokenKind, s: string) -> Token {
        var ctx = t->ctx;
        var h = self._home_at(at);
        if h != &null { ctx = h->ctx; }
        return ctx->make_token(at, k, s);
    }

    priv fn _str(self, s: llvm::StringRef) -> string {
        return string(s.data(), s.size());
    }

    priv fn _qual(self, d: const_obs::<clang::NamedDecl>) -> string {
        var pol = clang::PrintingPolicy(self.cctx->getLangOpts());
        pol.FullyQualifiedName = true;
        pol.SuppressUnwrittenScope = true;
        var s: libcxx::string;
        var os = llvm::raw_string_ostream(s);
        d->printQualifiedName(os, pol);
        os.flush();
        return "::" + std::nstring_to_string(s);
    }

    // === tables ===================================================================

    /// The table a decl in clang context \p dc goes into, on header \p t:
    /// the TU for the global namespace, a ModuleDecl for a namespace, the
    /// record's own context for a member.
    fn scope_for(self, t: *HeaderTarget, dc: const_obs::<clang::DeclContext>) -> *DeclContext {
        // Fill mode: the specialization being imported IS the shell. Nothing
        // registered its USR (an implicit specialization is never walked), so
        // the registry probe below would miss it. Records nested in it were
        // declared by this fill and resolve through the registry as usual.
        if (self.fill_spec != &null) && (dc != &null) && (clang::Decl::castFromDeclContext(dc) == self.fill_spec) {
            return self.fill_scope;
        }
        if dc == &null { return static_cast::<*DeclContext>(t->tu); }
        // Transparent contexts: linkage specs, inline namespaces, anonymous
        // structs/unions, export blocks -- their members belong to the parent.
        // NOT an unscoped enum, which clang also calls transparent: its
        // enumerators belong in the enum's own table (`Color::Green`), and
        // _bind_named adds them to the enclosing scope separately.
        if (dc->isTransparentContext() && (!llvm::isa::<clang::EnumDecl>(dc))) || dc->isInlineNamespace() {
            return self.scope_for(t, dc->getParent());
        }
        if dc->isTranslationUnit() { return static_cast::<*DeclContext>(t->tu); }
        var ns = llvm::dyn_cast::<clang::NamespaceDecl>(dc);
        if ns != &null { return static_cast::<*DeclContext>(self.namespace_for(t, ns)); }
        var rd = clang::Decl::castFromDeclContext(dc);
        if rd != &null {
            var kd = self.reg->find(TypeImport::usr_of(rd->getCanonicalDecl()));
            var kdc = NameLookup::context_of(kd);
            if kdc != &null { return kdc; }
        }
        // A context with no Kairo scope (a function body, a record nobody
        // imported): the decl has nowhere to live, so it is not imported.
        // Falling back to the TU made every such decl a GLOBAL, and libc++
        // alone then had dozens of "ambiguous" `type`s at file scope.
        return &null;
    }

    fn table_of(self, t: *HeaderTarget, dc: *DeclContext) -> *SymbolTable {
        if dc->dc_symbols == &null {
            var tbl = t->ctx->alloc_init_cleanup::<SymbolTable>();
            dc->set_symbols(tbl);
            // A fill's tables are the fill's to freeze: HeaderIndex froze
            // `t->scopes` once, when the set finished, and never reads it again.
            if self.fill_target != &null { self.fill_scopes.push_back(dc); }
            else { t->scopes.push_back(dc); }
        }
        return dc->dc_symbols;
    }

    /// Append \p d under \p name in \p dc's table unless already there.
    /// A fill writes into a frozen HEADER on purpose -- into tables it just
    /// created (the shell's, a nested record's), never one the set froze.
    fn bind(self, t: *HeaderTarget, dc: *DeclContext, name: DeclName, d: *Decl) {
        if t->frozen && (self.fill_target == &null) { return; }
        var tbl = self.table_of(t, dc);
        var cell = tbl->lookup(name);
        if cell != &null {
            for var i: usize = 0; i < cell->size(); ++i { if cell->get(i) == d { return; } }
        }
        tbl->append(name, d);
    }

    /// One ModuleDecl per (header, qualified namespace). Reopenings within
    /// the header share it; across headers they are distinct decls, linked
    /// into one redeclaration ring (ForeignRegistry::link_namespace) that
    /// ChainBinding's multi-scope Module anchor and ADL both walk.
    fn namespace_for(self, t: *HeaderTarget, ns: const_obs::<clang::NamespaceDecl>) -> *ModuleDecl {
        var q  = self._qual(ns);
        var nq = q.std_string();
        var it = t->namespaces.find(nq);
        if it != t->namespaces.end() { return it->second; }

        var parent = self.scope_for(t, ns->getParent());
        if parent == &null { parent = static_cast::<*DeclContext>(t->tu); }   // a namespace's parent is always a namespace or the TU.
        var at = self.range_of(ns);
        var nm = self._str(ns->getName());
        var name = self.ident(t, nm, self.name_range_of(ns));
        var m = ModuleDecl::create(t->ctx, at, name, parent);
        m->set_visibility(VisibilityKind::Public, at);
        m->is_inline  = ns->isInline();
        m->lexical_dc  = reinterpret_cast::<*void>(parent);
        m->semantic_dc = reinterpret_cast::<*void>(parent);
        m->mark_definition();
        parent->add_decl(static_cast::<*Decl>(m));
        // Keyed through _ident_key, not the token's imm: the token is interned
        // where its RANGE is (_tok), the key where the TABLE is.
        self.bind(t, parent, self._ident_key(t, parent, nm), static_cast::<*Decl>(m));
        t->namespaces.insert(libcxx::make_pair(nq, m));
        self.reg->link_namespace(nq, m);
        return m;
    }

    // === pass 1: declare =======================================================

    /// Mint + register + bind the name. Returns the Kairo decl (existing one
    /// if this USR was already imported by an earlier set or redecl).
    fn declare(self, d: *clang::Decl) -> *Decl {
        var nd = llvm::dyn_cast::<clang::NamedDecl>(d);
        if nd == &null { return &null; }
        if nd->getDeclName().isEmpty() && (!self._anon_with_typedef(nd)) { return &null; }

        var t = self.target_of(d);
        if t == &null { self.n_skipped += 1; return &null; }

        // A namespace is not ONE entity to Kairo: each header's reopening is
        // its own ModuleDecl (namespace_for), unioned by phase I and
        // ChainBinding as a reopened module. Registering it by USR -- which
        // every reopening shares -- bound the FIRST header's ModuleDecl into
        // each later header's table, while that header's members went into a
        // ModuleDecl nothing bound.
        var ns = llvm::dyn_cast::<clang::NamespaceDecl>(d);
        if ns != &null { return static_cast::<*Decl>(self.namespace_for(t, ns)); }

        var canon = d->getCanonicalDecl();
        var usr   = TypeImport::usr_of(canon);
        if usr.empty() { self.n_skipped += 1; return &null; }

        var existing = self.reg->find(usr);
        if existing != &null {
            // Second declaration of a known entity: only the NAME binding
            // in THIS header's table is new.
            self._bind_named(t, nd, existing);
            return existing;
        }

        var kd = self._mint(t, nd);
        if kd == &null { self.n_skipped += 1; return &null; }
        var won = self.reg->put(usr, kd);
        if won != kd { self._bind_named(t, nd, won); return won; }

        self._stamp(kd, d, nd, usr, t);
        self._bind_named(t, nd, kd);
        self.n_declared += 1;
        return kd;
    }

    /// A friend function declared in the class \p cls -- the hidden friend
    /// `friend bool operator==(const It&, const It&) { ... }` every libc++
    /// node-based iterator compares through. Its entity belongs to the
    /// enclosing namespace, but C++ finds it ONLY by argument-dependent lookup
    /// through \p cls, so its name is bound in the class's table and nowhere
    /// else. It is not a member (no `self`); operator lookup takes such a
    /// function from a class table as a free candidate (OperatorTyping::_gather).
    fn declare_friend(self, fn_: *clang::Decl, cls: *clang::DeclContext) -> *Decl {
        self._friend_scope = cls;
        var kd = self.declare(fn_);
        self._friend_scope = &null;
        return kd;
    }

    priv fn _anon_with_typedef(self, nd: const_obs::<clang::NamedDecl>) -> bool {
        var tag = llvm::dyn_cast::<clang::TagDecl>(nd);
        if tag == &null { return false; }
        return tag->getTypedefNameForAnonDecl() != &null;
    }

    priv fn _display_name(self, nd: const_obs::<clang::NamedDecl>) -> string {
        var tag = llvm::dyn_cast::<clang::TagDecl>(nd);
        if (tag != &null) && (tag->getTypedefNameForAnonDecl() != &null) {
            return self._str(tag->getTypedefNameForAnonDecl()->getName());
        }
        return std::nstring_to_string(nd->getNameAsString());
    }

    /// The empty Kairo node of the right kind, parented, no slots filled.
    priv fn _mint(self, t: *HeaderTarget, nd: *clang::NamedDecl) -> *Decl {
        var parent = self.scope_for(t, nd->getDeclContext());
        if parent == &null { return &null; }                 // nowhere to live: see scope_for.
        var at     = self.range_of(nd);
        var name   = self.ident(t, self._display_name(nd), self.name_range_of(nd));
        var out: *Decl = &null;

        switch nd->getKind() {
            case clang::Decl::Namespace {
                return static_cast::<*Decl>(self.namespace_for(t, llvm::cast::<clang::NamespaceDecl>(nd)));
            }
            case clang::Decl::CXXRecord { out = self._mint_record(t, llvm::cast::<clang::CXXRecordDecl>(nd), at, name, parent); }
            case clang::Decl::Record    { out = self._mint_record(t, llvm::cast::<clang::RecordDecl>(nd),    at, name, parent); }
            case clang::Decl::ClassTemplate {
                var ct = llvm::cast::<clang::ClassTemplateDecl>(nd);
                out = self._mint_record(t, ct->getTemplatedDecl(), at, name, parent);
                // The template decl and its templated record are one entity to us.
                self.reg->put(TypeImport::usr_of(ct->getTemplatedDecl()->getCanonicalDecl()), out);
            }
            case clang::Decl::ClassTemplateSpecialization {
                var sp = llvm::cast::<clang::ClassTemplateSpecializationDecl>(nd);
                // Implicit: the registry's. Inside a fill too -- a nested
                // implicit specialization is reached as a TYPE (`traits<A>`
                // in a member typedef), gets its own shell from TypeImport,
                // and is filled on its own first lookup.
                if !sp->isExplicitSpecialization() { return &null; }
                out = self._mint_record(t, sp, at, name, parent);
            }
            case clang::Decl::ClassTemplatePartialSpecialization {
                out = self._mint_record(t, llvm::cast::<clang::CXXRecordDecl>(nd), at, name, parent);
            }
            case clang::Decl::Enum {
                var e = EnumDecl::create(t->ctx, at, name, parent);
                out = static_cast::<*Decl>(e);
            }
            case clang::Decl::Function     { out = static_cast::<*Decl>(FunctionDecl::create(t->ctx, at, name, parent)); }
            case clang::Decl::CXXMethod    { out = static_cast::<*Decl>(FunctionDecl::create(t->ctx, at, name, parent)); }
            case clang::Decl::CXXConstructor { out = static_cast::<*Decl>(FunctionDecl::create(t->ctx, at, name, parent)); }
            case clang::Decl::CXXDestructor  { out = static_cast::<*Decl>(FunctionDecl::create(t->ctx, at, name, parent)); }
            case clang::Decl::CXXConversion  { out = static_cast::<*Decl>(FunctionDecl::create(t->ctx, at, name, parent)); }
            case clang::Decl::FunctionTemplate {
                var ft = llvm::cast::<clang::FunctionTemplateDecl>(nd);
                out = static_cast::<*Decl>(FunctionDecl::create(t->ctx, at, name, parent));
                self.reg->put(TypeImport::usr_of(ft->getTemplatedDecl()->getCanonicalDecl()), out);
            }
            case clang::Decl::Typedef   { out = static_cast::<*Decl>(TypeAliasDecl::create(t->ctx, at, name, &null)); }
            case clang::Decl::TypeAlias { out = static_cast::<*Decl>(TypeAliasDecl::create(t->ctx, at, name, &null)); }
            case clang::Decl::TypeAliasTemplate {
                var at_ = llvm::cast::<clang::TypeAliasTemplateDecl>(nd);
                out = static_cast::<*Decl>(TypeAliasDecl::create(t->ctx, at, name, &null));
                self.reg->put(TypeImport::usr_of(at_->getTemplatedDecl()->getCanonicalDecl()), out);
            }
            case clang::Decl::Var {
                var v = llvm::cast::<clang::VarDecl>(nd);
                var sc = StorageClass::Var;
                if v->isConstexpr() || v->getType().isConstQualified() { sc = StorageClass::Const; }
                if v->isStaticDataMember() || v->getStorageClass() == clang::SC_Static { sc = StorageClass::Static; }
                out = static_cast::<*Decl>(VariableDecl::create(t->ctx, at, name, sc));
            }
            case clang::Decl::Field {
                var f = llvm::cast::<clang::FieldDecl>(nd);
                out = static_cast::<*Decl>(FieldDecl::create(t->ctx, at, name, StorageClass::Var, &null, f->getFieldIndex()));
            }
            case clang::Decl::EnumConstant {
                var ec = llvm::cast::<clang::EnumConstantDecl>(nd);
                var parent_enum = llvm::dyn_cast::<clang::EnumDecl>(ec->getDeclContext());
                var idx: u32 = 0;
                if parent_enum != &null {
                    for e in parent_enum->enumerators() { if e == ec { break; } idx += 1; }
                }
                out = static_cast::<*Decl>(EnumVariantDecl::create(t->ctx, at, name, idx));
            }
            case clang::Decl::Concept {
                var i = InterfaceDecl::create(t->ctx, at, name, parent);
                i->is_cxx_concept = true;
                out = static_cast::<*Decl>(i);
            }
            default { return &null; }   // using, friend, static_assert, deduction guide, ...
        }
        if out == &null { return &null; }
        out->lexical_dc  = reinterpret_cast::<*void>(parent);
        out->semantic_dc = reinterpret_cast::<*void>(parent);
        out->set_visibility(self._vis(nd), at);
        parent->add_decl(out);
        return out;
    }

    priv fn _mint_record(self, t: *HeaderTarget, rd: *clang::RecordDecl, at: SourceRange,
                         name: Token, parent: *DeclContext) -> *Decl {
        if rd->isUnion() {
            var u = UnionDecl::create(t->ctx, at, name, parent);
            u->ffi_is_union = true;
            if rd->isCompleteDefinition() { u->mark_definition(); }
            return static_cast::<*Decl>(u);
        }
        // C++ `struct` and `class` are one thing to clang and two to Kairo;
        // a Kairo `struct` admits no named methods, so everything with a
        // method or a base is a ClassDecl. Plain aggregates stay structs.
        var cxx = llvm::dyn_cast::<clang::CXXRecordDecl>(rd);
        var is_class = (cxx != &null) && cxx->hasDefinition()
                    && ((cxx->getNumBases() > 0) || cxx->isPolymorphic() || self._has_named_methods(cxx));
        if is_class || rd->isClass() {
            var c = ClassDecl::create(t->ctx, at, name, parent);
            if rd->isCompleteDefinition() { c->mark_definition(); }
            if cxx != &null {
                c->is_final    = cxx->hasAttr::<clang::FinalAttr>();
                c->is_abstract = cxx->hasDefinition() && cxx->isAbstract();
            }
            return static_cast::<*Decl>(c);
        }
        var s = StructDecl::create(t->ctx, at, name, parent);
        if rd->isCompleteDefinition() { s->mark_definition(); }
        return static_cast::<*Decl>(s);
    }

    priv fn _has_named_methods(self, cxx: const_obs::<clang::CXXRecordDecl>) -> bool {
        for m in cxx->methods() {
            if m->isImplicit() { continue; }
            if llvm::isa::<clang::CXXConstructorDecl>(m) || llvm::isa::<clang::CXXDestructorDecl>(m) { continue; }
            if m->isOverloadedOperator() { continue; }
            return true;
        }
        return false;
    }

    priv fn _vis(self, nd: const_obs::<clang::NamedDecl>) -> VisibilityKind {
        switch nd->getAccess() {
            case clang::AS_private   { return VisibilityKind::Private; }
            case clang::AS_protected { return VisibilityKind::Protected; }
            default                  { return VisibilityKind::Public; }
        }
    }

    /// The FFILinkage stamp. Every imported kind derives it except
    /// EnumDecl / InterfaceDecl / EnumVariant / Field / Module; those carry
    /// no per-decl foreign facts sema needs.
    priv fn _stamp(self, kd: *Decl, d: *clang::Decl, nd: *clang::NamedDecl, usr: libcxx::string, t: *HeaderTarget) {
        var sp   = self._qual(nd);
        // A hidden friend has no qualified spelling: qualified lookup never
        // finds it, only ADL does. Its bare name is what C++ calls it by.
        if self._friend_scope != &null { sp = self._display_name(nd); }
        var us   = std::nstring_to_string(usr);
        var vset = reinterpret_cast::<*void>(self._set);
        var vd   = reinterpret_cast::<*void>(d);
        decl_set_imported(kd, vd, us, sp, vset, t->fid);
    }

    /// The name binding: ident key, or ctor / operator key for functions.
    priv fn _bind_named(self, t: *HeaderTarget, nd: const_obs::<clang::NamedDecl>, kd: *Decl) {
        // A partial specialization is never the answer to a name: the primary
        // owns it, and partials_of(primary) -- M1's pairing, fed by
        // _define_spec's register_partial -- is the only reader that wants
        // it. Binding it here put `vector<bool, A>` beside `vector` (and
        // `unique_ptr<T[], D>` beside its primary) in std's table, and every
        // `std::vector` step saw two entities (R028E). The same rule as a
        // Kairo `class <> Box<[T]>`, which _stmt_decl_imm declines to declare.
        if llvm::isa::<clang::ClassTemplatePartialSpecializationDecl>(nd) { return; }
        var dc: *DeclContext = &null;
        if self._friend_scope != &null { dc = self.scope_for(t, self._friend_scope); }
        else                           { dc = self.scope_for(t, nd->getDeclContext()); }
        if dc == &null { return; }
        // getAsFunction, not a FunctionDecl cast: a FunctionTemplateDecl is
        // not one, and took the ident path below, so every operator template
        // was bound under its display name `operator!=` and no `!=` ever
        // found it -- libc++ declares its iterator comparisons that way.
        var fn_ = nd->getAsFunction();
        if fn_ != &null {
            if llvm::isa::<clang::CXXConstructorDecl>(fn_) { self.bind(t, dc, DeclName::ctor(), kd); return; }
            if llvm::isa::<clang::CXXDestructorDecl>(fn_) {
                self.bind(t, dc, DeclName::op_name(TokenKind::KwDelete, TokenKind::TkUnknown), kd);
                return;
            }
            if fn_->isOverloadedOperator() {
                var k0 = TokenKind::TkUnknown;
                var k1 = TokenKind::TkUnknown;
                if self._op_kinds(fn_->getOverloadedOperator(), &k0, &k1) {
                    self.bind(t, dc, DeclName::op_name(k0, k1), kd);
                }
                return;
            }
            if llvm::isa::<clang::CXXConversionDecl>(fn_) {
                self.bind(t, dc, DeclName::op_name(TokenKind::KwAs, TokenKind::TkUnknown), kd);
                return;
            }
        }
        self.bind(t, dc, self._ident_key(t, dc, self._display_name(nd)), kd);
        // An UNSCOPED enumerator is also visible in the enum's enclosing scope.
        var ec = llvm::dyn_cast::<clang::EnumConstantDecl>(nd);
        if ec != &null {
            var ed = llvm::dyn_cast::<clang::EnumDecl>(ec->getDeclContext());
            if (ed != &null) && (!ed->isScoped()) {
                var outer = self.scope_for(t, ed->getDeclContext());
                if outer != &null { self.bind(t, outer, self._ident_key(t, outer, self._display_name(nd)), kd); }
            }
        }
    }

    /// The identifier key for \p dc's table. A table is keyed by ITS OWN
    /// TU's imms (hard invariant #2), and the TU owning \p dc need not be the
    /// header being walked: a class template forward-declared in one header
    /// and defined in another (all of libc++: <__fwd/vector.h>) gets its
    /// members from the second header, into the first header's decl.
    /// Interning through the walking header filed every such member under a
    /// key no lookup could probe -- `v.push_back` was "no member".
    priv fn _ident_key(self, t: *HeaderTarget, dc: *DeclContext, s: string) -> DeclName {
        var ctx = t->ctx;
        var tu  = NameLookup::tu_of(dc);
        if (tu != &null) && (tu->ctx != &null) { ctx = tu->ctx; }
        return DeclName::ident(ctx->get_imm_table()->intern_ident_copy(s));
    }

    /// C++ overloaded operator -> the Kairo `fn op` token pair. False for an
    /// operator Kairo has no spelling for; the Kairo decl still exists for
    /// EmitIR, it just is not findable by name.
    ///
    /// NOT here on purpose: OO_New / OO_Delete / OO_Array_New / OO_Array_Delete.
    /// Kairo's `op delete` is the DESTRUCTOR (cleanup of a possibly stack
    /// object, C++ `~T()`), not deallocation; C++ `operator delete` is
    /// allocation-side and has no Kairo counterpart. See _bind_named for the
    /// destructor mapping.
    priv fn _op_kinds(self, oo: clang::OverloadedOperatorKind, k0: *TokenKind, k1: *TokenKind) -> bool {
        (*k1) = TokenKind::TkUnknown;
        switch oo {
            case clang::OO_Plus                { (*k0) = TokenKind::OpPlus; }
            case clang::OO_Minus               { (*k0) = TokenKind::OpMinus; }
            case clang::OO_Star                { (*k0) = TokenKind::OpStar; }
            case clang::OO_Slash               { (*k0) = TokenKind::OpSlash; }
            case clang::OO_Percent             { (*k0) = TokenKind::OpPercent; }
            case clang::OO_Caret               { (*k0) = TokenKind::OpCaret; }
            case clang::OO_Amp                 { (*k0) = TokenKind::OpAmp; }
            case clang::OO_Pipe                { (*k0) = TokenKind::OpPipe; }
            case clang::OO_Tilde               { (*k0) = TokenKind::OpTilde; }
            case clang::OO_Exclaim             { (*k0) = TokenKind::OpExclaim; }
            case clang::OO_Equal               { (*k0) = TokenKind::OpEqual; }
            case clang::OO_Less                { (*k0) = TokenKind::OpLess; }
            case clang::OO_Greater             { (*k0) = TokenKind::OpGreater; }
            case clang::OO_PlusEqual           { (*k0) = TokenKind::OpPlusEqual; }
            case clang::OO_MinusEqual          { (*k0) = TokenKind::OpMinusEqual; }
            case clang::OO_StarEqual           { (*k0) = TokenKind::OpStarEqual; }
            case clang::OO_SlashEqual          { (*k0) = TokenKind::OpSlashEqual; }
            case clang::OO_PercentEqual        { (*k0) = TokenKind::OpPercentEqual; }
            case clang::OO_CaretEqual          { (*k0) = TokenKind::OpCaretEqual; }
            case clang::OO_AmpEqual            { (*k0) = TokenKind::OpAmpEqual; }
            case clang::OO_PipeEqual           { (*k0) = TokenKind::OpPipeEqual; }
            case clang::OO_LessLess            { (*k0) = TokenKind::OpLessLess; }
            case clang::OO_GreaterGreater      { (*k0) = TokenKind::OpGreaterGreater; }
            case clang::OO_LessLessEqual       { (*k0) = TokenKind::OpLessLessEqual; }
            case clang::OO_GreaterGreaterEqual { (*k0) = TokenKind::OpGreaterGreaterEqual; }
            case clang::OO_EqualEqual          { (*k0) = TokenKind::OpEqualEqual; }
            case clang::OO_ExclaimEqual        { (*k0) = TokenKind::OpExclaimEqual; }
            case clang::OO_LessEqual           { (*k0) = TokenKind::OpLessEqual; }
            case clang::OO_GreaterEqual        { (*k0) = TokenKind::OpGreaterEqual; }
            case clang::OO_Spaceship           { (*k0) = TokenKind::OpLessEqualGreater; }
            case clang::OO_AmpAmp              { (*k0) = TokenKind::OpAmpAmp; }
            case clang::OO_PipePipe            { (*k0) = TokenKind::OpPipePipe; }
            case clang::OO_PlusPlus            { (*k0) = TokenKind::OpPlusPlus; }
            case clang::OO_MinusMinus          { (*k0) = TokenKind::OpMinusMinus; }
            case clang::OO_Comma               { (*k0) = TokenKind::OpComma; }
            case clang::OO_Arrow               { (*k0) = TokenKind::OpArrow; }
            case clang::OO_ArrowStar           { (*k0) = TokenKind::OpArrowStar; }
            case clang::OO_Call                { (*k0) = TokenKind::OpLParen;  (*k1) = TokenKind::OpRParen; }
            case clang::OO_Subscript           { (*k0) = TokenKind::OpLSquare; (*k1) = TokenKind::OpRSquare; }
            default { return false; }   // new/delete family, co_await, conditional.
        }
        return true;
    }

    // === pass 2: define ==========================================================

    /// Fill the slots. Idempotent: a second set reaching the same decl sees
    /// the registry hit in declare() and never calls this.
    fn define(self, d: *clang::Decl, kd: *Decl, ti: *TypeImport) {
        if (d == &null) || (kd == &null) { return; }
        var t = self.target_of(d);
        if (t == &null) || (t->frozen && (self.fill_target == &null)) { return; }
        self.n_defined += 1;

        // Which Kairo decl owns each template depth in scope here: without
        // it every `T` in a template's signature imports as opaque.
        ti->tpl_owners.clear();
        self._template_owners(d, ti->tpl_owners);

        switch d->getKind() {
            case clang::Decl::CXXRecord                          { self._define_record(t, llvm::cast::<clang::CXXRecordDecl>(d), kd, ti); }
            case clang::Decl::Record                             { self._define_record_c(t, llvm::cast::<clang::RecordDecl>(d), kd, ti); }
            case clang::Decl::ClassTemplate                      { self._define_class_template(t, llvm::cast::<clang::ClassTemplateDecl>(d), kd, ti); }
            case clang::Decl::ClassTemplateSpecialization        { self._define_spec(t, llvm::cast::<clang::ClassTemplateSpecializationDecl>(d), kd, ti, false); }
            case clang::Decl::ClassTemplatePartialSpecialization { self._define_spec(t, llvm::cast::<clang::ClassTemplateSpecializationDecl>(d), kd, ti, true); }
            case clang::Decl::Enum                               { self._define_enum(t, llvm::cast::<clang::EnumDecl>(d), kd, ti); }
            case clang::Decl::Function                           { self._define_function(t, llvm::cast::<clang::FunctionDecl>(d), kd, ti, &null); }
            case clang::Decl::CXXMethod                          { self._define_function(t, llvm::cast::<clang::FunctionDecl>(d), kd, ti, &null); }
            case clang::Decl::CXXConstructor                     { self._define_function(t, llvm::cast::<clang::FunctionDecl>(d), kd, ti, &null); }
            case clang::Decl::CXXDestructor                      { self._define_function(t, llvm::cast::<clang::FunctionDecl>(d), kd, ti, &null); }
            case clang::Decl::CXXConversion                      { self._define_function(t, llvm::cast::<clang::FunctionDecl>(d), kd, ti, &null); }
            case clang::Decl::FunctionTemplate {
                var ft = llvm::cast::<clang::FunctionTemplateDecl>(d);
                self._define_function(t, ft->getTemplatedDecl(), kd, ti, ft->getTemplateParameters());
            }
            case clang::Decl::Typedef   { cast::<TypeAliasDecl>(kd)->aliased = ti->_import(llvm::cast::<clang::TypedefNameDecl>(d)->getUnderlyingType()); }
            case clang::Decl::TypeAlias { cast::<TypeAliasDecl>(kd)->aliased = ti->_import(llvm::cast::<clang::TypedefNameDecl>(d)->getUnderlyingType()); }
            case clang::Decl::TypeAliasTemplate {
                var at_ = llvm::cast::<clang::TypeAliasTemplateDecl>(d);
                var td  = cast::<TypeAliasDecl>(kd);
                self._generic_params(t, static_cast::<*Decl>(td), at_->getTemplateParameters(), ti, &(td->generic_params));
                td->aliased = ti->_import(at_->getTemplatedDecl()->getUnderlyingType());
            }
            case clang::Decl::Var {
                var v = llvm::cast::<clang::VarDecl>(d);
                var kv = cast::<VariableDecl>(kd);
                kv->type_ = ti->_import(v->getType());
                kv->is_thread = v->getTLSKind() != clang::VarDecl::TLS_None;
            }
            case clang::Decl::Field {
                var f = llvm::cast::<clang::FieldDecl>(d);
                cast::<FieldDecl>(kd)->type_ = ti->_import(f->getType());
                cast::<FieldDecl>(kd)->is_mutable = f->isMutable();
            }
            case clang::Decl::EnumConstant { 0; }        // value: EmitIR spells the enumerator by name.
            case clang::Decl::Concept      { 0; }        // constraint-only bound; no surface to import.
            default { 0; }
        }
    }

    /// Every Kairo decl owning a template parameter list that encloses \p d
    /// (\p d's own included), outermost first: index = clang depth. A method
    /// of a class template sees the class at depth 0; a member template of
    /// it adds itself at depth 1.
    priv fn _template_owners(self, d: *clang::Decl, out: ref!(vec::<*Decl>)) {
        var inner_first = vec::<*Decl>();
        var cur = d;
        while cur != &null {
            var kd = self._tpl_owner(cur);
            if kd != &null { inner_first.push_back(kd); }
            var dc = cur->getDeclContext();
            if (dc == &null) || dc->isTranslationUnit() { break; }
            cur = clang::Decl::castFromDeclContext(dc);
        }
        var n = inner_first.size();
        for var i: usize = 0; i < n; ++i { out.push_back(inner_first[n - 1 - i]); }
    }

    /// The Kairo decl for \p c when \p c owns a template parameter list: a
    /// template (registered under its templated decl's USR too), a record or
    /// function a template describes, or a partial specialization.
    priv fn _tpl_owner(self, c: *clang::Decl) -> *Decl {
        var td = llvm::dyn_cast::<clang::TemplateDecl>(c);
        if td != &null {
            var inner = td->getTemplatedDecl();                 // null for a concept.
            if inner == &null { return &null; }
            return self.reg->find(TypeImport::usr_of(inner->getCanonicalDecl()));
        }
        if llvm::isa::<clang::ClassTemplatePartialSpecializationDecl>(c) {
            return self.reg->find(TypeImport::usr_of(c->getCanonicalDecl()));
        }
        var rd = llvm::dyn_cast::<clang::CXXRecordDecl>(c);
        if (rd != &null) && (rd->getDescribedClassTemplate() != &null) {
            return self.reg->find(TypeImport::usr_of(rd->getCanonicalDecl()));
        }
        var fd = llvm::dyn_cast::<clang::FunctionDecl>(c);
        if (fd != &null) && (fd->getDescribedFunctionTemplate() != &null) {
            return self.reg->find(TypeImport::usr_of(fd->getCanonicalDecl()));
        }
        return &null;
    }

    // --- records ----------------------------------------------------------------

    /// Fill mode's record step: fields, methods, bases and layout of the
    /// completed specialization onto the shell. Runs after its members were
    /// declared and defined -- the order HeaderIndex gives a header's records.
    fn define_instance(self, spec: *clang::ClassTemplateSpecializationDecl, shell: *Decl, ti: *TypeImport) {
        if (self.fill_target == &null) || (spec == &null) || (shell == &null) { return; }
        ti->tpl_owners.clear();       // concrete: no parameter list encloses a specialization.
        self._define_record(self.fill_target, spec, shell, ti);
    }

    priv fn _define_record_c(self, t: *HeaderTarget, rd: *clang::RecordDecl, kd: *Decl, ti: *TypeImport) {
        var def = rd->getDefinition();
        if def == &null { return; }
        var fields = vec::<*FieldDecl>();
        self._collect_fields(t, def, fields, ti);
        if isa::<StructDecl>(kd)     { cast::<StructDecl>(kd)->fields.from_vec(&fields, t->ctx); }
        else if isa::<UnionDecl>(kd) { cast::<UnionDecl>(kd)->fields.from_vec(&fields, t->ctx); }
        else if isa::<ClassDecl>(kd) { cast::<ClassDecl>(kd)->fields.from_vec(&fields, t->ctx); }
        self._layout(def, kd);
    }

    priv fn _define_record(self, t: *HeaderTarget, rd: *clang::CXXRecordDecl, kd: *Decl, ti: *TypeImport) {
        var def = rd->getDefinition();
        if def == &null { return; }

        var fields  = vec::<*FieldDecl>();
        var methods = vec::<*FunctionDecl>();
        self._collect_fields(t, def, fields, ti);
        for m in def->methods() {
            if m->isImplicit() && (!m->isUserProvided()) { continue; }
            var km = self.reg->find(TypeImport::usr_of(m->getCanonicalDecl()));
            if km == &null { continue; }
            methods.push_back(cast::<FunctionDecl>(km));
        }
        var bases = vec::<InheritEdge>();
        for b in def->bases() {
            var e = InheritEdge{};
            e.base       = ti->_import(b.getType());
            e.is_virtual = b.isVirtual();
            e.visibility = static_cast::<u8>(self._vis_of_access(b.getAccessSpecifier()));
            e.range      = self.range_of(def);
            bases.push_back(e);
        }

        if isa::<ClassDecl>(kd) {
            var c = cast::<ClassDecl>(kd);
            c->fields.from_vec(&fields, t->ctx);
            c->methods.from_vec(&methods, t->ctx);
            c->derives_list.from_vec(&bases, t->ctx);
            c->ffi_is_final = def->hasAttr::<clang::FinalAttr>();
        } else if isa::<StructDecl>(kd) {
            var s = cast::<StructDecl>(kd);
            s->fields.from_vec(&fields, t->ctx);
            s->methods.from_vec(&methods, t->ctx);
        } else if isa::<UnionDecl>(kd) {
            var u = cast::<UnionDecl>(kd);
            u->fields.from_vec(&fields, t->ctx);
            u->methods.from_vec(&methods, t->ctx);
        }
        self._layout(def, kd);
    }

    priv fn _collect_fields(self, t: *HeaderTarget, def: *clang::RecordDecl, out: ref!(vec::<*FieldDecl>), ti: *TypeImport) {
        for f in def->fields() {
            if f->isAnonymousStructOrUnion() {
                // Its members were declared into THIS record's scope
                // (scope_for sees through the transparent context).
                var inner = f->getType()->getAsRecordDecl();
                if inner != &null { self._collect_fields(t, inner, out, ti); }
                continue;
            }
            var kf = self.reg->find(TypeImport::usr_of(f->getCanonicalDecl()));
            if kf == &null { continue; }
            out.push_back(cast::<FieldDecl>(kf));
        }
    }

    priv fn _vis_of_access(self, a: clang::AccessSpecifier) -> VisibilityKind {
        if a == clang::AS_private   { return VisibilityKind::Private; }
        if a == clang::AS_protected { return VisibilityKind::Protected; }
        return VisibilityKind::Public;
    }

    /// clang's layout onto the mixin. Only for a complete, non-dependent
    /// definition; a template pattern has no layout and `known` stays false.
    priv fn _layout(self, def: *clang::RecordDecl, kd: *Decl) {
        if def->isDependentType() || def->isInvalidDecl() { return; }
        if !def->isCompleteDefinition() { return; }
        var lay = ForeignLayout{};
        var rl  = &(self.cctx->getASTRecordLayout(def));
        lay.known       = true;
        lay.size_bytes  = static_cast::<u64>(rl->getSize().getQuantity());
        lay.align_bytes = static_cast::<u64>(rl->getAlignment().getQuantity());
        var i: u32 = 0;
        for f in def->fields() { lay.field_offsets.push_back(rl->getFieldOffset(i)); i += 1; }
        var cxx = llvm::dyn_cast::<clang::CXXRecordDecl>(def);
        if cxx != &null {
            lay.has_vfptr            = rl->hasOwnVFPtr();
            lay.polymorphic          = cxx->isPolymorphic();
            lay.abstract_            = cxx->isAbstract();
            lay.trivially_copyable   = cxx->isTriviallyCopyable();
            lay.trivial_dtor         = cxx->hasTrivialDestructor();
            lay.trivial_default_ctor = cxx->hasTrivialDefaultConstructor();
        } else {
            lay.trivially_copyable = true; lay.trivial_dtor = true; lay.trivial_default_ctor = true;
        }
        if isa::<ClassDecl>(kd)       { cast::<ClassDecl>(kd)->layout  = lay; }
        else if isa::<StructDecl>(kd) { cast::<StructDecl>(kd)->layout = lay; }
        else if isa::<UnionDecl>(kd)  { cast::<UnionDecl>(kd)->layout  = lay; }
    }

    // --- templates ----------------------------------------------------------------

    priv fn _define_class_template(self, t: *HeaderTarget, ct: *clang::ClassTemplateDecl, kd: *Decl, ti: *TypeImport) {
        var gps = decl_generic_params_slot(kd);
        if gps == &null { return; }
        self._generic_params(t, kd, ct->getTemplateParameters(), ti, gps);
        self._define_record(t, ct->getTemplatedDecl(), kd, ti);
    }

    /// Explicit (full) and partial specializations register against the
    /// primary exactly as T registers a Kairo `class <> Box<i32>`.
    priv fn _define_spec(self, t: *HeaderTarget, sp: *clang::ClassTemplateSpecializationDecl,
                         kd: *Decl, ti: *TypeImport, partial: bool) {
        var prim = self.reg->find(TypeImport::usr_of(sp->getSpecializedTemplate()->getCanonicalDecl()));
        if prim == &null { return; }
        var rep  = NameLookup::representative(prim);
        var args = vec::<*Type>();
        var ok   = true;
        var list = sp->getTemplateArgs().asArray();
        for var i: usize = 0; i < list.size(); ++i {
            if list[i].getKind() != clang::TemplateArgument::Type { ok = false; break; }
            args.push_back(ti->_import(list[i].getAsType()));
        }
        if !ok { return; }                 // non-type args: no registry shape.
        self._set_spec(kd, (SpecKind::Partial) if (partial) else (SpecKind::Explicit), rep, args, t->ctx);
        if partial {
            var ps = llvm::cast::<clang::ClassTemplatePartialSpecializationDecl>(sp);
            var gps = decl_generic_params_slot(kd);
            if gps != &null { self._generic_params(t, kd, ps->getTemplateParameters(), ti, gps); }
            self.instances->register_partial(rep, kd);
        } else {
            self.instances->register_explicit(rep, &args, kd, t->fid);
        }
        self._define_record(t, sp, kd, ti);
    }

    priv fn _set_spec(self, kd: *Decl, k: SpecKind, prim: *Decl, args: ref!(vec::<*Type>), ctx: *ASTContext) {
        decl_set_spec_kind(kd, k);
        decl_set_instantiated_from(kd, prim);
        // spec_args has no slot accessor: the one per-kind write left.
        if isa::<ClassDecl>(kd)       { cast::<ClassDecl>(kd)->spec_args.from_vec(&args, ctx);  }
        else if isa::<StructDecl>(kd) { cast::<StructDecl>(kd)->spec_args.from_vec(&args, ctx); }
        else if isa::<UnionDecl>(kd)  { cast::<UnionDecl>(kd)->spec_args.from_vec(&args, ctx);  }
    }

    /// TemplateParameterList -> GenericParamDecls, owner stamped so
    /// `generic_param(owner, index)` in TypeImport and ChainBinding's
    /// `_param_of` agree (the same contract T's _push_frame keeps).
    priv fn _generic_params(self, t: *HeaderTarget, owner: *Decl, tpl: const_obs::<clang::TemplateParameterList>,
                            ti: *TypeImport, out: *FrozenList::<*GenericParamDecl>) {
        var gps = vec::<*GenericParamDecl>();
        for var i: u32 = 0; i < tpl->size(); ++i {
            var p  = tpl->getParam(i);
            var nm = self._str(p->getName());
            if nm.size() == 0 { nm = f"__P{i}"; }
            var gp = GenericParamDecl::create(t->ctx, self.range_of(p), self.ident(t, nm, self.range_of(p)), i);
            gp->owner = NameLookup::representative(owner);
            gp->kind_bound = GenericParamKindBound::Any;      // opaque: the Rust rule. A concept bound would go in requires.
            var tt = llvm::dyn_cast::<clang::TemplateTypeParmDecl>(p);
            if tt != &null {
                gp->is_pack = tt->isParameterPack();
                if tt->hasDefaultArgument() {
                    gp->default_type = ti->_import(tt->getDefaultArgument().getArgument().getAsType());
                }
            }
            var nt = llvm::dyn_cast::<clang::NonTypeTemplateParmDecl>(p);
            if nt != &null {
                gp->is_const_param = true;
                gp->is_pack        = nt->isParameterPack();
                gp->value_type     = ti->_import(nt->getType());
            }
            // Template template params: recorded as an opaque type param.
            gp->impl_bounds.from_raw(static_cast::<*InheritEdge>(&null), 0);
            gp->derives_bounds.from_raw(static_cast::<*InheritEdge>(&null), 0);
            gps.push_back(gp);
        }
        out->from_vec(&gps, t->ctx);
    }

    // --- enums -----------------------------------------------------------------------

    priv fn _define_enum(self, t: *HeaderTarget, ed: *clang::EnumDecl, kd: *Decl, ti: *TypeImport) {
        var def = ed->getDefinition();
        var ke  = cast::<EnumDecl>(kd);
        ke->ffi_scoped_enum = ed->isScoped();
        // define() runs once per CLANG redeclaration, and every one of them
        // maps to this one Kairo decl (the registry). Fill and mark it only
        // from the definition itself: libc++ forward-declares enums
        // (`enum class byte : unsigned char;`) and defines them later, and a
        // second mark_definition is the "two definitions in one chain" ICE.
        if (def == &null) || (def != ed) { return; }
        ke->mark_definition();
        ke->underlying = ti->_import(def->getIntegerType());
        var vs = vec::<*EnumVariantDecl>();
        for ec in def->enumerators() {
            var kv = self.reg->find(TypeImport::usr_of(ec->getCanonicalDecl()));
            if kv == &null { continue; }
            vs.push_back(cast::<EnumVariantDecl>(kv));
        }
        ke->variants.from_vec(&vs, t->ctx);
        ke->is_adt = false;
    }

    // --- functions ----------------------------------------------------------------

    priv fn _define_function(self, t: *HeaderTarget, fd: *clang::FunctionDecl, kd: *Decl,
                             ti: *TypeImport, tpl: const_obs::<clang::TemplateParameterList>) {
        var kf = cast::<FunctionDecl>(kd);
        if tpl != &null { self._generic_params(t, kd, tpl, ti, &(kf->generic_params)); }

        var params = vec::<*ParamDecl>();
        var idx: u32 = 0;

        // Receiver. A non-static method gets Kairo's `self`, typed as the
        // record (what T's _synthesize_receiver would write). Statics have
        // no receiver and are found through `Type::m`.
        var m = llvm::dyn_cast::<clang::CXXMethodDecl>(fd);
        var is_ctor = llvm::isa::<clang::CXXConstructorDecl>(fd);
        var is_dtor = llvm::isa::<clang::CXXDestructorDecl>(fd);
        if (m != &null) && (!m->isStatic()) {
            var at = self.name_range_of(fd);
            var self_tok = self._tok(t, at, TokenKind::KwSelf, "self");
            var sp = ParamDecl::create_self(t->ctx, at, self_tok);
            sp->type_    = ti->_import(m->getThisType()->getPointeeType());
            sp->is_const = m->isConst();
            sp->index    = 0;
            params.push_back(sp);
            idx = 1;
            kf->ffi_ref_qualifier = (1) if (m->getRefQualifier() == clang::RQ_LValue)
                                  else (2) if (m->getRefQualifier() == clang::RQ_RValue) else (0);
            kf->ffi_virtual      = m->isVirtual();
            kf->ffi_pure_virtual = m->isPureVirtual();
            if m->isVirtual() { kf->abi = AbiKind::Virtual; }
            if m->size_overridden_methods() > 0 { kf->abi = AbiKind::Override; }
        } else if m != &null {
            kf->ffi_static_member = true;
            kf->abi = AbiKind::Static;
        }

        for p in fd->parameters() {
            var pat  = self.range_of(p);
            var pnm  = self._str(p->getName());
            var unnamed = pnm.size() == 0;
            if unnamed { pnm = f"__arg{idx}"; }
            var kp = ParamDecl::create(t->ctx, pat, self.ident(t, pnm, pat), ti->_import(p->getType()), idx, unnamed);
            kp->has_default = p->hasDefaultArg();           // spec: new field; OverloadResolution reads it.
            kf->cxx_param_spellings.push_back(ti->spelling(p->getType()));
            params.push_back(kp);
            idx += 1;
        }
        kf->params.from_vec(&params, t->ctx);
        kf->is_variadic    = false;                      // Kairo packs are generic; C `...` is its own flag:
        kf->ffi_c_variadic = fd->isVariadic();

        var rt = fd->getReturnType();
        kf->cxx_return_spelling = ti->spelling(rt);
        if rt->isVoidType() || is_ctor || is_dtor { kf->return_type = &null; }
        else { kf->return_type = ti->_import(rt); }
        if fd->isNoReturn() { kf->is_noreturn = true; }

        if fd->isOverloadedOperator() {
            kf->is_operator = true;
            var k0 = TokenKind::TkUnknown;
            var k1 = TokenKind::TkUnknown;
            if self._op_kinds(fd->getOverloadedOperator(), &k0, &k1) {
                var toks = vec::<Token>();
                var at = self.name_range_of(fd);
                toks.push_back(self._tok(t, at, k0, std::nstring_to_string(libcxx::string(clang::getOperatorSpelling(fd->getOverloadedOperator())))));
                if k1 != TokenKind::TkUnknown { toks.push_back(self._tok(t, at, k1, "")); }
                kf->op_token.from_vec(&toks, t->ctx);
            }
        }
        if llvm::isa::<clang::CXXConversionDecl>(fd) {
            kf->is_operator = true;
            kf->ffi_conversion_op = true;
            var toks = vec::<Token>();
            toks.push_back(self._tok(t, self.name_range_of(fd), TokenKind::KwAs, "as"));
            kf->op_token.from_vec(&toks, t->ctx);
        }

        if is_dtor {
            kf->is_operator = true;
            var toks = vec::<Token>();
            toks.push_back(self._tok(t, self.name_range_of(fd), TokenKind::KwDelete, "delete"));
            kf->op_token.from_vec(&toks, t->ctx);
        }

        var mods = FnModifier::None;
        if (m != &null) && m->isConst() { mods = mods | FnModifier::IsConst; }
        if fd->isConstexpr()            { kf->ffi_constexpr = true; }
        if fd->isInlined()              { mods = mods | FnModifier::IsInline; }
        kf->modifiers = mods;

        kf->body_kind = FnBodyKind::None;
        if fd->isDeleted()                  { kf->body_kind = FnBodyKind::Delete; kf->ffi_deleted = true; }
        else if fd->isDefaulted()           { kf->body_kind = FnBodyKind::Default; }
        else if (m != &null) && m->isPureVirtual() { kf->body_kind = FnBodyKind::Virtual; }
        kf->ffi_noexcept = fd->getExceptionSpecType() == clang::EST_BasicNoexcept
                        || fd->getExceptionSpecType() == clang::EST_NoexceptTrue;
        if is_ctor {
            var c = llvm::cast::<clang::CXXConstructorDecl>(fd);
            kf->ffi_explicit = c->isExplicit();
            if c->isCopyConstructor() { kf->transfer = TransferKind::Copy; }
            if c->isMoveConstructor() { kf->transfer = TransferKind::Move; }
        }
        if llvm::isa::<clang::CXXConversionDecl>(fd) {
            kf->ffi_explicit = llvm::cast::<clang::CXXConversionDecl>(fd)->isExplicit();
        }
    }
}