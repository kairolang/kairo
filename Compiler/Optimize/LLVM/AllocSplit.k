/// --- The Kairo Project ------------------- Optimize/LLVM/AllocSplit.k --- ///
///
///   Gives the global heap a path of its own through a function that
///   allocates and frees with the allocator in effect: `@create` and
///   `@destroy`, alloc_raw and free_raw, the container family
///   (Lib/builtin/alloc_raw.k).
///
///   Each of those chooses its allocator at run time. It loads scope_top,
///   the thread's innermost open scope, and takes the global heap when
///   there is none. Inlined into one function, an allocation and its free
///   read
///
///       if scope_top == null { p = mi_malloc_small(16) }
///       else                 { p = scope_top->alloc(16, 8) }
///       ... p ...
///       if scope_top == null { mi_free_small_nonnull(p) }
///       else                 { free_scoped(p, 16, 8) }
///
///   so the block is the merge of two calls and the free tests the stack
///   again: what AllocModel tells LLVM about the heap's entry points
///   reaches neither. When nothing between the two tests can open or close
///   a scope, the second has the first's answer. The pass copies the code
///   from the first test's no-scope edge up to and including the no-scope
///   arm of each later test, and in the copy every load of scope_top is
///   null:
///
///       if scope_top == null {
///           p = mi_malloc_small(16); ... p ...; mi_free_small_nonnull(p)
///       } else {
///           q = scope_top->alloc(16, 8); ... q ...
///           if scope_top == null { mi_free_small_nonnull(q) }
///           else                 { free_scoped(q, 16, 8) }
///       }
///
///   On the copy the block is one annotated call's, freed by an annotated
///   free, and LLVM treats it as it treats a malloc'd block: an unused
///   `@create` / `@destroy` pair is removed. The scope's arm is the code it
///   was.
///
///   What the pass relies on, all of it Lib/builtin/alloc_raw.k's:
///     - scope_top is written only by a scope opening or closing, and its
///       address is used only to load and store it. A function that does
///       anything else with the address is left alone.
///     - The heap's entry points, the ones AllocModel annotates, return
///       with the scope stack as they found it. So does the program's
///       global allocator behind the kairo_global_* symbols.
///
///   What may change the stack between two tests: a store to scope_top
///   (an AllocatorScope opening or closing, inlined), and any call except
///   one of the heap's annotated entry points, one that does not return,
///   and one whose memory effects LLVM knows to be none, reads only, or
///   confined to its arguments and to memory the module cannot name. A
///   call into unknown code may open a scope and return with it open
///   (AllocatorScope is movable), so it ends the copy.
///
///   Limits. A split copies at most kAllocSplitMaxInstrs instructions, and
///   a function's splits kAllocSplitFnInstrs in one run. The copied path
///   holds an annotated allocation, so the pass does nothing when
///   AllocModel is off, and it holds no loop: a loop between an allocation
///   and its free would be copied whole for one test. A first test inside
///   a loop is split within one iteration; the loop is not unrolled. The
///   pass does not run when optimising for size.
///
///   Where: after each instruction combining of the function
///   simplification pipeline. The first run on a function follows the
///   inlining of alloc_raw and free_raw into it, and the simplifications
///   after it fold the copy's tests and remove its dead allocation. A
///   scope_top load a copy was made for is marked (!kairo.alloc.split) and
///   never starts another, so a later run finds nothing to do.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/ArrayRef.h"
ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "llvm/ADT/Twine.h"
ffi "c++" import "llvm/IR/Attributes.h"
ffi "c++" import "llvm/IR/BasicBlock.h"
ffi "c++" import "llvm/IR/Constants.h"
ffi "c++" import "llvm/IR/Function.h"
ffi "c++" import "llvm/IR/GlobalVariable.h"
ffi "c++" import "llvm/IR/InstrTypes.h"
ffi "c++" import "llvm/IR/Instructions.h"
ffi "c++" import "llvm/IR/IntrinsicInst.h"
ffi "c++" import "llvm/IR/Intrinsics.h"
ffi "c++" import "llvm/IR/LLVMContext.h"
ffi "c++" import "llvm/IR/Metadata.h"
ffi "c++" import "llvm/IR/Module.h"
ffi "c++" import "llvm/IR/Use.h"
ffi "c++" import "llvm/IR/Verifier.h"
ffi "c++" import "llvm/Transforms/Utils/Cloning.h"
ffi "c++" import "llvm/Transforms/Utils/SSAUpdater.h"
ffi "c++" import "llvm/Transforms/Utils/ValueMapper.h"
ffi "c++" import "Native/Types.hh"

import Optimize::KairoPass::{
    KairoPass,
    PassPoint,
}

/// The most instructions one split copies. A copy pays for itself when the
/// allocation on it is removed, or by the scope tests it drops; a long path
/// between an allocation and its free gains little of either.
eval kAllocSplitMaxInstrs: u32 = 64

/// The most instructions all of one function's splits copy in one run.
eval kAllocSplitFnInstrs: u32 = 256

/// The most blocks one split looks through for a later scope test.
eval kAllocSplitMaxBlocks: usize = 48

/// What the pass reads off one block of the function.
struct SplitBlock {
    var bb: unsafe *llvm::BasicBlock = &null
    /// The scope_top loads ahead of anything in the block that may change
    /// the stack: on a path where the stack is empty on entry, each is null.
    var loads: [unsafe *llvm::Instruction]
    /// Something in the block may change the stack.
    var changes: bool = false
    /// The block can be copied: no exception handling, no token value, a
    /// plain terminator, no address taken.
    var copyable: bool = true
    /// The block holds an annotated allocation.
    var allocates: bool = false
    var count:     u32  = 0
    /// The scope_top load the terminator tests against null, the successor
    /// taken when it is null, and whether nothing after the load, in this
    /// block, may change the stack.
    var test_load: unsafe *llvm::Instruction = &null
    var null_succ: u32                       = 0
    var test_live: bool                      = false
}

/// The pass. One instance per function run (Optimize/PassRegistry.k).
pub class AllocSplit impl KairoPass {
    priv var _blocks: [SplitBlock]
    /// Block to 1 + its index in _blocks.
    priv var _index: llvm::DenseMap<u64, u32>
    /// The function's loads of scope_top and its stores to it.
    priv var _loads:  llvm::DenseMap<u64, u32>
    priv var _stores: llvm::DenseMap<u64, u32>
    priv var _nloads: usize
    /// The uses one value's repair rewrites (_outside_uses).
    priv var _uses:   llvm::SmallVector<unsafe *llvm::Use, 8>
    priv var _mark:   u32
    priv var _budget: u32

    pub fn AllocSplit(self) {
        self._nloads = 0
        self._mark   = 0
        self._budget = kAllocSplitFnInstrs
    }

    pub static fn pass_name() -> string {
        return "alloc-split"
    }

    /// After the inliner has put an allocation and its free in one
    /// function, and ahead of the simplifications that clean up the copy.
    pub static fn pass_point() -> PassPoint {
        return PassPoint::Peephole
    }

    /// Above -O0, and not when optimising for size: a split copies code,
    /// and only an allocation it lets LLVM remove pays that back.
    pub static fn enabled(opt_level: i32, size_level: i32) -> bool {
        return opt_level > 0 && size_level == 0
    }

    /// Splits every eligible scope test of `f`; true when one was split.
    pub fn run(self, m: unsafe *llvm::Module, f: unsafe *llvm::Function) -> bool {
        if f == &null || f->isDeclaration() || f->isPresplitCoroutine() || f->hasOptSize() {
            return false
        }

        var unsafe *g = m->getNamedGlobal(
            kairo::sref(r"_ZN7builtin9alloc_raw9scope_topE"),
        )

        if g == &null || g->use_empty() || !self._find_uses(g, f) {
            return false
        }

        self._mark = f->getContext().getMDKindID(
            kairo::sref(r"kairo.alloc.split"),
        )

        self._scan(f)

        // Only the blocks the function came with start a split; a copy
        // holds no scope test.
        var changed = false
        var n       = self._blocks.size()
        for var t: usize = 0; t < n; ++t {
            if self._split_at(f, t) {
                changed = true
            }
        }

        if changed && llvm::verifyFunction(*f, &null) {
            kairo::std::ice_fail(
                r"alloc-split left a function the verifier rejects",
            )
        }

        return changed
    }

    /// Records `f`'s loads of scope_top (`g`) and its stores to it. False
    /// when it has fewer than two loads, so no test to thread, or uses the
    /// variable's address for anything but a load or a store.
    priv fn _find_uses(self, g: unsafe *llvm::GlobalVariable, f: unsafe *llvm::Function) -> bool {
        var gv: unsafe *llvm::Value = g
        if !g->isThreadLocal() {
            // A target with no threads: the variable is used as it is.
            for u in g->users() {
                var unsafe *ui = llvm::dyn_cast<llvm::Instruction>(u)
                if ui == &null {
                    return false
                }

                if ui->getFunction() != f {
                    continue
                }

                if !self._record_use(ui, gv) {
                    return false
                }
            }
        }

        for var bi = f->begin(); bi != f->end(); ++bi {
            var unsafe *bb                           = unsafe &*bi
            var        i:  unsafe *llvm::Instruction = unsafe &bb->front()
            while i != &null {
                var unsafe *ta = llvm::dyn_cast<llvm::IntrinsicInst>(i)
                if ta != &null
                    && ta->getIntrinsicID() == (llvm::Intrinsic::threadlocal_address as u32)
                    && ta->getArgOperand(0) == gv {
                    var tav: unsafe *llvm::Value = ta
                    for u in ta->users() {
                        var unsafe *ui = llvm::dyn_cast<llvm::Instruction>(u)
                        if ui == &null || !self._record_use(ui, tav) {
                            return false
                        }
                    }
                }

                i = i->getNextNode()
            }
        }

        return self._nloads >= 2
    }

    /// Records `ui`, a user of scope_top's address `addr`, when it loads
    /// from it or stores to it; false for any other use.
    priv fn _record_use(self, ui: unsafe *llvm::Instruction, addr: unsafe *llvm::Value) -> bool {
        var unsafe *ld = llvm::dyn_cast<llvm::LoadInst>(ui)
        if ld != &null {
            self._loads[(ui as usize) as u64] = 1
            self._nloads += 1
            return true
        }

        var unsafe *st = llvm::dyn_cast<llvm::StoreInst>(ui)
        if st != &null && st->getValueOperand() != addr {
            self._stores[(ui as usize) as u64] = 1
            return true
        }

        return false
    }

    /// Whether `i` may leave the scope stack other than it found it.
    priv fn _changes_stack(self, i: unsafe *llvm::Instruction) -> bool {
        if self._stores.lookup((i as usize) as u64) != 0 {
            return true
        }

        var unsafe *cb = llvm::dyn_cast<llvm::CallBase>(i)
        if cb == &null {
            return false
        }

        if cb->isInlineAsm() {
            return true
        }

        return !(self._heap_call(cb)
            || cb->doesNotReturn()
            || cb->doesNotAccessMemory()
            || cb->onlyReadsMemory()
            || cb->onlyAccessesArgMemory()
            || cb->onlyAccessesInaccessibleMemory()
            || cb->onlyAccessesInaccessibleMemOrArgMem())
    }

    /// Whether `cb` calls one of the heap's entry points: a call AllocModel
    /// annotated, in either of its allocation families.
    priv fn _heap_call(self, cb: unsafe *llvm::CallBase) -> bool {
        var family = cb->getFnAttr(kairo::sref(r"alloc-family"))
        if !family.isValid() {
            return false
        }

        var name = family.getValueAsString()
        return name == kairo::sref(r"kairo") || name == kairo::sref(r"kairo_global")
    }

    /// Fills _blocks and _index from `f`.
    priv fn _scan(self, f: unsafe *llvm::Function) {
        for var bi = f->begin(); bi != f->end(); ++bi {
            var unsafe *bb = unsafe &*bi
            var        b   = SplitBlock { bb: bb }
            b.copyable = !bb->isEHPad() && !bb->hasAddressTaken()

            // The loads since the last thing that may change the stack.
            var fresh: [unsafe *llvm::Instruction]
            var i:     unsafe *llvm::Instruction   = unsafe &bb->front()
            while i != &null {
                b.count += 1
                if i->getType()->isTokenTy() {
                    b.copyable = false
                }

                if self._loads.lookup((i as usize) as u64) != 0 {
                    fresh.push(i)
                    if !b.changes {
                        b.loads.push(i)
                    }
                } else if self._changes_stack(i) {
                    b.changes = true
                    fresh.clear()
                }

                var unsafe *cb = llvm::dyn_cast<llvm::CallBase>(i)
                if cb != &null && self._heap_call(cb) && !cb->getType()->isVoidTy() {
                    b.allocates = true
                }

                i = i->getNextNode()
            }

            var unsafe *term = bb->getTerminator()
            var unsafe *br   = llvm::dyn_cast<llvm::BranchInst>(term)
            if br == &null {
                if !llvm::isa<llvm::SwitchInst>(term)
                    && !llvm::isa<llvm::ReturnInst>(term)
                    && !llvm::isa<llvm::UnreachableInst>(term) {
                    b.copyable = false
                }
            } else if br->isConditional() {
                var unsafe *cmp = llvm::dyn_cast<llvm::ICmpInst>(
                    br->getCondition(),
                )

                if cmp != &null && cmp->isEquality() {
                    var unsafe *lhs = cmp->getOperand(0)
                    var unsafe *rhs = cmp->getOperand(1)
                    if llvm::isa<llvm::ConstantPointerNull>(lhs) {
                        var unsafe *swap = lhs
                        lhs = rhs
                        rhs = swap
                    }

                    if llvm::isa<llvm::ConstantPointerNull>(rhs)
                        && self._loads.lookup((lhs as usize) as u64) != 0 {
                        b.test_load = llvm::cast<llvm::Instruction>(lhs)
                        b.null_succ = if cmp->getPredicate() == llvm::CmpInst::ICMP_EQ => 0u32
                                      else => 1u32
                        for *l in fresh {
                            if *l == b.test_load {
                                b.test_live = true
                            }
                        }
                    }
                }
            }

            self._index[(bb as usize) as u64] = (self._blocks.size() + 1) as u32
            self._blocks.push(b)
        }
    }

    /// The index in _blocks of block `b`'s successor `s`, or _blocks.size()
    /// when it is a block a split made.
    priv fn _succ(self, b: usize, s: usize) -> usize {
        var unsafe *sb = self._blocks[b].bb->getTerminator()->getSuccessor(
            s as u32,
        )

        var at = self._index.lookup((sb as usize) as u64)
        if at == 0 {
            return self._blocks.size()
        }

        return (at - 1) as usize
    }

    priv fn _succ_count(self, b: usize) -> usize {
        return self._blocks[b].bb->getTerminator()->getNumSuccessors() as usize
    }

    /// Splits the no-scope edge of block `t`'s scope test, when the test is
    /// one and the path from that edge qualifies (see the header).
    priv fn _split_at(self, f: unsafe *llvm::Function, t: usize) -> bool {
        if self._blocks[t].test_load == &null
            || !self._blocks[t].test_live
            || self._blocks[t].test_load->hasMetadata(self._mark) {
            return false
        }

        var        n      = self._blocks.size()
        var unsafe *t_bb  = self._blocks[t].bb
        var unsafe *tterm = t_bb->getTerminator()
        var        nsucc  = self._blocks[t].null_succ
        var        a      = self._succ(t, nsucc as usize)
        if a == n
            || a == t
            || self._succ(t, (1 - nsucc) as usize) == a
            || !self._blocks[a].copyable {
            return false
        }

        // Every block the no-scope edge reaches with the stack still empty
        // on entry: through blocks that cannot change it, never back
        // through the test.
        var reached: [bool]
        var keep:    [bool]
        var indeg:   [u32]
        for var i: usize = 0; i < n; ++i {
            reached.push(false)
            keep.push(false)
            indeg.push(0)
        }

        var order: [usize]
        reached[a] = true
        order.push(a)
        for var head: usize = 0; head < order.size(); ++head {
            if order.size() > kAllocSplitMaxBlocks {
                return false
            }

            var b = order[head]
            if self._blocks[b].changes {
                continue
            }

            for var s: usize = 0; s < self._succ_count(b); ++s {
                var to = self._succ(b, s)
                if to == n || to == t || reached[to] || !self._blocks[to].copyable {
                    continue
                }

                reached[to] = true
                order.push(to)
            }
        }

        // Worth copying: a block with a load that is null on this path, and
        // the no-scope arm of a test of such a load, which holds the free.
        var threaded: llvm::DenseMap<u64, u32>
        var targets:  usize                    = 0
        for *b in order {
            for *l in self._blocks[*b].loads {
                threaded[((*l) as usize) as u64] = 1
                targets += 1
            }

            if self._blocks[*b].loads.size() != 0 {
                keep[*b] = true
            }
        }

        if targets == 0 {
            return false
        }

        for *b in order {
            var unsafe *tested = self._blocks[*b].test_load
            if tested == &null
                || self._blocks[*b].changes
                || threaded.lookup((tested as usize) as u64) == 0 {
                continue
            }

            var arm = self._succ(*b, self._blocks[*b].null_succ as usize)
            if arm != n && reached[arm] {
                keep[arm] = true
            }
        }

        // And every block on the way to one.
        var grew = true
        while grew {
            grew = false
            for *b in order {
                if keep[*b] || self._blocks[*b].changes {
                    continue
                }

                for var s: usize = 0; s < self._succ_count(*b); ++s {
                    var to = self._succ(*b, s)
                    if to != n && keep[to] {
                        keep[*b] = true
                        grew     = true
                        break
                    }
                }
            }
        }

        if !keep[a] {
            return false
        }

        var kept:     [usize]
        var count:    u32     = 0
        var allocates         = false
        for *b in order {
            if !keep[*b] {
                continue
            }

            kept.push(*b)
            count += self._blocks[*b].count
            if self._blocks[*b].allocates {
                allocates = true
            }
        }

        if !allocates || count > kAllocSplitMaxInstrs || count > self._budget {
            return false
        }

        // No loop among the kept blocks: each is copied once, and a loop
        // would be copied whole.
        for *b in kept {
            if self._blocks[*b].changes {
                continue
            }

            for var s: usize = 0; s < self._succ_count(*b); ++s {
                var to = self._succ(*b, s)
                if to != n && keep[to] {
                    indeg[to] += 1
                }
            }
        }

        var ready: [usize]
        for *b in kept {
            if indeg[*b] == 0 {
                ready.push(*b)
            }
        }

        for var head: usize = 0; head < ready.size(); ++head {
            var b = ready[head]
            if self._blocks[b].changes {
                continue
            }

            for var s: usize = 0; s < self._succ_count(b); ++s {
                var to = self._succ(b, s)
                if to != n && keep[to] {
                    indeg[to] -= 1
                    if indeg[to] == 0 {
                        ready.push(to)
                    }
                }
            }
        }

        if ready.size() != kept.size() {
            return false
        }

        self._budget -= count

        // Copy the kept blocks. Each instruction and its copy sit at the
        // same place in their blocks, so the two are paired by position.
        var vmap:   llvm::ValueToValueMapTy
        var copies: llvm::SmallVector<unsafe *llvm::BasicBlock, 8>
        var dup_of: [unsafe *llvm::BasicBlock]
        var orig:   [unsafe *llvm::Instruction]
        var dup:    [unsafe *llvm::Value]
        var owner:  [usize]
        var pair:   llvm::DenseMap<u64, u32>
        for var i: usize = 0; i < n; ++i {
            dup_of.push(&null)
        }

        for *b in kept {
            var unsafe *bb = self._blocks[*b].bb
            var unsafe *nb = llvm::CloneBasicBlock(
                bb,
                &vmap,
                llvm::Twine(kairo::sref(r".g")),
                f,
                &null,
                true,
            )

            dup_of[*b] = nb
            copies.push_back(nb)
            var i: unsafe *llvm::Instruction = unsafe &bb->front()
            var j: unsafe *llvm::Instruction = unsafe &nb->front()
            while i != &null {
                var jv: unsafe *llvm::Value = j
                orig.push(i)
                dup.push(jv)
                owner.push(*b)
                pair[(i as usize) as u64] = orig.size() as u32

                i = i->getNextNode()
                j = j->getNextNode()
            }
        }

        llvm::remapInstructionsInBlocks(
            llvm::ArrayRef<unsafe *llvm::BasicBlock>(copies),
            &vmap,
        )

        // On the copy the stack is empty: each load the path reaches
        // unchanged is null.
        for var k: usize = 0; k < orig.size(); ++k {
            if threaded.lookup((orig[k] as usize) as u64) == 0 {
                continue
            }

            var unsafe *ld = llvm::cast<llvm::Instruction>(dup[k])
            var unsafe *nil = llvm::Constant::getNullValue(ld->getType())
            var nilv: unsafe *llvm::Value = nil
            ld->replaceAllUsesWith(nilv)
            ld->eraseFromParent()
            dup[k] = nilv
        }

        // An edge between two kept blocks stays inside the copy, unless
        // its source may change the stack: then the copy ends there and
        // the edge returns to the original.
        for *b in kept {
            var unsafe *nb = dup_of[*b]
            if !self._blocks[*b].changes {
                var unsafe *nterm = nb->getTerminator()
                for var s: usize = 0; s < self._succ_count(*b); ++s {
                    var to = self._succ(*b, s)
                    if to != n && keep[to] {
                        nterm->setSuccessor(s as u32, dup_of[to])
                    }
                }
            }
        }

        // A copy's phi keeps the entries of the edges that reach the copy:
        // the kept, unchanging predecessors' copies and, for the first
        // block, the test.
        for *b in kept {
            var i: unsafe *llvm::Instruction = unsafe &dup_of[*b]->front()
            while i != &null {
                var unsafe *phi = llvm::dyn_cast<llvm::PHINode>(i)
                if phi == &null {
                    break
                }

                i = i->getNextNode()
                var at = phi->getNumIncomingValues() as usize
                while at > 0 {
                    at -= 1
                    var unsafe *from = phi->getIncomingBlock(at as u32)
                    if from == t_bb {
                        if *b != a {
                            phi->removeIncomingValue(at as u32, false)
                        }

                        continue
                    }

                    var fi = self._index.lookup((from as usize) as u64)
                    if fi != 0
                        && keep[(fi - 1) as usize]
                        && !self._blocks[(fi - 1) as usize].changes {
                        phi->setIncomingBlock(
                            at as u32,
                            dup_of[(fi - 1) as usize],
                        )
                    } else {
                        phi->removeIncomingValue(at as u32, false)
                    }
                }
            }
        }

        // An edge that leaves the copy is a new edge into an original
        // block, whose phis take the copy's value of what the original
        // edge carries.
        for *b in kept {
            var unsafe *bb = self._blocks[*b].bb
            var unsafe *nb = dup_of[*b]
            for var s: usize = 0; s < self._succ_count(*b); ++s {
                var to = self._succ(*b, s)
                if to != n && keep[to] && !self._blocks[*b].changes {
                    continue
                }

                var unsafe *out = bb->getTerminator()->getSuccessor(s as u32)
                var i: unsafe *llvm::Instruction = unsafe &out->front()
                while i != &null {
                    var unsafe *phi = llvm::dyn_cast<llvm::PHINode>(i)
                    if phi == &null {
                        break
                    }

                    var unsafe *v = phi->getIncomingValueForBlock(bb)
                    var        at = pair.lookup((v as usize) as u64)
                    if at != 0 {
                        v = dup[(at - 1) as usize]
                    }

                    phi->addIncoming(v, nb)
                    i = i->getNextNode()
                }
            }
        }

        // The no-scope edge enters the copy.
        tterm->setSuccessor(nsucc, dup_of[a])
        self._blocks[a].bb->removePredecessor(t_bb, true)

        // A value defined in a kept block has two definitions, and a use
        // outside its block may be reached by either.
        for var k: usize = 0; k < orig.size(); ++k {
            var unsafe *def = orig[k]
            if def->getType()->isVoidTy() {
                continue
            }

            var unsafe *bb = self._blocks[owner[k]].bb
            var unsafe *nb = dup_of[owner[k]]
            self._uses.clear()
            self._outside_uses(def, bb)
            var unsafe *twin = llvm::dyn_cast<llvm::Instruction>(dup[k])
            if twin != &null {
                self._outside_uses(twin, nb)
            }

            if self._uses.empty() {
                continue
            }

            var defv: unsafe *llvm::Value = def
            var up                        = llvm::SSAUpdater(&null)

            up.Initialize(def->getType(), def->getName())
            up.AddAvailableValue(bb, defv)
            up.AddAvailableValue(nb, dup[k])
            for var u: usize = 0; u < self._uses.size(); ++u {
                up.RewriteUse(&*self._uses[u])
            }
        }

        // The original loads were copied for; none starts a split of its
        // own, which would copy the same tail again.
        var unsafe *done = llvm::MDNode::get(
            &f->getContext(),
            llvm::ArrayRef<unsafe *llvm::Metadata>(),
        )

        for *b in kept {
            for *l in self._blocks[*b].loads {
                (*l)->setMetadata(self._mark, done)
            }
        }

        return true
    }

    /// Adds to _uses the uses of `def` that its block `bb` does not hold: a
    /// use by an instruction of another block, or by a phi for an edge
    /// from another block.
    priv fn _outside_uses(self, def: unsafe *llvm::Instruction, bb: unsafe *llvm::BasicBlock) {
        for *u in def->uses() {
            var unsafe *user = llvm::cast<llvm::Instruction>(u->getUser())
            var unsafe *phi  = llvm::dyn_cast<llvm::PHINode>(user)
            if phi != &null {
                if phi->getIncomingBlock(u->getOperandNo()) == bb {
                    continue
                }
            } else if user->getParent() == bb {
                continue
            }

            self._uses.push_back(unsafe (u as unsafe *llvm::Use))
        }
    }
}
