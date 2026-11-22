// A virtual call whose slot can hold only a few small bodies, all defined in
// this TU, is versioned on the loaded slot above -O0
// (Codegen/Backend/SpecDevirt.k): one compare and one inlined arm per body,
// then the original indirect call for any other slot value. That fallback is
// always kept, so the rewrite is correct whatever derives from the class in
// another TU, a library or C++ (spec_devirt_cxx_subclass.k runs that case).
//
// - Pet::noise has three bodies, one per vtable (Pet, Cat, Dog): the vptr is
//   compared with each vtable's address point, and the slot is loaded only
//   on the fallback path. The most derived vtables come first, Pet's last.
// - Shape::area has four bodies: Shape's, Rect's, Square's and Tri's. Cube
//   derives Square without overriding, so its vtable holds Square's body
//   too, and five vtables are more than the chain takes: the loaded slot is
//   compared with each body instead, Square's once, Shape's own last.
// - Wide::f has five bodies, more than the chain takes: left indirect.
// - Big::f has an override too large to be worth an arm: left indirect.
// - At -O0 and -Os nothing is versioned.

ffi "c" fn ext_step(x: i64) -> i64

class Shape {
    fn Shape(self) { }
    virtual fn area(const self) -> i64 { return 0 }
}

class Rect derives Shape {
    var w: i64
    var h: i64
    fn Rect(self, w: i64, h: i64) { self.w = w; self.h = h }
    override fn area(const self) -> i64 { return self.w * self.h }
}

class Square derives Shape {
    var s: i64
    fn Square(self, s: i64) { self.s = s }
    override fn area(const self) -> i64 { return self.s * self.s }
}

class Cube derives Square {
    fn Cube(self, s: i64) { Square::Square(self, s) }
}

class Tri derives Shape {
    var b: i64
    var h: i64
    fn Tri(self, b: i64, h: i64) { self.b = b; self.h = h }
    override fn area(const self) -> i64 { return self.b * self.h / 2 }
}

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

class Wide {
    fn Wide(self) { }
    virtual fn f(const self) -> i64 { return 0 }
}

class W1 derives Wide {
    fn W1(self) { }
    override fn f(const self) -> i64 { return 1 }
}

class W2 derives Wide {
    fn W2(self) { }
    override fn f(const self) -> i64 { return 2 }
}

class W3 derives Wide {
    fn W3(self) { }
    override fn f(const self) -> i64 { return 3 }
}

class W4 derives Wide {
    fn W4(self) { }
    override fn f(const self) -> i64 { return 4 }
}

class Big {
    fn Big(self) { }
    virtual fn f(const self) -> i64 { return 0 }
}

class BigX derives Big {
    fn BigX(self) { }
    override fn f(const self) -> i64 {
        var r: i64 = 1
        r += ext_step(r); r += ext_step(r); r += ext_step(r); r += ext_step(r)
        r += ext_step(r); r += ext_step(r); r += ext_step(r); r += ext_step(r)
        r += ext_step(r); r += ext_step(r); r += ext_step(r); r += ext_step(r)
        r += ext_step(r); r += ext_step(r); r += ext_step(r); r += ext_step(r)
        r += ext_step(r); r += ext_step(r); r += ext_step(r); r += ext_step(r)
        return r
    }
}

pub fn noise_of(p: *const Pet) -> i64 { return p->noise() }
pub fn area_of(s: *const Shape) -> i64 { return s->area() }
pub fn wide_of(w: *const Wide) -> i64 { return w->f() }
pub fn big_of(b: *const Big) -> i64 { return b->f() }

fn main() -> i32 {
    var r = Rect(2, 3)
    var q = Square(4)
    var c = Cube(5)
    var t = Tri(6, 7)
    var w1 = W1()
    var w2 = W2()
    var w3 = W3()
    var w4 = W4()
    var bx = BigX()
    var cat = Cat()
    var dog = Dog()
    var n = area_of(const &r) + area_of(const &q) + area_of(const &c) + area_of(const &t)
    n += wide_of(const &w1) + wide_of(const &w2) + wide_of(const &w3) + wide_of(const &w4)
    n += big_of(const &bx)
    n += noise_of(const &cat) + noise_of(const &dog)
    return n as i32
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o0 %t.os
// RUN: %kairo %s --emit=llvm-ir -O2 --target=x86_64-linux-gnu --cache-dir %t.d
// RUN: %FileCheck %s --check-prefix=PET < %t.d/spec_devirt.ll
// RUN: %FileCheck %s --check-prefix=AREA < %t.d/spec_devirt.ll
// RUN: %FileCheck %s --check-prefix=WIDE < %t.d/spec_devirt.ll
// RUN: %FileCheck %s --check-prefix=BIG < %t.d/spec_devirt.ll

// PET-LABEL: define {{.*}}@_ZN11spec_devirt8noise_ofEPKNS_3PetE(
// PET:       %[[VP:vtable[0-9a-z.]*]] = load ptr, ptr %p
// PET-NOT:   load ptr, ptr %[[VP]]
// PET:       icmp eq ptr %[[VP]], getelementptr inbounds {{.*}}(i8, ptr @_ZTVN11spec_devirt3CatE, i64 16)
// PET-NOT:   load ptr, ptr %[[VP]]
// PET:       icmp eq ptr %[[VP]], getelementptr inbounds {{.*}}(i8, ptr @_ZTVN11spec_devirt3DogE, i64 16)
// PET-NOT:   load ptr, ptr %[[VP]]
// PET:       icmp eq ptr %[[VP]], getelementptr inbounds {{.*}}(i8, ptr @_ZTVN11spec_devirt3PetE, i64 16)
// PET:       %[[FN:[0-9a-z.]+]] = load ptr, ptr %[[VP]],
// PET-NEXT:  call {{.*}}i64 %[[FN]](ptr
// PET:       {{^}}}

// AREA-LABEL: define {{.*}}@_ZN11spec_devirt7area_ofEPKNS_5ShapeE(
// AREA:       %[[FN:[0-9a-z.]+]] = load ptr, ptr %vtable{{[0-9a-z.]*}},
// AREA:       icmp eq ptr %[[FN]], @_ZNK11spec_devirt6Square4areaEv
// AREA-DAG:   icmp eq ptr %[[FN]], @_ZNK11spec_devirt4Rect4areaEv
// AREA-DAG:   icmp eq ptr %[[FN]], @_ZNK11spec_devirt3Tri4areaEv
// AREA:       icmp eq ptr %[[FN]], @_ZNK11spec_devirt5Shape4areaEv
// AREA:       call {{.*}}i64 %[[FN]](ptr
// AREA:       {{^}}}

// WIDE-LABEL: define {{.*}}@_ZN11spec_devirt7wide_ofEPKNS_4WideE(
// WIDE-NOT:   icmp eq ptr %{{.*}}, {{.*}}spec_devirt
// WIDE:       call {{.*}}i64 %{{.*}}(ptr
// WIDE-NOT:   icmp eq ptr %{{.*}}, {{.*}}spec_devirt
// WIDE:       {{^}}}

// BIG-LABEL: define {{.*}}@_ZN11spec_devirt6big_ofEPKNS_3BigE(
// BIG-NOT:   icmp eq ptr %{{.*}}, {{.*}}spec_devirt
// BIG:       call {{.*}}i64 %{{.*}}(ptr
// BIG-NOT:   icmp eq ptr %{{.*}}, {{.*}}spec_devirt
// BIG:       {{^}}}

// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-gnu --cache-dir %t.o0
// RUN: %FileCheck %s --check-prefix=NONE < %t.o0/spec_devirt.ll
// RUN: %kairo %s --emit=llvm-ir -Os --target=x86_64-linux-gnu --cache-dir %t.os
// RUN: %FileCheck %s --check-prefix=NONE < %t.os/spec_devirt.ll
// NONE-NOT: icmp eq ptr %{{.*}}, {{.*}}spec_devirt
