/// --- The Kairo Project ------------------- Optimize/LLVM/AllocModel.k --- ///
///
///   Tells LLVM which functions allocate and free blocks of the runtime's
///   heap, so the optimiser treats them as it treats malloc and free: a
///   block that is only written and then freed is removed with its
///   allocation and its free, a load from a block never written folds to
///   undef (or to zero for a zeroed one), and a store into a block that is
///   freed next is dead. From the calls alone LLVM sees external functions
///   that may do anything.
///
///   What is annotated: the runtime heap's own entry points, which System
///   (Lib/builtin/alloc_raw.k), and Global where it is System, reach through
///   the inline helpers of Lib/rt/alloc.h. Their blocks are the process
///   heap's, each one freeable by itself. They are one allocation family,
///   "kairo", which no other function's blocks pair with, so LLVM removes a
///   block only with a Kairo free. The frees are not interchangeable: they
///   are sized, and Lib/rt/alloc.h picks the free from the size (a small
///   page, a large mapping, mimalloc), so only the free the block's own size
///   selects may take it. The family is safe because no annotation lets
///   LLVM put one free in place of another:
///
///       mi_malloc_small mi_malloc        alloc, uninitialized   allocsize(0)
///       mi_zalloc_small mi_zalloc        alloc, zeroed          allocsize(0)
///       mi_malloc_aligned                alloc, uninitialized   allocsize(0) allocalign(1)
///       mi_zalloc_aligned                alloc, zeroed          allocsize(0) allocalign(1)
///       kairo_rt_heap_large_alloc        alloc                  allocsize(0) allocalign(1)
///         (uninitialized or zeroed at a call whose third argument is the
///         constant 0 or 1)
///       mi_free mi_free_small_nonnull kairo_rt_heap_large_free
///                                        free                   allocptr(0)
///
///   and every allocation returns noalias. A null return is the only
///   failure (alloc.k's contract), as for malloc. Above -O0 an allocation
///   whose block nothing observes is removed, and with it the chance that
///   it fails: its null test folds to "not null".
///
///   What is left alone, and why:
///     - alloc_raw / free_raw / resize_raw, the container family and
///       everything built on them (`@create`, `@destroy`, the containers):
///       they choose the allocator at run time, from the thread's scope
///       stack, so a block may be an arena's. Their Global arm reaches the
///       entry points above, which are annotated there, but the block LLVM
///       sees is the merge of that arm and the scope's, and the free tests
///       the stack again, so nothing is removed through them.
///     - The scope frames' functions, called through a pointer: arena,
///       `@set_scoped_allocator` and user allocators, whose blocks may be
///       freed in bulk, never one by one.
///     - kairo_global_*: under `@set_global_allocator(A)` they are A's,
///       chosen when the program links, and A's allocations may be counted
///       or logged.
///     - kairo_rt_heap_resize: it resizes in place; LLVM has no kind for
///       that.
///     - kairo_rt_heap_realloc and System::realloc. As a realloc kind, LLVM
///       rewrites free(realloc(p)) into free(p), keeping the free's size;
///       a realloc across a size class then hands the block to the wrong
///       free (a mapped block to the small-page free).
///
///   Where: at the start of the pipeline, before the inliner. The entry
///   points are external functions, never inlined, so the inliner copies
///   calls to them out of the inline helpers into each caller, and the
///   declaration's attributes hold at every copy. Each call is annotated as
///   well: a call keeps its own attributes when a link-time optimisation
///   replaces the declaration with a definition that carries none.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/IR/Attributes.h"
ffi "c++" import "llvm/IR/Constants.h"
ffi "c++" import "llvm/IR/DerivedTypes.h"
ffi "c++" import "llvm/IR/Function.h"
ffi "c++" import "llvm/IR/InstrTypes.h"
ffi "c++" import "llvm/IR/LLVMContext.h"
ffi "c++" import "llvm/IR/Module.h"
ffi "c++" import "optional"
ffi "c++" import "Native/Types.hh"

import Optimize::KairoPass::{
    KairoPass,
    PassPoint,
}

/// One heap entry point: its name, its shape, and the allocation facts.
/// `shape` is the return type then the parameters: `p` a pointer, `i` an
/// integer, `v` no value (`p:ii` is a pointer from two integers); a
/// declaration of another shape is not this function. The
/// indices are parameter numbers, -1 for none.
struct HeapEntry {
    var name:  string
    var shape: string
    var kind:  u64    = 0
    var size:  i32    = -1 ///< allocsize: the byte count
    var align: i32    = -1 ///< allocalign: the alignment
    var freed: i32    = -1 ///< allocptr: the block freed
    var zero:  i32    = -1 ///< 0 or 1 here makes a call uninitialized or zeroed
}

fn alloc_kind(k: llvm::AllocFnKind) -> u64 {
    return k as u64
}

/// The entry points, as the table in the header lists them.
fn heap_entries() -> [HeapEntry] {
    var alloc   = alloc_kind(llvm::AllocFnKind::Alloc)
    var uninit  = alloc_kind(llvm::AllocFnKind::Uninitialized)
    var zeroed  = alloc_kind(llvm::AllocFnKind::Zeroed)
    var aligned = alloc_kind(llvm::AllocFnKind::Aligned)
    var free    = alloc_kind(llvm::AllocFnKind::Free)
    return [
        HeapEntry { name: "mi_malloc_small", shape: "p:i", kind: alloc | uninit, size: 0 },
        HeapEntry { name: "mi_malloc", shape: "p:i", kind: alloc | uninit, size: 0 },
        HeapEntry { name: "mi_zalloc_small", shape: "p:i", kind: alloc | zeroed, size: 0 },
        HeapEntry { name: "mi_zalloc", shape: "p:i", kind: alloc | zeroed, size: 0 },
        HeapEntry {
            name:  "mi_malloc_aligned",
            shape: "p:ii",
            kind:  alloc | uninit | aligned,
            size:  0,
            align: 1,
        },
        HeapEntry {
            name:  "mi_zalloc_aligned",
            shape: "p:ii",
            kind:  alloc | zeroed | aligned,
            size:  0,
            align: 1,
        },
        HeapEntry {
            name:  "kairo_rt_heap_large_alloc",
            shape: "p:iii",
            kind:  alloc | aligned,
            size:  0,
            align: 1,
            zero:  2,
        },
        HeapEntry { name: "mi_free", shape: "v:p", kind: free, freed: 0 },
        HeapEntry { name: "mi_free_small_nonnull", shape: "v:p", kind: free, freed: 0 },
        HeapEntry { name: "kairo_rt_heap_large_free", shape: "v:pi", kind: free, freed: 0 },
    ]
}

/// `t` as a shape letter: p, i, v, or ? for anything else.
fn shape_letter(t: unsafe *llvm::Type) -> u8 {
    if t->isPointerTy() {
        return 'p' as u8
    }

    if t->isIntegerTy() {
        return 'i' as u8
    }

    if t->isVoidTy() {
        return 'v' as u8
    }

    return '?' as u8
}

/// Whether `f`'s type is `shape`.
fn has_shape(f: unsafe *llvm::Function, const shape: string) -> bool {
    var unsafe *ft = f->getFunctionType()
    var        n   = ft->getNumParams() as usize
    if shape.size() != n + 2 || shape.data()[1] != (':' as u8) {
        return false
    }

    if shape_letter(ft->getReturnType()) != shape.data()[0] {
        return false
    }

    for var i: usize = 0; i < n; ++i {
        if shape_letter(ft->getParamType(i as u32)) != shape.data()[i + 2] {
            return false
        }
    }

    return true
}

/// The pass. One instance per module run (Optimize/PassRegistry.k).
pub class AllocModel impl KairoPass {
    pub fn AllocModel(self) { }

    pub static fn pass_name() -> string {
        return "alloc-model"
    }

    /// Before the inliner: see the header.
    pub static fn pass_point() -> PassPoint {
        return PassPoint::PipelineStart
    }

    /// Above -O0, at every size level: removing a block is smaller too.
    pub static fn enabled(opt_level: i32, size_level: i32) -> bool {
        return opt_level > 0
    }

    /// Annotates every entry point `m` declares, and every call of one;
    /// true when it declares any.
    pub fn run(self, m: unsafe *llvm::Module, f: unsafe *llvm::Function) -> bool {
        var changed = false
        var entries = heap_entries()
        for *e in entries {
            var unsafe *fn_ = m->getFunction(kairo::sref((*e).name))
            if fn_ != &null && self._annotate(m, fn_, *e) {
                changed = true
            }
        }

        return changed
    }

    /// Annotates `fn_` and its calls as `e` says, when it is a declaration
    /// of `e`'s shape. A definition is left alone: this module then holds
    /// the allocator itself, not a call into the runtime's.
    priv fn _annotate(self,
                      m:       unsafe *llvm::Module,
                      fn_:     unsafe *llvm::Function,
                      const e: HeapEntry) -> bool {
        if !fn_->isDeclaration() || !has_shape(fn_, e.shape) {
            return false
        }

        var *ctx = &m->getContext()
        fn_->addFnAttr(
            llvm::Attribute::get(&*ctx, llvm::Attribute::AllocKind, e.kind),
        )

        var family = llvm::Attribute::get(
            &*ctx,
            kairo::sref(r"alloc-family"),
            kairo::sref(r"kairo"),
        )

        fn_->addFnAttr(family)
        if e.size >= 0 {
            fn_->addFnAttr(
                llvm::Attribute::getWithAllocSizeArgs(
                    &*ctx,
                    e.size as u32,
                    cxx::std::optional<u32>(cxx::std::nullopt),
                ),
            )
        }

        var returns_block = (e.kind & alloc_kind(llvm::AllocFnKind::Free)) == 0
        if returns_block {
            fn_->addRetAttr(llvm::Attribute::NoAlias)
        }

        if e.align >= 0 {
            fn_->addParamAttr(e.align as u32, llvm::Attribute::AllocAlign)
        }

        if e.freed >= 0 {
            fn_->addParamAttr(e.freed as u32, llvm::Attribute::AllocatedPointer)
        }

        for u in fn_->users() {
            var unsafe *cb = llvm::dyn_cast<llvm::CallBase>(u)
            if cb == &null || cb->getCalledFunction() != fn_ {
                continue
            }

            cb->addFnAttr(
                llvm::Attribute::get(
                    &*ctx,
                    llvm::Attribute::AllocKind,
                    self._call_kind(cb, e),
                ),
            )

            cb->addFnAttr(family)
            if e.size >= 0 {
                cb->addFnAttr(
                    llvm::Attribute::getWithAllocSizeArgs(
                        &*ctx,
                        e.size as u32,
                        cxx::std::optional<u32>(cxx::std::nullopt),
                    ),
                )
            }

            if returns_block {
                cb->addRetAttr(llvm::Attribute::NoAlias)
            }

            if e.align >= 0 {
                cb->addParamAttr(e.align as u32, llvm::Attribute::AllocAlign)
            }

            if e.freed >= 0 {
                cb->addParamAttr(
                    e.freed as u32,
                    llvm::Attribute::AllocatedPointer,
                )
            }
        }

        return true
    }

    /// `e`'s kind at `cb`: for the large allocation, uninitialized or zeroed
    /// when its flag is a constant 0 or 1.
    priv fn _call_kind(self, cb: unsafe *llvm::CallBase, const e: HeapEntry) -> u64 {
        if e.zero < 0 {
            return e.kind
        }

        var unsafe *flag = llvm::dyn_cast<llvm::ConstantInt>(
            cb->getArgOperand(e.zero as u32),
        )

        if flag == &null {
            return e.kind
        }

        if flag->isZero() {
            return e.kind | alloc_kind(llvm::AllocFnKind::Uninitialized)
        }

        if flag->isOne() {
            return e.kind | alloc_kind(llvm::AllocFnKind::Zeroed)
        }

        return e.kind
    }
}
