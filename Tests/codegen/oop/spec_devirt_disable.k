// --disable-kairo-pass=spec-devirt turns speculative devirtualization off
// (Optimize/LLVM/SpecDevirt.k, spec_devirt.k has the shapes): at -O2 the
// call through Pet::noise, with three small bodies in this TU, keeps no
// compare of the vptr with a vtable, as at -O0. The flag reaches the object
// cache's key, so a cached object built with the pass is not reused.

class Pet {
    fn Pet(self) { }
    virtual fn noise(const self) -> i64 { return 0 }
}

class Cat derives Pet {
    fn Cat(self) { }
    override fn noise(const self) -> i64 { return 3 }
}

class Dog derives Pet {
    fn Dog(self) { }
    override fn noise(const self) -> i64 { return 5 }
}

pub fn noise_of(p: *const Pet) -> i64 { return p->noise() }

fn main() -> i32 {
    var cat = Cat()
    var dog = Dog()
    return (noise_of(const &cat) + noise_of(const &dog)) as i32
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.d
// RUN: %FileCheck %s --check-prefix=ON < %t.d/spec_devirt_disable.ll
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.d --disable-kairo-pass=spec-devirt
// RUN: %FileCheck %s --check-prefix=OFF < %t.d/spec_devirt_disable.ll

// ON-LABEL: define {{.*}}@_ZN19spec_devirt_disable8noise_ofEPKNS_3PetE(
// ON:       icmp eq ptr %{{.*}}, getelementptr inbounds {{.*}}@_ZTVN19spec_devirt_disable3CatE
// ON:       {{^}}}

// OFF-LABEL: define {{.*}}@_ZN19spec_devirt_disable8noise_ofEPKNS_3PetE(
// OFF-NOT:   icmp eq ptr %{{.*}}, {{.*}}spec_devirt_disable
// OFF:       call {{.*}}i64 %{{.*}}(ptr
// OFF-NOT:   icmp eq ptr %{{.*}}, {{.*}}spec_devirt_disable
// OFF:       {{^}}}
