/// --- The Kairo Project ------------------------- Native/KPlacement.hh --- ///
///
///   Construct-in-place and destroy-in-place for arena allocations.
///
///   WHY C++: the arenas hand out raw storage and the object has to be
///   constructed into it (placement new) and, for the cleanup lists, later
///   destroyed without freeing (an explicit destructor call). Kairo has no
///   spelling for either. These used to be inline C++ blocks spliced
///   into ASTContext, ArenaAllocator, ArenaList, TupleRecords and
///   InstantiationRegistry; Stage 1 does not emit inline foreign blocks, so
///   the C++ lives here and those classes call it.
///
///   Both are templates, so every TU that includes this sees the same
///   definition and there is nothing to collide at link time.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __KAIRO_NATIVE_KPLACEMENT_HH__
#define __KAIRO_NATIVE_KPLACEMENT_HH__

#include <new>
#include <utility>

namespace kairo {

/// `::new (mem) T(args...)`. \p mem must be suitably sized and aligned for
/// T; the arenas' alloc(sizeof(T), alignof(T)) is. Arguments are forwarded
/// as given, so an lvalue argument copy-constructs and an rvalue moves.
template <typename T, typename... Args>
inline T *construct_at(void *mem, Args &&...args) {
    return ::new (mem) T(::std::forward<Args>(args)...);
}

/// Runs T's destructor on the object at \p obj and leaves the storage alone
/// (the arena owns it). Shaped `void(void*)` so the cleanup lists can hold
/// one per allocated type: `c.run = kairo::destroy_in_place::<T>;`.
template <typename T>
inline void destroy_in_place(void *obj) {
    static_cast<T *>(obj)->~T();
}

}  // namespace kairo

#endif  // __KAIRO_NATIVE_KPLACEMENT_HH__
