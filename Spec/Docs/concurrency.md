# Concurrency

> [!IMPORTANT]
> This page is under development. The concurrency model is being designed. Full documentation will
> be added once the design is finalized.

Kairo's concurrency system provides async/await, coroutines, and thread-level primitives. The
following features are planned and referenced across the existing documentation:

### Async/Await

The `async` modifier on functions and the `await` keyword for waiting on asynchronous results.
See [Functions](/docs/language/functions#function-modifiers) for the `async` modifier.

### Coroutines (`yield`)

Functions with a `yield T` return type produce values cooperatively. The `yield` keyword suspends
the function and produces a value to the caller. See
[Functions](/docs/language/functions#special-return-types) for yield return types.

### `spawn`

Launching concurrent work. Syntax and runtime model (green threads, OS threads, or event loop) are
being finalized.

### Atomic Types (`atomic T`)

Thread-safe wrapper type for lock-free operations. Referenced in
[Functions](/docs/language/functions#special-return-types).

### Thread-Local Storage (`thread T`)

Per-thread storage modifier. Referenced in
[Functions](/docs/language/functions#special-return-types).

### Synchronization Primitives

Mutexes, channels, and other coordination mechanisms will be documented here once the standard
library concurrency API is finalized.

### Custom Awaitables

Classes can define `fn <T> op await(self, obj: std::forward<T>) -> T` to customize the behavior of
`await` when called on an instance. See
[Operators](/docs/language/operators#special-operators) for the `op await` overload.

```kairo
await async_fn()       // syntax sugar for a state machine
spawn some_async_fn()  // syntax sugar for detaching a thread
yield some_value       // syntax sugar for a coroutine, function must have yield on return type

fn get_tokens() -> yield string {
    yield "token1"
    yield "token2"
}
```

`op await` is overloadable: `fn op await (self) -> T` for custom async types.

- `await async_fn()` syntax sugar for state machine
- `spawn some_async_fn()` syntax sugar for detaching a thread
- `yield some_value` coroutine syntax, function must have `-> yield T` return type
- `fn op await (self) -> T` overloadable for custom async types
- `atomic T` thread-safe wrapper type
- `thread T` thread-local storage type
