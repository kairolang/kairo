// A generic Kairo class and struct (Inputs/box.k: Box<T> with a member
// template combine<U>, Combined<A, B>) used from modern C++ and from
// Objective-C++: a C++20 concept over a Kairo field, CTAD on a Kairo class
// template, a generic lambda calling a Kairo member template, structured
// bindings over a Kairo struct, a std::vector of Kairo instances, an
// Objective-C block and protocol taking Kairo types. The destructor runs
// once, at the scope's end.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d

// RUN: %kcc %S/Inputs/box_runner.cpp -o %t.d/cxx
// RUN: %t.d/cxx | %FileCheck %s --check-prefix=CXX --match-full-lines
// CXX:      Inspecting Box with val = 42
// CXX-NEXT: C++ lambda got Combined: {42, 3.14}
// CXX-NEXT: vec item: 42 | 100.5
// CXX-NEXT: vec item: 42 | 200.75
// CXX-NEXT: Box::~Box()
// CXX-EMPTY:

// The same program from separate runs: the .cpp's own instances
// (Box<int>::combine<double>, Combined<int, double>) are its to make.
// RUN: %kcc -c %S/Inputs/box_runner.cpp -o %t.d/runner.o
// RUN: %kcc -c %S/Inputs/box.k -o %t.d/box.o
// RUN: %kcc %t.d/runner.o %t.d/box.o -o %t.d/cxx_sep
// RUN: %t.d/cxx_sep | %FileCheck %s --check-prefix=CXX --match-full-lines

// And through kairo itself.
// RUN: %kairo %S/Inputs/box_runner.cpp -o %t.d/cxx_kairo --cache-dir %t.d/ko
// RUN: %t.d/cxx_kairo | %FileCheck %s --check-prefix=CXX --match-full-lines

// Objective-C++ with blocks. The runner stubs the GNU ObjC and blocks ABI
// symbols itself: the musl sysroot has no libobjc.
// RUN: %kcc -fblocks %S/Inputs/box_runner.mm -o %t.d/objcxx
// RUN: %t.d/objcxx | %FileCheck %s --check-prefix=OBJC --match-full-lines
// OBJC:      Obj-C++ block got Combined: {42, 3.14}
// OBJC-NEXT: Box::~Box()
// OBJC-EMPTY:
