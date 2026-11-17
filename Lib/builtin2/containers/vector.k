/// builtin/containers/vector.k
///
/// Called by the compiler: a literal `[a, b, c]` is `Vector()`, then
/// `reserve(n)`, then `push(v)` per element. Keep those three as they are.

ffi "c++" import "rt/global_alloc.h"

import base::cmp::*
import base::copy::*
import base::intrinsics::*
import base::iter::*
import base::range::*
import builtin::Null
import containers::slice::*

// The block every empty vector points just past: 64 bytes, 64-aligned, all
// zero, so the capacity word at `buf - W` reads 0 on every word size and the
// address is a valid `*T` for any `T` aligned to 64 or less. Nothing writes
// or frees it: every path that writes the header or frees the block first
// sees a capacity of 0. Constant, so the optimizer reads that 0 at compile
// time and a vector that never grows costs no call to destroy.
@align(64) priv eval VEC_EMPTY: [u64; 8] = [0, 0, 0, 0, 0, 0, 0, 0]

/// Bytes in front of element 0: the capacity word, padded to the element's
/// alignment.
priv inline fn vec_header(elem_align: usize) -> usize {
    return if elem_align > sizeof usize => elem_align else => sizeof usize
}

priv inline fn vec_block_align(elem_align: usize) -> usize {
    return if elem_align > alignof usize => elem_align else => alignof usize
}

@cold_path @no_inline
priv fn vec_capacity_overflow() -> ! {
    __builtin_trap()
}

@cold_path @no_inline
priv fn vec_alloc_fail() -> ! {
    __builtin_trap()
}

/// `H + cap * elem_size`; traps when it does not fit in a usize.
priv inline fn vec_block_bytes(cap: usize, elem_size: usize, elem_align: usize) -> usize {
    var body: usize = 0
    if __builtin_mul_overflow(cap, elem_size, &body) {
        vec_capacity_overflow()
    }

    var bytes: usize = 0
    if __builtin_add_overflow(body, vec_header(elem_align), &bytes) {
        vec_capacity_overflow()
    }

    return bytes
}

/// The capacity a grower allocates: at least `need`, and at least double the
/// old one. The generic caller has already raised `need` to its element
/// type's minimum (`Vector::min_cap_`), a constant there, so no division by
/// the element size happens here.
priv inline fn vec_next_cap(old: usize, need: usize) -> usize {
    if old <= usize::MAX >> 1 && old * 2 > need {
        return old * 2
    }

    return need
}

/// A new block for exactly `cap` elements (`cap > 0`); returns element 0,
/// with the capacity word written.
priv fn vec_alloc(cap: usize, elem_size: usize, elem_align: usize, zeroed: bool) -> unsafe *u8 {
    var bytes            = vec_block_bytes(cap, elem_size, elem_align)
    var al               = vec_block_align(elem_align)
    var blk:  unsafe *u8 = &null
    if zeroed {
        blk = kairo_global_alloc_zeroed(bytes, al)
    } else {
        blk = kairo_global_alloc(bytes, al)
    }

    if blk == &null {
        vec_alloc_fail()
    }

    unsafe {
        var nb: unsafe *u8 = blk + vec_header(elem_align)
        *((nb as unsafe *usize) - 1) = cap
        return nb
    }
}

/// Frees the block whose element 0 is `buf`, holding `cap > 0` elements.
priv inline fn vec_free(buf: unsafe *u8, cap: usize, elem_size: usize, elem_align: usize) {
    var h = vec_header(elem_align)
    unsafe {
        kairo_global_free(
            buf - h,
            h + cap * elem_size,
            vec_block_align(elem_align),
        )
    }
}

/// Tries to give the block whose element 0 is `buf` room for exactly
/// `new_cap` elements without moving it; on success the capacity word holds
/// `new_cap`.
priv fn vec_resize_in_place(buf:        unsafe *u8,
                            old_cap:    usize,
                            new_cap:    usize,
                            elem_size:  usize,
                            elem_align: usize) -> bool {
    var h     = vec_header(elem_align)
    var bytes = vec_block_bytes(new_cap, elem_size, elem_align)
    unsafe {
        if !kairo_global_resize(
            buf - h,
            h + old_cap * elem_size,
            bytes,
            vec_block_align(elem_align),
        ) {
            return false
        }

        *((buf as unsafe *usize) - 1) = new_cap
    }

    return true
}

/// Gives the block whose element 0 is `buf` room for exactly `new_cap`
/// elements, moving it if it must; the first `old_cap` elements' bytes go
/// with it. Valid only for relocatable elements.
priv fn vec_realloc(buf:        unsafe *u8,
                    old_cap:    usize,
                    new_cap:    usize,
                    elem_size:  usize,
                    elem_align: usize) -> unsafe *u8 {
    if vec_resize_in_place(buf, old_cap, new_cap, elem_size, elem_align) {
        return buf
    }

    var h                = vec_header(elem_align)
    var bytes            = vec_block_bytes(new_cap, elem_size, elem_align)
    var blk:  unsafe *u8 = &null
    unsafe {
        blk = kairo_global_realloc(
            buf - h,
            h + old_cap * elem_size,
            bytes,
            vec_block_align(elem_align),
        )
    }

    if blk == &null {
        vec_alloc_fail()
    }

    unsafe {
        var nb: unsafe *u8 = blk + h
        *((nb as unsafe *usize) - 1) = new_cap
        return nb
    }
}

/// The growth core shared by every relocatable element type, expanded into
/// both forms of grow_bytes below so the cold call is one function. `buf` is
/// element 0 of the current block, the shared empty header, or null (an
/// element aligned above 64 with no block). Gives element 0 of a block holding
/// at least `need` elements with the old ones in place; the capacity word in
/// front of it is written. realloc carries the whole old block, so `len` is
/// not needed.
priv macro vec_grow_body!(buf, need, elem_size, elem_align) {
    var ob:  unsafe *u8 = &null
    var old: usize      = 0
    if buf? {
        unsafe {
            ob  = buf as unsafe *u8
            old = *((ob as unsafe *const usize) - 1)
        }
    }

    var cap            = vec_next_cap(old, need)
    var nb: unsafe *u8 = &null
    if old == 0 {
        nb = vec_alloc(cap, elem_size, elem_align, false)
    } else {
        nb = vec_realloc(ob, old, cap, elem_size, elem_align)
    }

    unsafe {
        return nb as *u8
    }
}

// Growth for relocatable elements: byte-level, one copy for every `T`.
// Returns the new buffer; the header in front of it holds the new cap.
eval if defined!(__x86_64__) || defined!(__aarch64__) {
    @cold_path @preserve_most @no_inline
    priv fn grow_bytes(buf:        *u8?,
                       len:        usize,
                       need:       usize,
                       elem_size:  usize,
                       elem_align: usize) -> *u8 {
        vec_grow_body!(buf, need, elem_size, elem_align)
    }
} else {
    @cold_path @no_inline
    priv fn grow_bytes(buf:        *u8?,
                       len:        usize,
                       need:       usize,
                       elem_size:  usize,
                       elem_align: usize) -> *u8 {
        vec_grow_body!(buf, need, elem_size, elem_align)
    }
}

/// Two words, the same two as a `Slice<T>`: the conversion to a slice is a
/// reinterpretation. `[cap: usize]` sits just before element 0, padded to
/// `T`'s alignment. An empty vector points at a shared header with cap 0,
/// so push needs no null check (an over-aligned `T` uses null instead).
/// Slice members are reached through the one-hop lookup rule: `v.sort()`.
/// MOVE-ONLY: `copy()` duplicates. A literal `[a, b]` moves its temporaries in.
@relocatable
pub class <T> Vector {
    // Element 0. Never null, except for a `T` aligned above 64 with no block.
    // Elements [0, len) are live, [len, cap) are raw. cap is 0 exactly when
    // buf is the shared empty header (or null).
    priv var buf: *T?
    priv var len: usize

    pub fn Vector(self) {
        self.set_empty_()
    }

    pub fn <R impl ElemRange<T>> Vector(self, const r: R) requires T impl Copyable { // copies r.size() elements from r.data(); names no C++ type
        self.set_empty_()
        var n = r.size()
        if n == 0 {
            return
        }

        unsafe {
            var unsafe *nb = vec_alloc(n, sizeof T, alignof T, false) as unsafe *T
            Vector<T>::copy_run_(nb, r.data(), n)
            self.set_base_(nb)
        }

        self.len = n
    }

    @move pub fn Vector(self, other: Self) { // bitwise; other becomes empty
        unsafe {
            *(&self.buf as unsafe *usize) = *(&other.buf as unsafe *const usize)
        }

        self.len = other.len
        other.set_empty_()
        other.len = 0
    }

    pub fn op finally(self) {
        var c = self.cap_()
        Vector<T>::destroy_(self.base_(), self.len)
        if c != 0 {
            unsafe {
                vec_free(self.base_() as unsafe *u8, c, sizeof T, alignof T)
            }
        }
    }

    // A slice of a temporary vector dies with the statement. Until Tether.
    @implicit pub fn op as (const self) -> [const T;] {
        unsafe {
            return Slice<const T>(self.base_() as unsafe *const T, self.len)
        }
    }

    @implicit pub fn op as (self) -> [T;] {
        return Slice<T>(self.base_(), self.len)
    }

    @hot_path pub fn op []  (const self, i: usize) -> *const T { // traps
        @unlikely
        if i >= self.len {
            index_fail(i, self.len)
        }

        unsafe {
            return (self.base_() + i) as unsafe *const T as *const T
        }
    }

    @hot_path pub fn op []= (self, i: usize) -> *T { // traps
        @unlikely
        if i >= self.len {
            index_fail(i, self.len)
        }

        unsafe {
            return (self.base_() + i) as *T
        }
    }

    pub fn op []  (const self, r: Range<usize>) -> [const T;] {
        var hi = self.range_end_(r.begin, r.end, r.inclusive)
        unsafe {
            return Slice<const T>(
                (self.base_() + r.begin) as unsafe *const T,
                hi - r.begin,
            )
        }
    }

    pub fn op []= (self, r: Range<usize>) -> [T;] {
        var hi = self.range_end_(r.begin, r.end, r.inclusive)
        unsafe {
            return Slice<T>(self.base_() + r.begin, hi - r.begin)
        }
    }

    pub fn op []  (const self, r: RangeFrom<usize>) -> [const T;] {
        @unlikely
        if r.begin > self.len {
            range_fail(r.begin, self.len, self.len)
        }

        unsafe {
            return Slice<const T>(
                (self.base_() + r.begin) as unsafe *const T,
                self.len - r.begin,
            )
        }
    }

    pub fn op []= (self, r: RangeFrom<usize>) -> [T;] {
        @unlikely
        if r.begin > self.len {
            range_fail(r.begin, self.len, self.len)
        }

        unsafe {
            return Slice<T>(self.base_() + r.begin, self.len - r.begin)
        }
    }

    pub fn op []  (const self, r: RangeTo<usize>) -> [const T;] {
        var hi = self.range_end_(0, r.end, r.inclusive)
        unsafe {
            return Slice<const T>(self.base_() as unsafe *const T, hi)
        }
    }

    pub fn op []= (self, r: RangeTo<usize>) -> [T;] {
        var hi = self.range_end_(0, r.end, r.inclusive)
        return Slice<T>(self.base_(), hi)
    }

    pub fn op in (self) -> yield *T {
        var p = self.base_()
        unsafe {
            var e = p + self.len
            while p != e {
                yield p as *T
                p += 1
            }
        }
    }

    pub fn op in (const self) -> yield *const T {
        var p = self.base_()
        unsafe {
            var e = p + self.len
            while p != e {
                yield p as unsafe *const T as *const T
                p += 1
            }
        }
    }

    @cold_path @no_inline
    priv fn grow_moving(self, need: usize) { // elements that are not relocatable
        // Compiled only where it can be called: the class is instantiated
        // whole, and a relocatable T grows through grow_bytes.
        eval if !__builtin_is_trivially_relocatable<T>() {
            var old = self.cap_()
            var cap = vec_next_cap(old, Vector<T>::min_need_(need))
            var ob  = self.base_()
            unsafe {
                if old != 0
                    && vec_resize_in_place(
                        ob as unsafe *u8,
                        old,
                        cap,
                        sizeof T,
                        alignof T,
                    ) {
                    return
                }
            }

            unsafe {
                var unsafe *nb = vec_alloc(cap, sizeof T, alignof T, false) as unsafe *T
                for var i: usize = 0; i < self.len; ++i {
                    __builtin_construct_at<T>(
                        (nb + i) as unsafe *u8,
                        move(*(ob + i)),
                    )

                    __builtin_destruct_at((ob + i) as *T)
                }

                if old != 0 {
                    vec_free(ob as unsafe *u8, old, sizeof T, alignof T)
                }

                self.set_base_(nb)
            }
        } else {
            __builtin_trap()
        }
    }

    // --- the funnel ---------------------------------------------------------

    /// Element 0: the block, the shared empty header, or null for a `T`
    /// aligned above 64 with no block. Not dereferenced unless `len > 0`.
    prot inline fn base_(const self) -> unsafe *T {
        unsafe {
            return *(&self.buf as unsafe *const unsafe *T)
        }
    }

    /// One load from the word in front of element 0.
    prot inline fn cap_(const self) -> usize {
        eval if __builtin_align_of<T>() > 64 {
            if self.base_() == &null {
                return 0
            }
        }

        unsafe {
            return *((self.base_() as unsafe *const usize) - 1)
        }
    }

    prot inline fn len_(const self) -> usize {
        return self.len
    }

    prot inline fn set_len_(self, n: usize) {
        self.len = n
    }

    priv inline fn set_base_(self, p: unsafe *T) {
        unsafe {
            *(&self.buf as unsafe *unsafe *T) = p
        }
    }

    priv inline fn set_empty_(self) {
        eval if __builtin_align_of<T>() > 64 {
            self.buf = null
        } else {
            unsafe {
                self.set_base_(
                    ((&VEC_EMPTY[7] as unsafe *const u64) + 1) as unsafe *T,
                )
            }
        }
    }

    /// Grows to hold at least `need` elements, keeping the live ones.
    priv inline fn grow_to_(self, need: usize) {
        eval if __builtin_is_trivially_relocatable<T>() {
            unsafe {
                var *nb = grow_bytes(
                    self.base_() as unsafe *u8 as *u8?,
                    self.len,
                    Vector<T>::min_need_(need),
                    sizeof T,
                    alignof T,
                )

                self.set_base_(nb as unsafe *u8 as unsafe *T)
            }
        } else {
            self.grow_moving(need)
        }
    }

    /// The exclusive end of `lo..end` (`lo..=end` when `inclusive`); traps
    /// unless the range lies inside `[0, len]`.
    priv inline fn range_end_(const self, lo: usize, end: usize, inclusive: bool) -> usize {
        var hi = end
        if inclusive {
            @unlikely
            if end >= self.len {
                range_fail(lo, end, self.len)
            }

            hi = end + 1
        }

        @unlikely
        if lo > hi || hi > self.len {
            range_fail(lo, hi, self.len)
        }

        return hi
    }

    /// Writes `n` copies of `v` into the raw slots at `dst`.
    priv static inline fn fill_run_(dst: unsafe *T, const v: T, n: usize) requires T impl Copyable {
        unsafe {
            eval if Vector<T>::bitwise_copy_() {
                for var i: usize = 0; i < n; ++i {
                    __builtin_copy(
                        (dst + i) as unsafe *u8,
                        &v as unsafe *const T as unsafe *const u8,
                        sizeof T,
                    )
                }
            } else {
                for var i: usize = 0; i < n; ++i {
                    __builtin_construct_at<T>((dst + i) as unsafe *u8, copy(v))
                }
            }
        }
    }

    /// The default `T` is all zero bytes: the primitives, whose default is
    /// zero.
    priv static eval fn zero_default_() -> bool {
        return __builtin_is_integral<T>() || __builtin_is_floating_point<T>()
    }

    // --- element runs -------------------------------------------------------

    /// Moves the value out of `*p`, leaving the slot raw.
    prot static inline fn take_(p: unsafe *T) -> T {
        unsafe {
            var t = move(*p)
            eval if !__builtin_is_trivially_destructible<T>() {
                __builtin_destruct_at(p as *T)
            }

            return t
        }
    }

    /// Destroys `n` live elements from `p`, back to front.
    prot static inline fn destroy_(p: unsafe *T, n: usize) {
        eval if !__builtin_is_trivially_destructible<T>() {
            var i = n
            while i != 0 {
                i -= 1
                unsafe {
                    __builtin_destruct_at((p + i) as *T)
                }
            }
        }
    }

    /// Relocates `n` live elements from `src` to `dst`; the ranges may
    /// overlap. Afterwards `dst` holds them and the part of `src` outside
    /// `dst` is raw.
    prot static inline fn relocate_(dst: unsafe *T, src: unsafe *T, n: usize) {
        if n == 0 {
            return
        }

        eval if __builtin_is_trivially_relocatable<T>() {
            // memmove is defined when dst == src: no test for it.
            unsafe {
                __builtin_move_mem(
                    dst as unsafe *u8,
                    src as unsafe *const u8,
                    n * sizeof T,
                )
            }
        } else {
            if dst == src {
                return
            }

            unsafe {
                if (dst as usize) < (src as usize) {
                    for var i: usize = 0; i < n; ++i {
                        __builtin_construct_at<T>(
                            (dst + i) as unsafe *u8,
                            move(*(src + i)),
                        )

                        __builtin_destruct_at((src + i) as *T)
                    }
                } else {
                    var i = n
                    while i != 0 {
                        i -= 1
                        __builtin_construct_at<T>(
                            (dst + i) as unsafe *u8,
                            move(*(src + i)),
                        )

                        __builtin_destruct_at((src + i) as *T)
                    }
                }
            }
        }
    }

    /// Copies `n` elements from `src` into the raw slots at `dst`; the ranges
    /// do not overlap.
    priv static inline fn copy_run_(dst: unsafe *T,
                                    src: unsafe *const T,
                                    n:   usize) requires T impl Copyable {
        eval if Vector<T>::bitwise_copy_() {
            unsafe {
                __builtin_copy(
                    dst as unsafe *u8,
                    src as unsafe *const u8,
                    n * sizeof T,
                )
            }
        } else {
            unsafe {
                for var i: usize = 0; i < n; ++i {
                    __builtin_construct_at<T>(
                        (dst + i) as unsafe *u8,
                        copy(*(src + i)),
                    )
                }
            }
        }
    }

    /// `need` raised to one cache line of elements, four at least: the
    /// smallest block a grower makes.
    priv static inline fn min_need_(need: usize) -> usize {
        var m: usize = 64 / sizeof T
        if m < 4 {
            m = 4
        }

        return if need < m => m else => need
    }

    /// A copy of a `T` is its bytes: its copy constructor is trivial (which
    /// a move-only class with a `copy()` method does not have).
    priv static eval fn bitwise_copy_() -> bool {
        return __builtin_is_trivially_copyable<T>()
            && __builtin_is_trivially_constructible<T, const T>()
    }
}

extend <T> Vector<T> {
    pub static fn with_capacity(n: usize) -> [T] {
        var v = Vector<T>()
        if n != 0 {
            unsafe {
                v.set_base_(
                    vec_alloc(n, sizeof T, alignof T, false) as unsafe *T,
                )
            }
        }

        return v
    }

    pub fn size(const self) -> usize {
        return self.len
    }

    pub fn is_empty(const self) -> bool {
        return self.len == 0
    }

    pub fn capacity(const self) -> usize {
        return self.cap_()
    }

    pub fn reserve(self, n: usize) {
        if n > self.cap_() {
            self.grow_to_(n)
        }
    }

    pub fn shrink_to_fit(self) {
        var c = self.cap_()
        if c == self.len {
            return
        }

        var ob = self.base_()
        if self.len == 0 {
            unsafe {
                vec_free(ob as unsafe *u8, c, sizeof T, alignof T)
            }

            self.set_empty_()
            return
        }

        eval if __builtin_is_trivially_relocatable<T>() {
            unsafe {
                self.set_base_(
                    vec_realloc(ob as unsafe *u8, c, self.len, sizeof T, alignof T) as unsafe *T,
                )
            }
        } else {
            unsafe {
                if vec_resize_in_place(
                    ob as unsafe *u8,
                    c,
                    self.len,
                    sizeof T,
                    alignof T,
                ) {
                    return
                }

                var unsafe *nb = vec_alloc(self.len, sizeof T, alignof T, false) as unsafe *T
                Vector<T>::relocate_(nb, ob, self.len)
                vec_free(ob as unsafe *u8, c, sizeof T, alignof T)
                self.set_base_(nb)
            }
        }
    }

    @hot_path pub fn push(self, v: T) {
        var n = self.len
        @unlikely
        if n == self.cap_() {
            self.grow_to_(n + 1)
        }

        unsafe {
            __builtin_construct_at<T>((self.base_() + n) as unsafe *u8, v)
        }

        self.len = n + 1
    }

    pub fn pop(self) -> T? {
        if self.len == 0 {
            return null
        }

        self.len -= 1
        unsafe {
            return Vector<T>::take_(self.base_() + self.len)
        }
    }

    pub fn insert(self, i: usize, v: T) {
        var n = self.len
        @unlikely
        if i > n {
            index_fail(i, n)
        }

        if n == self.cap_() {
            self.grow_to_(n + 1)
        }

        unsafe {
            var p = self.base_() + i
            Vector<T>::relocate_(p + 1, p, n - i)
            __builtin_construct_at<T>(p as unsafe *u8, v)
        }

        self.len = n + 1
    }

    pub fn remove(self, i: usize) -> T { // traps
        var n = self.len
        @unlikely
        if i >= n {
            index_fail(i, n)
        }

        unsafe {
            var p = self.base_() + i
            var t = Vector<T>::take_(p)
            Vector<T>::relocate_(p, p + 1, n - i - 1)
            self.len = n - 1
            return t
        }
    }

    pub fn swap_remove(self, i: usize) -> T { // traps
        var n = self.len
        @unlikely
        if i >= n {
            index_fail(i, n)
        }

        unsafe {
            var b = self.base_()
            var t = Vector<T>::take_(b + i)
            Vector<T>::relocate_(b + i, b + (n - 1), 1)
            self.len = n - 1
            return t
        }
    }

    pub fn drain(self, r: Range<usize>) -> Drain<T> {
        var hi  = self.range_end_(r.begin, r.end, r.inclusive)
        var old = self.len
        self.len = r.begin
        return Drain<T>(&self, r.begin, hi, old)
    }

    pub fn append(self, other: [T]) { // consumes other
        var m = other.len
        if m == 0 {
            return
        }

        // An empty vector takes other's block, unless its own already has
        // the room: a reserved block is kept, and the elements move into it.
        if self.len == 0 && self.cap_() < m {
            // Swapped, not overwritten: other's destructor frees this block.
            var mine = self.base_()
            self.set_base_(other.base_())
            other.set_base_(mine)
            self.len  = m
            other.len = 0
            return
        }

        var n = self.len
        self.reserve(n + m)
        unsafe {
            Vector<T>::relocate_(self.base_() + n, other.base_(), m)
        }

        other.len = 0
        self.len  = n + m
    }

    pub fn retain(self, keep: fn(*const T) -> bool) {
        // len stays 0 while elements are moved: a trap in keep leaks the
        // rest rather than destroying an element twice.
        var n = self.len
        self.len = 0
        var b        = self.base_()
        var w: usize = 0
        unsafe {
            for var r: usize = 0; r < n; ++r {
                if keep((b + r) as unsafe *const T as *const T) {
                    Vector<T>::relocate_(b + w, b + r, 1)
                    w += 1
                } else {
                    Vector<T>::destroy_(b + r, 1)
                }
            }
        }

        self.len = w
    }

    pub fn truncate(self, n: usize) {
        var old = self.len
        if n >= old {
            return
        }

        // len first: a trap in a destructor cannot destroy an element twice.
        self.len = n
        unsafe {
            Vector<T>::destroy_(self.base_() + n, old - n)
        }
    }

    pub fn clear(self) {
        eval if __builtin_is_trivially_destructible<T>() {
            self.len = 0
        } else {
            self.truncate(0)
        }
    }
}

extend <T impl Default> Vector<T> {
    pub static fn with_len(n: usize) -> [T] {
        var v = Vector<T>()
        if n == 0 {
            return v
        }

        eval if Vector<T>::zero_default_() {
            unsafe {
                v.set_base_(
                    vec_alloc(n, sizeof T, alignof T, true) as unsafe *T,
                )
            }
        } else {
            unsafe {
                var unsafe *b = vec_alloc(n, sizeof T, alignof T, false) as unsafe *T
                v.set_base_(b)
                for var i: usize = 0; i < n; ++i {
                    __builtin_construct_at<T>(
                        (b + i) as unsafe *u8,
                        T::make_default(),
                    )
                }
            }
        }

        v.len = n
        return v
    }

    pub fn resize(self, n: usize) {
        var old = self.len
        if n <= old {
            self.truncate(n)
            return
        }

        self.reserve(n)
        unsafe {
            var b = self.base_()
            eval if Vector<T>::zero_default_() {
                __builtin_set_mem(
                    (b + old) as unsafe *u8,
                    0 as byte,
                    (n - old) * sizeof T,
                )
            } else {
                for var i = old; i < n; ++i {
                    __builtin_construct_at<T>(
                        (b + i) as unsafe *u8,
                        T::make_default(),
                    )
                }
            }
        }

        self.len = n
    }
}

extend <T impl Copyable> Vector<T> {
    pub fn copy(const self) -> Self { // deep
        var v = Vector<T>()
        var n = self.len
        if n == 0 {
            return v
        }

        unsafe {
            var unsafe *b = vec_alloc(n, sizeof T, alignof T, false) as unsafe *T
            Vector<T>::copy_run_(b, self.base_() as unsafe *const T, n)
            v.set_base_(b)
        }

        v.len = n
        return v
    }

    pub static fn filled(n: usize, const v: T) -> [T] {
        var out = Vector<T>()
        if n == 0 {
            return out
        }

        unsafe {
            var unsafe *b = vec_alloc(n, sizeof T, alignof T, false) as unsafe *T
            out.set_base_(b)
            Vector<T>::fill_run_(b, v, n)
        }

        out.len = n
        return out
    }

    pub static fn from_slice(const items: [const T;]) -> [T] {
        var v = Vector<T>()
        var n = items.count_()
        if n == 0 {
            return v
        }

        unsafe {
            var unsafe *b = vec_alloc(n, sizeof T, alignof T, false) as unsafe *T
            Vector<T>::copy_run_(b, items.first_(), n)
            v.set_base_(b)
        }

        v.len = n
        return v
    }

    pub fn resize(self, n: usize, const v: T) { // overloads resize(self, n) in the Default extend
        var old = self.len
        if n <= old {
            self.truncate(n)
            return
        }

        // `v` may be an element of this vector: keep its offset across the
        // growth and read it from the new block.
        var src = unsafe &v as usize
        var lo  = self.base_() as usize
        var off = src - lo
        var own = src >= lo && off < old * sizeof T
        self.reserve(n)
        if own {
            src = (self.base_() as usize) + off
        }

        unsafe {
            Vector<T>::fill_run_(
                self.base_() + old,
                *(src as unsafe *const T),
                n - old,
            )
        }

        self.len = n
    }

    pub fn extend_from(self, const items: [const T;]) {
        var m = items.count_()
        if m == 0 {
            return
        }

        // `items` may be a view of this vector: keep its offset across the
        // growth and read it from the new block.
        var n   = self.len
        var src = items.first_() as usize
        var lo  = self.base_() as usize
        var off = src - lo
        var own = src >= lo && off < n * sizeof T
        self.reserve(n + m)
        if own {
            src = (self.base_() as usize) + off
        }

        unsafe {
            Vector<T>::copy_run_(self.base_() + n, src as unsafe *const T, m)
        }

        self.len = n + m
    }
}

extend <T impl Eq> Vector<T> {
    pub fn dedup(self) {
        var n = self.len
        if n < 2 {
            return
        }

        self.len = 0
        var b        = self.base_()
        var w: usize = 1
        unsafe {
            for var r: usize = 1; r < n; ++r {
                if *(b + r) == *(b + (w - 1)) {
                    Vector<T>::destroy_(b + r, 1)
                } else {
                    Vector<T>::relocate_(b + w, b + r, 1)
                    w += 1
                }
            }
        }

        self.len = w
    }
}

extend <T> Vector<T> impl FromIterator<T> {
    static fn <J impl Iterator> from_iter(it:   J,
                                          hint: usize) -> Self requires __builtin_is_same<J::Item, T>() {
        var v = Vector<T>()
        v.reserve(hint)
        loop {
            var x = it.next()
            // COMPILER-WORKAROUND(dependent-narrow): `if x?` does not narrow
            // a `J::Item?` in the emitted C++ of a static of a generic extend
            // block when `Item` is a class (the nullable itself reaches
            // push), and `unwrap!(x)` names the variable, so it is moved.
            if x? {
                v.push(move(unwrap!(x)))
            } else {
                break
            }
        }

        return v
    }
}

/// Move-only: it points into the vector and closes the gap when it ends,
/// so a copy would close it twice.
///
/// While it lives the vector's length is the start of the drained range;
/// the vector must not be used until the drain ends. Elements [head, tail)
/// are still to be yielded; the kept tail is [tail, end) and moves down to
/// the start of the range at the end.
pub class <T> Drain {
    priv var vec:  *Vector<T>
    priv var head: usize
    priv var tail: usize
    priv var end:  usize

    prot fn Drain(self, v: *Vector<T>, head: usize, tail: usize, end: usize) {
        self.vec  = v
        self.head = head
        self.tail = tail
        self.end  = end
    }

    @move pub fn Drain(self, other: Self) {
        self.vec   = other.vec
        self.head  = other.head
        self.tail  = other.tail
        self.end   = other.end
        other.head = 0
        other.tail = 0
        other.end  = 0
    }

    pub fn op finally(self) { // drops the rest, closes the gap
        var kept = self.end - self.tail
        if self.head == self.tail && kept == 0 {
            return
        }

        var b  = self.vec->base_()
        var lo = self.vec->len_()
        unsafe {
            Vector<T>::destroy_(b + self.head, self.tail - self.head)
            Vector<T>::relocate_(b + lo, b + self.tail, kept)
        }

        self.vec->set_len_(lo + kept)
        self.head = 0
        self.tail = 0
        self.end  = 0
    }
}

extend <T> Drain<T> impl DoubleEnded {
    type Item = T
    fn next(self) -> T? {
        if self.head == self.tail {
            return null
        }

        var i = self.head
        self.head = i + 1
        unsafe {
            return Vector<T>::take_(self.vec->base_() + i)
        }
    }

    fn next_back(self) -> T? {
        if self.head == self.tail {
            return null
        }

        // The slot taken is closed at once by moving the kept tail down one,
        // so the kept tail always starts at `tail`: four words hold no other
        // record of where it starts. Free when the range reaches the end.
        self.tail -= 1
        unsafe {
            var p = self.vec->base_() + self.tail
            var t = Vector<T>::take_(p)
            Vector<T>::relocate_(p, p + 1, self.end - self.tail - 1)
            self.end -= 1
            return t
        }
    }
}

extend <T> Drain<T> impl ExactSize {
    fn remaining(const self) -> usize {
        return self.tail - self.head
    }
}

extend <T> Vector<T> impl Default {
    static inline fn make_default() -> Vector<T> {
        return Vector<T>()
    }
}
