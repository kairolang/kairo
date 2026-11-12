/// --- The Kairo Project ------------------- Sema/Foreign/HeaderIndex.k --- ///
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
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "clang/AST/ASTContext.h"
ffi "c++" import "clang/AST/Decl.h"
ffi "c++" import "clang/AST/DeclBase.h"
ffi "c++" import "clang/AST/DeclCXX.h"
ffi "c++" import "clang/AST/DeclTemplate.h"
ffi "c++" import "clang/AST/DeclFriend.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import AST::Context::DeclContext::DeclContext
import AST::Context::GlobalDisambigTable::GlobalDisambigTable
import AST::Context::SymbolTable::SymbolTable
import AST::Context::TranslationUnit::TranslationUnit
import AST::Mixin::Annotation::VisibilityKind
import AST::Node::Base::Decl
import AST::Node::Declarations::ModuleDecl
import Config::Invocation::CompilerInvocation
import Diagnostic::Engine::DiagEngine
import Interop::Clang::HeaderSet::HeaderSet
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Resolution::ImportProbe::ImportResolver
import Resolution::ModulePath::ModulePath
import Sema::Foreign::DeclImport::{
    DeclImport,
    HeaderTarget,
}
import Sema::Foreign::ForeignRegistry::ForeignRegistry
import Sema::Foreign::TypeImport::TypeImport
import Support::FileIO::Path::Path
import Support::TimeReport::TimeRegion
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenKind::TokenKind

pub class HeaderIndex {
    priv var _sm:   *SourceManager
    priv var _tcm:  unsafe *TokenCacheManager
    priv var _diag: *DiagEngine
    priv var _res:  *ImportResolver
    priv var _inv:  unsafe *CompilerInvocation
    priv var _g:    *GlobalDisambigTable
    priv var _reg:  unsafe *ForeignRegistry

    /// header fid -> target, across every set indexed by this compiler.
    priv var _targets: llvm::DenseMap<u32, unsafe *HeaderTarget> ///< fid -> target; 0 is the invalid fid, never ~0. Iterated only to destroy.

    fn HeaderIndex(self,
                   sm:   *SourceManager,
                   tcm:  unsafe *TokenCacheManager,
                   diag: *DiagEngine,
                   res:  *ImportResolver,
                   inv:  unsafe *CompilerInvocation,
                   g:    *GlobalDisambigTable,
                   reg:  unsafe *ForeignRegistry) {
        self._sm   = sm
        self._tcm  = tcm
        self._diag = diag
        self._res  = res
        self._inv  = inv
        self._g    = g
        self._reg  = reg
    }

    // Move-only: the destructor destroys every target, so a copy would destroy
    // them twice. The source is left with none.
    @move fn HeaderIndex(self, other: Self) {
        self._sm      = other._sm
        self._tcm     = other._tcm
        self._diag    = other._diag
        self._res     = other._res
        self._inv     = other._inv
        self._g       = other._g
        self._reg     = other._reg
        self._targets = cxx::std::move(other._targets)
        other._targets.clear()
    }

    fn op finally (self) {
        for var it = self._targets.begin(); it != self._targets.end(); ++it {
            kairo::std::destroy(it->second)
        }

        self._targets.clear()
    }

    fn target_for_fid(self, fid: u32) -> unsafe *HeaderTarget {
        var it = self._targets.find(fid)
        if it == self._targets.end() {
            return &null
        }

        return it->second
    }

    /// The one way to mint a foreign TU from outside the index.
    fn ensure_target(self, fid: u32, const path: string) -> unsafe *HeaderTarget {
        return self._target(fid, path)
    }

    /// A DeclImport wired to \p hs and this index's targets. index() builds
    /// one per set; ForeignInstantiate builds one per fill and switches it to
    /// fill mode (DeclImport::in_fill).
    fn importer_for(self, hs: unsafe *HeaderSet) -> DeclImport {
        var di = DeclImport()
        di._set      = hs
        di.reg       = self._reg
        di.ksm       = self._sm
        di.store     = self._g->types()
        di.instances = self._g->instances()
        di.cctx      = hs->ast()
        di.csm       = hs->csm()
        di.targets   = unsafe &self._targets
        di.diag      = unsafe (self._diag as unsafe *DiagEngine)
        return di
    }

    /// A TypeImport against \p hs's AST. \p kctx interns opaque names; \p fid
    /// is the home of any registry entry it mints.
    fn type_importer_for(self,
                         hs:   unsafe *HeaderSet,
                         kctx: unsafe *ASTContext,
                         fid:  u32) -> TypeImport {
        return TypeImport(
            self._g->types(),
            self._g->instances(),
            self._reg,
            hs->ast(),
            kctx,
            fid,
        )
    }

    /// The one entry point. Idempotent per set.
    pub fn index(self, hs: unsafe *HeaderSet) -> bool {
        if hs->indexed {
            return true
        }

        if !hs->is_built() {
            return false
        }

        hs->indexed = true
        if !hs->ok || hs->ast() == &null {
            // A bad header already reached the user as clang's own error; this
            // is a breadcrumb then. Only a failure clang said nothing about
            // (no target, backend not ready, PCH incomplete) is ours.
            if hs->diag_buf.error_count() > 0 {
                kairo::Logger::warn(
                    kairo::Logger::Stage::Driver,
                    "HeaderIndex: set failed to build; nothing imported",
                )
            } else {
                kairo::Logger::error(
                    kairo::Logger::Stage::Driver,
                    "HeaderIndex: set failed to build; nothing imported (no clang diagnostic)",
                )
            }

            return false
        }

        var _t = TimeRegion("HeaderIndex")

        // The builtin singletons are built once per build, normally by the
        // first SemaContext -- and headers are indexed BEFORE any sema runs.
        // Unbuilt, CanonicalTypeStore::builtin answers null and every `int`
        // in every header imports as opaque. init() is first-caller-wins, so
        // the width comes from exactly where SemaContext takes it; a second
        // source would give usize two sizes depending on who ran first.
        var pbits:   usize = 64
        var i64_long       = true
        var ldb:     usize = 0
        var lda:     usize = 0
        var wcb:     usize = 0
        if self._inv != &null {
            pbits    = self._inv->target.pointer_width
            i64_long = self._inv->target.int64_is_long
            ldb      = self._inv->target.long_double_bits
            lda      = self._inv->target.long_double_align
            wcb      = self._inv->target.wchar_bits
        }

        if pbits == 0 {
            pbits    = 64
            i64_long = true
        }

        self._g->types()->init(pbits, i64_long, ldb, lda, wcb)

        // 1. fids + contexts + TUs, in clang's touch order.
        var fresh = cxx::std::vector<unsafe *HeaderTarget>()
        for var i: usize = 0; i < hs->files.size(); ++i {
            var *f  = &hs->files[i]
            var fid = self._sm->load_file(Path(f->path)) // a known path answers with its existing fid (VFM cache hit).
            if fid == u32::MAX {
                continue
            }

            f->kfid = fid
            hs->cfid_to_kfid.try_emplace(f->cfid_hash as u64, fid)
            var unsafe *t = self._target(fid, f->path)
            if !t->frozen {
                fresh.push_back(t)
            }
        }

        // 2. import.
        var di = self.importer_for(hs)

        var any_ctx: unsafe *ASTContext = &null
        if fresh.size() > 0 {
            any_ctx = fresh[0]->ctx
        } else if hs->files.size() > 0 {
            any_ctx = self._target(hs->files[0].kfid, hs->files[0].path)->ctx
        }

        var home_fid: u32 = if (fresh.size() > 0) => (fresh[0]->fid) else => 0
        var ti            = self.type_importer_for(hs, any_ctx, home_fid)

        var pairs = cxx::std::vector<(unsafe *void, unsafe *Decl)>() // (clang::Decl*, Kairo decl) for pass 2.
        self.walk_declare(hs->ast()->getTranslationUnitDecl(), &di, &pairs)
        for var i: usize = 0; i < pairs.size(); ++i {
            di.define(
                unsafe (pairs[i].0 as unsafe *clang::Decl),
                pairs[i].1,
                unsafe &ti,
            )
        }

        // 3. freeze what this set created.
        for var i: usize = 0; i < fresh.size(); ++i {
            var unsafe *t = fresh[i]
            for var s: usize = 0; s < t->scopes.size(); ++s {
                if t->scopes[s]->dc_symbols != &null {
                    t->scopes[s]->dc_symbols->freeze()
                }
            }

            if t->tu->dc_symbols == &null { // a header that declared nothing at file scope still needs a table.
                var unsafe *tbl = t->ctx->alloc_init_cleanup<SymbolTable>(
                    t->ctx,
                )

                tbl->freeze()
                t->tu->set_symbols(tbl)
            }

            self._module_self(t)
            t->frozen = true
        }

        hs->contributed.store(
            fresh.size() > 0 || di.n_declared > 0,
            kairo::std::MemoryOrder::relaxed,
        )

        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"HeaderIndex: {fresh.size()} new header TU(s), {di.n_declared} decl(s) declared, {di.n_defined} defined, {di.n_skipped} skipped, {ti.n_opaque} opaque type(s)",
        )

        return true
    }

    /// Get-or-create the target for a header fid. Creating means: an
    /// ImmediateTable for the fid (no lexing: the header is C++, not Kairo),
    /// an ASTContext, a TranslationUnit shell.
    priv fn _target(self, fid: u32, const path: string) -> unsafe *HeaderTarget {
        var it = self._targets.find(fid)
        if it != self._targets.end() {
            return it->second
        }

        self._tcm->ensure_imm_table(fid) // spec: new TCM entry point; see below.

        var mp = ModulePath()
        var unsafe *ctx = self._g->get_or_create_context(
            fid,
            self._sm,
            self._tcm,
            self._diag,
            self._res,
            self._inv,
            mp,
        )

        var unsafe *tu = ctx->tu
        if tu == &null {
            tu = ctx->alloc_init_pp_cleanup<TranslationUnit>(
                ctx,
                fid,
                ctx->hoisted,
                self._g,
            )

            tu->is_foreign = true // spec: new flag; _sema and _parse skip it.
            ctx->tu        = tu
        }

        var unsafe *t = kairo::std::create<HeaderTarget>()
        t->fid    = fid
        t->ctx    = ctx
        t->tu     = tu
        t->frozen = tu->dc_symbols != &null && tu->dc_symbols->is_frozen()
        self._targets.try_emplace(fid, t)
        return t
    }

    /// The synthetic per-file module a plain `ffi import "h" as h` binds:
    /// a ModuleDecl SHARING the TU's table (the A2 model the parser uses
    /// for Kairo files). Named after the header's basename.
    priv fn _module_self(self, t: unsafe *HeaderTarget) {
        if t->tu->module_self != &null {
            return
        }

        var base  = Path(self._sm->get_filename(t->fid)).stem() // VERIFY: Path::stem()
        var ident = ""
        for var i: usize = 0; i < base.size(); ++i {
            var c = base[i]
            var ok = c >= ('a' as u8) && c <= ('z' as u8)
                || c >= ('A' as u8) && c <= ('Z' as u8)
                || c >= ('0' as u8) && c <= ('9' as u8)
                || c == ('_' as u8)
            ident.push_back(if (ok) => (c) else => ('_' as u8))
        }

        // TokenText finds the interner FROM THE RANGE's fid: an invalid range
        // spells as "$FALLBACK-MISSING-INTERN$". A zero-length range at the
        // header's start is resolvable and honest -- the module IS the file
        // (the same token ASTParse synthesizes for a Kairo file's module).
        var start = self._sm->get_loc(t->fid, 0)
        var at    = SourceRange(start, start)
        var tok   = t->ctx->make_token(at, TokenKind::LitIdentifier, ident)
        var unsafe *m = ModuleDecl::create(
            t->ctx,
            at,
            tok,
            unsafe (t->tu as unsafe *DeclContext),
        )

        m->set_symbols(t->tu->dc_symbols)
        m->is_implicit = true
        m->mark_definition()
        m->set_visibility(VisibilityKind::Public, SourceRange::invalid())
        t->tu->module_self = m
    }

    /// Pass 1 over a clang DeclContext, recursing into namespaces, records,
    /// enums, linkage specs, templates. Records (clang decl, Kairo decl) for
    /// pass 2 in the same order, so a record is defined after its members
    /// were declared. Public for ForeignInstantiate, which walks a completed
    /// ClassTemplateSpecializationDecl the same way.
    fn walk_declare(self,
                    dc:         unsafe *clang::DeclContext,
                    di:         *DeclImport,
                    @inout out: cxx::std::vector<(unsafe *void, unsafe *Decl)>) {
        // clang declares a record's implicit special members lazily (the
        // default constructor of `struct S : B { APValue v; }` only when
        // something looks it up). Kairo never asks clang, it reads decls(), so
        // without this `S()` finds only the copy / move constructors that an
        // earlier lookup happened to declare. Before the loop: declaring adds
        // to the very list it iterates.
        var unsafe *crd = llvm::dyn_cast<clang::CXXRecordDecl>(dc)
        if crd != &null
            && crd->hasDefinition()
            && crd->isCompleteDefinition()
            && !crd->isDependentContext()
            && !crd->isInvalidDecl() {
            var unsafe *hs = di->_set
            if hs != &null && hs->sema() != &null {
                var slock = kairo::std::LockGuard(*hs->sema_lock())
                hs->sema()->ForceDeclarationOfImplicitMembers(crd)
            }
        }

        for d in dc->decls() {
            var kind = d->getKind()
            // clang marks every UsingShadowDecl implicit (its using-declaration
            // is the written decl), so the shadow is let through by kind.
            if d->isImplicit()
                && !llvm::isa<clang::CXXMethodDecl>(d)
                && kind != clang::Decl::UsingShadow {
                continue
            }

            // A header an earlier set indexed is frozen: bind() and define()
            // are no-ops for it, and declare() only finds the entity that set
            // registered under the same USR. Walking it again cost a USR and a
            // registry probe per decl for every later set -- the self-host
            // graph's 115 sets re-walked the same LLVM/libc++ headers.
            // Namespaces and transparent containers still recurse: a header
            // they open may be one this set brings in first. Never in a fill.
            if (!di->in_fill())
                && kind != clang::Decl::Namespace
                && kind != clang::Decl::LinkageSpec
                && kind != clang::Decl::Export {
                var unsafe *ft = di->target_of(d)
                if ft != &null && ft->frozen {
                    continue
                }
            }

            // Transparent containers: recurse, no node.
            if kind == clang::Decl::LinkageSpec || kind == clang::Decl::Export {
                self.walk_declare(llvm::cast<clang::DeclContext>(d), di, &out)
                continue
            }

            if kind == clang::Decl::Namespace {
                var unsafe *kd = di->declare(d)
                self.walk_declare(llvm::cast<clang::DeclContext>(d), di, &out)
                continue
            }

            if kind == clang::Decl::ClassTemplate
                || kind == clang::Decl::FunctionTemplate
                || kind == clang::Decl::TypeAliasTemplate {
                var unsafe *kd = di->declare(d)
                if kd != &null {
                    out.push_back((unsafe (d as unsafe *void), kd))
                    // Members of a CLASS template only. A templated FunctionDecl
                    // is a DeclContext too, and its decls() are the function's
                    // locals and parameters: walking it filed every local of
                    // every inline libc++ template (`__i`, `__c`) as a global.
                    var unsafe *td = llvm::cast<clang::TemplateDecl>(d)->getTemplatedDecl()
                    var unsafe *tdc = llvm::dyn_cast<clang::DeclContext>(td)
                    if tdc != &null && llvm::isa<clang::RecordDecl>(td) {
                        self.walk_declare(tdc, di, &out)
                    }

                    // User-written specializations live in the template's spec list, not in any DeclContext walk.
                    var unsafe *ct = llvm::dyn_cast<clang::ClassTemplateDecl>(d)
                    if ct != &null {
                        for sp in ct->specializations() {
                            if !sp->isExplicitSpecialization() {
                                continue
                            }

                            var unsafe *ks = di->declare(sp)
                            if ks == &null {
                                continue
                            }

                            out.push_back((unsafe (sp as unsafe *void), ks))
                            self.walk_declare(sp, di, &out)
                        }

                        var parts: llvm::SmallVector<unsafe *clang::ClassTemplatePartialSpecializationDecl, 8>
                        ct->getPartialSpecializations(&parts)
                        for var i: usize = 0; i < parts.size(); ++i {
                            var unsafe *ks = di->declare(parts[i])
                            if ks == &null {
                                continue
                            }

                            out.push_back(
                                (unsafe (parts[i] as unsafe *void), ks),
                            )

                            self.walk_declare(parts[i], di, &out)
                        }
                    }
                }

                continue
            }

            // A friend FUNCTION of a class (the hidden friend operators of
            // every node-based libc++ iterator): declared, bound in the class.
            // Not in a template's PATTERN, whose friend is dependent on the
            // class's parameters; a fill walks each specialization, where
            // clang has instantiated the friend's declaration concretely.
            if kind == clang::Decl::Friend {
                var unsafe *fr = llvm::cast<clang::FriendDecl>(d)->getFriendDecl()
                if fr != &null && llvm::isa<clang::FunctionDecl>(fr) && !fr->isTemplated() {
                    var unsafe *kf = di->declare_friend(fr, dc)
                    if kf != &null {
                        out.push_back((unsafe (fr as unsafe *void), kf))
                    }
                }

                continue
            }

            // `using ::sqrt;` in a namespace: the target is bound there too
            // (DeclImport::declare_using). Not in a class: `using B::g;` is
            // ClassDecl::ffi_usings, and MemberLookup continues into B for
            // it; binding B's g in the derived table as well would hand
            // overload resolution the same candidate twice. Not at file
            // scope either: libc++'s <math.h> does `using
            // std::__math::sqrt;` there, and its f32 / long double overloads
            // beside the C `sqrt` make a plain `sqrt(2.0)` SC064E (an untyped
            // float literal ranks every float parameter alike).
            if kind == clang::Decl::UsingShadow {
                var unsafe *rdc = dc->getRedeclContext()
                if rdc->isFileContext() && !rdc->isTranslationUnit() {
                    var unsafe *sh    = llvm::cast<clang::UsingShadowDecl>(d)
                    var        before = di->n_declared
                    var unsafe *kt    = di->declare_using(sh)
                    if kt != &null && di->n_declared != before {
                        out.push_back(
                            (unsafe (sh->getTargetDecl() as unsafe *void), kt),
                        )
                    }
                }

                continue
            }

            var unsafe *kd = di->declare(d)
            if kd == &null {
                // Anonymous struct/union: its members are the parent's.
                var unsafe *rd = llvm::dyn_cast<clang::RecordDecl>(d)
                if rd != &null && rd->isAnonymousStructOrUnion() {
                    self.walk_declare(rd, di, &out)
                }

                continue
            }

            out.push_back((unsafe (d as unsafe *void), kd))

            // Scopes with members: records and enums (their members are
            // declared BEFORE the record's define sees them).
            var unsafe *sub = llvm::dyn_cast<clang::DeclContext>(d)
            if sub != &null && (llvm::isa<clang::RecordDecl>(d) || llvm::isa<clang::EnumDecl>(d)) {
                // Only the definition has members; a forward decl walks nothing.
                var unsafe *tag = llvm::cast<clang::TagDecl>(d)
                // A nested class of an implicit instantiation is only DECLARED
                // until something requires it complete; ForeignInstantiate
                // completes the ones a fill reaches and walks them itself.
                if tag->isCompleteDefinition() {
                    self.walk_declare(sub, di, &out)
                }
            }
        }
    }
}
