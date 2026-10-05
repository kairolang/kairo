// A generic record with a place `op []`, its const pair, and a value
// `op []` returning a slice. The value form used to reach MemberTyping's
// pointee ICE, since every `op []` was taken as a place.

struct <T> Buf {
    var data: [T; 4]

    fn op [](self, i: usize) -> *T { return &self.data[i] }
    fn op [](const self, i: usize) -> *const T { return &self.data[i] }

    fn op [](self, r: Range<usize>) -> [T;] {   // a value: a view into data
        var hi = r.end
        if r.inclusive { hi += 1 }
        return Slice<T>(&self.data[r.begin], hi - r.begin)
    }
}

fn peek(const b: Buf<i32>, i: usize) -> i32 { return b[i] }

fn main() -> i32 {
    var b = Buf<i32>{ data: [1, 2, 3, 4] }
    b[1] = 20                    // through the place
    var s = b[1..3]              // the value form: a view of 20 3
    s[0] = 7                     // the view writes through to b.data[1]
    if peek(b, 1) != 7 { return 1 }
    return s[0] + s[1] + b[3]    // 7 + 3 + 4 == 14
}

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 14
