// A record temporary at the head of a method chain lives to the end of the
// statement for neighbouring shapes: a chain of four steps, a hoisting
// f-string in the first argument, and one in the last. `dropped` counts
// objects destroyed before `emit()`; the program exits with it, at -O0 and
// -O2.

var dropped: i32 = 0;

class B {
    pub var done: bool = false;
    fn B(self) { }
    @move fn B(self, other: Self) { self.done = other.done; other.done = true; }
    fn step(self, s: string) -> unsafe *Self { return unsafe &self; }
    fn emit(self) { self.done = true; }
    fn op finally(self) { if !self.done { dropped += 1; } }
}

fn make() -> B { return B(); }

fn main() -> i32 {
    var nm = "v";
    make().step(f"a {nm}" "b")->step("x")->step("y")->step("z")->emit();
    make().step("x")->step(f"b {nm}" "c")->emit();
    make().step("x")->step("y")->step(f"c {nm}" "d")->emit();
    return dropped;
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -w -O0 -o %t.exe --cache-dir %t.d0
// RUN: %t.exe
// RUN: rm -f %t.exe
// RUN: %kairo %s -w -O2 -o %t.exe --cache-dir %t.d2
// RUN: %t.exe
