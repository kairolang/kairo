// mem.k: @cxx::new / @cxx::delete, C++'s own new and delete, for memory
// that crosses to and from C++ (c-cpp-memory.mdx).
ffi "c++" import "gadget.h"

pub fn kairo_new_gadget(v: i32) -> unsafe *Gadget {
    return @cxx::new Gadget(v)
}

pub fn kairo_delete_gadget(g: unsafe *Gadget) {
    @cxx::delete g
}

pub fn kairo_new_gadgets(n: usize) -> unsafe *Gadget {
    return @cxx::new [Gadget; n]
}

pub fn kairo_delete_gadgets(g: unsafe *Gadget) {
    @cxx::delete [] g
}

pub fn kairo_new_ints(n: i32) -> unsafe *i32 {
    var unsafe *p = @cxx::new [i32; n]
    for var i: i32 = 0; i < n; ++i {
        unsafe { p[i] = (i + 1) * 10 }
    }
    return p
}

pub fn kairo_sum_delete_ints(p: unsafe *i32, n: i32) -> i32 {
    var s: i32 = 0
    for var i: i32 = 0; i < n; ++i {
        unsafe { s += p[i] }
    }
    @cxx::delete [] p
    return s
}
