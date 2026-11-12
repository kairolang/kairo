/// --- The Kairo Project ------------ Sema/Foreign/ForeignInstantiate.k --- ///
///
///   \brief Fill an implicit instance of an IMPORTED class template from
///          clang: complete the specialization in the primary's phase-A AST,
///          then import its members into the registry shell.
///
///   \detail
///     An instance of a C++ template is clang's, never M2's
///     (MemberLookup::filled_by_clang). Substituting into the pattern Kairo
///     imported would have to re-derive what clang's instantiation already
///     knows -- dependent member typedefs through `allocator_traits`,
///     SFINAE'd members, partial-specialization selection -- and get some of
///     it wrong. So the shell is filled by asking clang for the
///     ClassTemplateSpecializationDecl and running DeclImport over it exactly
///     as HeaderIndex runs it over a header. Afterwards the shell is an
///     ordinary filled instance (ForeignFill::Filled) and nothing walks the
///     pattern for it again.
///
///     Demand-driven: MemberLookup::_walk_record calls fill() the first time
///     anything looks into the shell. A failure is sticky
///     (ForeignFill::FailedSticky) and leaves lookup on the pattern -- exactly
///     the behaviour before fills existed, so a fill can only add answers.
///
///   \par Threading
///     `_mu` is ONE lock for every fill in the build, on purpose. A fill
///     allocates in the primary's header TU (tables, frozen lists, tokens),
///     and two HeaderSets can each hold their own sema_lock() while
///     instantiating two instances of one primary, so the set lock alone does
///     not cover the Kairo side. Fills are rare and cheap next to a parse.
///     Lock order: `_mu`, then the set's sema_lock(); nothing takes them the
///     other way round.
///
///     Fills nest. DeclImport::define imports types, a type can be a
///     qualified path into another unfilled shell, and TypeResolve fills on
///     that path too. Both locks are therefore RECURSIVE, so a nested fill of
///     a different shell proceeds on the thread that already holds them; a
///     nested fill of the SAME shell (its own member naming it back) finds it
///     in `_active` and returns false at once -- the caller walks the
///     pattern, as for any unfilled shell, and the outer fill finishes it.
///     Each fill's verdict and reason travel up its own call chain
///     (FillResult, a local `why`), never through a member, so a nested
///     fill cannot overwrite the outer one's.
///
///     The shell's ForeignFill (TemplateParams.k) is the state other threads
///     read: written only here, under `_mu`, as a fill's last write
///     (decl_publish_fill, a release store); read anywhere with no lock
///     (decl_instantiated / decl_fill_failed, acquire loads).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh"
ffi "c++" import "clang/AST/ASTContext.h"
ffi "c++" import "clang/AST/Decl.h"
ffi "c++" import "clang/AST/DeclCXX.h"
ffi "c++" import "clang/AST/DeclTemplate.h"
ffi "c++" import "clang/AST/Expr.h"
ffi "c++" import "clang/Basic/DiagnosticSema.h"
ffi "c++" import "clang/Basic/PartialDiagnostic.h"
ffi "c++" import "clang/Sema/Sema.h"
ffi "c++" import "clang/Sema/Overload.h" // ImplicitConversionSequence (cxx_converts)
ffi "c++" import "clang/Sema/TemplateDeduction.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/ADT/SmallString.h"
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/KClangPurity.hh" // decl_purity
ffi "c++" import "Native/KThread.hh" // sema_mint_rank
ffi "c++" import "atomic"
ffi "c++" import "vector"
ffi "c++" import "memory"

import AST::Context::InstantiationRegistry::{
    InstanceEntry,
    InstantiationRegistry,
}
import AST::DeclFacts::{
    decl_clang,             decl_cxx_spelling, decl_fill_failed, decl_foreign_fill,
    decl_instantiated_from, decl_origin_fid,   decl_origin_set,  decl_publish_fill,
    decl_set_imported,
}
import AST::Mixin::TemplateParams::ForeignFill
import AST::Node::Base::{
    Decl,
    Expr,
    Type,
}
import AST::Node::CanonicalNodes::{
    BuiltinType,
    canon_unqual,
}
import AST::Node::Casting::dyn_cast
import Diagnostic::BufferedDiagSink::BufferedDiagSink
import Diagnostic::ClangDiagAdapter::ClangDiagAdapter
import Interop::Clang::HeaderSet::HeaderSet
import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Sema::Foreign::DeclImport::{
    DeclImport,
    HeaderTarget,
}
import Sema::Foreign::ForeignRegistry::ForeignRegistry
import Sema::Foreign::HeaderIndex::HeaderIndex
import Sema::Foreign::TypeExport::TypeExport
import Sema::Foreign::TypeImport::TypeImport
import Sema::Resolve::NameLookup::NameLookup

/// One fill attempt's verdict. Unspelled is not clang's verdict on the
/// instance: no set tried could spell an argument (or the set only declares
/// the template), so another demanding TU's set may still fill it.
enum FillResult derives u8 {
    Filled,
    Failed,
    Unspelled,
}

/// A shell whose fill came back Unspelled, beside the demanding set it was
/// tried with (null: none).
struct UnspelledRec {
    var shell: unsafe *Decl      = &null
    var set:   unsafe *HeaderSet = &null
}

pub class ForeignInstantiate {
    priv var _mu:        kairo::std::RecursiveMutex ///< ONE lock for all fills; see the file header.
    priv var _active:    cxx::std::vector<unsafe *Decl> ///< shells mid-fill, outermost first; guarded by `_mu`.
    priv var _hindex:    *HeaderIndex
    priv var _reg:       unsafe *ForeignRegistry
    priv var _instances: unsafe *InstantiationRegistry
    /// Fills that came back Unspelled, guarded by `_mu`. Such a failure is
    /// not sticky (the shell stays Shell): another TU's set may see the
    /// argument's header, so only the same (shell, set) pair is not retried.
    priv var _unspelled: cxx::std::vector<UnspelledRec>
    /// For TypeExport's stand-ins of Kairo records (`vector<S>`), which
    /// are named as EmitIR names them. Null until the driver has a
    /// preprocessor; a Kairo-record argument is refused until then.
    pub var psym: unsafe *PreprocessorSymbolTable = &null

    pub var n_filled: usize = 0
    pub var n_failed: usize = 0

    fn ForeignInstantiate(self,
                          hindex:    *HeaderIndex,
                          reg:       unsafe *ForeignRegistry,
                          instances: unsafe *InstantiationRegistry) {
        self._hindex    = hindex
        self._reg       = reg
        self._instances = instances
    }

    /// Fill \p shell (an unfilled instance whose primary is imported). True
    /// if it is filled afterwards, by this call or an earlier one. clang's
    /// own diagnostics for the fill go to \p sink, the demanding TU's; null
    /// leaves them on the set's fallback printer. \p fid is that TU: a
    /// Kairo instance the fill names first (`Nullable<i32>` behind
    /// `vector<i32?>`) is homed there, as one its own typing named would be.
    /// -1 when no TU demands it (fid 0 is a TU: the first file loaded).
    /// \p alt is that TU's own header set, the fallback when the primary's
    /// set cannot spell the arguments (see _fill_locked); null for none.
    fn fill(self,
            shell: unsafe *Decl,
            sink:  unsafe *BufferedDiagSink = &null,
            fid:   i64 = -1,
            alt:   unsafe *HeaderSet = &null) -> bool {
        if shell == &null {
            return false
        }

        // Unlocked fast path. ForeignFill leaves Shell once, for a terminal
        // state, as the LAST write of a fill holding `_mu` (a release
        // store), and TUs that do not import each other run their typed
        // checks on pool workers: the acquire load makes everything the fill
        // wrote visible to a reader that saw Filled. The re-read under the
        // lock is what is load-bearing for the slow path.
        var st = decl_foreign_fill(shell)
        if st == ForeignFill::Filled {
            self._rerequest(shell, fid, alt)
            return true
        }

        if st == ForeignFill::FailedSticky || decl_fill_failed(shell) {
            return false
        }

        var lock = kairo::std::LockGuard(self._mu)
        st = decl_foreign_fill(shell)
        if st == ForeignFill::Filled {
            self._rerequest(shell, fid, alt)
            return true
        }

        if st == ForeignFill::FailedSticky {
            return false
        }

        // Re-entered for a shell this thread is already filling: not a
        // failure (the outer fill will finish it), so no sticky flag.
        for var i: usize = 0; i < self._active.size(); ++i {
            if self._active[i] == shell {
                return false
            }
        }

        // Already found unspellable with this same demanding set: nothing
        // has changed that a retry would see.
        for var i: usize = 0; i < self._unspelled.size(); ++i {
            if self._unspelled[i].shell == shell && self._unspelled[i].set == alt {
                return false
            }
        }

        self._active.push_back(shell)
        // Every registry request the fill makes is recorded on the shell's
        // entry, for a TU earlier in import order that comes later.
        var unsafe *fe = self._instances->entry_of(shell)
        var unsafe *prev = self._instances->begin_fill(
            fe,
            fid,
            unsafe (alt as unsafe *void),
        )

        var why = string()
        var r   = self._fill_locked(shell, sink, fid, alt, unsafe &why)
        self._instances->end_fill(fe, prev)
        self._active.pop_back()
        if r == FillResult::Filled {
            self.n_filled += 1
            return true
        }

        self.n_failed += 1
        // A fill no set tried could spell is the demanding TU's gap, not the
        // instance's. With the whole tree in one compile, a TU whose set never
        // includes Compilation.h read a member of `unique_ptr<Compilation>`
        // first; a sticky failure there left the instance unfilled for
        // ClangJobs.k too, whose own set spells it, and its `pointer` stayed
        // '<ffi type>'. So only clang's own verdict is sticky; an
        // unspelled fill is retried for each other demanding set.
        if r == FillResult::Unspelled {
            var rec = UnspelledRec()
            rec.shell = shell
            rec.set   = alt
            self._unspelled.push_back(rec)
        } else {
            decl_publish_fill(shell, ForeignFill::FailedSticky)
        }

        // clang's own errors for the fill already went to `sink`, with spans
        // in the header. TODO(diag): a Kairo note pointing at the USE that
        // demanded the fill; until then the use's member typing reports
        // `unknown` as it did before fills.
        var unsafe *prim = decl_instantiated_from(shell)
        var        what  = "<no pattern>"
        if prim != &null {
            what = decl_cxx_spelling(prim)
        }

        kairo::Logger::warn(
            kairo::Logger::Stage::Driver,
            f"ForeignInstantiate: instance of {what} not filled: {why}",
        )

        return false
    }

    /// \p shell was filled for some TU; if that TU comes after the caller's
    /// in import order, the caller re-makes the fill's registry requests,
    /// so homes and worklist order are what they would have been had the
    /// caller filled it first, as a one-thread run does. Cheap when
    /// it does nothing: no Sema rank on this thread, or no earlier demand.
    priv fn _rerequest(self, shell: unsafe *Decl, fid: i64, alt: unsafe *HeaderSet) {
        if *kairo::sema_mint_rank() == u64::MAX {
            return
        }

        var unsafe *e = self._instances->entry_of(shell)
        if e == &null {
            return
        }

        self._instances->rerequest(e, fid, unsafe (alt as unsafe *void))
    }

    priv fn _fill_locked(self,
                         shell: unsafe *Decl,
                         sink:  unsafe *BufferedDiagSink,
                         fid:   i64,
                         alt:   unsafe *HeaderSet,
                         why:   unsafe *string) -> FillResult {
        // 1. who owns the pattern.
        var unsafe *prim = decl_instantiated_from(shell)
        if prim == &null {
            (*why) = "no pattern"
            return FillResult::Failed
        }

        var unsafe *hs = unsafe (decl_origin_set(prim) as unsafe *HeaderSet)
        if hs == &null {
            (*why) = "primary has no header set"
            return FillResult::Failed
        }

        // A set's clang instance lives until HeaderSetCache::release_all,
        // after every TU's sema. A fill past that is a pass looking into an
        // instance after Checked -- a schedule bug, never the user's.
        if !hs->alive() {
            kairo::std::ice_fail(
                "ForeignInstantiate: fill after the primary's header set was released",
            )
        }

        var unsafe *cctx  = hs->ast()
        var unsafe *csema = hs->sema()
        if cctx == &null || csema == &null {
            (*why) = "header set has no AST / Sema"
            return FillResult::Failed
        }

        var unsafe *ct = TypeExport::class_template_of(
            unsafe (decl_clang(prim) as unsafe *clang::Decl),
        )

        if ct == &null {
            (*why) = "primary is not a class template"
            return FillResult::Failed
        }

        var unsafe *t = self._hindex->target_for_fid(decl_origin_fid(prim))
        if t == &null {
            (*why) = "primary's header has no import target"
            return FillResult::Failed
        }

        // The shell's own spec_args are empty by design; its args are the
        // registry entry's (canonical, parameter order, defaults filled).
        var unsafe *e = self._instances->entry_of(shell)
        if e == &null {
            (*why) = "not a registry instance"
            return FillResult::Failed
        }

        // Where a Kairo instance a stand-in names is homed (TypeExport::
        // home_fid): the demanding TU, else the TU that named the shell.
        var home = if (fid >= 0) => (fid) else => (e->home_fid)

        var r = self._fill_in(shell, sink, home, hs, ct, t, e, why)
        if r != FillResult::Unspelled {
            return r
        }

        // The primary's set could not spell an argument. The primary is the
        // FIRST set to import its header, not the one that named the
        // instance: with UTF8View.k ahead of PartitionQueue.k in one build,
        // `vector` was UTF8View's set's, which never includes KThread.hh, so
        // `vector<SeqCell<Task, 64>>` had no spelling there and every
        // `size_type` member stayed opaque (`_buf[i]` was SC063E). The
        // demanding TU's own set names the instance in its source, so it
        // usually sees every argument's header too: re-find the template
        // there and fill through it. The shell then belongs to that set, as
        // one imported from it would.
        if alt == &null || alt == hs || !alt->alive() {
            return r
        }

        if alt->ast() == &null || alt->sema() == &null {
            return r
        }

        var first = *why
        var ax = TypeExport(
            alt->ast(),
            alt->sema(),
            unsafe (alt as unsafe *void),
        )

        var unsafe *act = ax.refind_template(ct)
        if act == &null {
            return r
        }

        e->fill_used_alt = true // InstantiationRegistry::rerequest; under `_mu`.
        r                = self._fill_in(shell, sink, home, alt, act, t, e, why)
        if r == FillResult::Unspelled {
            (*why) = f"{first}; also in the demanding TU's set"
        }

        return r
    }

    /// Steps 2-6 of a fill, in \p hs's AST with \p ct its template. Unspelled
    /// when an argument has no clang spelling in this set or the set only
    /// declares the template (the caller may retry in another). A failure's
    /// reason goes to \p why, the caller's own.
    priv fn _fill_in(self,
                     shell: unsafe *Decl,
                     sink:  unsafe *BufferedDiagSink,
                     home:  i64,
                     hs:    unsafe *HeaderSet,
                     ct:    unsafe *clang::ClassTemplateDecl,
                     t:     unsafe *HeaderTarget,
                     e:     unsafe *InstanceEntry,
                     why:   unsafe *string) -> FillResult {
        var unsafe *cctx  = hs->ast()
        var unsafe *csema = hs->sema()

        // Everything from here asks clang::Sema, including spelling the args:
        // a nested instance argument is itself a CheckTemplateIdType.
        var slock = kairo::std::LockGuard(*hs->sema_lock())

        // clang's diagnostics for this fill -- a static_assert in the
        // pattern, an undefined specialization it names -- go to the TU that
        // demanded it, through the engine, with spans in the header.
        var da: unsafe *ClangDiagAdapter = &null
        if sink != &null {
            da = hs->begin_diag(sink)
        }

        finally {
            hs->end_diag(da)
        }

        // 2. the specialization. When the shell was imported FROM one in this
        //    set's AST, that decl is the answer: the Kairo args are lossy
        //    (ForeignRegistry::note_spec) and re-spelling them can name a
        //    different specialization. Otherwise spell the args in THIS
        //    set's AST and ask for the template-id.
        var ty = clang::QualType()
        var unsafe *hint = unsafe (self._reg->spec_of(shell) as unsafe *clang::ClassTemplateSpecializationDecl)
        if hint != &null {
            // A decl of another set's AST is not usable here.
            var unsafe *hint_ctx = unsafe &hint->getASTContext()
            if hint_ctx == cctx {
                ty = clang::QualType::getFromOpaquePtr(
                    (cctx->getCanonicalTagType(hint)).getAsOpaquePtr(),
                )
            }
        }

        if ty.isNull() {
            var tx = TypeExport(cctx, csema, unsafe (hs as unsafe *void))
            tx.reg       = self._reg
            tx.psym      = self.psym
            tx.instances = self._instances
            tx.home_fid  = home
            var qs: llvm::SmallVector<clang::TemplateArgument, 8>
            for var i: usize = 0; i < e->args.size(); ++i {
                var a = tx.to_clang_arg(ct, i, e->args[i], &qs)
                if a.isNull() {
                    (*why) = f"template argument {i} has no clang spelling in phase A"
                    return FillResult::Unspelled
                }

                qs.push_back(a)
            }

            ty = tx.template_id(ct, &qs)
            if ty.isNull() {
                (*why) = "clang rejected the template-id"
                return FillResult::Failed
            }
        }

        // 3. complete. RequireCompleteType is what instantiates the class
        //    definition: member DECLARATIONS, which is all sema needs.
        //    Member function bodies stay pending; phase B instantiates those
        //    itself from the PCH.
        //    isCompleteType, not RequireCompleteType: an instance of a
        //    template the header only declares (libc++'s `__value_type<K,
        //    V>`, a tag map's __tree is parameterized on and never
        //    completes) is legal C++ as long as nothing needs it complete,
        //    and a fill is often speculative -- ClassLifecycle reads the
        //    facts of every template argument of a field's type. Asked to
        //    REQUIRE it, clang reported "implicit instantiation of undefined
        //    template" (CL001E) for a `map<i32, i32>` class field nobody
        //    used. Errors inside an instantiation that does happen (a
        //    static_assert in the pattern) are still clang's to report.
        var *diags = &csema->getDiagnostics()
        var before = diags->getNumErrors()
        // An instance with a class-type argument this set only declares
        // (`DenseMapPair<GlobalDecl, V>` named by DenseMapBase's members while
        // ASTContext.h forward-declares GlobalDecl) is often named only, never
        // used: clang itself would never complete it. Completing it here is a
        // hard error in libc++ (`pair` field of incomplete type) that no
        // importer asked for, so the attempt is silent and the instance stays
        // unfilled. Any other fill keeps clang's diagnostics.
        var quiet = false
        var unsafe *qspec = llvm::dyn_cast_or_null<clang::ClassTemplateSpecializationDecl>(
            ty->getAsCXXRecordDecl(),
        )

        if qspec != &null {
            var qargs = qspec->getTemplateArgs().asArray()
            for var qi: usize = 0; qi < qargs.size(); ++qi {
                if qargs[qi].getKind() != clang::TemplateArgument::Type {
                    continue
                }

                var unsafe *qrd = qargs[qi].getAsType()->getAsCXXRecordDecl()
                if qrd != &null
                    && qrd->getDefinition() == &null
                    && !llvm::isa<clang::ClassTemplateSpecializationDecl>(qrd) {
                    quiet = true
                    break
                }
            }
        }

        var was_quiet = diags->getSuppressAllDiagnostics()
        if quiet {
            diags->setSuppressAllDiagnostics(true)
        }

        var incomplete = !csema->isCompleteType(ct->getLocation(), ty)
        if quiet {
            diags->setSuppressAllDiagnostics(was_quiet)
            var unsafe *qd = ty->getAsCXXRecordDecl()
            if qd != &null && qd->isInvalidDecl() {
                (*why) = "clang could not complete the specialization"
                return FillResult::Failed
            }
        }

        if incomplete || diags->getNumErrors() > before {
            (*why) = "clang could not complete the specialization"
            // Incomplete with no error is this SET's gap, not the instance's:
            // the primary is the FIRST set to import its header, and there
            // the template may be only declared (a set that reaches
            // `SmallString` through <DependencyDirectivesScanner.h>'s
            // forward declaration, while the demanding TU includes
            // SmallString.h). The caller retries in the demanding TU's set;
            // without that, `s.size()` on a SmallString was R025E.
            // An error means the pattern itself rejected these arguments,
            // which no other set changes.
            if !(diags->getNumErrors() > before) {
                return FillResult::Unspelled
            }

            return FillResult::Failed
        }

        var unsafe *spec = llvm::dyn_cast_or_null<clang::ClassTemplateSpecializationDecl>(
            ty->getAsCXXRecordDecl(),
        )

        if spec == &null {
            (*why) = "completed type is not a class template specialization"
            return FillResult::Failed
        }

        // 4. import, in fill mode: every decl lands in the primary's header,
        //    the specialization itself maps to the shell.
        var di = self._hindex->importer_for(hs)
        var ti = self._hindex->type_importer_for(hs, t->ctx, t->fid)
        // The instance's pointer arguments keep the flavour they were written
        // with (`vector<*Node>` hands out `*Node`, not `unsafe *Node`):
        // TypeImport::note_pointer_arg. Spelled again here because the hint
        // path above never spelled them.
        var px = TypeExport(cctx, csema, unsafe (hs as unsafe *void))
        px.reg       = self._reg
        px.psym      = self.psym
        px.instances = self._instances
        px.home_fid  = home
        // A sibling argument with the same canonical C++ type must be seen
        // too, or it is mistaken for the one that was noted.
        var any_noted = false
        for var i: usize = 0; i < e->args.size(); ++i {
            if TypeImport::has_pointer_arg(e->args[i]) {
                any_noted = true
            }
        }

        for var i: usize = 0; i < e->args.size(); ++i {
            if !any_noted {
                continue
            }

            var unsafe *ab = dyn_cast<BuiltinType>(canon_unqual(e->args[i]))
            if ab == &null && !TypeImport::has_pointer_arg(e->args[i]) {
                continue
            }

            ti.note_pointer_arg(e->args[i], px.to_clang(e->args[i]))
        }

        // A VARIANT: another Kairo instance already owns this clang
        // specialization (`vector<u64>` beside `vector<usize>`, both
        // `vector<unsigned long>` to clang). It shares the specialization
        // but not the members, whose types follow each instance's own
        // arguments (DeclImport's VariantFill). The spec's own USR maps to
        // this shell inside the fill, so `const vector&` is this instance.
        var own_usr: llvm::StringMap<unsafe *Decl>
        var variant: unsafe *llvm::StringMap<unsafe *Decl> = &null
        var spec_usr = TypeImport::usr_of(spec)
        if !spec_usr.empty() {
            var unsafe *owner = self._reg->find((spec_usr).str())
            if owner != &null && owner != shell {
                own_usr.try_emplace((spec_usr).str(), shell)
                variant     = unsafe &own_usr
                ti.fill_usr = variant
            }
        }

        di.begin_fill(
            t,
            NameLookup::context_of(shell),
            unsafe (spec as unsafe *clang::Decl),
            variant,
        )

        var pairs = cxx::std::vector<(unsafe *void, unsafe *Decl)>()
        self._hindex->walk_declare(spec, &di, &pairs)
        self._complete_nested(csema, cctx, &di, &pairs)
        for var i: usize = 0; i < pairs.size(); ++i {
            di.define(
                unsafe (pairs[i].0 as unsafe *clang::Decl),
                pairs[i].1,
                unsafe &ti,
            )
        }

        di.define_instance(spec, shell, unsafe &ti)

        // 5. the shell becomes an imported decl: EmitIR spells it by the
        //    specialization's full name, and the registry maps the spec's
        //    USR to it so a later import naming the spec finds this node.
        var usr = TypeImport::usr_of(spec)
        var sp = ti.spelling(
            clang::QualType::getFromOpaquePtr(
                (cctx->getCanonicalTagType(spec)).getAsOpaquePtr(),
            ),
        )

        decl_set_imported(
            shell,
            unsafe (spec as unsafe *void),
            string(
                unsafe ((usr.data() as unsafe *const u8) as *const u8),
                usr.size(),
            ),
            sp,
            unsafe (hs as unsafe *void),
            t->fid,
        )

        if !usr.empty() {
            self._reg->put((usr).str(), shell)
        }

        // 6. freeze what the fill created, THEN publish. The shell's
        //    ForeignFill is the fast path's state and must be the last write:
        //    decl_publish_fill is the release store fill()'s acquire load
        //    pairs with.
        di.end_fill()
        decl_publish_fill(shell, ForeignFill::Filled)
        kairo::Logger::info(
            kairo::Logger::Stage::Driver,
            f"ForeignInstantiate: filled {sp}: {di.n_declared} decl(s) declared, {di.n_defined} defined, {ti.n_opaque} opaque type(s)",
        )

        return FillResult::Filled
    }

    /// Whether clang's own template argument deduction and substitution
    /// keep the imported function template \p f as a candidate for a call
    /// with these arguments: 1 kept, 0 removed (\p why says by what), 2
    /// removed over a Kairo record's stand-in (soft: see below), -1
    /// undecided -- the arguments or the template have no clang spelling
    /// here, or clang's DEDUCTION (not substitution) disagreed with Kairo's.
    ///
    /// Why clang and not Kairo's own deduction: a C++ overload set is told
    /// apart by substitution failure ([temp.deduct]/8) -- `enable_if_t<...>
    /// = 0` on a defaulted parameter (libc++'s three `make_unique`s), on the
    /// return type, on a parameter, `void_t`, decltype, a requires-clause.
    /// Each is an expression over the deduced arguments that only C++'s
    /// template machinery can evaluate, and clang is in-process with the
    /// header's AST. Kairo deduces first (the candidate's rank and bindings
    /// are its), then clang deduces again from the same arguments, spelled
    /// as opaque expressions of their types and value categories, as
    /// AddTemplateOverloadCandidate does for the call EmitIR writes.
    ///
    /// Only a substitution-class failure removes the candidate --
    /// SubstitutionFailure, ConstraintsNotSatisfied, InvalidExplicitArguments:
    /// C++'s SFINAE verdicts. A deduction mismatch is left to Kairo's own
    /// deduction, which already judged the same arguments with its
    /// conversions; overruling it there would make an export gap (an
    /// argument TypeExport spells approximately) look like the user's error.
    ///
    /// \p explicit_args are the call's written generic arguments, \p arg_tys
    /// / \p arg_cats the call arguments in C++ order with no implicit object,
    /// each the argument's value type (a literal's default) and category.
    /// Takes `_mu` then the set's sema_lock(), the fill order.
    ///
    /// \p ret, when \p want_ret, receives the specialization's return type as
    /// clang substituted it, imported: the one source for a return type
    /// Kairo imported opaque (`enable_if_t<..., int>`, `-> decltype(...)`).
    /// \p fid is the calling TU (-1 none), as for fill(); \p alt_set its own
    /// HeaderSet (null for none), the retry when \p f's set cannot spell the
    /// arguments.
    fn deduce_call(self,
                   f:             unsafe *Decl,
                   explicit_args: unsafe *cxx::std::vector<unsafe *Type>,
                   arg_tys:       unsafe *cxx::std::vector<unsafe *Type>,
                   arg_cats:      unsafe *cxx::std::vector<Expr::ValueCategory>,
                   sink:          unsafe *BufferedDiagSink,
                   why:           unsafe *string,
                   want_ret:      bool,
                   @inout ret:    unsafe *Type,
                   fid:           i64 = -1,
                   alt_set:       unsafe *void = &null,
                   conv_at:       unsafe *cxx::std::vector<usize> = &null) -> i8 {
        var unsafe *cd = unsafe (decl_clang(f) as unsafe *clang::Decl)
        if cd == &null {
            return -1
        }

        var unsafe *ftd = llvm::dyn_cast<clang::FunctionTemplateDecl>(cd)
        if ftd == &null {
            var unsafe *fd = llvm::dyn_cast<clang::FunctionDecl>(cd)
            if fd != &null {
                ftd = fd->getDescribedFunctionTemplate()
            }
        }

        if ftd == &null {
            return -1
        }

        // A member template of a class template's PATTERN: its enclosing
        // arguments are not known, so there is nothing concrete to deduce.
        // A filled instance's members are concrete and take the path below.
        if ftd->getDeclContext()->isDependentContext() {
            return -1
        }

        var unsafe *hs = unsafe (decl_origin_set(f) as unsafe *HeaderSet)
        if hs == &null || !hs->alive() {
            return -1
        }

        if hs->ast() == &null || hs->sema() == &null {
            return -1
        }

        var unsafe *alt   = unsafe (alt_set as unsafe *HeaderSet)
        var        lock   = kairo::std::LockGuard(self._mu)
        var        opaque = false
        var r = self._deduce_in(
            f,
            ftd,
            hs,
            &*explicit_args,
            &*arg_tys,
            &*arg_cats,
            sink,
            &*why,
            want_ret,
            &ret,
            fid,
            &opaque,
            conv_at,
        )

        // The function's set is the FIRST to import its header, not the
        // caller's: `std::move` belongs to whichever set reached <utility>
        // first, and that set may never include llvm/Support/Error.h. There
        // `std::move(err)` spelled its argument as an opaque blob, so the
        // return type clang substitutes (`remove_reference_t<T>&&`) was never
        // imported and the call typed as `<ffi type>&&`; every `consumeError(
        // std::move(err))` then had no overload. The calling TU's own
        // set names the argument's type in its source, so it usually sees its
        // header: re-find the template there and deduce again, as a fill
        // retries an instance. Only an answer the first set could not
        // give is taken from the retry; a firm verdict there stands.
        var unspelled = r == -1 || r == 1 && want_ret && opaque
        if !unspelled || alt == &null || alt == hs || !alt->alive() {
            return r
        }

        if alt->ast() == &null || alt->sema() == &null {
            return r
        }

        var ax = TypeExport(
            alt->ast(),
            alt->sema(),
            unsafe (alt as unsafe *void),
        )

        var unsafe *aftd = ax.refind_function_template(ftd)
        if aftd == &null {
            return r
        }

        var aret:   unsafe *Type = &null
        var awhy                 = ""
        var aopaque              = false
        var r2 = self._deduce_in(
            f,
            aftd,
            alt,
            &*explicit_args,
            &*arg_tys,
            &*arg_cats,
            sink,
            &awhy,
            want_ret,
            &aret,
            fid,
            &aopaque,
            conv_at,
        )

        if r == -1 {
            *why = awhy
            ret  = aret
            return r2
        }

        if r2 == 1 && aret != &null {
            ret = aret
        }

        return r
    }

    /// deduce_call's work in one set: \p ftd is the template as \p hs's AST
    /// declares it. \p opaque reports that an argument had no spelling there
    /// but an opaque blob, so no return type was imported. Under `_mu`.
    priv fn _deduce_in(self,
                       f:                    unsafe *Decl,
                       ftd:                  unsafe *clang::FunctionTemplateDecl,
                       hs:                   unsafe *HeaderSet,
                       @inout explicit_args: cxx::std::vector<unsafe *Type>,
                       @inout arg_tys:       cxx::std::vector<unsafe *Type>,
                       @inout arg_cats:      cxx::std::vector<Expr::ValueCategory>,
                       sink:                 unsafe *BufferedDiagSink,
                       @inout why:           string,
                       want_ret:             bool,
                       @inout ret:           unsafe *Type,
                       fid:                  i64,
                       @inout opaque:        bool,
                       conv_at:              unsafe *cxx::std::vector<usize>) -> i8 {
        var unsafe *cctx  = hs->ast()
        var unsafe *csema = hs->sema()
        var        slock  = kairo::std::LockGuard(*hs->sema_lock())
        // A hard error outside the immediate context (a static_assert in a
        // trait the condition instantiates) is the program's error in C++
        // too; it goes to the calling TU like a fill's.
        var da: unsafe *ClangDiagAdapter = &null
        if sink != &null {
            da = hs->begin_diag(sink)
        }

        finally {
            hs->end_diag(da)
        }

        var tx = TypeExport(cctx, csema, unsafe (hs as unsafe *void))
        tx.reg               = self._reg
        tx.psym              = self.psym
        tx.instances         = self._instances
        tx.home_fid          = fid // \p fid: the calling TU, which a Kairo instance spelled here is homed in.
        tx.allow_opaque_args = true // see TypeExport::allow_opaque_args; a removal over a blob is soft (below).
        var        loc  = ftd->getLocation()
        var unsafe *tpl = ftd->getTemplateParameters()

        var ali = clang::TemplateArgumentListInfo(loc, loc)
        var prior: llvm::SmallVector<clang::TemplateArgument, 8>
        for var i: usize = 0; i < explicit_args.size(); ++i {
            var a = tx.to_clang_arg_of(tpl, i, (explicit_args)[i], &prior)
            if a.isNull() {
                return -1
            }

            if !tx.add_arg_loc(&ali, a, loc) {
                return -1
            }

            prior.push_back(a)
        }

        // Each argument as an expression of its type and category, which is
        // all [temp.deduct.call] reads of one. Allocated in the set's
        // ASTContext: the deduction's bookkeeping may keep pointers to them.
        var exprs: llvm::SmallVector<unsafe *clang::Expr, 8>
        for var i: usize = 0; i < arg_tys.size(); ++i {
            var q = tx.to_clang((arg_tys)[i])
            if q.isNull() {
                return -1
            }

            var vk = clang::VK_PRValue
            if (arg_cats)[i] == Expr::ValueCategory::LValue {
                vk = clang::VK_LValue
            }

            if (arg_cats)[i] == Expr::ValueCategory::XValue {
                vk = clang::VK_XValue
            }

            var unsafe *mem = cctx->Allocate(
                sizeof(clang::OpaqueValueExpr),
                alignof(clang::OpaqueValueExpr) as u32,
            )

            var unsafe *e = cxx::std::construct_at(
                unsafe (mem as unsafe *clang::OpaqueValueExpr),
                loc,
                q,
                vk,
                clang::OK_Ordinary,
                unsafe (&null as unsafe *clang::Expr),
            )

            exprs.push_back(unsafe (e as unsafe *clang::Expr))
        }

        // An argument class this set only forward-declares (`ofstream` in
        // the set of <ostream>, where <__fwd/fstream.h> declares it and
        // <fstream> was never included): a constraint reading it
        // (`is_base_of<ios_base, basic_ofstream<char>>` in `operator<<(
        // _Stream&&, const _Tp&)`) is a hard libc++ error clang would never
        // raise for a caller that included <fstream>. The attempt is silent
        // and, unless it succeeds anyway, undecided so the demanding TU's
        // set deduces it again (the same rule as a fill's).
        var quiet_args = false
        for var qi: usize = 0; qi < exprs.size(); ++qi {
            var qt = exprs[qi]->getType().getNonReferenceType()
            while qt->isPointerType() {
                qt = qt->getPointeeType()
            }

            var unsafe *qrd = qt->getAsCXXRecordDecl()
            if qrd == &null {
                continue
            }

            var unsafe *qspec = llvm::dyn_cast<clang::ClassTemplateSpecializationDecl>(
                qrd,
            )

            var unsafe *qdef = qrd->getDefinition()
            if qdef == &null && qspec != &null {
                // An implicit instance is complete when its template's pattern
                // is defined: clang instantiates it on demand.
                var unsafe *qpat = qspec->getSpecializedTemplate()->getTemplatedDecl()
                if qpat->getDefinition() != &null {
                    continue
                }
            }

            if qdef == &null {
                quiet_args = true
                break
            }
        }

        var info = clang::sema::TemplateDeductionInfo(loc, 0)
        var spec: unsafe *clang::FunctionDecl             = &null
        var eap:  unsafe *clang::TemplateArgumentListInfo = &null
        if explicit_args.size() > 0 {
            eap = unsafe &ali
        }

        var *qdiags         = &csema->getDiagnostics()
        var args_were_quiet = qdiags->getSuppressAllDiagnostics()
        if quiet_args {
            qdiags->setSuppressAllDiagnostics(true)
        }

        // The trap counts errors even while diagnostics are suppressed, and an
        // immediate-context SFINAE failure is never one (Sema captures it), so
        // it tells a hard error from a template's own substitution failure.
        var trap = clang::DiagnosticErrorTrap(&*qdiags)
        // No non-dependent conversion check: Kairo ranked every argument
        // against its parameter already, with its own conversions.
        var r = csema->DeduceTemplateArguments(
            ftd,
            eap,
            llvm::ArrayRef<unsafe *clang::Expr>(exprs),
            &spec,
            &info,
            false,
            false,
            false,
            clang::QualType(),
            clang::Expr::Classification(),
            false,
            llvm::function_ref<fn (llvm::ArrayRef<clang::QualType>, bool) -> bool>(
                fn (ps: llvm::ArrayRef<clang::QualType>, only: bool) -> bool { return false },
            ),
        )

        opaque = tx.used_opaque
        if quiet_args {
            qdiags->setSuppressAllDiagnostics(args_were_quiet)
            // Only a HARD error (an incomplete class read by a trait) makes
            // the verdict unreliable. A SFINAE removal over an incomplete
            // argument is clang's own answer: `make_unique<PCHGenerator>(
            // module_cache_ref)` drops the bounded-array overload by its
            // `enable_if` whatever ModuleCache's completeness. Other
            // failure classes fall to the checks below.
            if r != clang::TemplateDeductionResult::Success && trap.hasErrorOccurred() {
                return -1
            }
        }

        // \p conv_at: arguments Kairo passed on unchecked because their
        // parameter is opaque until substituted (`format_string<T...>`).
        // The specialization's own parameter is now concrete; C++ takes the
        // argument iff an implicit conversion sequence exists, which clang
        // builds -- a consteval constructor is only checked at the emitted
        // call, where the literal is a literal.
        if r == clang::TemplateDeductionResult::Success && spec != &null && conv_at != &null {
            for var ci: usize = 0; ci < conv_at->size(); ++ci {
                var k = (*conv_at)[ci]
                if k >= exprs.size() || k >= (spec->getNumParams() as usize) {
                    continue
                }

                var pq = spec->getParamDecl(k as u32)->getType()
                var cw = qdiags->getSuppressAllDiagnostics()
                qdiags->setSuppressAllDiagnostics(true)
                var ctrap = clang::DiagnosticErrorTrap(&*qdiags)
                var ics = csema->TryImplicitConversion(
                    exprs[k],
                    pq,
                    false,
                    clang::Sema::AllowedExplicit::None,
                    true,
                    false,
                    false,
                )

                qdiags->setSuppressAllDiagnostics(cw)
                if ics.isBad() || ctrap.hasErrorOccurred() {
                    (why) = f"argument {k + 1} does not convert to the parameter C++ substituted"
                    return 0
                }
            }
        }

        if r == clang::TemplateDeductionResult::Success {
            if want_ret && spec != &null && !tx.used_opaque {
                // `decltype(auto)` / `auto` (llvm::dyn_cast, cast, isa): the
                // specialization's declared return type is the placeholder
                // until its body is instantiated, and imported as such it is
                // opaque -- `dyn_cast<TagDecl>(nd)` typed as nothing, so
                // every `->` on it was R027E. clang deduces it as it would
                // at a call: by instantiating the definition, quietly (a
                // failure leaves the placeholder, and the call untyped).
                if spec->getReturnType()->getContainedDeducedType() != &null {
                    csema->DeduceReturnType(spec, loc, false)
                }

                var unsafe *t = self._hindex->target_for_fid(decl_origin_fid(f))
                if t != &null {
                    var ti = self._hindex->type_importer_for(hs, t->ctx, t->fid)
                    ret = ti._import(spec->getReturnType())
                }
            }

            return 1
        }

        if r != clang::TemplateDeductionResult::ConstraintsNotSatisfied
            && r != clang::TemplateDeductionResult::SubstitutionFailure
            && r != clang::TemplateDeductionResult::InvalidExplicitArguments {
            kairo::Logger::info(
                kairo::Logger::Stage::Driver,
                f"ForeignInstantiate: clang's deduction of {kairo::std::from_std_string<string>(ftd->getQualifiedNameAsString())} disagreed with Kairo's (result {(r as i32)}); Kairo's verdict kept",
            )

            return -1
        }

        // A removal that read a Kairo record through its stand-in (fields,
        // no methods: TypeExport::used_standin) may be the stand-in's fault
        // -- `IndexableBuffer<RingBuf<i32>>` probes `len()`, which only the
        // real record has -- or may not be (`make_unique<Cp>`'s array
        // overloads fail on `Cp` being no array, which the stand-in shows
        // truly). So it is a SOFT removal (2): the candidate loses to any
        // firm one it ties, and stands when nothing else does.
        var verdict: i8 = if (tx.used_standin) => (2) else => 0
        if r == clang::TemplateDeductionResult::ConstraintsNotSatisfied {
            (why) = "its constraints are not satisfied"
            return verdict
        }

        (why) = "substitution failure"
        if info.hasSFINAEDiagnostic() {
            // getStringArg is not const; the diagnostic is ours to read.
            var unsafe *pd = unsafe ((&info.peekSFINAEDiagnostic()) as unsafe *clang::PartialDiagnosticAt)
            var *d = &(*pd).second
            // clang's own note for a failed enable_if condition
            // (DiagnoseBadDeduction): the error text reads "'enable_if'
            // cannot be used to disable this declaration", which is what a
            // hard error would say, not why this candidate went.
            if d->getDiagID() == (clang::diag::err_typename_nested_not_found_requirement as u32) {
                var req = d->getStringArg(0)
                (why) = f"requirement '{string(unsafe ((req.data() as unsafe *const u8) as *const u8), req.size())}' was not satisfied"
                return verdict
            }

            if d->getDiagID() == (clang::diag::err_typename_nested_not_found_enable_if as u32) {
                (why) = "disabled by 'enable_if'"
                return verdict
            }

            var buf: llvm::SmallString<128>
            d->EmitToString(&csema->getDiagnostics(), &buf)
            if buf.size() > 0 {
                (why) = f"substitution failure: {string(unsafe ((buf.data() as unsafe *const u8) as *const u8), buf.size())}"
            }
        }

        return verdict
    }

    /// What clang says of the imported function \p f's side effects (see
    /// Native/KClangPurity.hh): 0 none, 1 const, 2 pure.
    ///
    /// Invariant: Sema threads never read clang's AST outside the owning
    /// set's sema_lock(). The answer walks the redeclaration chain, and a
    /// chain is not immutable data: a fill on another pool thread runs
    /// clang::Sema in the same ASTContext (instantiating members, adding
    /// redeclarations, completing lazy chain links), so an unlocked walk
    /// read a half-written link and called through null. Only the
    /// set lock, not `_mu`: nothing here allocates on the Kairo side, and
    /// taking the set lock alone keeps the `_mu`-then-set order intact.
    static fn decl_purity(f: unsafe *Decl) -> u8 {
        var unsafe *cd = decl_clang(f)
        if cd == &null {
            return 0
        }

        var unsafe *hs = unsafe (decl_origin_set(f) as unsafe *HeaderSet)
        if hs == &null {
            return kairo::clang_decl_purity(cd)
        }

        // Not alive(): that may revive a released set, a rebuild this read
        // must never trigger. A released set nulls its decls' clang_decl,
        // so a non-null one is live; the mutex itself always is.
        var slock = kairo::std::LockGuard(*hs->sema_lock())
        return kairo::clang_decl_purity(cd)
    }

    /// The return type clang deduces for the imported non-template \p f
    /// declared `auto` / `auto*` / `decltype(auto)`, imported; null when it
    /// is not such a function or clang cannot deduce it. Asked at a call,
    /// never at import: deducing instantiates the body, and a header full of
    /// unused `auto` members (toml++'s node_view) must cost nothing.
    /// A template's specialization is deduce_call's (want_ret). The set's
    /// diagnostics are quiet: a body that does not compile for this
    /// instance is an error only where C++ would call it, and then the
    /// emitted call reports it.
    fn deduced_return(self, f: unsafe *Decl) -> unsafe *Type {
        var unsafe *cd = unsafe (decl_clang(f) as unsafe *clang::Decl)
        if cd == &null {
            return &null
        }

        var unsafe *fd = llvm::dyn_cast<clang::FunctionDecl>(cd)
        var unsafe *hs = unsafe (decl_origin_set(f) as unsafe *HeaderSet)
        if fd == &null || hs == &null {
            return &null
        }

        // The cheap no first, under the set lock alone (decl_purity's order,
        // and no `_mu`, so a call of a non-`auto` function costs one
        // uncontended lock): DeduceReturnType below, on another thread,
        // rewrites fd's type with setType, so even this read races it
        // unlocked. A non-null clang_decl means the set is live.
        {
            var pre = kairo::std::LockGuard(*hs->sema_lock())
            if fd->getDescribedFunctionTemplate() != &null || fd->isDependentContext() {
                return &null
            }

            if fd->getReturnType()->getContainedDeducedType() == &null {
                return &null
            }
        }

        if (!hs->alive()) || hs->ast() == &null || hs->sema() == &null {
            return &null
        }

        var        lock   = kairo::std::LockGuard(self._mu)
        var unsafe *csema = hs->sema()
        var        slock  = kairo::std::LockGuard(*hs->sema_lock())
        var        *diags = &csema->getDiagnostics()
        var        was    = diags->getSuppressAllDiagnostics()
        diags->setSuppressAllDiagnostics(true)
        var trap = clang::DiagnosticErrorTrap(&*diags)
        var bad  = csema->DeduceReturnType(fd, fd->getLocation(), false)
        diags->setSuppressAllDiagnostics(was)
        if bad || trap.hasErrorOccurred() {
            return &null
        }

        var rq = fd->getReturnType()
        if rq->isUndeducedType() {
            return &null
        }

        var unsafe *t = self._hindex->target_for_fid(decl_origin_fid(f))
        if t == &null {
            return &null
        }

        var ti = self._hindex->type_importer_for(hs, t->ctx, t->fid)
        return ti._import(rq)
    }

    /// C++ takes a \p from of category \p cat to the class \p to through ONE
    /// user-defined conversion ([over.best.ics]), as clang judges it at a
    /// call to the imported \p f. Asked of clang rather than re-derived:
    /// the real converting constructors are templates (`fmt::basic_string_
    /// view(const S&)`), take a defaulted trailing parameter (`basic_string(
    /// const CharT*, const Alloc& = Alloc())`), are consteval (`fstring`), or
    /// are not declared until the specialization is complete and clang
    /// declares them; a hand search saw none of those. Only a
    /// user-defined sequence answers true: a standard conversion is Kairo's
    /// own lattice to judge. Diagnostics are suppressed and any hard error
    /// is a no: the probe is a question, never the program's error.
    ///
    /// \p lit_n nonzero: the source is a string literal, asked as what C++
    /// sees -- an lvalue `const char[lit_n]` -- not its decayed `const char*`
    /// (\p from is then ignored). A constructor template on `const char
    /// (&)[N]` (fmt's `format_string`) deduces N only from the array; the
    /// pointer-taking constructors still see it through the decay.
    fn cxx_converts(self,
                    f:     unsafe *Decl,
                    from:  unsafe *Type,
                    cat:   Expr::ValueCategory,
                    to:    unsafe *Type,
                    lit_n: u64 = 0) -> bool {
        var unsafe *cd = unsafe (decl_clang(f) as unsafe *clang::Decl)
        var unsafe *hs = unsafe (decl_origin_set(f) as unsafe *HeaderSet)
        if cd == &null || hs == &null || (!hs->alive()) || from == &null || to == &null {
            return false
        }

        if hs->ast() == &null || hs->sema() == &null {
            return false
        }

        var        lock   = kairo::std::LockGuard(self._mu)
        var unsafe *cctx  = hs->ast()
        var unsafe *csema = hs->sema()
        var        slock  = kairo::std::LockGuard(*hs->sema_lock())
        var        tx     = TypeExport(cctx, csema, unsafe (hs as unsafe *void))
        tx.reg       = self._reg
        tx.psym      = self.psym
        tx.instances = self._instances
        var fq = clang::QualType()
        if lit_n != 0 {
            fq = cctx->getConstantArrayType(
                cctx->CharTy.withConst(),
                llvm::APInt(64, lit_n),
                &null,
                clang::ArraySizeModifier::Normal,
                0,
            )
        } else {
            fq = tx.to_clang(from)
        }

        var tq = tx.to_clang(to)
        if fq.isNull() || tq.isNull() || tx.used_opaque {
            return false
        }

        var loc = cd->getLocation()
        var vk  = clang::VK_PRValue
        if cat == Expr::ValueCategory::LValue || lit_n != 0 {
            vk = clang::VK_LValue
        }

        if cat == Expr::ValueCategory::XValue {
            vk = clang::VK_XValue
        }

        var unsafe *mem = cctx->Allocate(
            sizeof(clang::OpaqueValueExpr),
            alignof(clang::OpaqueValueExpr) as u32,
        )

        var unsafe *e = cxx::std::construct_at(
            unsafe (mem as unsafe *clang::OpaqueValueExpr),
            loc,
            fq.getNonReferenceType(),
            vk,
            clang::OK_Ordinary,
            unsafe (&null as unsafe *clang::Expr),
        )

        var *diags = &csema->getDiagnostics()
        var was    = diags->getSuppressAllDiagnostics()
        diags->setSuppressAllDiagnostics(true)
        var trap = clang::DiagnosticErrorTrap(&*diags)
        var ics = csema->TryImplicitConversion(
            unsafe (e as unsafe *clang::Expr),
            tq,
            false,
            clang::Sema::AllowedExplicit::None,
            true,
            false,
            false,
        )

        diags->setSuppressAllDiagnostics(was)
        if trap.hasErrorOccurred() {
            return false
        }

        return ics.isUserDefined()
    }

    /// Nested records of the specialization. Implicit instantiation of
    /// `holder<alloc>` instantiates the DECLARATION of `holder<alloc>::node`,
    /// not its definition (that waits until the type is required complete),
    /// so walk_declare declares `node` and correctly walks nothing inside it:
    /// `node` bound as a type with no fields or methods. Complete each such
    /// record the walk reached, then walk it, appending to \p pairs --
    /// so a record completed here yields ITS nested records to the same loop
    /// (`A<T>::B::C`), and everything is declared before the define pass.
    ///
    /// Only records inside this specialization's own DeclContext walk: a
    /// type a member SIGNATURE mentions is not reached here and stays on
    /// demand (the ensure_filled trigger). Completing transitively would have
    /// the first <vector> fill instantiate half of libc++.
    ///
    /// Runs inside _fill_locked, under `_mu` and the set's sema_lock already:
    /// no lock of its own, so no second ordering. A record clang cannot
    /// complete is skipped (memberless, logged), as for the outer fill.
    priv fn _complete_nested(self,
                             csema:        unsafe *clang::Sema,
                             cctx:         unsafe *clang::ASTContext,
                             di:           *DeclImport,
                             @inout pairs: cxx::std::vector<(unsafe *void, unsafe *Decl)>) {
        var seen   = llvm::DenseSet<u64>()    // record addresses: never the reserved keys
        var *diags = &csema->getDiagnostics()
        for var i: usize = 0; i < pairs.size(); ++i {
            var unsafe *d  = unsafe (pairs[i].0 as unsafe *clang::Decl)
            var unsafe *rd = llvm::dyn_cast<clang::CXXRecordDecl>(d)
            if rd == &null {
                continue
            }

            if rd->isCompleteDefinition() {
                continue
            }

            // A member class of the instantiation, not a forward declaration
            // the header left incomplete on purpose.
            if rd->getInstantiatedFromMemberClass() == &null {
                continue
            }

            var key = (rd as usize as u64)
            if !seen.insert(key).second {
                continue
            }

            // Each completion only adds records nested in the one completed,
            // so this terminates on any finite header; the cap turns a clang
            // or walk bug that re-offers records forever into an ICE, not a hang.
            if seen.size() > 4096 {
                kairo::std::ice_fail(
                    "ForeignInstantiate: nested-record completion did not converge",
                )
            }

            var before = diags->getNumErrors()
            var ty = clang::QualType::getFromOpaquePtr(
                (cctx->getCanonicalTagType(rd)).getAsOpaquePtr(),
            )

            var incomplete = csema->RequireCompleteType(rd->getLocation(), ty, (clang::diag::err_incomplete_type as u32))
            var unsafe *def = rd->getDefinition()
            if incomplete || diags->getNumErrors() > before || def == &null {
                kairo::Logger::warn(
                    kairo::Logger::Stage::Driver,
                    f"ForeignInstantiate: nested {kairo::std::from_std_string<string>(rd->getQualifiedNameAsString())} not completed; left without members",
                )

                continue
            }

            self._hindex->walk_declare(def, di, &pairs)
        }
    }
}
