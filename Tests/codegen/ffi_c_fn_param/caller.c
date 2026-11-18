/* Corpus for ffi_c_fn_param/apply.k. kairo_apply is DEFINED in Kairo with
 * C linkage; to a C caller its `fn(i32) -> i32` parameter is an ordinary
 * function pointer. */
#include "caller.h"

int kairo_apply(int (*f)(int), int x);

static int twice(int x) { return x * 2; }

int c_drive(void) { return kairo_apply(twice, 21); }
