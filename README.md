# Kairo Programming Language

<div align="center">
  <img src="Assets/kairo-logo.svg" alt="Kairo Programming Language Logo" width="60%">
</div>

---

Kairo is a **statically typed compiled general purpose language**, built for systems programming and high-performance applications. Designed with native bi-directional C++ interoperability in mind. Kairo aims to combine the power and control of low-level languages with the safety and clarity of high-level design.

### The goals of Kairo

- Safe, and productive programming language.
- Allow for low-level programming with fine-grained control.
- Native bidirectional C and C++ interoperability.
- Include a portable, well-structured standard library.
- Encourage clear, maintainable, and reviewable code through strong, expressive semantics.
- An alternative to C, C++ or work alongside them.
- No runtime, no garbage collector, no hidden costs - safety through visibility, not restriction.

### Current Status

The **Stage 0 compiler** (written in C++) is functional and can compile Kairo albeit not all the features that stage1 has, you can download it from the [release page](https://github.com/kairolang/kairo/releases), works, but has quite a few bugs, **stage0 issues will not be fixed unless critical**. Development of the **Stage1 compiler**, written in Kairo itself, is in progress.
> [!WARNING]
> [Documentation](https://www.kairolang.org/docs) is technically complete now matching, stage1 and what it can do once built, but the compiler is still in development and not ready for production use.
> If you want to help with documentation, please reach out to us on [Discord](https://discord.gg/VHCnPccDc)

### Why Kairo?

##### Think of programming languages like making coffee

- **C and C++** hands you all the ingredients and equipment, every knob and button live. No recipe, no instructions. You'll have to learn and make something, what you make is on you.
- **Rust** provides you with all the ingredients, fancy equipment, and a precise recipe with every step measured. The coffee comes out reliably good, and the recipe catches mistakes before you brew.
- **Kairo** gives you ingredients, equipment, and recipes, and the kitchen is wired into the C and C++ kitchens next door. Borrow their beans and machines, and send finished coffee back through the same door.

### Design Rationale

- We liked the simplicity of **Python's** syntax but wanted more.
- We wanted the performance and control of **C and C++**.
- We admired **Rust's** safety features but, at times, found them cumbersome.
- We liked **Rust's** Meta-programming and Trait system.
- We liked **Zig's** approach to interoperability.
- We wanted a powerful module system.
- We wanted a robust standard library.
- We wanted a language that would work drop-in with any existing C or C++ codebases.
- We wanted all; So we created **Kairo**.

Kairo is built to slot directly into C **and** C++ ecosystems, offering a fresh syntax and features, without abandoning decades of code.

### Getting Started

**Download a release:** grab a prebuilt binary from the [releases page](https://github.com/kairolang/kairo/releases).

**Build from source:** see [BUILD.md](BUILD.md) - covers the quick install script, manual setup, PATH configuration, the VSCode extension, and debugging.

**Code reference:** since the docs are still catching up, the [Compiler directory](https://github.com/kairolang/kairo/tree/main/Compiler) is compiling Stage 0 code.

### License

Kairo is licensed under the Attribution 4.0 International License. See the [LICENSE](https://github.com/kairolang/kairo/blob/main/license) for more details.

### AI Usage Disclosure

[Read The Full Post Here](https://www.kairolang.org/blog/how-ai-is-used-in-kairo/).
TLDR: Lang design, Compiler, and Architecture are 100% human. No AI-generated code in the compiler and language design stage1 or stage0. Docs have AI usage; mostly used for polishing.

### Acknowledgements

We want to thank all our contributors pushing Kairo forward.

<div align="center">
  <a href="https://github.com/kairolang/kairo/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=kairolang/kairo">
</a>
</div>

### Stars

<a href="https://www.star-history.com/?repos=kairolang%2Fkairo&type=timeline&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=kairolang/kairo&type=timeline&theme=dark&legend=top-left&sealed_token=RrrzUDpwMVZfmAhKTMoffR2pTPUXIYzucBvcqBCemCfJ8TIoWwRLM7JHP94oqYawcyH9SZDCYlqeBhoYtszRBUG5ml0dJVQHtszhdMCjZgQxejQ757s5W5jpfP-r17CFfLmcMOgY74-HVdWfBwk3NMqpRcNiwR0nabY7ZcdPFXidbe3cT4Nz1BeSzOd8" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=kairolang/kairo&type=timeline&legend=top-left&sealed_token=RrrzUDpwMVZfmAhKTMoffR2pTPUXIYzucBvcqBCemCfJ8TIoWwRLM7JHP94oqYawcyH9SZDCYlqeBhoYtszRBUG5ml0dJVQHtszhdMCjZgQxejQ757s5W5jpfP-r17CFfLmcMOgY74-HVdWfBwk3NMqpRcNiwR0nabY7ZcdPFXidbe3cT4Nz1BeSzOd8" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=kairolang/kairo&type=timeline&legend=top-left&sealed_token=RrrzUDpwMVZfmAhKTMoffR2pTPUXIYzucBvcqBCemCfJ8TIoWwRLM7JHP94oqYawcyH9SZDCYlqeBhoYtszRBUG5ml0dJVQHtszhdMCjZgQxejQ757s5W5jpfP-r17CFfLmcMOgY74-HVdWfBwk3NMqpRcNiwR0nabY7ZcdPFXidbe3cT4Nz1BeSzOd8" />
 </picture>
</a>
