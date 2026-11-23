// The error types the raising forms carry (AllocError, Utf8Error, KeyExists)
// are builtin names: a program that imports only std names them in `catch`
// without importing the builtin library.

import std::io::println
import std::mem::try_create_in

class Failing {
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
}

class Box {
    pub var v: i64
    pub fn Box(self, v: i64) {
        self.v = v
    }
}

fn main() -> i32 {
    try {
        var *b = try_create_in<Box, Failing>(1)
        println(f"created {b->v}")
    } catch e: AllocError {
        println(f"alloc {e.size()} {e.align()}")
    }

    var bytes: [u8] = [0x61, 0xff]
    try {
        var s = string::try_from_utf8(bytes)
        println(f"utf8 {s}")
    } catch e: Utf8Error {
        println("utf8 error")
    }

    var m: {i32: i32} = {}
    m[1] = 10
    try {
        var *v = m.try_insert(1, 20)
        println(f"inserted {*v}")
    } catch e: KeyExists {
        println("key exists")
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s
// CHECK: alloc 8 8
// CHECK-NEXT: utf8 error
// CHECK-NEXT: key exists
