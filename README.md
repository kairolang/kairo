<div align="center">
  <img src="assets/kairo-logo.svg" alt="Kairo Programming Language" width="60%">
</div>

# Kairo - Stage 0 Bootstrap Compiler

Kairo is a **statically typed systems programming language** built for high-performance applications and seamless C/C++ interoperability. The goal: the control of C++, safety without the friction of Rust's borrow checker, and a clean modern syntax.

This branch is the **stage-0 compiler** - ~20,000 lines of C++ that transpiles Kairo source to C++. It's complete. All active development has moved to the self-hosted stage-1 compiler on the [`canary`](https://github.com/kairolang/kairo/) branch.

> [!WARNING]
> Stage-0 is functional but unstable and bug-prone. Documentation does not fully reflect what stage-0 can compile - most doc examples target stage-1 syntax. For working stage-0 code references, see the [toolchain source](https://github.com/kairolang/kairo/tree/canary/kairo-0.1.1%2Bbc.251007/toolchain).

---

## Building

### Prerequisites

- **C++ compiler**: Clang ≥ 17, MSVC v143+, or GCC
- **Xmake**: [xmake.io](https://xmake.io)
- **Git**

All platforms (macOS, Windows, Linux) are supported and tested.

### [macOS / Linux / Windows] (GCC IS UNSUPPORTED ON ALL PLATFORMS, we have tested msvc on windows and clang on mac and linux to be working.)

```sh
git clone https://github.com/kairolang/kairo.git
cd kairo
# make sure to init submodules, this might take a while
git submodule update --init --recursive
xmake build
# emits a binary to ./build/release/<platform>/bin/
# feel free to add that to your PATH for easier usage
```

### Run

```sh
./build/release/<platform>/bin/kairo hello_world.k
```

---

## Usage

```sh
kairo hello_world.k
./hello_world
```

```rs
fn main() -> i32 {
    std::print("Hello, World!");
    return 0;
}
```

---

## Known Limitations

- **Error reporting is partial**: syntax errors are caught and remapped; semantic errors fall through to raw C++ diagnostics
- **Documentation is inconsistent**: most examples target stage-1 syntax, not stage-0. Use the [toolchain source](https://github.com/kairolang/kairo/tree/canary/kairo-0.1.1%2Bbc.251007/toolchain) as ground truth for what stage-0 compiles today
- **No stdlib yet**: standard library is being built on `self-hosted`

---

## Contributing

Stage-0 is **complete and frozen**. Bug reports are welcome; feature PRs won't be merged here (unless it fixes a really bad bug). All development is on [`self-hosted`](https://github.com/kairolang/kairo/tree/self-hosted).

- [Issues](https://github.com/kairolang/kairo/issues)
- [Pull Requests](https://github.com/kairolang/kairo/pulls)
- [Contributing Guide](CONTRIBUTING.md)
- [Website source](https://github.com/kairolang/kairo-site) - contributions and feedback welcome

---

## License

Attribution 4.0 International - see [LICENSE](https://github.com/kairolang/kairo/blob/main/license).

---

## Links

- [www.kairolang.org](https://www.kairolang.org)
- [self-hosted branch](https://github.com/kairolang/kairo/tree/self-hosted)

<div align="center">
  <a href="https://github.com/kairolang/kairo/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=kairolang/kairo">
  </a>
</div>