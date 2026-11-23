/// --- The Kairo Project ------------------- Optimize/LLVM/SpecDevirt.k --- ///
///
///   Speculative devirtualization of a virtual call with a few possible
///   targets, run on each Kairo TU's IR at the start of the optimisation
///   pipeline (Optimize/LLVM/PassBridge.hh puts it there).
///
///   A virtual call clang emits for a Kairo class loads the vptr, tests it
///   against the static class's type id (llvm.public.type.test, from
///   -fdevirtualize-speculatively), loads the slot and calls through it. Every
///   vtable in the module that carries the same type id says, at the same
///   offset, which function that slot may hold. When those functions are few,
///   small and defined here, the call is versioned on them:
///
///       if vptr == &VtA[ap] { A(this) } else if vptr == &VtB[ap] { B(this) }
///       else { vptr[slot](this) }
///
///   and the inliner then folds each direct arm into the caller. The vptr
///   itself is compared with each vtable's address point when the vtables
///   are as few as the bodies allow, which spares the slot load on every
///   arm; when several vtables share a body (a subclass that does not
///   override), the loaded slot is compared with each body instead:
///
///       fn = vptr[slot]
///       if fn == @A { A(this) } else if fn == @B { B(this) } else { fn(this) }
///
///   Either rewrite is correct for any program. A vtable is a constant, so a
///   vptr at its address point reads @A from the slot, and a slot holding @A
///   makes the call a direct call to @A makes. A vptr or slot holding
///   anything else (a class this TU does not see, a C++ subclass, a vtable
///   from a shared library) reaches the original indirect call unchanged. So
///   nothing needs the class hierarchy to be closed; which targets are
///   visible only decides whether a site is worth versioning.
///
///   A site with one target is left to clang's own speculative pass
///   (WholeProgramDevirt in speculative mode, at the end of the pipeline),
///   which versions it the same way; versioning it here too would compare it
///   twice.
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
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "llvm/Analysis/TypeMetadataUtils.h"
ffi "c++" import "llvm/IR/Constants.h"
ffi "c++" import "llvm/IR/Dominators.h"
ffi "c++" import "llvm/IR/Function.h"
ffi "c++" import "llvm/IR/GlobalVariable.h"
ffi "c++" import "llvm/IR/InstrTypes.h"
ffi "c++" import "llvm/IR/Instructions.h"
ffi "c++" import "llvm/IR/Intrinsics.h"
ffi "c++" import "llvm/IR/LLVMContext.h"
ffi "c++" import "llvm/IR/Metadata.h"
ffi "c++" import "llvm/IR/Module.h"
ffi "c++" import "llvm/Transforms/Utils/CallPromotionUtils.h"
ffi "c++" import "Native/Types.hh"

import Optimize::KairoPass::{
    KairoPass,
    PassPoint,
}

/// The most targets one call site is versioned for. Each one is a compare
/// on the path to every later arm and to the indirect fallback, so past a
/// few the chain costs more than the indirect call it avoids.
eval kSpecDevirtMaxTargets: usize = 4

/// The largest target worth a direct arm, in IR instructions before any
/// optimisation. An arm pays for itself by being inlined; a larger body
/// gains little from a direct call and adds a copy per call site.
eval kSpecDevirtMaxInstrs: u32 = 64

/// One vtable that carries a type id: the offset of that type's address
/// point within it, and how many type ids the vtable carries in all (a
/// derived class's vtable also carries every base's ids).
pub struct SpecDevirtMember {
    pub var gv:  unsafe *llvm::GlobalVariable = &null
    pub var off: u64                          = 0
    pub var ids: u32                          = 0
}

/// One virtual call found under a type test: the call, the vptr the test
/// reads, the type id it was tested against (an index into
/// SpecDevirt._members) and the slot's offset from the address point.
pub struct SpecDevirtSite {
    pub var cb:   unsafe *llvm::CallBase = &null
    pub var vptr: unsafe *llvm::Value    = &null
    pub var tid:  u32                    = 0
    pub var off:  u64                    = 0
}

/// The pass. One instance per module run (Optimize/PassRegistry.k).
pub class SpecDevirt impl KairoPass {
    /// Type id (its metadata node's address) to 1 + its index in _members.
    priv var _index:   llvm::DenseMap<u64, u32>
    priv var _members: [[SpecDevirtMember]]
    priv var _sites:   [SpecDevirtSite]

    pub fn SpecDevirt(self) { }

    pub static fn pass_name() -> string {
        return "spec-devirt"
    }

    /// Before the inliner, which then folds each direct arm into its caller.
    pub static fn pass_point() -> PassPoint {
        return PassPoint::PipelineStart
    }

    /// Above -O0, where clang emits the type tests the pass reads
    /// (-fdevirtualize-speculatively, ClangBackend), and not when optimising
    /// for size: every versioned site grows by a compare and an inlined copy
    /// of each target.
    pub static fn enabled(opt_level: i32, size_level: i32) -> bool {
        return opt_level > 0 && size_level == 0
    }

    /// Versions every eligible virtual call in `m`; true when one changed.
    pub fn run(self, m: unsafe *llvm::Module, f: unsafe *llvm::Function) -> bool {
        var unsafe *pub_test = llvm::Intrinsic::getDeclarationIfExists(
            m,
            llvm::Intrinsic::public_type_test as u32,
        )

        var unsafe *tt = llvm::Intrinsic::getDeclarationIfExists(
            m,
            llvm::Intrinsic::type_test as u32,
        )

        if pub_test == &null && tt == &null {
            return false
        }

        self._collect_vtables(m)
        if self._members.size() == 0 {
            return false
        }

        // Every site is found before any is rewritten: versioning splits
        // blocks, which would leave a function's dominator tree stale for
        // the type tests still to be read in it.
        self._collect_sites(pub_test)
        self._collect_sites(tt)

        // A call reached from two type tests is versioned once.
        var done:   llvm::DenseMap<u64, u32>
        var changed                          = false
        for *s in self._sites {
            var key = ((*s).cb as usize) as u64
            if done.lookup(key) != 0 {
                continue
            }

            done[key] = 1
            if self._version(m, (*s)) {
                changed = true
            }
        }

        return changed
    }

    /// Indexes every constant global with !type metadata by type id.
    priv fn _collect_vtables(self, m: unsafe *llvm::Module) {
        for var it = m->global_begin(); it != m->global_end(); ++it {
            var unsafe *gv = unsafe &*it
            if !gv->hasMetadata(llvm::LLVMContext::MD_type as u32)
                || !gv->isConstant()
                || !gv->hasInitializer() {
                continue
            }

            var types: llvm::SmallVector<unsafe *llvm::MDNode, 4>
            gv->getMetadata(llvm::LLVMContext::MD_type as u32, &types)
            for var i: usize = 0; i < types.size(); ++i {
                var unsafe *md = types[i]
                if md->getNumOperands() < 2 {
                    continue
                }

                var unsafe *off = llvm::mdconst::dyn_extract<llvm::ConstantInt>(
                    md->getOperand(0),
                )

                if off == &null {
                    continue
                }

                var key = (md->getOperand(1).get() as usize) as u64
                var at  = self._index.lookup(key)
                if at == 0 {
                    self._members.push([])
                    at               = self._members.size() as u32
                    self._index[key] = at
                }

                self._members[(at - 1) as usize].push(
                    SpecDevirtMember { gv: gv, off: off->getZExtValue(), ids: types.size() as u32 },
                )
            }
        }
    }

    /// Records the virtual calls under each call of `tt` (a type-test
    /// intrinsic, null when the module declares none) whose type id some
    /// vtable here carries, skipping functions optimised for size.
    priv fn _collect_sites(self, tt: unsafe *llvm::Function) {
        if tt == &null {
            return
        }

        // A type test's users, grouped by function so each dominator tree
        // is built once.
        var fn_index: llvm::DenseMap<u64, u32>
        var fns:      [unsafe *llvm::Function]
        var by_fn:    [[unsafe *llvm::CallInst]]
        for u in tt->users() {
            var unsafe *ci = llvm::dyn_cast<llvm::CallInst>(u)
            if ci == &null {
                continue
            }

            var unsafe *f = ci->getFunction()
            if f->hasOptSize() {
                continue
            }

            var key = (f as usize) as u64
            var at  = fn_index.lookup(key)
            if at == 0 {
                fns.push(f)
                by_fn.push([])
                at            = fns.size() as u32
                fn_index[key] = at
            }

            by_fn[(at - 1) as usize].push(ci)
        }

        for var i: usize = 0; i < fns.size(); ++i {
            var dt = llvm::DominatorTree(&*fns[i])
            for *ci in by_fn[i] {
                var unsafe *idv = llvm::cast<llvm::MetadataAsValue>(
                    (*ci)->getArgOperand(1),
                )

                var tid = self._index.lookup(
                    (idv->getMetadata() as usize) as u64,
                )

                if tid == 0 {
                    continue
                }

                var calls:   llvm::SmallVector<llvm::DevirtCallSite, 1>
                var assumes: llvm::SmallVector<unsafe *llvm::CallInst, 1>
                llvm::findDevirtualizableCallsForTypeTest(&calls, &assumes, (*ci), &dt)
                for var k: usize = 0; k < calls.size(); ++k {
                    self._sites.push(
                        SpecDevirtSite {
                            cb:   unsafe &calls[k].CB,
                            vptr: (*ci)->getArgOperand(0)->stripPointerCasts(),
                            tid:  tid - 1,
                            off:  calls[k].Offset,
                        },
                    )
                }
            }
        }
    }

    /// Versions one site when its targets are 2 to kSpecDevirtMaxTargets
    /// small functions defined here, each callable directly with the call's
    /// own signature. The targets of the most derived vtables are compared
    /// first: a base class's own body is the one most often overridden.
    priv fn _version(self, m: unsafe *llvm::Module, s: SpecDevirtSite) -> bool {
        // A musttail call must stay the last thing before its return, and a
        // ptrauth bundle signs the indirect callee: neither can be split.
        if s.cb->isMustTailCall()
            || s.cb->countOperandBundlesOfType(
                llvm::LLVMContext::OB_ptrauth as u32,
            ) != 0 {
            return false
        }

        // Each distinct body, the vtables (address points) holding it, and
        // the most type ids any of them carries.
        var targets: [unsafe *llvm::Function]
        var points:  [[SpecDevirtMember]]
        var rank:    [u32]
        for *mem in self._members[s.tid as usize] {
            var hit = llvm::getFunctionAtVTableOffset(
                (*mem).gv,
                (*mem).off + s.off,
                &*m,
            )

            var unsafe *f = hit.first
            if f == &null {
                return false
            }

            var name = f->getName()
            if name == kairo::sref(r"__cxa_pure_virtual")
                || name == kairo::sref(r"__cxa_deleted_virtual") {
                continue
            }

            var seen = false
            for var i: usize = 0; i < targets.size(); ++i {
                if targets[i] == f {
                    if (*mem).ids > rank[i] {
                        rank[i] = (*mem).ids
                    }

                    points[i].push((*mem))
                    seen = true
                }
            }

            if seen {
                continue
            }

            if f->isDeclaration()
                || f->getInstructionCount() > kSpecDevirtMaxInstrs
                || f->getFunctionType() != s.cb->getFunctionType()
                || !llvm::isLegalToPromote(*s.cb, f, &null) {
                return false
            }

            targets.push(f)
            points.push([(*mem)])
            rank.push((*mem).ids)
            if targets.size() > kSpecDevirtMaxTargets {
                return false
            }
        }

        if targets.size() < 2 {
            return false
        }

        var npoints: usize = 0
        for *p in points {
            npoints += (*p).size()
        }

        var unsafe *vptr    = llvm::dyn_cast<llvm::Instruction>(s.vptr)
        var        by_vptr  = vptr != &null && npoints <= kSpecDevirtMaxTargets
        var unsafe *byte_ty = llvm::Type::getInt8Ty(&m->getContext())
        var unsafe *word_ty = llvm::Type::getInt64Ty(&m->getContext())

        // Under vptr compares only the fallback reads the slot, so its load
        // moves down to the indirect call, off the path every arm takes,
        // when nothing between the two can write memory (an argument's
        // evaluation can).
        var unsafe *ld = llvm::dyn_cast<llvm::LoadInst>(
            s.cb->getCalledOperand(),
        )

        var sink = by_vptr && ld != &null && ld->getParent() == s.cb->getParent()
        if sink {
            var stop: unsafe *llvm::Instruction = s.cb
            var at:   unsafe *llvm::Instruction = ld->getNextNode()
            while at != &null && at != stop {
                if at->mayWriteToMemory() {
                    sink = false
                    break
                }

                at = at->getNextNode()
            }
        }

        // Most derived first, equal ranks in vtable order. Each versioning
        // moves the original call into the else block, so the next compare
        // goes in front of what is left of the chain.
        var done: [bool]
        for var i: usize = 0; i < targets.size(); ++i {
            done.push(false)
        }

        for var n: usize = 0; n < targets.size(); ++n {
            var best = targets.size()
            for var i: usize = 0; i < targets.size(); ++i {
                if !done[i] && (best == targets.size() || rank[i] > rank[best]) {
                    best = i
                }
            }

            done[best] = true
            var direct: unsafe *llvm::CallBase = &null
            if by_vptr {
                var aps: llvm::SmallVector<unsafe *llvm::Constant, 2>
                for *p in points[best] {
                    aps.push_back(
                        llvm::ConstantExpr::getInBoundsGetElementPtr(
                            byte_ty,
                            (*p).gv,
                            llvm::ConstantInt::get(word_ty, (*p).off),
                        ),
                    )
                }

                direct = unsafe &llvm::promoteCallWithVTableCmp(
                    &*s.cb,
                    vptr,
                    targets[best],
                    llvm::ArrayRef<unsafe *llvm::Constant>(aps),
                    &null,
                )
            } else {
                direct = unsafe &llvm::versionCallSite(
                    &*s.cb,
                    targets[best],
                    &null,
                )

                direct->setCalledOperand(targets[best])
            }

            direct->setMetadata(llvm::LLVMContext::MD_prof as u32, &null)
            direct->setMetadata(llvm::LLVMContext::MD_callees as u32, &null)
        }

        // The load and the address it reads take the vptr, defined above
        // the first compare, so they still dominate their uses down there.
        if sink {
            if ld->hasOneUse() {
                var unsafe *addr = llvm::dyn_cast<llvm::Instruction>(
                    ld->getPointerOperand(),
                )

                ld->moveBefore(s.cb->getIterator())
                if addr != &null && addr != vptr && addr->hasOneUse() {
                    addr->moveBefore(ld->getIterator())
                }
            }
        }

        return true
    }
}
