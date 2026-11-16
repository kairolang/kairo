// `@relocatable` on a record is clang's `trivial_abi`: the record is passed
// and returned as a trivial type of its layout would be, although it has a
// destructor. Beside `@packed` / `@align(N)` it joins the same attribute
// list. It applies to records only and takes no arguments.

// RUN: %kairo --print-ir %s | %FileCheck %s --check-prefix=IR
// RUN: %kairo %s -o %t && %t
// RUN: { %kairo --type-check-only -DBAD %s || true; } 2>&1 | %FileCheck %s --check-prefix=ERR

// IR: class __attribute((trivial_abi)) Handle
// IR: struct __attribute((packed, aligned(8), trivial_abi)) Both
// IR-NOT: trivial_abi{{.*}}Plain

static live: i32 = 0

@relocatable
class Handle {
    pub var fd: i32

    pub fn Handle(self, fd: i32) {
        self.fd = fd
        live += 1
    }

    @move pub fn Handle(self, other: Self) {
        self.fd  = other.fd
        other.fd = -1
    }

    pub fn op finally(self) {
        if self.fd >= 0 {
            live -= 1
        }
    }
}

@packed @align(8) @relocatable
struct Both {
    var a: u8
    var b: u32
}

class Plain {
    pub var x: i32 = 0
}

fn take(h: Handle) -> i32 {
    return h.fd
}

fn make(fd: i32) -> Handle {
    return Handle(fd)
}

eval if defined!(BAD) {
    // ERR: [[@LINE+1]]:{{[0-9]+}}: error {{.*}}'@relocatable' applies only to a class, struct or union
    @relocatable fn not_a_record() {}

    // ERR: [[@LINE+1]]:{{[0-9]+}}: error {{.*}}'@relocatable' takes no arguments
    @relocatable(1) struct Arg { var a: i32 }
}

fn main() -> i32 {
    var p = Plain()
    var b = Both { a: 1, b: 2 }
    var got = take(make(7))
    if got != 7 || live != 0 || p.x != 0 || b.b != 2 {
        return 1
    }

    return 0
}
