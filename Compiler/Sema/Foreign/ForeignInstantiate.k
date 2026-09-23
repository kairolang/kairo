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
///     ordinary filled instance (`instantiated`) and nothing walks the
///     pattern for it again.
///
///     Demand-driven: MemberLookup::_walk_record calls fill() the first time
///     anything looks into the shell. A failure is sticky
///     (`foreign_fill_failed`) and leaves lookup on the pattern -- exactly
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
ffi "c++" import "clang/AST/Decl.h";
ffi "c++" import "clang/AST/DeclCXX.h";
ffi "c++" import "clang/AST/DeclTemplate.h";
ffi "c++" import "clang/Basic/DiagnosticSema.h";
ffi "c++" import "clang/Sema/Sema.h";
ffi "c++" import "llvm/ADT/SmallVector.h";

import AST::Context::ASTContext::*;
import AST::Context::DeclContext::*;
import AST::Context::SymbolTable::*;
import AST::Context::InstantiationRegistry::*;
import AST::Node::Base::*;
import AST::Node::Declarations::*;
import AST::DeclFacts::*;
import AST::Node::Casting::*;
import Sema::Resolve::NameLookup::*;
import Sema::Foreign::ForeignRegistry::*;
import Sema::Foreign::TypeImport::*;
import Sema::Foreign::TypeExport::*;
import Sema::Foreign::DeclImport::*;
import Sema::Foreign::HeaderIndex::*;
import Interop::Clang::HeaderSet::*;
import Preprocessor::PreprocessorSymbolTable::*;
import Diagnostic::BufferedDiagSink::*;
import Diagnostic::ClangDiagAdapter::*;

class ForeignInstantiate {
    priv var _mu:        std::RecursiveMutex;      ///< ONE lock for all fills; see the file header.
    priv var _active:    vec::<*Decl>;             ///< shells mid-fill, outermost first; guarded by `_mu`.
    priv var _hindex:    obs::<HeaderIndex>;
    priv var _reg:       obs::<ForeignRegistry>;
    priv var _instances: obs::<InstantiationRegistry>;
    priv var _why:       string = "";              ///< the last failure's reason, for the log line.
    /// For TypeExport's stand-ins of Kairo records (`vector<S>`), which
    /// are named as EmitIR names them. Null until the driver has a
    /// preprocessor; a Kairo-record argument is refused until then.
    pub var psym:        obs::<PreprocessorSymbolTable> = &null;

    pub var n_filled: usize = 0;
    pub var n_failed: usize = 0;

    fn ForeignInstantiate(self, hindex: *HeaderIndex, reg: *ForeignRegistry, instances: *InstantiationRegistry) {
        self._hindex    = hindex;
        self._reg       = reg;
        self._instances = instances;
    }

    /// Fill \p shell (an unfilled instance whose primary is imported). True
    /// if it is filled afterwards, by this call or an earlier one. clang's
    /// own diagnostics for the fill go to \p sink, the demanding TU's; null
    /// leaves them on the set's fallback printer.
    fn fill(self, shell: *Decl, sink: *BufferedDiagSink = &null) -> bool {
        if shell == &null { return false; }
        // Unlocked fast path. Both flags only ever go false -> true, each is
        // written LAST by a fill holding `_mu`, and today every caller is the
        // driver thread; the re-check under the lock is what is load-bearing.
        if decl_instantiated(shell) { return true; }
        if decl_fill_failed(shell) { return false; }

        var lock = std::LockGuard(self._mu);
        if decl_instantiated(shell) { return true; }
        if decl_fill_failed(shell) { return false; }
        // Re-entered for a shell this thread is already filling: not a
        // failure (the outer fill will finish it), so no sticky flag.
        for var i: usize = 0; i < self._active.size(); ++i {
            if self._active[i] == shell { return false; }
        }

        self._active.push_back(shell);
        var ok = self._fill_locked(shell, sink);
        self._active.pop_back();
        if ok {
            self.n_filled += 1;
            return true;
        }
        decl_set_fill_failed(shell);
        self.n_failed += 1;
        // clang's own errors for the fill already went to `sink`, with spans
        // in the header. TODO(diag): a Kairo note pointing at the USE that
        // demanded the fill; until then the use's member typing reports
        // `unknown` as it did before fills.
        var prim = decl_instantiated_from(shell);
        var what = "<no pattern>";
        if prim != &null { what = decl_cxx_spelling(prim); }
        Logger::warn(Logger::Stage::Driver,
            f"ForeignInstantiate: instance of {what} not filled: {self._why}");
        return false;
    }

    priv fn _fill_locked(self, shell: *Decl, sink: *BufferedDiagSink) -> bool {
        // 1. who owns the pattern.
        var prim = decl_instantiated_from(shell);
        if prim == &null { self._why = "no pattern"; return false; }
        var hs = reinterpret_cast::<*HeaderSet>(decl_origin_set(prim));
        if hs == &null { self._why = "primary has no header set"; return false; }
        // A set's clang instance lives until HeaderSetCache::release_all,
        // after every TU's sema. A fill past that is a pass looking into an
        // instance after Checked -- a schedule bug, never the user's.
        ICE_IF((!hs->alive()), "ForeignInstantiate: fill after the primary's header set was released");
        var cctx = hs->ast();
        var csema = hs->sema();
        if (cctx == &null) || (csema == &null) { self._why = "header set has no AST / Sema"; return false; }

        var ct = TypeExport::class_template_of(reinterpret_cast::<*clang::Decl>(decl_clang(prim)));
        if ct == &null { self._why = "primary is not a class template"; return false; }
        var t = self._hindex->target_for_fid(decl_origin_fid(prim));
        if t == &null { self._why = "primary's header has no import target"; return false; }
        // The shell's own spec_args are empty by design; its args are the
        // registry entry's (canonical, parameter order, defaults filled).
        var e = self._instances->entry_of(shell);
        if e == &null { self._why = "not a registry instance"; return false; }

        // Everything from here asks clang::Sema, including spelling the args:
        // a nested instance argument is itself a CheckTemplateIdType.
        var slock = std::LockGuard(*(hs->sema_lock()));

        // clang's diagnostics for this fill -- a static_assert in the
        // pattern, an undefined specialization it names -- go to the TU that
        // demanded it, through the engine, with spans in the header.
        var da: *ClangDiagAdapter = &null;
        if sink != &null { da = hs->begin_diag(sink); }
        finally { hs->end_diag(da); }

        // 2. the args, spelled in THIS set's AST.
        var tx = TypeExport(cctx, csema, reinterpret_cast::<*void>(hs));
        tx.reg       = self._reg;
        tx.psym      = self.psym;
        tx.instances = self._instances;
        var qs: llvm::SmallVector::<clang::QualType, 8>;
        for var i: usize = 0; i < e->args.size(); ++i {
            var q = tx.to_clang(e->args[i]);
            if q.isNull() { self._why = f"template argument {i} has no clang spelling in phase A"; return false; }
            qs.push_back(q);
        }

        // 3. declare + complete. RequireCompleteType is what instantiates the
        //    class definition: member DECLARATIONS, which is all sema needs.
        //    Member function bodies stay pending; phase B instantiates those
        //    itself from the PCH.
        var ty = tx.template_id(ct, qs);
        if ty.isNull() { self._why = "clang rejected the template-id"; return false; }
        var diags  = &(csema->getDiagnostics());
        var before = diags->getNumErrors();
        var incomplete = csema->RequireCompleteType(ct->getLocation(), ty, clang::diag::err_incomplete_type);
        if incomplete || (diags->getNumErrors() > before) {
            self._why = "clang could not complete the specialization";
            return false;
        }
        var spec = llvm::dyn_cast_or_null::<clang::ClassTemplateSpecializationDecl>(ty->getAsCXXRecordDecl());
        if spec == &null { self._why = "completed type is not a class template specialization"; return false; }

        // 4. import, in fill mode: every decl lands in the primary's header,
        //    the specialization itself maps to the shell.
        var di = self._hindex->importer_for(hs);
        di.fill_target = t;
        di.fill_scope  = NameLookup::context_of(shell);
        di.fill_spec   = static_cast::<*clang::Decl>(spec);
        var ti = self._hindex->type_importer_for(hs, t->ctx, t->fid);

        var pairs = vec::<(*void, *Decl)>();
        self._hindex->walk_declare(spec, &di, pairs);
        self._complete_nested(csema, cctx, &di, pairs);
        for var i: usize = 0; i < pairs.size(); ++i {
            di.define(reinterpret_cast::<*clang::Decl>(libcxx::get::<0>(pairs[i])), libcxx::get::<1>(pairs[i]), &ti);
        }
        di.define_instance(spec, shell, &ti);

        // 5. the shell becomes an imported decl: EmitIR spells it by the
        //    specialization's full name, and the registry maps the spec's
        //    USR to it so a later import naming the spec finds this node.
        var usr = TypeImport::usr_of(spec);
        var sp  = ti.spelling(clang::QualType(cctx->getCanonicalTagType(spec)));
        decl_set_imported(shell, reinterpret_cast::<*void>(spec), std::nstring_to_string(usr),
                          sp, reinterpret_cast::<*void>(hs), t->fid);
        if !usr.empty() { self._reg->put(usr, shell); }

        // 6. freeze what the fill created, THEN publish. `instantiated` is
        //    the fast path's flag and must be the last write.
        for var i: usize = 0; i < di.fill_scopes.size(); ++i {
            if di.fill_scopes[i]->dc_symbols != &null { di.fill_scopes[i]->dc_symbols->freeze(); }
        }
        decl_set_instantiated(shell);
        Logger::info(Logger::Stage::Driver,
            f"ForeignInstantiate: filled {sp}: {di.n_declared} decl(s) declared, {di.n_defined} defined, {ti.n_opaque} opaque type(s)");
        return true;
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
    priv fn _complete_nested(self, csema: *clang::Sema, cctx: *clang::ASTContext,
                             di: *DeclImport, pairs: ref!(vec::<(*void, *Decl)>)) {
        var seen = set::<u64>();
        var diags = &(csema->getDiagnostics());
        for var i: usize = 0; i < pairs.size(); ++i {
            var d  = reinterpret_cast::<*clang::Decl>(libcxx::get::<0>(pairs[i]));
            var rd = llvm::dyn_cast::<clang::CXXRecordDecl>(d);
            if rd == &null { continue; }
            if rd->isCompleteDefinition() { continue; }
            // A member class of the instantiation, not a forward declaration
            // the header left incomplete on purpose.
            if rd->getInstantiatedFromMemberClass() == &null { continue; }
            var key = reinterpret_cast::<u64>(rd);
            if seen.contains(key) { continue; }
            seen.insert(key);
            // Each completion only adds records nested in the one completed,
            // so this terminates on any finite header; the cap turns a clang
            // or walk bug that re-offers records forever into an ICE, not a hang.
            ICE_IF((seen.size() > 4096), "ForeignInstantiate: nested-record completion did not converge");

            var before = diags->getNumErrors();
            var ty = clang::QualType(cctx->getCanonicalTagType(rd));
            var incomplete = csema->RequireCompleteType(rd->getLocation(), ty, clang::diag::err_incomplete_type);
            var def = rd->getDefinition();
            if incomplete || (diags->getNumErrors() > before) || (def == &null) {
                Logger::warn(Logger::Stage::Driver,
                    f"ForeignInstantiate: nested {std::nstring_to_string(rd->getQualifiedNameAsString())} not completed; left without members");
                continue;
            }
            self._hindex->walk_declare(def, di, pairs);
        }
    }

}
