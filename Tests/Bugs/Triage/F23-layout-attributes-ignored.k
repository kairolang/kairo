// build: kairo F23-layout-attributes-ignored.k   (expect "5 16", exit 0; and @bitfield/@voided to be diagnosed or honored)
import std::io

@packed
struct Header {
    var tag: u8
    var len: u32
}

@align(16)
struct Vec4 {
    var x: f32
}

@bitfield(3)            // not a known attribute: no diagnostic today
struct Flags { var bits: u8 }

@voided                 // not a known attribute: no diagnostic today
struct Marker { var m: u8 }

fn main() -> i32 {
    io::println(f"{sizeof Header} {alignof Vec4}")
    if (sizeof Header != 5) || (alignof Vec4 != 16) { return 1 }
    return 0
}
