// `--emit-headers` of a file with a `@set_scoped_allocator(A)` class: the
// class's definition holds the arena's two fields before and after the
// others, and a C++ file that includes the header, builds an object and
// calls its methods compiles.
import builtin::base::alloc::*

pub class Arenas {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        return &null
    }

    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool {
        return false
    }

    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
        return &null
    }

    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        return &null
    }

    pub static fn arena_open() -> usize {
        return 1
    }

    pub static fn arena_close(arena: usize) { }
    pub static fn arena_enter(arena: usize) -> usize {
        return 0
    }

    pub static fn arena_leave(previous: usize) { }
    pub static fn arena_range(arena: usize) -> (unsafe *u8, unsafe *u8) {
        return (&null, &null)
    }
}

@set_scoped_allocator(Arenas)
pub class Log {
    pub var n: i32 = 0
    pub fn add(self) {
        self.n += 1
    }

    pub fn get(const self) -> i32 {
        return self.n
    }
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s --check-prefix=HDR < %t.d/h/emit_headers_scoped_class.hh
// RUN: printf '#include "emit_headers_scoped_class.hh"\nint f() { ::emit_headers_scoped_class::Log l; l.add(); return l.get(); }\n' > %t.d/use.cc
// RUN: { %clangxx -std=c++23 -fsyntax-only -I %t.d/h -I %S/../../Lib %t.d/use.cc 2>&1 || true; } | %FileCheck %s --check-prefix=CXX --allow-empty

// HDR: class Log {
// HDR: ::builtin::base::alloc::ObjectArena<::emit_headers_scoped_class::Arenas> __kairo_arena;
// HDR-NEXT: signed int n = 0;
// HDR-NEXT: ::builtin::base::alloc::ObjectArenaEnd<::emit_headers_scoped_class::Arenas> __kairo_arena_end;

// CXX-NOT: error
