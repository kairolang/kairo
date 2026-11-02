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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub import builtin::base::alloc::{
    Allocator, Resizer, Reallocator, ZeroAllocator, ScopedAllocator,
    FullAllocator, ScopedFullAllocator,
    Uninitialized, UninitializedSlice, uninitialized_from,
    AllocatorScope, Global, System,
    create, try_create, destroy, create_slice, destroy_slice,
    alloc_raw, free_raw, resize_raw,
    create_in, try_create_in, destroy_in, create_slice_in, destroy_slice_in,
    alloc_in, release_in, alloc_bytes, free_bytes, alloc_zeroed,
    resize_bytes, try_resize_in_place, realloc_by_copy,
    set_oom_handler, oom,
}
