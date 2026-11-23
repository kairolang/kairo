// An ADT enum whose `op panic` comes from an extension, raised and caught.
// The message hook for the C++ view (`__kairo_pmsg<E>`) names the enum
// itself: spelled from the enum's layout record it was `E::E`, the record's
// constructor, and clang rejected every TU that defines the enum.

import std::io

enum Fault {
    Bad { what: string },
    Empty,
}

extend Fault {
    pub fn op panic (const self) -> string = match self {
        case .Bad(const what) => f"bad {what}"
        case .Empty => "empty"
    }
}

fn check(const s: string) panic(Fault) -> i32 {
    if s.is_empty() {
        panic Fault::Empty
    }

    if s != "ok" {
        panic Fault::Bad { what: s.copy() }
    }

    return 1
}

fn main() -> i32 {
    for s in ["ok", "", "x"] {
        var shown = try f"{check(s)}" catch e: Fault => e.op panic()
        io::println(shown)
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: Fault::Fault>
// CXX: struct __kairo_pmsg< ::{{.*}}Fault> {
// CXX-NOT: Fault::Fault>
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 1
// OUT-NEXT: empty
// OUT-NEXT: bad x
// RUN: rm -f %t.exe
