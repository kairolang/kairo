import std::io::println

pub enum <T> Frame {
    Burst { base: T, count: i32 },
    Code  { status: i32 },
    Idle,
}

pub class Batch {
    pub var frames: [Frame<i32>; 3] = [.Idle, .Idle, .Idle]
    pub var tag: i32? = null

    pub fn Batch(self, a: i32, b: i32) {
        self.frames[0] = .Burst { base: a, count: 3 }
        self.frames[1] = .Code  { status: b }
        self.frames[2] = .Idle
        self.tag = a + b
    }

    pub fn score(const self) -> i32 = match self.frames[1] {
        case .Code(const status) where status >= 200 => match status { case 200..=299 => 50 default => 10 }
        default => 0
    } + (self.tag ?? 0)

    pub fn op [](self, idx: usize) -> *Frame<i32> { return &self.frames[idx] }
    // Move-only: a custom destructor over an implicit copy is SC060W, now
    // that Frame<i32> has lifecycle facts of its own and Batch reads as COPY.
    @move fn Batch(self, other: Self) = default
    fn op delete(self) { println("[Kairo] Batch::~Batch() RAII dtor fired from C++ scope!") }
}

pub fn make_burst(base: i32, count: i32) -> Frame<i32> = .Burst { base: base, count: count }
pub fn sum_burst(f: Frame<i32>) -> i32 = match f {
    case .Burst(const base, const count) => base * count
    default => 0
}