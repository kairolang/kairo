// One generic ADT at four kinds of payload. Its special members are written
// once, in every form; the instance's payload picks the form, so Opt is as
// cheap as its payload and as transferable as its payload, and no more.
//
//   i32      trivially copyable: every special member is the defaulted one,
//            and a function building an Opt<i32> keeps it in registers.
//   Owner    owns something: copies run its copy, assignment destroys the
//            old payload, scope exit destroys the live one.
//   Unique   move only: built in place, moved, move-assigned, read.
//   Pinned   neither copied nor moved: built in place, read, destroyed.
//
// ClassLifecycle states the categories. An instance reads its generic
// pattern, whose facts all wait for an argument, so the instance's category
// is pinned through a non-generic enum over the same payload.

var drops: i32 = 0
var moves: i32 = 0

class Owner {
    pub var id: i32
    pub fn Owner(self, id: i32) { self.id = id; }
    @copy fn Owner(self, const other: Self) = default
    fn op delete(self) { drops = drops + 1; }
}

class Unique {
    pub var n: i32
    pub fn Unique(self, n: i32) { self.n = n; }
    @move fn Unique(self, other: Self) { self.n = other.n; moves = moves + 1; }
}

class Pinned {
    pub var n: i32
    pub fn Pinned(self, n: i32) { self.n = n; }
    @copy fn Pinned(self, const other: Self) = delete
    @move fn Pinned(self, other: Self) = delete
    fn op delete(self) { drops = drops + 1; }
}

enum <T> Opt { Some { v: T }, None }
enum UniqueSlot { Has { u: Unique }, Empty }
enum PinnedSlot { Has { p: Pinned }, Empty }

fn twice(x: i32) -> Opt<i32> { return Opt<i32>::Some { v: x << 1 }; }

fn get(o: Opt<i32>) -> i32 = match o {
    case .Some(var v) => v
    case .None        => -1
}

fn owner_id(const o: Opt<Owner>) -> i32 = match o {
    case .Some(const v) => v.id
    case .None          => 0
}

fn unique_n(const o: Opt<Unique>) -> i32 = match o {
    case .Some(const v) => v.n
    case .None          => 0
}

fn slot_n(const s: UniqueSlot) -> i32 = match s {
    case .Has(const u) => u.n
    case .Empty        => 0
}

fn pinned_n(const o: Opt<Pinned>) -> i32 = match o {
    case .Some(const v) => v.n
    case .None          => 0
}

fn relay(@move o: Opt<Unique>) -> Opt<Unique> { return o; }
fn relay_slot(@move s: UniqueSlot) -> UniqueSlot { return s; }

fn trivial() -> bool {
    var a = twice(3)
    var b = a
    b = Opt<i32>::None
    return (get(a) == 6) && (get(b) == -1)
}

fn owning() -> bool {
    drops = 0
    var ok = true
    {
        var a = Opt<Owner>::Some { v: Owner(1) }
        var b = a
        ok = (owner_id(b) == 1)
        b = Opt<Owner>::None                    // the copy is destroyed
        ok = ok && (drops == 1) && (owner_id(b) == 0)
    }                                           // and a's at scope exit
    return ok && (drops == 2)
}

fn move_only() -> bool {
    moves = 0
    var a = Opt<Unique>::Some { v: Unique(4) }
    var b = relay(a)                            // one move
    b = Opt<Unique>::Some { v: Unique(5) }      // one move, out of the temporary
    var s = UniqueSlot::Has { u: Unique(6) }
    var t = relay_slot(s)                       // one move
    return (moves == 3) && (unique_n(b) == 5) && (slot_n(t) == 6)
}

fn immovable() -> bool {
    drops = 0
    var ok = true
    {
        var p = Opt<Pinned>::Some { v: Pinned(7) }
        var q = PinnedSlot::Has { p: Pinned(8) }
        var e: Opt<Pinned> = .None
        ok = (pinned_n(p) == 7) && (pinned_n(e) == 0)
    }
    return ok && (drops == 2)
}

fn main() -> i32 {
    var r = 0
    if trivial()   { r += 1 }
    if owning()    { r += 2 }
    if move_only() { r += 4 }
    if immovable() { r += 8 }
    return r                                    // 15
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA:      ===== SEMA fid {{[0-9]+}}: {{.*}}categories.k =====
// SEMA:        lifecycle Owner: category=COPY trivial_copy=0 trivial_dtor=0 destructible=1
// SEMA-NEXT:   lifecycle Unique: category=MOVE trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT:   lifecycle Pinned: category=NON_TRANSFER trivial_copy=0 trivial_dtor=0 destructible=1
// SEMA-NEXT:   lifecycle Opt: category=? trivial_copy=? trivial_dtor=? destructible=?
// SEMA-NEXT:   lifecycle UniqueSlot: category=MOVE trivial_copy=0 trivial_dtor=1 destructible=1
// SEMA-NEXT:   lifecycle PinnedSlot: category=NON_TRANSFER trivial_copy=0 trivial_dtor=0 destructible=1

// The generic record carries every form, each behind the flag that picks it;
// a trivially copyable instance gets the defaulted ones. The non-generic
// records carry only the form their category allows.
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}categories.k
// CXX:       template<class T> struct Opt {
// CXX:       static constexpr bool __kairo_trivial_copy = __is_trivially_copyable(__kairo_Some_t);
// CXX:       Opt(const Opt&) requires __kairo_trivial_copy = default;
// CXX:       Opt(Opt&&) requires __kairo_trivial_copy = default;
// CXX:       Opt& operator=(const Opt&) requires __kairo_trivial_copy = default;
// CXX:       Opt& operator=(Opt&&) requires __kairo_trivial_copy = default;
// CXX:       ~Opt() requires __kairo_trivial_dtor = default;
// CXX:       struct UniqueSlot {
// CXX:       UniqueSlot(const UniqueSlot&) = delete;
// CXX-NEXT:  UniqueSlot(UniqueSlot&& o) noexcept : __kairo_tag(o{{ ?}}.{{ ?}}__kairo_tag) {
// CXX:       UniqueSlot& operator=(const UniqueSlot&) = delete;
// CXX-NEXT:  UniqueSlot& operator=(UniqueSlot&& o) noexcept {
// CXX:       ~UniqueSlot() = default;
// CXX:       struct PinnedSlot {
// CXX:       PinnedSlot(const PinnedSlot&) = delete;
// CXX-NEXT:  PinnedSlot(PinnedSlot&&) = delete;
// CXX-NEXT:  PinnedSlot& operator=(const PinnedSlot&) = delete;
// CXX-NEXT:  PinnedSlot& operator=(PinnedSlot&&) = delete;
// CXX-NEXT:  ~PinnedSlot() noexcept {

// REQUIRES: clang, llvm-objdump
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15

// Opt<i32> is eight bytes and trivially copyable, so twice() returns it in a
// register: at -O2 no call and no load, store, push or pop (padding nops
// aside, which are written with a memory operand). Spelled for x86 (push,
// pop, `(%` memory operands), AArch64 (ldr/str/ldp/stp) and RISC-V (l*/s*,
// jalr), so the check holds on whichever arch the host is.
// RUN: %kairo %s -c -O2 --cache-dir %t.o2
// RUN: %objdump -d --no-show-raw-insn %t.o2/categories.o | awk '/<[^>]*5twice[^>]*>:/,/^$/' | grep -v nop > %t.twice.s
// RUN: grep -q ret %t.twice.s
// RUN: { ! grep -qE 'call|push|pop|\(%|[[:space:]](bl|ldr|str|ldp|stp|jalr|ld|sd|lw|sw)[[:space:]]' %t.twice.s; }
