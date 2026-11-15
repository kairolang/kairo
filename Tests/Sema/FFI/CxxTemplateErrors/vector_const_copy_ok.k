ffi "c++" import "vector"

pub class Box {
    pub var v: i32
    pub fn Box(self) = default

    @copy
    pub fn Box(self, const other: Self) {
        self.v = other.v
    }

    pub fn Box(self, v: i32) {
        self.v = v
    }
}

pub class Mv {
    pub var v: i32
    pub fn Mv(self) = default

    @move
    pub fn Mv(self, other: Self) {
        self.v = other.v
        other.v = 0
    }

    pub fn Mv(self, v: i32) {
        self.v = v
    }
}

fn main() -> i32 {
    var b   = Box(10)
    var vec = cxx::std::vector<Box>()
    vec.push_back(b)
    vec.push_back(Box(20))
    var mv = cxx::std::vector<Mv>()
    mv.push_back(Mv(5))
    return vec[0].v + vec[1].v + mv[0].v - 35
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --allow-empty --implicit-check-not="error ["
// RUN: %t.exe
