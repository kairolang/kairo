import std::io::println

pub enum <T> Frame {
    Burst { base: T, count: i32 },
    Code  { status: i32 },
    Idle,
}

pub class Batch {
    pub var frames: [Frame<i32>; 3]
    pub var tag: i32? = null
    pub var ok: bool

    pub fn Batch(self, a: i32, b: i32) {
        self.frames = [.Burst { base: a, count: 3 }, .Code { status: b }, .Idle]
        self.ok = true
        self.frames[2] = .Code { status: 1 }
        self.tag = a + b
    }

    pub fn score(const self) -> i32 = match self.frames[1] {
        case .Code(const status) where status >= 200 => match status { case 200..=299 => 50 default => 10 }
        default => 0
    } + (self.tag ?? 0)

    pub fn op [](self, idx: usize) -> *Frame<i32> { return &self.frames[idx] }
    fn op delete(self) { println("[Kairo] Batch::~Batch() RAII dtor fired from C++ scope!") }
}

pub fn make_burst(base: i32, count: i32) -> Frame<i32> = .Burst { base: base, count: count }
pub fn sum_burst(f: Frame<i32>) -> i32 = match f {
    case .Burst(const base, const count) => base * count
    default => 0
}
