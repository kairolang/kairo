// What the hot members of string compile to at -O2 on x86-64 SysV, read off
// the LLVM IR. size() is one shift. An append's fast path has two tests
// that share one cold edge, the copy and no other call; the cold half is
// called preserve_most with the string's two words by value, so a string
// that is only appended to stays out of memory. Dropping a literal-backed
// string is nothing. A string and a panicking parse return in registers.

struct Small {
    var v: u32
}

extend Small impl FromStr {
    static fn from_str(const s: string) -> Small? {
        var err = ParseError { at: 0, kind: ParseErrorKind::None }
        return Small::from_str_reason(s, &err)
    }

    static fn from_str_reason(const s: string, @inout err: ParseError) -> Small? {
        if s.is_empty() {
            err.kind = ParseErrorKind::Empty
            return null
        }

        return Small { v: s.size() as u32 }
    }
}

fn sz(const s: string) -> usize {
    return s.size()
}

fn app_lit(@inout s: string) {
    s += "abcd"
}

fn app_str(@inout s: string, const o: string) {
    s.push_str(o)
}

fn push_c(@inout s: string, c: char) {
    s.push(c)
}

fn drop_lit() -> usize {
    var s = "hello"
    return s.size()
}

fn lit() -> string {
    return "hello"
}

fn pass(s: string) -> string {
    return s
}

fn fill(n: u64) -> string {
    var s = string()
    for var i: u64 = 0; i < n; i += 1 {
        s.push('a')
    }

    return s
}

fn cstr(@inout s: string) -> unsafe *const __builtin_c_char {
    return s.c_str()
}

fn parse_small(const s: string) panic(ParseError) -> Small {
    return s.parse<Small>()
}

fn main() -> i32 {
    var s = "abc"
    app_lit(&s)
    return (sz(s) - 7) as i32
}

// --- lit wiring ---
// REQUIRES: sysroot-x86_64-linux-gnu
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -O2 --target=x86_64-linux-gnu --emit=llvm-ir -o %t.d/out.ll --cache-dir %t.d/c
// RUN: %FileCheck %s --input-file=%t.d/out.ll

// size(): the meta word, shifted.
// CHECK-LABEL: define {{.*}} @_ZN{{[0-9a-zA-Z_]*}}2szE
// CHECK-NOT:   {{ call }}
// CHECK:       lshr i64 %{{.*}}, 3
// CHECK-NOT:   {{ call }}
// CHECK:       ret i64

// `+=` of a literal: owned? room? then four bytes and the NUL, stored inline.
// CHECK-LABEL: define {{.*}}7app_litE
// CHECK-NOT:   {{ call }}
// CHECK:       br i1
// CHECK-NOT:   {{ call }}
// CHECK:       br i1
// CHECK-NOT:   {{ call }}
// CHECK:       store i32 1684234849
// CHECK-NOT:   {{ call }}
// CHECK:       call preserve_mostcc { ptr, i64 } @{{.*}}append_slow_
// CHECK-NOT:   {{ call }}
// CHECK:       ret void

// push_str of any string: one memcpy on the fast path, one cold call.
// CHECK-LABEL: define {{.*}}7app_strE
// CHECK-NOT:   {{ call }}
// CHECK:       call void @llvm.memcpy
// CHECK-NOT:   {{ call }}
// CHECK:       call preserve_mostcc { ptr, i64 } @{{.*}}append_slow_
// CHECK-NOT:   {{ call }}
// CHECK:       ret void

// push: the byte and its NUL are one two-byte store.
// CHECK-LABEL: define {{.*}}6push_cE
// CHECK-NOT:   {{ call }}
// CHECK:       store i16
// CHECK-NOT:   {{ call }}
// CHECK:       call preserve_mostcc { ptr, i64 } @{{.*}}push_slow_
// CHECK-NOT:   {{ call }}
// CHECK:       ret void

// A literal-backed string is dropped without a call.
// CHECK-LABEL: define {{.*}}8drop_litE
// CHECK-NOT:   {{ call }}
// CHECK:       ret i64 5

// By-value return and pass: two registers, no sret.
// CHECK:       define {{[^(]*}}{ ptr, i64 } @{{[^(]*}}3litEv()
// CHECK:       define {{[^(]*}}{ ptr, i64 } @{{[^(]*}}4passE{{[^(]*}}(ptr %{{[^,]*}}, i64 %{{[^,)]*}})

// A string that is only pushed to never has its address taken: no stack slot.
// CHECK-LABEL: define {{.*}}4fillE
// CHECK-NOT:   alloca
// CHECK:       call preserve_mostcc { ptr, i64 } @{{.*}}push_slow_
// CHECK-NOT:   alloca
// CHECK:       ret { ptr, i64 }

// c_str on a view promotes through a cold preserve_most call.
// CHECK-LABEL: define {{.*}}4cstrE
// CHECK:       call preserve_mostcc { ptr, i64 } @{{.*}}promote_

// A panicking parse returns in registers.
// CHECK:       define {{[^(]*}}{ i64, i64 } @{{[^(]*}}11parse_smallE
// CHECK-NOT:   sret

// CHECK:       declare preserve_mostcc {{.*}}promote_{{.*}} #[[COLD:[0-9]+]]
// CHECK:       attributes #[[COLD]] = { cold
