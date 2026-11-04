// Corpus for main.k: the demanding TU, whose header set holds the definition.
ffi "c++" import "def.h"

pub fn count() -> u32 {
    var s: Str<64>
    s.push_back(1)
    return s.size()
}
