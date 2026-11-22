/// --- The Kairo Project -------------------------------- Lib/std/mem.k --- ///
///
///   Heap allocation, re-exported from Lib/builtin/base/alloc.k so user code
///   writes std::create<T>(...) and std::destroy(p). The non-_in functions use
///   the allocator in effect (the innermost open AllocatorScope on this
///   thread, else Global); the *_in<.., A> functions name A explicitly.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// Heap allocation API, re-exported from `builtin::base::alloc` so user code can write
/// `std::create<T>(...)` and `std::destroy(p)`.
///
/// The functions without an `_in` suffix use the allocator in effect: the innermost open
/// `AllocatorScope` on this thread, otherwise `Global`. The `*_in<.., A>` functions name the
/// allocator `A` explicitly. Each re-exported item is documented in the core library reference.
pub import builtin::base::alloc::{
    Allocator,
    AllocatorScope,
    FullAllocator,
    Global,
    Reallocator,
    Resizer,
    ScopedAllocator,
    ScopedFullAllocator,
    System,
    Uninitialized,
    UninitializedSlice,
    ZeroAllocator,
    alloc_bytes,
    alloc_in,
    alloc_raw,
    alloc_zeroed,
    create,
    create_in,
    create_slice,
    create_slice_in,
    destroy,
    destroy_in,
    destroy_slice,
    destroy_slice_in,
    free_bytes,
    free_raw,
    oom,
    realloc_by_copy,
    release_in,
    resize_bytes,
    resize_in_place,
    resize_raw,
    set_oom_handler,
    try_create,
    try_create_in,
    try_resize_in_place,
    uninitialized_from,
}
