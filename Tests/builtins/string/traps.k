// A byte offset that is out of range or inside a char is checked in every
// build: the operation traps and leaves no half-made string. The number of
// arguments picks the case; with none, the same operations at valid offsets
// all succeed.

fn main(argc: i32) -> i32 {
    var kind = argc - 1
    var text = "aé€😀z" // boundaries at 0 1 3 6 10 11
    var s    = text.to_owned()
    var n: usize = 0

    if kind == 0 {
        n += s[1] as usize
        n += s[1..3].size() + s[6..].size() + s[..10].size()
        s.insert(3, "x")
        s.remove_range(3usize..4usize)
        s.truncate(10)
        var ok = string(text.data(), 6)
        return (s.size() + ok.size() - 16) as i32
    }

    if kind == 1 { n += s[2] as usize }                  // inside é
    if kind == 2 { n += s[11] as usize }                 // the end is not a char
    if kind == 3 { n += s[2..6].size() }                 // start inside a char
    if kind == 4 { n += s[1..5].size() }                 // end inside a char
    if kind == 5 { n += s[1..12].size() }                // end past the length
    if kind == 6 { n += s[7..].size() }                  // from inside a char
    if kind == 7 { n += s[12..].size() }                 // from past the length
    if kind == 8 { n += s[..8].size() }                  // to inside a char
    if kind == 9 { n += s[6..3].size() }                 // start after end
    if kind == 10 { s.insert(2, "x") }                   // insert inside a char
    if kind == 11 { s.insert(12, "x") }                  // insert past the end
    if kind == 12 { s.remove_range(1usize..2usize) }     // remove ends inside a char
    if kind == 13 { s.remove_range(4usize..6usize) }     // remove starts inside a char
    if kind == 14 { s.remove_range(6usize..12usize) }    // remove past the end
    if kind == 15 { s.truncate(9) }                      // truncate inside a char
    if kind == 16 { var v = text.view(); v.truncate(2) } // on a view too
    if kind == 17 { var bad = string(text.data(), 2) }   // bytes that end inside a char
    if kind == 18 {                                      // a lone continuation byte
        var bad = string(b"a\x80b")
    }

    if kind == 19 {                                      // a surrogate, encoded
        var bad = string(b"\xed\xa0\x80")
    }

    return (n + s.size()) as i32 & 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %t.o2.exe
// RUN: not --crash %t.exe 1
// RUN: not --crash %t.exe 1 2
// RUN: not --crash %t.exe 1 2 3
// RUN: not --crash %t.exe 1 2 3 4
// RUN: not --crash %t.exe 1 2 3 4 5
// RUN: not --crash %t.exe 1 2 3 4 5 6
// RUN: not --crash %t.exe 1 2 3 4 5 6 7
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19
// RUN: not --crash %t.o2.exe 1
// RUN: not --crash %t.o2.exe 1 2
// RUN: not --crash %t.o2.exe 1 2 3
// RUN: not --crash %t.o2.exe 1 2 3 4
// RUN: not --crash %t.o2.exe 1 2 3 4 5
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9 10
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9 10 11
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9 10 11 12
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9 10 11 12 13
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18
// RUN: not --crash %t.o2.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19
