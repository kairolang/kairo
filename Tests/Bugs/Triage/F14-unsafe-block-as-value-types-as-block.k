// build: kairo F14-unsafe-block-as-value-types-as-block.k -o f25   (expect exit 0)
ffi "c" import "stdlib.h"

fn main() -> i32 {
    var p: unsafe *const u8 = unsafe { malloc(4) as unsafe *const u8 }   // SC028E
    unsafe { free(p as unsafe *void) }
    return 0
}
