// A union takes no `extend` block: plain, with `impl`, generic, or through
// an alias. Operators and constructors a union declares in its own body
// still meet an interface's requirements.

interface Same {
    fn op ==(const self, o: Self) -> bool
}

interface Named {
    fn name(const self) -> i32
}

union Bits impl Same {
    var word: u32
    var half: u16
    fn op ==(const self, o: Bits) -> bool { return self.word == o.word }
}

union <T> Slot {
    var value: T
    var raw: u64
}

type Alias = Bits

extend Bits { fn raw(self) -> u32 { return self.word } }
extend Bits impl Named { fn name(const self) -> i32 { return 1 } }
extend <T> Slot<T> { fn get(self) -> u64 { return self.raw } }
extend Alias { fn other(self) -> u32 { return self.word } }

fn main() -> i32 {
    var a: Bits
    a.word = 1
    var b: Bits
    b.word = 1
    return if (a == b) => (0) else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: extend_union_target.k:26:8: error [SC361E]: a union cannot be extended; unions are raw memory overlays with no behavior: wrap the union in a struct or class and add the behavior there
// CHECK: extend_union_target.k:27:8: error [SC361E]: a union cannot be extended
// CHECK: extend_union_target.k:28:12: error [SC361E]: a union cannot be extended
// CHECK: extend_union_target.k:29:8: error [SC361E]: a union cannot be extended
