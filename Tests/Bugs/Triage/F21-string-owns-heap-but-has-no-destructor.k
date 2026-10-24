// build: kairo F21-string-owns-heap-but-has-no-destructor.k --target=x86_64-unknown-linux-gnu -o f33 && valgrind --leak-check=full ./f33   (expect 0 bytes definitely lost; dynamic glibc target so valgrind sees malloc)
enum <T> Opt { None, Some { v: T } }

struct Note {
    var s: string
}

fn main() -> i32 {
    var n: i32 = 41
    var a = f"heap {n}"          // FmtBuf::finish: malloc'd, cap > 0
    var b = a                    // plain copy: shallow, nothing frees either
    var o: Opt<string> = .Some { v: f"opt {n}" }
    var o2 = o
    var note = Note { s: f"note {n}" }
    var note2 = note
    return 0
}
