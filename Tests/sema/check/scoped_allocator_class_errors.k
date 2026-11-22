// `@set_scoped_allocator(A)` on a class or struct: what it rejects. An A
// that is no ArenaAllocator (SC162E on the attribute); a method that cannot
// open the arena: a generator (SC367E), an expression body with no written
// return type (SC366E), a method of an `extend` when A is the type's
// own generic parameter (SC116E), each with a note at the attribute;
// arguments other than one type, and a second use on one type (SC366E); the
// attribute on an `extend` of a type that carries it (SC366E, the note at
// the type); and on an interface, an enum or a union (SC143E).
import builtin::base::alloc::*

class Arenas {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn arena_open() -> usize { return 1 }
    pub static fn arena_close(arena: usize) { }
    pub static fn arena_enter(arena: usize) -> usize { return 0 }
    pub static fn arena_leave(previous: usize) { }
    pub static fn arena_range(arena: usize) -> (unsafe *u8, unsafe *u8) { return (&null, &null) }
}

class NotArena {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
}

@set_scoped_allocator(NotArena)
class Wrong {
    var n: i32 = 0
    fn get(self) -> i32 { return self.n }
}

@set_scoped_allocator(Arenas)
class Gen {
    var n: i32 = 0
    fn numbers(self) -> yield i32 {
        yield self.n
    }
    fn inferred(self) = self.n
    fn written(self) -> i32 = self.n
    static fn make() -> i32 = 1
}

@set_scoped_allocator(A)
class <A impl ArenaAllocator> Pool {
    var n: i32 = 0
    fn get(self) -> i32 { return self.n }
}

extend <A impl ArenaAllocator> Pool<A> {
    fn more(self) -> i32 { return 1 }
}

@set_scoped_allocator(Arenas)
@set_scoped_allocator(Arenas)
class Twice { }

@set_scoped_allocator
class NoArg { }

@set_scoped_allocator(Arenas, Arenas)
struct TwoArgs { var a: i32 }

@set_scoped_allocator(in: Arenas)
class Keyword { }

@set_scoped_allocator(1 + 2)
class NotAType { }

@set_scoped_allocator(Arenas)
extend Gen {
    fn more(self) -> i32 { return 1 }
}

@set_scoped_allocator(Arenas)
interface Named { fn name(self) -> i32 }

@set_scoped_allocator(Arenas)
enum Color { Red, Green }

@set_scoped_allocator(Arenas)
union Bits { var a: i32 }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: scoped_allocator_class_errors.k:29:1: error [SC162E]: 'NotArena' does not conform to 'ArenaAllocator': no member 'resize' with the requirement's signature
// CHECK: alloc.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: required by this bound
// CHECK: scoped_allocator_class_errors.k:39:9: error [SC367E]: a 'yield' inside a '@set_scoped_allocator' scope: the generator would suspend with the scope still open on the thread
// CHECK: scoped_allocator_class_errors.k:35:1: note [SC367N]: the scope opens here
// CHECK: scoped_allocator_class_errors.k:41:8: error [SC366E]: '@set_scoped_allocator' on 'Gen' opens its arena in each method's block body; this method's expression body has no written return type ('-> T'), which a block body would not infer
// CHECK: scoped_allocator_class_errors.k:35:1: note [SC366N]: the attribute is here
// CHECK: scoped_allocator_class_errors.k:53:8: error [SC116E]: '@set_scoped_allocator' on 'Pool' with a generic parameter of 'Pool' as the allocator, in a method of an 'extend', is not yet supported
// CHECK: scoped_allocator_class_errors.k:46:1: note [SC116N]: the attribute is here
// CHECK: scoped_allocator_class_errors.k:57:1: error [SC366E]: '@set_scoped_allocator' is written twice on 'Twice': an object owns one arena
// CHECK: fix-it:"{{.*}}scoped_allocator_class_errors.k":{57:1-57:30}:""
// CHECK: scoped_allocator_class_errors.k:56:1: note [SC366N]: this one names the arena's allocator
// CHECK: scoped_allocator_class_errors.k:60:1: error [SC366E]: '@set_scoped_allocator' takes one argument, the allocator type: '@set_scoped_allocator(A)'; it has none
// CHECK: scoped_allocator_class_errors.k:63:1: error [SC366E]: '@set_scoped_allocator' takes one argument, the allocator type: '@set_scoped_allocator(A)'; it has 2
// CHECK: scoped_allocator_class_errors.k:66:1: error [SC366E]: '@set_scoped_allocator' takes one argument, the allocator type: '@set_scoped_allocator(A)'; a keyword argument names nothing it takes
// CHECK: scoped_allocator_class_errors.k:69:1: error [SC366E]: '@set_scoped_allocator' takes one argument, the allocator type: '@set_scoped_allocator(A)'; its argument must be a type
// CHECK: scoped_allocator_class_errors.k:72:1: error [SC366E]: '@set_scoped_allocator' cannot be written on an 'extend'; write it on the type's own declaration
// CHECK: fix-it:"{{.*}}scoped_allocator_class_errors.k":{72:1-72:30}:""
// CHECK: scoped_allocator_class_errors.k:36:1: note [SC366N]: 'Gen' is declared here
// CHECK: scoped_allocator_class_errors.k:77:1: error [SC143E]: '@set_scoped_allocator' applies only to a function, a block, or a class or struct
// CHECK: fix-it:"{{.*}}scoped_allocator_class_errors.k":{77:1-77:30}:""
// CHECK: scoped_allocator_class_errors.k:78:1: note [I900N]: the attribute is on this declaration
// CHECK: scoped_allocator_class_errors.k:80:1: error [SC143E]: '@set_scoped_allocator' applies only to a function, a block, or a class or struct
// CHECK: fix-it:"{{.*}}scoped_allocator_class_errors.k":{80:1-80:30}:""
// CHECK: scoped_allocator_class_errors.k:81:1: note [I900N]: the attribute is on this declaration
// CHECK: scoped_allocator_class_errors.k:83:1: error [SC143E]: '@set_scoped_allocator' applies only to a function, a block, or a class or struct
// CHECK: fix-it:"{{.*}}scoped_allocator_class_errors.k":{83:1-83:30}:""
// CHECK: scoped_allocator_class_errors.k:84:1: note [I900N]: the attribute is on this declaration
