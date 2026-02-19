<div align="center">
  <img src="assets/kairo-logo.svg" alt="Kairo Programming Language" width="60%">
</div>

# Kairo - Stage 0 Bootstrap Compiler

Kairo is a **statically typed systems programming language** built for high-performance applications and seamless C/C++ interoperability. The goal: the control of C++, safety without the friction of Rust's borrow checker, and a clean modern syntax.

This branch is the **stage-0 compiler** - ~20,000 lines of C++ that transpiles Kairo source to C++. It's complete. All active development has moved to the self-hosted stage-1 compiler on the [`canary`](https://github.com/kairolang/kairo-lang/) branch.

> [!WARNING]
> Stage-0 is functional but unstable and bug-prone. Documentation does not fully reflect what stage-0 can compile - most doc examples target stage-1 syntax. For working stage-0 code references, see the [toolchain source](https://github.com/kairolang/kairo-lang/tree/canary/kairo-0.1.1%2Bbc.251007/toolchain).

---

## Goals

- Safe, productive systems programming without sacrificing low-level control
- First-class C and C++ interoperability - drop into any existing codebase
- A strong module system and portable standard library
- Clear, expressive semantics that scale to large codebases
- A viable alternative to C, C++, and Rust - or a complement to them

---

## Design Rationale

Kairo draws from what works across existing languages and drops what doesn't:

- **Python**: readable syntax, approachable semantics
- **C/C++**: performance, control, and ecosystem reach
- **Rust**: safety features and trait/metaprogramming system - without the borrow checker rigidity
- **Zig**: pragmatic interoperability model

The core bet: you shouldn't have to choose between safety and productivity, or between modern ergonomics and C++ ecosystem access.

---

## What Stage-0 Does

- **Transpiles `.kro` → C++**, invoking the host compiler (Clang/MSVC/GCC) - no LLVM dependency
- **Error remapping**: rewrites C++ diagnostics back to Kairo source locations
- **Debugger source mapping**: step through `.kro` files in gdb/lldb/msvc
- **Lexer**: SIMD-optimized UTF-8 tokenizer, ~40–150ns/token
- **Parser**: hand-written recursive descent, full Kairo grammar
- **Import resolution**: module graph
- **kbld**: native Kairo build tool

---

## Language Highlights

### AMT - Advanced Memory Tracking

Kairo's borrow checker doesn't hard-stop compilation. Instead it detects violations and reacts:

- **Shared managed pointer**: multiple owners detected → auto-converted to `shared_ptr`-equivalent
- **Sole managed pointer**: single clear owner → `unique_ptr`-equivalent
- Conversion only triggers on violation. Clean code has zero smart pointer overhead.

This is intentional. Strict borrow checking is a hard sell for C++ shops migrating incrementally. AMT gives them a path without a rewrite cliff.

### Type System

- **Non-nullable by default**: null is opt-in via Questionable Types (`T?`)
- **Type-level unsafety**: `unsafe` is a type property, not just a block annotation - it propagates through the IR
- **Generics with zero-cost abstractions**: constrained generics that monomorphize cleanly
- **Comprehensive error handling**: structured panicking with full control over propagation

### C++ Interop

Include C++ headers directly, call C++ functions, expose Kairo to C++ - no extern blocks, no manual ABI negotiation.
```lua
ffi "c++" import "my_header.hpp";
```

---

## Building

### Prerequisites

- **C++ compiler**: Clang ≥ 17, MSVC v143+, or GCC
- **Xmake**: [xmake.io](https://xmake.io)
- **Git**

All platforms (macOS, Windows, Linux) are supported and tested.

### [macOS / Linux / Windows] (GCC IS UNSUPPORTED ON ALL PLATFORMS, we have tested msvc on windows and clang on mac and linux to be working.)

```sh
git clone https://github.com/kairolang/kairo-lang.git
cd kairo-lang
xmake build
```

### Run

```sh
xmake run tests       # test suite
xmake run kairo -h    # compiler CLI
```

---

## Usage

```sh
kairo hello_world.kro
./hello_world
```

```rs
fn main() -> i32 {
    std::print("Hello, World!");
    return 0;
}
```

---

---

## Known Limitations

- **Error reporting is partial**: syntax errors are caught and remapped; semantic errors fall through to raw C++ diagnostics
- **Documentation is inconsistent**: most examples target stage-1 syntax, not stage-0. Use the [toolchain source](https://github.com/kairolang/kairo-lang/tree/canary/kairo-0.1.1%2Bbc.251007/toolchain) as ground truth for what stage-0 compiles today
- **No stdlib yet**: standard library is being built on `self-hosted`

---

## Contributing

Stage-0 is **complete and frozen**. Bug reports are welcome; feature PRs won't be merged here (unless it fixes a really bad bug). All development is on [`self-hosted`](https://github.com/kairolang/kairo-lang/tree/self-hosted).

- [Issues](https://github.com/kairolang/kairo-lang/issues)
- [Pull Requests](https://github.com/kairolang/kairo-lang/pulls)
- [Contributing Guide](CONTRIBUTING.md)
- [Website source](https://github.com/kairolang/kairo-site) - contributions and feedback welcome

---

## License

Attribution 4.0 International - see [LICENSE](https://github.com/kairolang/kairo-lang/blob/main/license).

---

## Links

- [kairo-lang.com](https://www.kairo-lang.com)
- [Installation Guide](https://www.kairo-lang.com/install/)
- [self-hosted branch](https://github.com/kairolang/kairo-lang/tree/self-hosted)

<div align="center">
  <a href="https://github.com/kairolang/kairo-lang/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=kairolang/kairo-lang">
  </a>
</div>