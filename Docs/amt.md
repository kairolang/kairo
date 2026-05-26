# AMT (Automatic Memory Tracking)

> [!IMPORTANT]
> This page is under development. AMT is Kairo's core memory safety mechanism and its documentation
> will be comprehensive once the implementation is finalized.

AMT is a compile-time analysis pass that tracks pointer lifetimes, determines ownership, and
automatically promotes pointers to the appropriate smart pointer type. It provides memory safety
without requiring lifetime annotations from the programmer.

Key concepts that will be covered on this page:

- Full-program analysis model how AMT tracks pointer provenance across function boundaries
- Smart pointer promotion when and how `*T` is promoted to `std::Unique<*T>`, `std::Shared<*T>`,
  or `std::Weak<*T>`
- Compile errors vs automatic fixes when AMT can resolve an issue silently and when it must
  reject the program
- Allocator integration `std::create<T>()`, `std::alloc<T>()`, custom allocators, and how AMT
  interacts with allocation strategies
- `fn op delete` and automatic destructor insertion
- Cross-translation-unit analysis via `.ksummary` artifacts
- Interaction with [unsafe blocks](/docs/language/unsafe) how `unsafe { }` suspends AMT and how
  `forget!()` drops pointers from tracking
- Interaction with [C/C++ interop](/docs/language/c-c++) smart pointer mapping between Kairo's
  AMT types and C++ `std::unique_ptr`, `std::shared_ptr`, `std::weak_ptr`

See [Pointers](/docs/language/pointers) for pointer types and
[Ownership](/docs/language/ownership) for the ownership model that AMT enforces.

`fn op delete (self)` defines custom destruction. If not defined, compiler generates `fn op delete (self) = default`. If any member has a deleted destructor, the whole object requires `unsafe` to use.

Allocator system:

```kairo
class MyAllocator impl std::Allocator {
    fn allocate(self, size: usize) -> *u8
    fn deallocate(self, ptr: *u8, size: usize)
}

@set_allocator(MyAllocator)
```

`std::create<T>` uses the active allocator. Everything in std that allocates goes through it. `delete x[0]` calls `T`'s `op delete` first, then the allocator's deallocation. Considering future granularity: `@set_allocator_for(T, MyAllocator)`, `@set_collection_allocator(MyAllocator)`, etc. undecided.

- `fn op delete (self)` custom destruction, `= default`, `= delete` behavior
- `std::Allocator` interface with `allocate`/`deallocate`
- `@set_allocator(MyAllocator)` global allocator override
- `delete x[0]` explicit deletion calling `T`'s `op delete` then allocator's dealloc
- `std::create<T>` uses the active allocator
- Future granularity: `@set_allocator_for(T, ...)`, `@set_collection_allocator(...)` undecided
