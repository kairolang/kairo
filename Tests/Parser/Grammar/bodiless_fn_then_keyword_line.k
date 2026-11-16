// A trailing function modifier sits on the line of the signature it
// follows. After a signature with no body, a keyword that starts the next
// line opens the next declaration: `eval if`, an `eval` constant, an
// `inline fn`, a `const` binding.

// RUN: %kairo --type-check-only %s
// RUN: %kairo %s -o %t && %t

class C {
    pub var a: i32 = 0

    pub fn first(self) -> i32
    eval if defined!(NEVER_DEFINED_HERE) {
        pub fn pick(self) -> i32 { return 1 }
    } else {
        pub fn pick(self) -> i32 { return 2 }
    }

    pub fn second(self) -> i32
    eval N: i32 = 5

    pub fn third(self) -> i32
    inline fn fourth(self) -> i32 { return 4 }

    pub fn fifth(self) -> i32
    const K: i32 = 7

    // On the signature's own line the keyword is still a modifier.
    pub fn sixth(self) inline -> i32 { return 6 }
}

fn C::first(self) -> i32 { return 1 }
fn C::second(self) -> i32 { return C::N }
fn C::third(self) -> i32 { return 3 }
fn C::fifth(self) -> i32 { return self.K }

fn main() -> i32 {
    var c = C()
    var sum = c.first() + c.pick() + c.second() + c.third() + c.fourth() + c.fifth() + c.sixth()
    if sum != 1 + 2 + 5 + 3 + 4 + 7 + 6 {
        return 1
    }

    return 0
}
