// `@set_scoped_allocator(A)`: every position and argument form it rejects.
// SC366E for arguments that are not one type, a function with no body or
// with an expression body and no return type, and an `extend` (with a note
// at the extended type and a fix-it that removes the attribute); SC367E for
// a `yield` inside the scope, with a note at the attribute; SC162E on a
// class or struct, whose A must be an ArenaAllocator; SC143E anywhere else.
// A generator declared inside a scoped function is not inside the scope.
static buf: [u8; 64]
class Bump {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { unsafe { return &buf[0] as unsafe *u8 } }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return ptr }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return Bump::alloc(size, align) }
    pub static fn enter() -> usize { return 0 }
    pub static fn leave(m: usize) { }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { unsafe { return (&buf[0] as unsafe *u8, (&buf[0] as unsafe *u8) + 64) } }
}

class Parser {
    pub var n: i32 = 0
    fn Parser(self) = default
}

// The arena belongs to the type: SC366E, the note at 'class Parser'.
@set_scoped_allocator(Bump)
extend Parser {
    fn twice(self) -> i32 { return self.n * 2 }
}

// No body to open the scope in: a requirement, a defaulted constructor.
interface Shape {
    @set_scoped_allocator(Bump)
    fn area(self) -> i32
}

class Holder {
    @set_scoped_allocator(Bump)
    fn Holder(self) = default
}

// The return type of an expression body is inferred; a block body would
// make it void.
@set_scoped_allocator(Bump)
fn inferred() = 4

// The arguments: one type, nothing else.
@set_scoped_allocator
fn no_args() { }

@set_scoped_allocator(Bump, Bump)
fn two_args() { }

@set_scoped_allocator(in: Bump)
fn keyword_arg() { }

@set_scoped_allocator(1 + 2)
fn not_a_type() { }

// A `yield` inside the scope, of a function or of a block.
@set_scoped_allocator(Bump)
fn numbers() -> yield i32 {
    yield 1
}

fn block_numbers() -> yield i32 {
    @set_scoped_allocator(Bump) {
        yield 2
    }
    yield 3
}

// A generator declared inside the scope is not inside it: no error.
@set_scoped_allocator(Bump)
fn nested_gen() {
    fn local() -> yield i32 { yield 4 }
    for x in local() { }
}

// A class or struct takes an ArenaAllocator, which Bump is not.
@set_scoped_allocator(Bump)
class Pool { }

@set_scoped_allocator(Bump)
struct Pair { var a: i32 }

// Misplaced: an enum, an interface, a variable, a field, a statement that
// is not a block, an expression.
@set_scoped_allocator(Bump)
enum Color { Red, Green }

@set_scoped_allocator(Bump)
interface Named { fn name(self) -> i32 }

@set_scoped_allocator(Bump)
static counter: i32 = 0

class Fields {
    @set_scoped_allocator(Bump)
    pub var f: i32 = 0
}

fn call() -> i32 { return 1 }

fn main() -> i32 {
    @set_scoped_allocator(Bump)
    var x = 1
    @set_scoped_allocator(Bump)
    if x > 0 { x = 2 }
    @set_scoped_allocator(Bump) call()
    return x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: scoped_allocator_errors.k:26:1: error [SC366E]: '@set_scoped_allocator' cannot be written on an 'extend'; write it on the type's own declaration
// CHECK: fix-it:"{{.*}}scoped_allocator_errors.k":{26:1-26:28}:""
// CHECK: scoped_allocator_errors.k:20:1: note [SC366N]: 'Parser' is declared here
// CHECK: scoped_allocator_errors.k:33:5: error [SC366E]: '@set_scoped_allocator' needs a function body to open the scope in; this function has none
// CHECK: fix-it:"{{.*}}scoped_allocator_errors.k":{33:5-33:32}:""
// CHECK: scoped_allocator_errors.k:38:5: error [SC366E]: '@set_scoped_allocator' needs a function body to open the scope in; this function has none
// CHECK: fix-it:"{{.*}}scoped_allocator_errors.k":{38:5-38:32}:""
// CHECK: scoped_allocator_errors.k:44:1: error [SC366E]: '@set_scoped_allocator' on a function with an expression body needs the return type written ('-> T'): the scope opens in a block body, which does not infer one
// CHECK: scoped_allocator_errors.k:48:1: error [SC366E]: '@set_scoped_allocator' takes one argument, the allocator type: '@set_scoped_allocator(A)'; it has none
// CHECK: scoped_allocator_errors.k:51:1: error [SC366E]: '@set_scoped_allocator' takes one argument, the allocator type: '@set_scoped_allocator(A)'; it has 2
// CHECK: scoped_allocator_errors.k:54:1: error [SC366E]: '@set_scoped_allocator' takes one argument, the allocator type: '@set_scoped_allocator(A)'; a keyword argument names nothing it takes
// CHECK: scoped_allocator_errors.k:57:1: error [SC366E]: '@set_scoped_allocator' takes one argument, the allocator type: '@set_scoped_allocator(A)'; its argument must be a type
// CHECK: scoped_allocator_errors.k:63:5: error [SC367E]: a 'yield' inside a '@set_scoped_allocator' scope: the generator would suspend with the scope still open on the thread
// CHECK: scoped_allocator_errors.k:61:1: note [SC367N]: the scope opens here
// CHECK: scoped_allocator_errors.k:68:9: error [SC367E]: a 'yield' inside a '@set_scoped_allocator' scope: the generator would suspend with the scope still open on the thread
// CHECK: scoped_allocator_errors.k:67:5: note [SC367N]: the scope opens here
// CHECK: scoped_allocator_errors.k:81:1: error [SC162E]: 'Bump' does not conform to 'ArenaAllocator': no member 'arena_open' with the requirement's signature
// CHECK: scoped_allocator_errors.k:89:1: error [SC143E]: '@set_scoped_allocator' applies only to a function, a block, or a class or struct
// CHECK: fix-it:"{{.*}}scoped_allocator_errors.k":{89:1-89:28}:""
// CHECK: scoped_allocator_errors.k:90:1: note [I900N]: the attribute is on this declaration
// CHECK: scoped_allocator_errors.k:92:1: error [SC143E]: '@set_scoped_allocator' applies only to a function, a block, or a class or struct
// CHECK: fix-it:"{{.*}}scoped_allocator_errors.k":{92:1-92:28}:""
// CHECK: scoped_allocator_errors.k:93:1: note [I900N]: the attribute is on this declaration
// CHECK: scoped_allocator_errors.k:95:1: error [SC143E]: '@set_scoped_allocator' applies only to a function, a block, or a class or struct
// CHECK: fix-it:"{{.*}}scoped_allocator_errors.k":{95:1-95:28}:""
// CHECK: scoped_allocator_errors.k:96:1: note [I900N]: the attribute is on this declaration
// CHECK: scoped_allocator_errors.k:99:5: error [SC143E]: '@set_scoped_allocator' applies only to a function, a block, or a class or struct
// CHECK: fix-it:"{{.*}}scoped_allocator_errors.k":{99:5-99:32}:""
// CHECK: scoped_allocator_errors.k:100:9: note [I900N]: the attribute is on this declaration
// CHECK: scoped_allocator_errors.k:106:5: error [SC143E]: '@set_scoped_allocator' applies only to a function, a block, or a class or struct
// CHECK: fix-it:"{{.*}}scoped_allocator_errors.k":{106:5-106:32}:""
// CHECK: scoped_allocator_errors.k:107:5: note [I900N]: the attribute is on this declaration
// CHECK: scoped_allocator_errors.k:108:5: error [SC143E]: '@set_scoped_allocator' applies only to a function, a block, or a class or struct
// CHECK: fix-it:"{{.*}}scoped_allocator_errors.k":{108:5-108:32}:""
// CHECK: scoped_allocator_errors.k:109:5: note [I900N]: the attribute is on this statement
// CHECK: scoped_allocator_errors.k:110:5: error [SC143E]: '@set_scoped_allocator' applies only to a function, a block, or a class or struct; it does not apply to an expression
