// An override of a KAIRO virtual returns what C++ accepts as an override of
// the method it emits (SC297E). Without it clang
// rejects the emitted pair (CL001E "virtual function 'val' has a different
// return type"), naming C++ types and offering no fix. The docs have no
// covariance rule for Kairo classes, so no rule is added: every pair below
// that clang rejects is SC297E with a fix-it to the base's return, and
// every pair clang accepted still compiles (override_return_kairo_ok.k).

class Other { var z: i32 = 0 }

class KB {
    var o: Other
    virtual fn val(self) -> i32 { return 1 }
    virtual fn un(self) -> u32 { return 1 }
    virtual fn me(self) -> *KB { return &self }
    virtual fn opt(self) -> *KB? { return &self }
    virtual fn copy(self) -> KB { return KB() }
    virtual fn run(self) { }
    virtual fn cme(self) -> *KB { return &self }
}

class KD derives KB {
    override fn val(self) -> i64 { return 2 }
    override fn un(self) -> i32 { return 2 }
    override fn me(self) -> *Other { return &self.o }
    override fn opt(self) -> *KD? { return &self }
    override fn copy(self) -> KD { return KD() }
    override fn run(self) -> i32 { return 0 }
    override fn cme(self) -> *const KD { return &self }
}

// Without `override` the method still overrides (C++ makes it virtual), and
// no `->` is `void`. A `const self` method is another method, not an
// override, so its return is not compared here.
class KB2 {
    virtual fn val(self) -> i32 { return 1 }
    virtual fn get(self) -> i32 { return 1 }
    virtual fn other(self) -> i32 { return 1 }
}

class KD2 derives KB2 {
    fn val(self) -> i64 { return 2 }
    override fn get(self) { }
    fn other(const self) -> i64 { return 2 }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: override_return_kairo_virtual.k:23:30: error [SC297E]: 'val' returns 'i64', but the virtual it overrides returns 'i32'
// CHECK-NEXT: fix-it:"{{.*}}":{23:30-23:33}:"i32"
// CHECK-NEXT: override_return_kairo_virtual.k:13:29: note [SC297N]: the virtual it overrides, whose return it must match
// CHECK: override_return_kairo_virtual.k:24:29: error [SC297E]: 'un' returns 'i32', but the virtual it overrides returns 'u32'
// CHECK-NEXT: fix-it:"{{.*}}":{24:29-24:32}:"u32"
// CHECK: override_return_kairo_virtual.k:25:29: error [SC297E]: 'me' returns '*Other', but the virtual it overrides returns '*KB'
// CHECK-NEXT: fix-it:"{{.*}}":{25:29-25:35}:"*KB"
// CHECK: override_return_kairo_virtual.k:26:30: error [SC297E]: 'opt' returns '*KD?', but the virtual it overrides returns '*KB?'
// CHECK-NEXT: fix-it:"{{.*}}":{26:30-26:34}:"*KB?"
// CHECK: override_return_kairo_virtual.k:27:31: error [SC297E]: 'copy' returns 'KD', but the virtual it overrides returns 'KB'
// CHECK-NEXT: fix-it:"{{.*}}":{27:31-27:33}:"KB"
// CHECK: override_return_kairo_virtual.k:28:30: error [SC297E]: 'run' returns 'i32', but the virtual it overrides returns 'void'
// CHECK: override_return_kairo_virtual.k:29:30: error [SC297E]: 'cme' returns '*const KD', but the virtual it overrides returns '*KB'
// CHECK: override_return_kairo_virtual.k:42:21: error [SC297E]: 'val' returns 'i64', but the virtual it overrides returns 'i32'
// CHECK-NEXT: fix-it:"{{.*}}":{42:21-42:24}:"i32"
// CHECK: override_return_kairo_virtual.k:43:17: error [SC297E]: 'get' returns 'void', but the virtual it overrides returns 'i32'
