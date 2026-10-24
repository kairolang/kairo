// build: kairo F15-poisoned-cast-argument-cascades-into-sc063e.k --type-check-only   (expect SC023E only)
ffi "c" import "stdlib.h"

fn main() -> i32 {
    var p: unsafe *const u8
    unsafe { p = malloc(4) as unsafe *const u8 }
    free(p as unsafe *void)     // SC023E is right; the SC063E beside it is a cascade
    return 0
}
