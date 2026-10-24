import std::io::println
ffi "c++" import "cxx_math.hh"

pub class <T> RingBuf {
    pub var data: [T; 4]
    pub var count: usize

    pub fn RingBuf(self) {
        self.count = 0
    }

    pub fn push(self, val: T) {
        if self.count < 4 {
            self.data[self.count] = val
            self.count += 1
        }
    }

    pub fn len(const self) -> usize = self.count

    // Const-overloaded place operator `[]` -> maps to `T&` and `const T&` in C++!
    pub fn op [](self, idx: usize) -> *T {
        return &self.data[idx]
    }

    pub fn op [](const self, idx: usize) -> *const T {
        return &self.data[idx]
    }

    fn op delete(self) {
        println("  [Kairo] RingBuf::~RingBuf() destroyed!")
    }
}

pub fn run_kairo_side(@inout buf: RingBuf<i32>) -> i32 {
    println("[Kairo] Calling C++20 concept-constrained cxx_scale_and_sum on RingBuf<i32>...")
    var sum = cxx_scale_and_sum(&buf, 3)

    var acc = CxxAccumulator()
    var lval = 7
    acc.feed(lval) // picks feed(const int&)
    acc.feed(10)   // picks feed(int&&)

    // Assign directly through C++ `int&` return value!
    acc.last_mut() += 500

    return sum + acc.get_total()
}