// kcc_cxx_alloc_ops.k's module: Kairo records C++ news and deletes, and a
// counting global allocator that says which allocator served each block.
import builtin::base::alloc::*

static allocs: i32 = 0
static frees: i32 = 0
static last_size: usize = 0
static last_align: usize = 0

pub class Counting {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        allocs += 1
        last_size = size
        last_align = align
        return System::alloc(size, align)
    }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        frees += 1
        last_size = size
        last_align = align
        System::free(ptr, size, align)
    }
    static fn resize(ptr: unsafe *u8, o: usize, nn: usize, align: usize) -> bool { return System::resize(ptr, o, nn, align) }
    static fn realloc(ptr: unsafe *u8, o: usize, nn: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<Counting>(ptr, o, nn, align) }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return System::alloc_zeroed(size, align) }
}

@set_global_allocator(Counting)

pub fn n_allocs() -> i32 { return allocs }
pub fn n_frees() -> i32 { return frees }
pub fn size_seen() -> usize { return last_size }
pub fn align_seen() -> usize { return last_align }

pub class Point {
    var x: i32
    var y: i32
    pub fn Point(self, x: i32, y: i32) { self.x = x; self.y = y }
    pub fn sum(const self) -> i32 { return self.x + self.y }
}

pub struct Pair {
    var a: i64
    var b: i64
}

// Over-aligned: C++ picks the align_val_t forms.
@align(64) pub struct Wide {
    var v: i32
}

// Generic: Box<i32> is an instance this module names (extern template in
// the C++ view), Box<i64> one it never does.
pub class <T> Box {
    var v: T
    pub fn Box(self, v: T) { self.v = v }
    pub fn get(const self) -> T { return self.v }
}

pub enum Shape {
    Circle { r: i32 },
    Square { s: i32 },
}

pub fn area(s: *Shape) -> i32 = match *s {
    case .Circle(var r) => 3 * r * r
    case .Square(var s) => s * s
}

pub fn square(s: i32) -> Shape { return Shape::Square { s: s } }

pub fn box_get(b: *Box<i32>) -> i32 { return b->get() }

// The Kairo side of a crossing: create and destroy, the allocator's front end.
pub fn make_point(x: i32) -> *Point { return create<Point>(x, x) }
pub fn drop_point(p: *Point) { destroy<Point>(p) }
