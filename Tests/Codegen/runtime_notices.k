import std::io

fn main() -> i32 {
    io::println("hello")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// Every program Kairo links carries mimalloc's MIT notice (Lib/rt/mimalloc.c,
// kairo_rt_notice_mimalloc), so a binary needs no separate attribution. It
// must survive dead-stripping: the release level with -fgc-sections (ELF
// --gc-sections, Mach-O -dead_strip, COFF -opt:ref, wasm-ld gc). Checked on
// the linked binary itself, so the object format does not matter; the notice
// is newline-delimited text, one CHECK line per line of the license.
//
// Twice: the runtime as direct objects (the plain link), and as the lazy
// Kairo library (--kairo-lib), where an object no symbol pulls in is never
// opened at all.
//
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -O3 -fgc-sections -o %t.d/direct.exe
// RUN: %t.d/direct.exe | %FileCheck %s --check-prefix=RUNS
// RUN: %FileCheck %s --input-file=%t.d/direct.exe
// RUN: %kairo %s -c -O3 --emit-scope=inputs -o %t.d/main.o
// RUN: %kairo %t.d/main.o --kairo-lib -O3 -fgc-sections -o %t.d/lazy.exe
// RUN: %t.d/lazy.exe | %FileCheck %s --check-prefix=RUNS
// RUN: %FileCheck %s --input-file=%t.d/lazy.exe

// RUNS: hello

// CHECK:      MIT License
// CHECK-EMPTY:
// CHECK-NEXT: Copyright (c) 2018-2025 Microsoft Corporation, Daan Leijen
// CHECK-EMPTY:
// CHECK-NEXT: Permission is hereby granted, free of charge, to any person obtaining a copy
// CHECK-NEXT: of this software and associated documentation files (the "Software"), to deal
// CHECK-NEXT: in the Software without restriction, including without limitation the rights
// CHECK-NEXT: to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// CHECK-NEXT: copies of the Software, and to permit persons to whom the Software is
// CHECK-NEXT: furnished to do so, subject to the following conditions:
// CHECK-EMPTY:
// CHECK-NEXT: The above copyright notice and this permission notice shall be included in all
// CHECK-NEXT: copies or substantial portions of the Software.
// CHECK-EMPTY:
// CHECK-NEXT: THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// CHECK-NEXT: IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// CHECK-NEXT: FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// CHECK-NEXT: AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// CHECK-NEXT: LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// CHECK-NEXT: OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// CHECK-NEXT: SOFTWARE.
