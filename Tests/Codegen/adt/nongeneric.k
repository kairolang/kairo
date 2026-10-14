// A non-generic ADT's lifecycle is known when it is declared, so its record
// carries exactly the one form of each special member its payloads allow,
// with nothing left for C++ to choose: Note owns a string, so every one has
// a body that copies, moves or destroys the live payload; Point holds only
// integers, so every one is the defaulted, trivial one.

enum Note { Text { s: string, n: i32 }, Code { c: i32 }, Blank }
enum Point { At { x: i32, y: i32 }, Origin }

fn weight(const x: Note) -> i32 = match x {
    case .Text(const s, const n) => (s.len as i32) * 10 + n
    case .Code(const c)          => c
    case .Blank                  => 0
}

fn sum(p: Point) -> i32 = match p {
    case .At(var x, var y) => x + y
    case .Origin           => 0
}

fn main() -> i32 {
    var a = Note::Text { s: "abc", n: 4 }
    var b = a                                   // 34
    var c = Note::Code { c: 5 }
    c = a                                       // across tags: 34
    var d: Note = .Blank
    a = d                                       // 0
    var p = Point::At { x: 1, y: 2 }
    var q = p
    q = Point::Origin
    return weight(a) + weight(b) + weight(c) + sum(p) + sum(q)    // 0 + 34 + 34 + 3 + 0 == 71
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// Each record's special members are consecutive, one of each, and nothing
// in this file's records is constrained. Point comes first: Note waits for
// the string record it holds.
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}nongeneric.k
// CXX-NOT:   requires
// CXX:       struct Point {
// CXX:       Point(::__kairo_vt<1>) : __kairo_tag(__kairo_Tag::Origin) {
// CXX-NEXT:  }
// CXX-NEXT:  Point(const Point&) = default;
// CXX-NEXT:  Point(Point&&) = default;
// CXX-NEXT:  Point& operator=(const Point&) = default;
// CXX-NEXT:  Point& operator=(Point&&) = default;
// CXX-NEXT:  ~Point() = default;
// CXX-NEXT:  private{{ ?}}:
// CXX-NOT:   requires
// CXX:       struct Note {
// CXX:       Note(::__kairo_vt<2>) : __kairo_tag(__kairo_Tag::Blank) {
// CXX-NEXT:  }
// CXX-NEXT:  Note(const Note& o) : __kairo_tag(o{{ ?}}.{{ ?}}__kairo_tag) {
// CXX-NEXT:  __kairo_construct_from(o);
// CXX-NEXT:  }
// CXX-NEXT:  Note(Note&& o) : __kairo_tag(o{{ ?}}.{{ ?}}__kairo_tag) {
// CXX-NEXT:  __kairo_construct_from(static_cast<Note&&>(o));
// CXX-NEXT:  }
// CXX-NEXT:  Note& operator=(const Note& o) {
// CXX-NOT:   {{requires|= default|= delete|Note\(}}
// CXX:       Note& operator=(Note&& o) {
// CXX-NOT:   {{requires|= default|= delete|Note\(}}
// CXX:       ~Note() {
// CXX-NEXT:  __kairo_destroy();
// CXX-NEXT:  }
// CXX-NEXT:  private{{ ?}}:
// CXX-NOT:   requires

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 71
