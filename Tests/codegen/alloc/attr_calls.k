// Each allocation attribute lowers to a call of the alloc.k function it stands
// for: the generic `create` / `try_create` / `alloc_storage` / `create_slice`
// family, the raw byte functions of alloc_raw.k, and, with `in: A`, the
// `_in` / `_with` / `_bytes` variants parameterised by the allocator type.
// The checks follow the uses in source order inside one function.

class A {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return &null }
}

class Box {
    pub var v: i32
    pub fn Box(self, v: i32) { self.v = v }
    @move fn Box(self, other: Self) = default
}

fn forms(p: *Box, q: unsafe *u8) {
    var *a = @create Box(1)
    var *b = @create(in: A) Box(2)
    var *c = try @try_create Box(3) catch e: AllocError => p
    var *d = try @try_create(in: A) Box(4) catch e: AllocError => p
    @destroy a
    @destroy(in: A) b
    var e? = @alloc Box
    var f? = @alloc(in: A) Box
    var g? = @alloc(count: 2) Box
    var h? = @alloc(count: 2, in: A) Box
    var unsafe *i = @alloc(size: 8, align: 8)
    var unsafe *j = @alloc(size: 8, align: 8, in: A)
    var unsafe *k = @alloc_zeroed(size: 8, align: 8)
    var unsafe *l = @alloc_zeroed(size: 8, align: 8, in: A)
    @free p
    @free(in: A) p
    @free(size: 8, align: 8) q
    @free(size: 8, align: 8, in: A) q
    var unsafe *m = @resize(size: 8, new_size: 16, align: 8) q
    var unsafe *n = @resize(size: 8, new_size: 16, align: 8, in: A) q
    var o = @resize_in_place(size: 8, new_size: 16, align: 8) q
    var r = @resize_in_place(size: 8, new_size: 16, align: 8, in: A) q
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: void forms({{.*}}) noexcept {
// IR-NEXT: = ::builtin::base::alloc::create<{{.*}}Box, signed int>(1);
// IR-NEXT: = ::builtin::base::alloc::create_in<{{.*}}Box, {{.*}}::A, signed int>(2);
// IR-NEXT: = ::builtin::base::alloc::try_create<{{.*}}Box, signed int>(3);
// IR-NEXT: = ::builtin::base::alloc::try_create_in<{{.*}}Box, {{.*}}::A, signed int>(4);
// IR-NEXT: ::builtin::base::alloc::destroy<{{.*}}Box>(a);
// IR-NEXT: ::builtin::base::alloc::destroy_with<{{.*}}::A, {{.*}}Box>(b);
// IR-NEXT: = ::builtin::base::alloc::alloc_storage<{{.*}}Box>();
// IR-NEXT: = ::builtin::base::alloc::alloc_in<{{.*}}Box, {{.*}}::A>();
// IR-NEXT: = ::builtin::base::alloc::create_slice<{{.*}}Box>(2);
// IR-NEXT: = ::builtin::base::alloc::create_slice_in<{{.*}}Box, {{.*}}::A>(2);
// IR-NEXT: = ::builtin::alloc_raw::alloc_raw(8, 8);
// IR-NEXT: = ::builtin::base::alloc::alloc_bytes<{{.*}}::A>(8, 8);
// IR-NEXT: = ::builtin::base::alloc::alloc_raw_zeroed(8, 8);
// IR-NEXT: = ::builtin::base::alloc::alloc_zeroed<{{.*}}::A>(8, 8);
// IR-NEXT: ::builtin::base::alloc::free_storage<{{.*}}Box>(p);
// IR-NEXT: ::builtin::base::alloc::free_storage_with<{{.*}}::A, {{.*}}Box>(p);
// IR-NEXT: ::builtin::alloc_raw::free_raw(q, 8, 8);
// IR-NEXT: ::builtin::base::alloc::free_bytes<{{.*}}::A>(q, 8, 8);
// IR-NEXT: = ::builtin::alloc_raw::resize_raw(q, 8, 16, 8);
// IR-NEXT: = ::builtin::base::alloc::resize_bytes<{{.*}}::A>(q, 8, 16, 8);
// IR-NEXT: = ::builtin::base::alloc::resize_raw_in_place(q, 8, 16, 8);
// IR-NEXT: = ::builtin::base::alloc::resize_in_place<{{.*}}::A>(q, 8, 16, 8);
