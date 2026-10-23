# Ownership and Promotion

Provenance and epochs govern whether an *access* is safe. A separate analysis governs *where a value
lives and who frees it*. Its residuals are Tier P (transformable) or Tier N (unfixable), never Tier
R there is no runtime check for "who owns this."

When Tether determines that a heap pointer needs ownership semantics, it selects a [smart pointer type](/docs/language/pointers/#smart-pointer-promotion)
from the pointer's whole-program usage. In **debug** it performs the promotion and warns; in
**release** it emits a hard error naming the type to annotate.

## `std::Unique<T>` single owner

Exactly one live binding holds the pointer at any point. Ownership may transfer between scopes; the
count of live owners is always one.

```kairo
fn make_config() -> *Config {
    var cfg = @create Config(8080)
    return cfg
    // debug: promote cfg -> std::Unique<Config>
    // release: error, annotate the return type
}
```

## `std::Shared<T>` multiple owners

Multiple live bindings refer to the same allocation and single ownership cannot be proven. The
allocation is reference-counted; the object is destroyed when the last `Shared` reference's scope
ends.

```kairo
fn share_config(a: *Server, b: *Server) {
    var cfg = @create Config(8080)
    a.config = cfg
    b.config = cfg
    // debug: promote cfg -> std::Shared<Config>
}
```

A short-lived alias that dies before the owner escapes does **not** force `Shared`. The trigger is
not "multiple pointers exist" but "multiple pointers are *live* at a point where shared ownership is
required for safety."

```kairo
var cfg = @create Config(8080)
{
    var tmp: *Config = cfg
    validate(tmp)
}                        // tmp is dead here
return cfg               // single owner at the escape -> Unique
```

## `std::Weak<*T>` back-reference

A pointer that, promoted to `Shared`, would close a reference cycle (A -> B -> A). `Weak` does not
contribute to the count and does not keep the target alive; access requires a liveness check.

```kairo
class Node {
    var child: *Node
    var parent: *Node     // points back at the owner -> Weak
}
```

## No promotion

A pointer whose lifetime is fully contained, or provably bounded by its referent's lifetime, stays a
plain `*T` with no overhead:

```kairo
fn process() {
    var data = @create Buffer(1024)
    fill(data)
    consume(data)
    @destroy data    // fully contained -> plain *T
}
```

Field access and interior pointers are covered in [Bounds and Provenance](/docs/language/tether-bounds/#field-access-and-interior-pointers).

---

## Stack Pointers

A stack value has no heap allocation behind it, so it cannot be promoted to a smart pointer. But the
(B) model splits stack escape into two cases by whether the value is **heap-promotable** that is,
whether Tether can mechanically rewrite the stack allocation into a [`@create`](/docs/language/pointers/#heap-allocation) call.

**Heap-promotable escape Tier P.** A plain local whose address escapes via return or store, where
the value's type can be heap-allocated:

```kairo
fn make() -> *i32 {
    var x = 42
    return &x
    // debug: rewrite `var x = 42` into `var x = @create i32(); *x = 42`,
    //        then promote the escaping pointer (Unique)
    // release: hard error, heap-allocate explicitly or restructure
}
```

In debug, Tether lifts `x` to the heap and the escape becomes a legal ownership transfer. In release
this is a hard error, because silently turning a stack allocation into a heap allocation in a
release binary is exactly the hidden allocation the language forbids. The diagnostic shows the fix:

```
error[Tether]: address of stack local 'x' escapes its scope
  --> src/m.k:3:12
   3 |     return &x
     |            ^^ 'x' is stack-allocated and destroyed at end of make()
  note: in debug, Tether would heap-promote: var x = @create i32()
  help: allocate on the heap explicitly, or restructure to avoid the escape
```

**Non-promotable escape Tier N.** A borrow with no value to lift (a pointer into a structure Tether
cannot heap-allocate, an escape into an opaque sink where Tether cannot even establish the
heap-allocation pattern) is a hard error in both modes. There is nothing to transform.

Dangling within a function is likewise a hard error in both modes the value is gone, there is no
allocation to lift, and the access is statically known to be invalid:

```kairo
fn also_bad() {
    var p: *i32
    {
        var x = 42
        p = &x
    }                  // x destroyed here (epoch incremented)
    *p = 10            // hard error: p's provenance epoch is stale
}
```

## See also

- [Tether](/docs/language/tether/)
- [Proof Model](/docs/language/tether-proof-model/)
- [Bounds and Provenance](/docs/language/tether-bounds/)
- [Threading](/docs/language/tether-threading/)
- [Tether Internals](/docs/language/tether-internals/)
- [Ownership](/docs/language/ownership/)
- [Pointers](/docs/language/pointers/)
- [Class Lifecycle](/docs/language/classes-lifecycle/)
