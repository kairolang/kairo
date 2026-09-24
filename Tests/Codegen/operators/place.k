// A place operator returns `*T` in Kairo and `T&` in C++: the same object.
// Both directions are exercised: assignment through the subscript, a read
// through the const overload, and taking the address to get the pointer back.

struct Buffer {
    var data: [u8; 4]

    fn op [](self, i: usize) -> *u8 { return &self.data[i] }
    fn op [](const self, i: usize) -> *const u8 { return &self.data[i] }
}

fn peek(const b: Buffer, i: usize) -> u8 { return b[i] }

fn main() -> i32 {
    var buff = Buffer{ data: [1, 2, 3, 4] }
    buff[1] = 40                 // through the reference
    var p = &buff[2]             // the pointer back
    *p = 5
    buff[3] += 1                 // primitive compound on a place
    return (peek(buff, 0) as i32) + (buff[1] as i32) + (buff[2] as i32) + (buff[3] as i32)   // 1 + 40 + 5 + 5 == 51
}

// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: unsigned char& operator[](
// CXX-DAG: const unsigned char& operator[](
// CXX-NOT: unsigned char* operator[](

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 51
