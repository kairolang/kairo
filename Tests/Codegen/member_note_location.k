import std::io::println
ffi "c++" import "<mutex>";

pub enum <T> Frame {
    Burst { base: T, count: i32 },
    Code  { status: i32 },
    Idle,
}

pub class Batch {
    pub var frames: [Frame<i32>; 3] = [.Idle, .Idle, .Idle]
    pub var guard: cxx::std::lock_guard<cxx::std::mutex>
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
    fn op delete(self) { println("[Kairo] Batch::~Batch() RAII dtor fired from C++ scope!") }
}

pub fn make_burst(base: i32, count: i32) -> Frame<i32> = .Burst { base: base, count: count }
pub fn sum_burst(f: Frame<i32>) -> i32 = match f {
    case .Burst(const base, const count) => base * count
    default => 0
}

// A clang diagnostic on a record member lands on the member's name. Every
// token of the emitted C++ claims a byte of its Kairo anchor, and one with
// no byte of its own left walks on through the file: here a token of the
// class took the first byte of `guard` before the field was spelled, so the
// name walked on and clang's "member is declared here" landed at line 33, in
// `sum_burst`. The name now takes its byte back (TokenSink::_steal). This
// explanation sits below the code on purpose: the collision depends on the
// bytes above it, so it must not move.
//
// `guard` has an imported type with no default constructor: the error is
// clang's, not Kairo's (TypeUtil::why_no_default leaves C++ types to clang).
// The error itself is at the constructor's out-of-line definition, whose
// name byte its in-class declaration holds, so it walks on too and its line
// is not checked (TICKETS.TXT, "a definition's name shares its
// declaration's byte").

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -c -o %t.o 2>&1 || true; } | %FileCheck %s
// CHECK: member_note_location.k:{{[0-9]+}}:{{[0-9]+}}: error [CL001E]: constructor for '{{.*}}Batch' must explicitly initialize the member 'guard'
// CHECK: member_note_location.k:12:13: note [{{[A-Z0-9]+}}]: member is declared here