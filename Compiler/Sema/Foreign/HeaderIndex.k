/// --- The Kairo Project -------------------- Sema/Foreign/HeaderIndex.k --- ///
///
///   \brief Driver-thread index of a built HeaderSet: mint a Kairo fid, an
///          ASTContext and a TranslationUnit per header clang touched (in
///          the order it touched them), then two passes of DeclImport over
///          the clang TU, then freeze every table this set created.
///
///   \par Order
///     Fids are minted from HeaderSet::files in first-touch order, so the
///     Kairo SM and the phase-A clang SM agree on the order files entered.
///     A header some earlier set already minted keeps its fid and its TU;
///     this set neither re-declares nor re-defines it (HeaderTarget::frozen),
///     but still records cfid -> kfid for it so locations in this set's AST
///     that fall in that header map.
///
///   \par Threading
///     Driver thread only. Everything it touches (SM, TCM, GlobalDisambig-
///     Table, the header contexts' arenas) is driver-owned. importer_for /
///     walk_declare are also ForeignInstantiate's, which serializes its own
///     callers.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "clang/AST/ASTContext.h";
ffi "c++" import "clang/AST/Decl.h";
ffi "c++" import "clang/AST/DeclBase.h";
ffi "c++" import "clang/AST/DeclCXX.h";
ffi "c++" import "clang/AST/DeclTemplate.h";

import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::GlobalDisambigTable::*;
import AST::Context::SymbolTable::*;
import AST::Context::TranslationUnit::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::Node::Casting::*;
import Location::SourceManager::*;
import Support::FileIO::Path::*;
import Support::TimeReport::*;
import Token::TokenCacheManager::*;
import Diagnostic::Engine::*;
import Config::Invocation::*;
import Resolution::ModulePath::*;
import Resolution::ImportProbe::*;
import Sema::Foreign::ForeignRegistry::*;
import Sema::Foreign::TypeImport::*;
import Sema::Foreign::DeclImport::*;
import Interop::Clang::HeaderSet::*;

class HeaderIndex {
    priv var _sm:   obs::<SourceManager>;
    priv var _tcm:  obs::<TokenCacheManager>;
    priv var _diag: obs::<DiagEngine>;
    priv var _res:  obs::<ImportResolver>;
    priv var _inv:  obs::<CompilerInvocation>;
    priv var _g:    obs::<GlobalDisambigTable>;
    priv var _reg:  obs::<ForeignRegistry>;

    /// header fid -> target, across every set indexed by this compiler.
    priv var _targets: libcxx::unordered_map::<u32, *HeaderTarget>;

    fn HeaderIndex(self, sm: *SourceManager, tcm: *TokenCacheManager, diag: *DiagEngine,
                   res: *ImportResolver, inv: *CompilerInvocation, g: *GlobalDisambigTable,
                   reg: *ForeignRegistry) {
        self._sm = sm; self._tcm = tcm; self._diag = diag; self._res = res;
        self._inv = inv; self._g = g; self._reg = reg;
    }

    fn op delete (self) {
        for var it = self._targets.begin(); it != self._targets.end(); ++it { std::destroy(it->second); }
        self._targets.clear();
    }

    fn target_for_fid(self, fid: u32) -> *HeaderTarget {
        var it = self._targets.find(fid);
        if it == self._targets.end() { return &null; }
        return it->second;
    }

    /// The one way to mint a foreign TU from outside the index.
    fn ensure_target(self, fid: u32, path: string) -> *HeaderTarget { return self._target(fid, path); }

    /// A DeclImport wired to \p hs and this index's targets. index() builds
    /// one per set; ForeignInstantiate builds one per fill and switches it to
    /// fill mode (DeclImport::fill_target).
    fn importer_for(self, hs: *HeaderSet) -> DeclImport {
        var di = DeclImport();
        di._set = hs; di.reg = self._reg; di.ksm = self._sm;
        di.store = self._g->types(); di.instances = self._g->instances();
        di.cctx = hs->ast(); di.csm = hs->csm();
        di.targets = &(self._targets);
        return di;
    }

    /// A TypeImport against \p hs's AST. \p kctx interns opaque names; \p fid
    /// is the home of any registry entry it mints.
    fn type_importer_for(self, hs: *HeaderSet, kctx: *ASTContext, fid: u32) -> TypeImport {
        return TypeImport(self._g->types(), self._g->instances(), self._reg, hs->ast(), kctx, fid);
    }

    /// The one entry point. Idempotent per set.
    fn index(self, hs: *HeaderSet) -> bool {
        if hs->indexed { return true; }
        if !hs->built.load(std::MemoryOrder::acquire) { return false; }
        hs->indexed = true;
        if (!hs->ok) || (hs->ast() == &null) {
            Logger::error(Logger::Stage::Driver, "HeaderIndex: set failed to build; nothing imported");
            return false;
        }
        var _t = TimeRegion("HeaderIndex");

        // The builtin singletons are built once per build, normally by the
        // first SemaContext -- and headers are indexed BEFORE any sema runs.
        // Unbuilt, CanonicalTypeStore::builtin answers null and every `int`
        // in every header imports as opaque. init() is first-caller-wins, so
        // the width comes from exactly where SemaContext takes it; a second
        // source would give usize two sizes depending on who ran first.
        var pbits: usize = 64;
        var lp64 = true;
        if self._inv != &null { pbits = self._inv->target.pointer_width; lp64 = self._inv->target.lp64; }
        if pbits == 0 { pbits = 64; lp64 = true; }
        self._g->types()->init(pbits, lp64);

        // 1. fids + contexts + TUs, in clang's touch order.
        var fresh = vec::<*HeaderTarget>();
        for var i: usize = 0; i < hs->files.size(); ++i {
            var f = &(hs->files[i]);
            var fid = self._sm->load_file(Path(f->path));     // a known path answers with its existing fid (VFM cache hit).
            if fid == u32(-1) { continue; }
            f->kfid = fid;
            hs->cfid_to_kfid.insert(libcxx::make_pair(f->cfid_hash, fid));
            var t = self._target(fid, f->path);
            if !t->frozen { fresh.push_back(t); }
        }

        // 2. import.
        var di = self.importer_for(hs);

        var any_ctx: *ASTContext = &null;
        if fresh.size() > 0 { any_ctx = fresh[0]->ctx; }
        else if hs->files.size() > 0 { any_ctx = self._target(hs->files[0].kfid, hs->files[0].path)->ctx; }
        var home_fid: u32 = (fresh[0]->fid) if (fresh.size() > 0) else (0);
        var ti = self.type_importer_for(hs, any_ctx, home_fid);

        var pairs = vec::<(*void, *Decl)>();                 // (clang::Decl*, Kairo decl) for pass 2.
        self.walk_declare(hs->ast()->getTranslationUnitDecl(), &di, pairs);
        for var i: usize = 0; i < pairs.size(); ++i {
            di.define(reinterpret_cast::<*clang::Decl>(libcxx::get::<0>(pairs[i])), libcxx::get::<1>(pairs[i]), &ti);
        }

        // 3. freeze what this set created.
        for var i: usize = 0; i < fresh.size(); ++i {
            var t = fresh[i];
            for var s: usize = 0; s < t->scopes.size(); ++s {
                if t->scopes[s]->dc_symbols != &null { t->scopes[s]->dc_symbols->freeze(); }
            }
            if t->tu->dc_symbols == &null {           // a header that declared nothing at file scope still needs a table.
                var tbl = t->ctx->alloc_init_cleanup::<SymbolTable>();
                tbl->freeze();
                t->tu->set_symbols(tbl);
            }
            self._module_self(t);
            t->frozen = true;
        }

        Logger::info(Logger::Stage::Driver,
            f"HeaderIndex: {fresh.size()} new header TU(s), {di.n_declared} decl(s) declared, {di.n_defined} defined, {di.n_skipped} skipped, {ti.n_opaque} opaque type(s)");
        return true;
    }

    /// Get-or-create the target for a header fid. Creating means: an
    /// ImmediateTable for the fid (no lexing: the header is C++, not Kairo),
    /// an ASTContext, a TranslationUnit shell.
    priv fn _target(self, fid: u32, path: string) -> *HeaderTarget {
        var it = self._targets.find(fid);
        if it != self._targets.end() { return it->second; }

        self._tcm->ensure_imm_table(fid);                    // spec: new TCM entry point; see below.

        var mp  = ModulePath();
        var ctx = self._g->get_or_create_context(fid, self._sm, self._tcm, self._diag, self._res, self._inv, mp);
        var tu  = reinterpret_cast::<*TranslationUnit>(ctx->tu);
        if tu == &null {
            tu = ctx->alloc_init_pp_cleanup::<TranslationUnit>(ctx, fid, ctx->hoisted, self._g);
            tu->is_foreign = true;                          // spec: new flag; _sema and _parse skip it.
            ctx->tu = reinterpret_cast::<*void>(tu);
        }
        var t = std::create::<HeaderTarget>();
        t->fid = fid; t->ctx = ctx; t->tu = tu;
        t->frozen = (tu->dc_symbols != &null) && tu->dc_symbols->is_frozen();
        self._targets.insert(libcxx::make_pair(fid, t));
        return t;
    }

    /// The synthetic per-file module a plain `ffi import "h" as h` binds:
    /// a ModuleDecl SHARING the TU's table (the A2 model the parser uses
    /// for Kairo files). Named after the header's basename.
    priv fn _module_self(self, t: *HeaderTarget) {
        if t->tu->module_self != &null { return; }
        var base = Path(self._sm->get_filename(t->fid)).stem();      // VERIFY: Path::stem()
        var ident = string("");
        for var i: usize = 0; i < base.size(); ++i {
            var c = base[i];
            var ok = ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || ((c >= '0') && (c <= '9')) || (c == '_');
            ident += (c) if (ok) else ('_');
        }
        // TokenText finds the interner FROM THE RANGE's fid: an invalid range
        // spells as "$FALLBACK-MISSING-INTERN$". A zero-length range at the
        // header's start is resolvable and honest -- the module IS the file
        // (the same token ASTParse synthesizes for a Kairo file's module).
        var start = self._sm->get_loc(t->fid, 0);
        var at    = SourceRange(start, start);
        var tok = t->ctx->make_token(at, TokenKind::LitIdentifier, ident);
        var m = ModuleDecl::create(t->ctx, at, tok, static_cast::<*DeclContext>(t->tu));
        m->set_symbols(t->tu->dc_symbols);
        m->is_implicit = true;
        m->mark_definition();
        m->set_visibility(VisibilityKind::Public, SourceRange::invalid());
        t->tu->module_self = static_cast::<*Decl>(m);
    }

    /// Pass 1 over a clang DeclContext, recursing into namespaces, records,
    /// enums, linkage specs, templates. Records (clang decl, Kairo decl) for
    /// pass 2 in the same order, so a record is defined after its members
    /// were declared. Public for ForeignInstantiate, which walks a completed
    /// ClassTemplateSpecializationDecl the same way.
    fn walk_declare(self, dc: *clang::DeclContext, di: *DeclImport, out: ref!(vec::<(*void, *Decl)>)) {
        for d in dc->decls() {
            if d->isImplicit() && (!llvm::isa::<clang::CXXMethodDecl>(d)) { continue; }
            var kind = d->getKind();

            // Transparent containers: recurse, no node.
            if (kind == clang::Decl::LinkageSpec) || (kind == clang::Decl::Export) {
                self.walk_declare(llvm::cast::<clang::DeclContext>(d), di, out);
                continue;
            }
            if kind == clang::Decl::Namespace {
                var kd = di->declare(d);
                self.walk_declare(llvm::cast::<clang::DeclContext>(d), di, out);
                continue;
            }
            if (kind == clang::Decl::ClassTemplate) || (kind == clang::Decl::FunctionTemplate)
            || (kind == clang::Decl::TypeAliasTemplate) {
                var kd = di->declare(d);
                if kd != &null {
                    out.push_back((reinterpret_cast::<*void>(d), kd));
                    // Members of a CLASS template only. A templated FunctionDecl
                    // is a DeclContext too, and its decls() are the function's
                    // locals and parameters: walking it filed every local of
                    // every inline libc++ template (`__i`, `__c`) as a global.
                    var td = llvm::cast::<clang::TemplateDecl>(d)->getTemplatedDecl();
                    var tdc = llvm::dyn_cast::<clang::DeclContext>(td);
                    if (tdc != &null) && llvm::isa::<clang::RecordDecl>(td) { self.walk_declare(tdc, di, out); }
                    // User-written specializations live in the template's spec list, not in any DeclContext walk.
                    var ct = llvm::dyn_cast::<clang::ClassTemplateDecl>(d);
                    if ct != &null {
                        for sp in ct->specializations() {
                            if !sp->isExplicitSpecialization() { continue; }
                            var ks = di->declare(sp);
                            if ks == &null { continue; }
                            out.push_back((reinterpret_cast::<*void>(sp), ks));
                            self.walk_declare(sp, di, out);
                        }
                        var parts: llvm::SmallVector::<*clang::ClassTemplatePartialSpecializationDecl, 8>;
                        ct->getPartialSpecializations(parts);
                        for var i: usize = 0; i < parts.size(); ++i {
                            var ks = di->declare(parts[i]);
                            if ks == &null { continue; }
                            out.push_back((reinterpret_cast::<*void>(parts[i]), ks));
                            self.walk_declare(parts[i], di, out);
                        }
                    }
                }
                continue;
            }

            var kd = di->declare(d);
            if kd == &null {
                // Anonymous struct/union: its members are the parent's.
                var rd = llvm::dyn_cast::<clang::RecordDecl>(d);
                if (rd != &null) && rd->isAnonymousStructOrUnion() {
                    self.walk_declare(rd, di, out);
                }
                continue;
            }
            out.push_back((reinterpret_cast::<*void>(d), kd));

            // Scopes with members: records and enums (their members are
            // declared BEFORE the record's define sees them).
            var sub = llvm::dyn_cast::<clang::DeclContext>(d);
            if (sub != &null) && (llvm::isa::<clang::RecordDecl>(d) || llvm::isa::<clang::EnumDecl>(d)) {
                // Only the definition has members; a forward decl walks nothing.
                var tag = llvm::cast::<clang::TagDecl>(d);
                // A nested class of an implicit instantiation is only DECLARED
                // until something requires it complete; ForeignInstantiate
                // completes the ones a fill reaches and walks them itself.
                if tag->isCompleteDefinition() { self.walk_declare(sub, di, out); }
            }
        }
    }
}