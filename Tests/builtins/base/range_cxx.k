// `ByteRange` and `ElemRange<T>` are structural: the C++ standard library's
// contiguous types meet them as they are, with no declaration anywhere.
// `std::string` and `std::string_view` are byte ranges, `std::vector<T>`
// and `std::span<const T>` element ranges, and `string` builds from a byte
// range. `std::span<T>` over a mutable `T` does not conform: its `data()`
// returns `T*`, and a requirement returning `*const T` is met only by that
// exact signature.

ffi "c++" import "string"
ffi "c++" import "string_view"
ffi "c++" import "vector"
ffi "c++" import "span"

fn <S impl ByteRange> byte_sum(const s: S) -> u32 {
    var t: u32 = 0
    unsafe {
        var p = s.data() as unsafe *const u8
        for var i: usize = 0; i < s.size(); i++ {
            t += p[i] as u32
        }
    }

    return t
}

fn <R impl ElemRange<i32>> elem_sum(const r: R) -> i32 {
    var t = 0
    unsafe {
        var p = r.data()
        for var i: usize = 0; i < r.size(); i++ {
            t += p[i]
        }
    }

    return t
}

fn main() -> i32 {
    var cs  = cxx::std::string("abc")
    var sv  = cxx::std::string_view("de")
    var v   = cxx::std::vector<i32>()
    v.push_back(4)
    v.push_back(5)
    var sp  = cxx::std::span<const i32>(v.data(), v.size())
    var bad = 0
    if byte_sum(cs) != 97 + 98 + 99 {
        bad += 1
    }

    if byte_sum(sv) != 100 + 101 {
        bad += 2
    }

    if elem_sum(v) != 9 || elem_sum(sp) != 9 {
        bad += 4
    }

    var k = string(cs)
    if k.size() != 3 || k.data()[2] != 99 {
        bad += 8
    }

    return bad
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
