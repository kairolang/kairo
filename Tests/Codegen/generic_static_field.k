// A static field named through a generic class's instance (MONO G4) is that
// instance's: `Box<i32>::count` spells `Box<int>::count`, never the bare
// class template `Box::count`, which names no class (CL001E "use of class
// template requires template arguments"). Each instance has its own static,
// as C++ instantiates one per class. The same holds for a static of a type
// nested in an instance, through a defaulted argument, in a generic body
// (`Box<T>::made`, dependent), read, assigned and compound-assigned.

class <T> Box {
    pub static count: i32 = 5
    pub static made: i32
    pub var v: T
    fn Box(self, v: T) { self.v = v  Box<T>::made += 1 }
}

class <K> Outer {
    pub struct Inner {
        pub static hits: i32 = 2
        pub var k: K
    }
}

class <T, U = i8> Pair {
    pub static width: i32 = 1
}

class Plain {
    pub static n: i32 = 4
}

fn <T> made_of() -> i32 { return Box<T>::made }

fn main() -> i32 {
    var r = Box<i32>::count                    // 5
    Box<i32>::count = 7
    Box<i64>::count += 10                       // its own static: 15
    r += Box<i32>::count                        // 12
    var b = Box<i32>(3)
    var c = Box<i32>(4)
    var d = Box<i64>(9)
    r += made_of<i32>() * 100                   // 212
    r += made_of<i64>() * 1000                  // 1212
    r += Box<i64>::count                        // 1227
    Outer<i32>::Inner::hits += 1
    r += Outer<i32>::Inner::hits * 10000        // 31227
    r += Pair<i32>::width * 100000              // 131227
    r += Plain::n - 4                           // a non-generic one is unchanged
    return r % 256                              // 155
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}generic_static_field.k
// IR:      ( ::generic_static_field::Box<T>::made += 1);
// IR:      return{{ ?}}::generic_static_field::Box<T>::made;
// IR:      signed int r = ::generic_static_field::Box<signed int>::count;
// IR-NEXT: ( ::generic_static_field::Box<signed int>::count = 7);
// IR-NEXT: ( ::generic_static_field::Box<signed long{{( long)?}}>::count += 10);
// IR:      ( ::generic_static_field::Outer<signed int>::Inner::hits += 1);
// IR:      ::generic_static_field::Pair<signed int, signed char>::width
// IR:      ::generic_static_field::Plain::n
// IR-NOT:  Box::count

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 155
