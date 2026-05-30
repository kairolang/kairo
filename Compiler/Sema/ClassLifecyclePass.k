// =============================================================================
// Class lifecycle semantics copy/move/destruction rules
// =============================================================================
//
// A class declares its lifecycle category through which transfer constructors
// it defines. The category is enforced at declaration time and propagated to
// callsites by AMT.
//
// 1. CONSTRUCTOR FORMS
// --------------------
//   - Default ctor:    fn Class(self, ...)
//   - Copy ctor:       @copy fn Class(self, other: Self)
//   - Move ctor:       @move fn Class(self, other: Self)
//   - Destructor:      fn op delete(self)
//
//   A ctor with signature (self, other: Self) and no attribute defaults to @copy.
//
// 2. MUTUAL EXCLUSION
// -------------------
//   A class may define EITHER @copy OR @move, never both.
//   Defining both is a compile error.
//
//      class Buffer {
//          @copy
//          fn Buffer(self, other: Self) = default   // OK: copy class
//      }
//
//      class UniqueFile {
//          @move
//          fn UniqueFile(self, other: Self) = default  // OK: move class
//      }
//
//      class Bad {
//          @copy fn Bad(self, other: Self) = default
//          @move fn Bad(self, other: Self) = default       // ERROR: cannot define both
//      }
//
// 3. CLASS LIFECYCLE CATEGORIES
// -----------------------------
//   - COPY:        has @copy ctor (explicit or implicit), allows copy + move-as-copy
//   - MOVE:        has @move ctor, only allows move, copy is forbidden
//   - NON_TRANSFER: both @copy and @move are = delete'd, neither copy nor move allowed
//   - DEFAULT (no transfer ctor declared): treated as COPY with compiler-generated members
//
// 4. RULE OF THREE
// ----------------
//   The user defines at most:
//     1. The default constructor
//     2. The copy OR move constructor (one, never both)
//     3. The destructor (op delete)
//
//   Each may be: a user body, = default, or = delete.
//
//   Exmaple of a user-defined copy class with custom destructor:
//     class Buffer {
//         var data: *u8
//         fn Buffer(self, size: usize) {
//             self.data = std::alloc<u8>(size)
//         }
//
//         @move
//         fn Buffer(self, other: Self) {
//             self.data  = other.data
//             other.data = null
//         }
//
//         fn op delete(self) {
//             std::free(self.data)
//         }
//     }
//
//   The user CANNOT write op =. It is auto-derived.
//
// 5. op = AUTO-DERIVATION
// -----------------------
//   op = is generated automatically based on the transfer ctor:
//
//     ctor form              ->  op = form
//     -----------------------------------------------------------------
//     = default              ->  = default
//     = delete               ->  = delete
//     { body }               ->  { self.~Class(); <ctor body>; return self }
//
//   The body case auto-invokes the destructor on self before running the
//   ctor body. This handles the self-overwrite case (a = b) correctly without
//   user effort.
//
//   Writing op = explicitly is dissalowed and is a compile error. This may change if there is real need for user-defined assignment logic.
//
// 6. DESTRUCTOR CONSISTENCY
// -------------------------
//   If the transfer ctor has a body AND op delete is = delete'd:
//     -> compile error
//     -> "auto-derived op = requires destructor invocation, but op delete is deleted"
//
//   Fix: provide a destructor (or = default), or change the transfer ctor to
//   = default / = delete.
//
// 7. NON-TRANSFERABLE CLASSES
// ---------------------------
//   To make a class neither copyable nor movable (e.g., for scope guards),
//   = delete both attributes:
//
//      class ScopeLock {
//          fn ScopeLock(self) = default
//          @copy fn ScopeLock(self, other: Self) = delete
//          @move fn ScopeLock(self, other: Self) = delete
//          fn op delete(self) { /* ... */ }
//      }
//
//   Such a class is stack-only and cannot be assigned, copied, or moved.
//   Any attempt produces a compile error.
//
// 8. DEFAULT CLASS (NO TRANSFER CTOR)
// -----------------------------------
//   If a class declares no @copy or @move ctor, it is implicitly COPY.
//   Compiler generates:
//     - Default constructor (memberwise default-init, iff all fields are default-constructible)
//     - Copy ctor (memberwise copy)
//     - op = (memberwise copy assign)
//     - Destructor (memberwise destroy in reverse declaration order)
//
//   WARNING: a class with a custom destructor but no explicit @copy / @move
//   ctor triggers a warning. The class is implicitly copyable but the custom
//   destructor suggests it manages a resource copying may cause double-free
//   or aliasing bugs.
//
//      class UniqueFile {
//          var handle: unsafe *void
//          fn op delete(self) { close_file(self.handle) }
//          // WARN: custom dtor with implicit copy ctor; likely incorrect.
//          //   help: declare as @move:
//          //           @move fn UniqueFile(self, other: Self) = default
//          //   help: or delete copy explicitly:
//          //           @copy fn UniqueFile(self, other: Self) = delete
//      }
//
// 9. INHERITANCE
// --------------
//   A derived class must match its base's lifecycle category:
//     - Base is COPY  -> derived must be COPY or NON_TRANSFER
//     - Base is MOVE  -> derived must be MOVE or NON_TRANSFER
//     - Base is NON_TRANSFER -> derived must be NON_TRANSFER
//
//   Mismatching categories is a compile error.
//
// 10. GENERIC CONSTRAINTS AND TYPE PARAMETERS
// -------------------------------------------
//   Type parameters accept any T by default. Whether a specific T is valid
//   for a given instantiation depends on what the body does with it:
//
//     - Body uses T only by reference (*T, *const T, etc...):
//         any T is acceptable, including NON_TRANSFER.
//     - Body copies T:
//         T must be COPY (or AMT proves all copies elide to moves).
//     - Body moves T:
//         T must be COPY or MOVE.
//     - Body returns T by value:
//         T must be COPY or MOVE.
//
//   Errors fire at instantiation with diagnostics pointing to both the body
//   operation that requires the capability and the type that lacks it.
//
//   This matches C++'s duck-typed template model: instantiation succeeds if
//   the body's operations on T are compatible with T's actual capabilities.
//
//   Explicit bounds may be added to document intent or fail-fast at the
//   constraint check rather than at the offending body operation:
//
//     fn <T: class>  process(item: T)        { ... }   // T must be a class
//     fn <T: struct> serialize(item: T)      { ... }   // T must be a struct
//     fn <T: enum>   stringify(item: T)      { ... }   // T must be an enum
//     fn <T: union>  inspect(item: T)        { ... }   // T must be a union
//     fn <T impl std::Moveable>  store(item: T) -> T     { ... }   // T must be COPY class
//     fn <T impl std::Copyable>  consume(item: T)        { ... }   // T must be MOVE class
//     fn <T>         identity(item: T) -> T  { ... }   // any T (inferred bound)
//
//   Bounds are checked at instantiation. Failure at the bound produces a
//   clearer diagnostic than failure mid-body.
//
// 11. Compiler-synthesized construction
// -----------------
//   Compiler-synthesized:
//     - fn MyClass(self) = default
//     - @copy fn MyClass(self, other: Self) = default
//     - @move fn MyClass(self, other: Self) = default
//     - fn op delete(self) = default
//   Does:
//     CLAUDE THIS IS IDENTIACL TO C++ BEHAVIOUR, dont mention c++, but restate in your own words
//
// 12. AMT COPY ELISION
// --------------------
//   For COPY classes, AMT may silently emit a move instead of a copy when
//   it proves the source is unused after the transfer. This is a pure
//   optimization with no observable semantic difference the source is
//   destroyed either way, just earlier when elided.
//
//   Users do not opt into or out of this optimization. It is invisible.
//   AMT does not do this if the move ctor is deleted.
//
// =============================================================================
virtual interface Foo {
    fn bar(self) -> i32
    fn Foo(self)
    @move fn Foo(self, other: Self)
    fn op delete (self)
}

class Bar impl Foo {
    var x: i32
    fn bar(self) -> i32 { return self.x }
    fn Foo(self) = default
    @move fn Foo(self, other: Self) = default
    fn op delete (self) = default
}

var bs: [Foo] = [Bar(42), Bar(43)]
var fs: [*Foo] = [*bs] // or even:
fs[0] = &bs[0]
fs[0].bar() // 42