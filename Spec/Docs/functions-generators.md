# Generators

A function is a **generator** when its return type is written `-> yield T`. Calling it does not run the body;
it returns a sequence that runs the body a step at a time as values are asked for, most often by a [`for` loop](/docs/language/control-flow/#for-range-and-iterator).

```kairo
fn generate_numbers() -> yield i32 {
    for i in 0..10 {
        yield i
    }
}

for n in generate_numbers() {
    std::println(n)
}
```

Only the written return type makes a generator. A spelled-out `-> Yield<T>` is an ordinary function that
returns a `Yield<T>` value, and a `yield` in the body does not turn a function into a generator.

In a generator's body:

- `yield e` produces the next value. `e` must convert to `T`.
- Yielding a slice literal is an error: its backing array ends at the suspension, before the caller sees the
  value.
- A bare `return` ends the sequence early. `return e` is an error, since a generator has no return value.
- Falling off the end of the body also ends the sequence. There is no missing-return error.
- A generator with no `yield` at all is valid and produces nothing.

```kairo
fn first_positive(xs: [i32;]) -> yield i32 {
    for x in xs {
        if x > 0 {
            yield x
            return      // ok: ends the sequence
        }
    }
}                       // ok: falling off the end also ends it
```

`yield` is an error ([SC111E](/docs/language/diagnostics/#sc111e-yield-where-nothing-can-yield)):

- outside a function;
- inside a [closure](/docs/language/closures/) (closures cannot yield yet);
- in a function not declared `-> yield T`.

These functions cannot be generators ([SC112E](/docs/language/diagnostics/#sc112e-this-kind-of-function-cannot-be-a-generator)): `main`, constructors, destructors (`op delete`), `eval`
functions, C-variadic functions, and functions returning `!`.

## Generator lifetimes

A generator can do one thing an ordinary function cannot: its suspended body keeps references to `self` and
to [`@inout` arguments](/docs/language/functions-parameter-modes/) after the call that created it has returned.

- A loop like `for x in xs.gen()` keeps `xs` alive for the whole loop, so it is safe.
- A generator stored in a variable can outlive what it refers to, and then dangles.

Do not keep a generator longer than the object it was created from.

```kairo
var it = make_list().gen()   // the list is destroyed at the end of this statement
for x in it { }              // it reads a destroyed list
```

> [!NOTE]
> The current compiler does not report a generator that outlives what it refers to. See
> [Implementation Status](/docs/status/#not-diagnosed).

## Special return types

These return type modifiers interact with Kairo's concurrency and type system. Each is covered in detail on
its respective page:

| Return type | Description | Details |
|---|---|---|
| `yield T` | Generator: produces a sequence of `T` values | [Generators](#generators) |
| `atomic T` | Atomic wrapper thread-safe operations | [Concurrency](/docs/language/concurrency/) |
| `thread T` | Thread-local storage | [Concurrency](/docs/language/concurrency/) |

## See also

- [Functions](/docs/language/functions/)
- [Default, Named, and Variadic Parameters](/docs/language/functions-parameters/)
- [Parameter Passing Modes](/docs/language/functions-parameter-modes/)
- [Function Overloading](/docs/language/functions-overloading/)
- [Function Declarations](/docs/language/functions-declarations/)
- [Control Flow](/docs/language/control-flow/)
- [Concurrency](/docs/language/concurrency/)
- [Closures](/docs/language/closures/)
- [Diagnostics](/docs/language/diagnostics/)
