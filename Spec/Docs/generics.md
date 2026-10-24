# Generics

How type parameters of [generic classes](/docs/language/classes/#generic-classes) and functions are constrained.

## Type parameter constraints

A generic body may use only what its bounds grant. The body is checked once, where it is defined, against its bounds, never per instantiation. Calling a method no bound declares, copying a `T` without a copy bound, or declaring `var x: T` without a constructor bound is a compile error in the generic itself.

**Implicit capabilities.** Every type parameter may be destroyed and moved without saying so. Instantiating with a type whose `op delete` is `= delete`, or whose category is NON_TRANSFER, is an error at the instantiation site. It names the generic's implicit requirement, not a line inside its body. (Opt-out syntax: TBD.)

Two kinds of bounds exist:

**Kind bounds** restrict `T` to a specific category of type declaration:

```kairo
fn <T: class>  process(item: T)   { ... }
fn <T: struct> serialize(item: T) { ... }
fn <T: enum>   stringify(item: T) { ... }
fn <T: union>  inspect(item: T)   { ... }
```

**Interface bounds** restrict `T` to types that satisfy a given [interface](/docs/language/interfaces/). The standard library will provide interfaces describing [lifecycle capabilities](/docs/language/classes-lifecycle/#lifecycle-categories), allowing constraints like "T must be copyable" or "T must be movable" to be written as interface bounds. The exact names and shapes of these interfaces are still being finalized in `std` write your own if you need them now:

```kairo
interface Copyable {
    @copy
    fn Copyable(self, const other: Self)
}

interface Defaultable {
    fn Defaultable(self)
}

fn <T impl Copyable> store(item: T) -> T { ... }
```

See [Requires Clauses](/docs/language/requires/) for the full constraint system.

---

## See also

- [Generic Classes](/docs/language/classes/#generic-classes)
- [Interfaces](/docs/language/interfaces/)
- [Interface Requirements](/docs/language/interfaces-requirements/)
- [Requires Clauses](/docs/language/requires/)
- [Where Clauses](/docs/language/where/)
- [Generic Functions](/docs/language/functions/#generic-functions)
- [Generic Structs](/docs/language/structures/#generic-structs)
- [Class Lifecycle](/docs/language/classes-lifecycle/#lifecycle-categories)
