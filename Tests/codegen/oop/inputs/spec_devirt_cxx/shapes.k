// Kairo hierarchies a C++ file derives from (main.cc), whose calls are
// versioned (spec_devirt_cxx_subclass.k). area_of's compares the vptr with
// the three Kairo vtables.
pub class Shape {
    pub fn Shape(self) { }
    pub virtual fn area(const self) -> i64 { return 1 }
}

pub class Rect derives Shape {
    pub var w: i64 = 0
    pub var h: i64 = 0
    pub fn Rect(self, w: i64, h: i64) { self.w = w; self.h = h }
    pub override fn area(const self) -> i64 { return self.w * self.h }
}

pub class Square derives Shape {
    pub var s: i64 = 0
    pub fn Square(self, s: i64) { self.s = s }
    pub override fn area(const self) -> i64 { return self.s * self.s }
}

pub fn area_of(s: *const Shape) -> i64 { return s->area() }

// Meter's body is in five vtables (M1 to M4 do not override), more than the
// vptr compares take, so level_of's call compares the loaded slot with the
// two bodies instead.
pub class Gauge {
    pub fn Gauge(self) { }
    pub virtual fn level(const self) -> i64 { return 2 }
}

pub class Meter derives Gauge {
    pub fn Meter(self) { }
    pub override fn level(const self) -> i64 { return 30 }
}

pub class M1 derives Meter {
    pub fn M1(self) { }
}

pub class M2 derives Meter {
    pub fn M2(self) { }
}

pub class M3 derives Meter {
    pub fn M3(self) { }
}

pub class M4 derives Meter {
    pub fn M4(self) { }
}

pub fn level_of(g: *const Gauge) -> i64 { return g->level() }
