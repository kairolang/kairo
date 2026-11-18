// The CRTP downcast `(unsafe &self) as unsafe *T` adjusts for the offset of
// every base, not only the second one: with three mixins of different sizes
// each reads the host's own field. Exit 0 only if all three read 7, 8 and 9.
class <T: type> MixA {
    pub var a: i64 = 1
    priv inline fn dyn(self) -> unsafe *T { return unsafe ((unsafe &self) as unsafe *T); }
    fn from_a(self) -> i32 { return self.dyn()->x; }
}
class <T: type> MixB {
    pub var b: i32 = 2
    priv inline fn dyn(self) -> unsafe *T { return unsafe ((unsafe &self) as unsafe *T); }
    fn from_b(self) -> i32 { return self.dyn()->y; }
}
class <T: type> MixC {
    pub var c: i64 = 3
    pub var d: i64 = 4
    priv inline fn dyn(self) -> unsafe *T { return unsafe ((unsafe &self) as unsafe *T); }
    fn from_c(self) -> i32 { return self.dyn()->z; }
}
class Host derives MixA<Host>, MixB<Host>, MixC<Host> {
    pub var x: i32 = 7
    pub var y: i32 = 8
    pub var z: i32 = 9
}
fn main() -> i32 {
    var h: Host;
    if h.from_a() != 7 { return 1; }
    if h.from_b() != 8 { return 2; }
    if h.from_c() != 9 { return 3; }
    return 0;
}

// --- lit wiring ---
// RUN: rm -f %t.exe && rm -rf %t.d
// RUN: %kairo -fduck-generics %s -O0 -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe
// RUN: rm -f %t.exe
// RUN: %kairo -fduck-generics %s -O2 -o %t.exe --cache-dir %t.d/o2
// RUN: %t.exe
