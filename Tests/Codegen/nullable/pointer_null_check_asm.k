// A nullable safe pointer `*T?` is one machine pointer whose null is the
// empty state: no tag, no second word. A null-checked read through it is the
// same instructions as the read through an `unsafe *T` compared with `&null`,
// in each place a pointer is held:
//
//   by value     test, branch, load
//   struct field one load of the field, then test, branch, load
//   union field  the same, with the field at offset 0
//
// The checks pin the whole body of each function on x86-64 at -O2, so a tag
// word, a second load or a call into the library shows as a failure here.

pub struct SSafe {
    var tag: i64
    var p:   *i32?
}

pub struct SUnsafe {
    var tag: i64
    var p:   unsafe *i32
}

pub union USafe {
    var p: *i32?
    var n: usize
}

pub union UUnsafe {
    var p: unsafe *i32
    var n: usize
}

@no_inline
pub fn value_safe(p: *i32?) -> i32 {
    if p != null {
        return *p
    }

    return -1
}

@no_inline
pub fn value_unsafe(p: unsafe *i32) -> i32 {
    if p != &null {
        return unsafe *p
    }

    return -1
}

@no_inline
pub fn struct_safe(const s: *SSafe) -> i32 {
    var *q? = s->p
    if q != null {
        return *q
    }

    return -1
}

@no_inline
pub fn struct_unsafe(const s: *SUnsafe) -> i32 {
    if s->p != &null {
        return unsafe *s->p
    }

    return -1
}

@no_inline
pub fn union_safe(const u: *USafe) -> i32 {
    unsafe {
        var *q? = u->p
        if q != null {
            return *q
        }
    }

    return -1
}

@no_inline
pub fn union_unsafe(const u: *UUnsafe) -> i32 {
    unsafe {
        if u->p != &null {
            return *u->p
        }
    }

    return -1
}

fn main() -> i32 {
    if sizeof(SSafe) != sizeof(SUnsafe) || sizeof(SSafe) != 16 {
        return 1
    }

    if sizeof(USafe) != sizeof(UUnsafe) || sizeof(USafe) != 8 {
        return 2
    }

    if sizeof(*i32?) != sizeof(unsafe *i32) {
        return 3
    }

    var x: i32     = 7
    var a          = SSafe { tag: 1, p: &x }
    var b          = SUnsafe { tag: 1, p: unsafe (&x as unsafe *i32) }
    var c: USafe
    var d: UUnsafe
    unsafe {
        c.p = &x
        d.p = &x as unsafe *i32
    }

    if value_safe(&x) != 7 || value_unsafe(unsafe (&x as unsafe *i32)) != 7 {
        return 4
    }

    if struct_safe(&a) != 7 || struct_unsafe(&b) != 7 {
        return 5
    }

    if union_safe(&c) != 7 || union_unsafe(&d) != 7 {
        return 6
    }

    if value_safe(null) != -1 || value_unsafe(&null) != -1 {
        return 7
    }

    a.p = null
    b.p = &null
    if struct_safe(&a) != -1 || struct_unsafe(&b) != -1 {
        return 8
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, sysroot-x86_64-linux-gnu
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 --emit=asm --target=x86_64-linux-gnu --cache-dir %t.d/asm
//
// Directives, comments and local labels are dropped, so what is left of a
// function is its symbol and its instructions, checked line after line.
// RUN: grep -vE '^[[:space:]]*(\.|#)|^\.L' %t.d/asm/pointer_null_check_asm.s | %FileCheck %s
//
// CHECK-LABEL: {{^}}_ZN22pointer_null_check_asm10value_safeE{{.*}}:
// CHECK-NEXT: testq %rdi, %rdi
// CHECK-NEXT: je
// CHECK-NEXT: movl (%rdi), %eax
// CHECK-NEXT: retq
// CHECK-NEXT: movl $-1, %eax
// CHECK-NEXT: retq
//
// CHECK-LABEL: {{^}}_ZN22pointer_null_check_asm12value_unsafeE{{.*}}:
// CHECK-NEXT: testq %rdi, %rdi
// CHECK-NEXT: je
// CHECK-NEXT: movl (%rdi), %eax
// CHECK-NEXT: retq
// CHECK-NEXT: movl $-1, %eax
// CHECK-NEXT: retq
//
// CHECK-LABEL: {{^}}_ZN22pointer_null_check_asm11struct_safeE{{.*}}:
// CHECK-NEXT: movq 8(%rdi), %rax
// CHECK-NEXT: testq %rax, %rax
// CHECK-NEXT: je
// CHECK-NEXT: movl (%rax), %eax
// CHECK-NEXT: retq
// CHECK-NEXT: movl $-1, %eax
// CHECK-NEXT: retq
//
// CHECK-LABEL: {{^}}_ZN22pointer_null_check_asm13struct_unsafeE{{.*}}:
// CHECK-NEXT: movq 8(%rdi), %rax
// CHECK-NEXT: testq %rax, %rax
// CHECK-NEXT: je
// CHECK-NEXT: movl (%rax), %eax
// CHECK-NEXT: retq
// CHECK-NEXT: movl $-1, %eax
// CHECK-NEXT: retq
//
// CHECK-LABEL: {{^}}_ZN22pointer_null_check_asm10union_safeE{{.*}}:
// CHECK-NEXT: movq (%rdi), %rax
// CHECK-NEXT: testq %rax, %rax
// CHECK-NEXT: je
// CHECK-NEXT: movl (%rax), %eax
// CHECK-NEXT: retq
// CHECK-NEXT: movl $-1, %eax
// CHECK-NEXT: retq
//
// CHECK-LABEL: {{^}}_ZN22pointer_null_check_asm12union_unsafeE{{.*}}:
// CHECK-NEXT: movq (%rdi), %rax
// CHECK-NEXT: testq %rax, %rax
// CHECK-NEXT: je
// CHECK-NEXT: movl (%rax), %eax
// CHECK-NEXT: retq
// CHECK-NEXT: movl $-1, %eax
// CHECK-NEXT: retq

// The same program at -O0 and at -O2 runs: the sizes agree and every read
// returns the value, or -1 for null.
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run0
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.opt.exe --cache-dir %t.d/run2
// RUN: %t.opt.exe
