# Contributing to Kairo

Thanks for your interest in contributing to Kairo.

Kairo is a production-grade compiler and toolchain. Contributions are expected to meet a high standard of correctness, clarity, and maintainability.

---

## Before You Start

- Read this document fully
- Ensure your contribution aligns with the project's architecture
- For large changes, open an issue first

Unapproved large changes may be rejected.

---

## Ways to Contribute

### Bug Reports

If you encounter a bug, submit an issue with:

- Minimal reproducible example
- Expected vs actual behavior
- Environment details (OS, compiler flags, version)

Low-effort reports may be ignored.

---

### Bug Fixes

- Reference the issue being fixed
- Keep the fix minimal and focused
- Add a test that fails before and passes after

---

### Features / Large Changes

Before implementation:

1. Open an issue
2. Clearly describe:
   - Problem
   - Proposed solution
   - Alternatives considered

Wait for approval before proceeding.

---

## Development Standards

### Code Quality

- Follow existing architecture and patterns
- Prefer clarity over cleverness
- Avoid unnecessary abstractions
- Ideally no dead code or commented-out blocks

---

### Compiler Integrity

Changes must integrate cleanly with:

- AST
- Semantic analysis
- Code generation pipeline

Workarounds that bypass core systems will be rejected.

---

### Testing

All non-trivial changes must include:

- Unit or integration tests
- Edge case coverage where applicable

No tests == no merge.

---

### Commits

Each commit must:

- Be atomic (one logical change)
- Have a clear message:

```

[component] <brief description>

- Optionally a more detailed explanation of the change, rationale, and any relevant context.

```

Examples:

`[parser] Fix incorrect handling of nested generics`

```
[codegen] Add support for 128-bit integers
- This adds support for i128 and u128 types in code generation.
- It required changes to the register allocator and instruction selection.
- Tests were added to cover basic usage and edge cases.
```


Avoid vague messages like “fixed things”.

---

### Pull Requests

Before submitting:

- Rebase onto latest `canary`
- Ensure clean build
- Ensure all tests pass

PRs must:

- Explain *why* the change is needed
- Avoid unrelated changes
- Be reviewable in isolation

Messy PRs will be rejected.

---

## Code Review

- Reviews are strict and technical
- Address all feedback before requesting re-review
- Inactive or unresponsive PRs may be closed

---

## Licensing (Required)

By contributing, you agree that:

- Your contributions are licensed under:
  **Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION**
- You grant the Kairo Software Foundation the right to use, modify, sublicense, and relicense your contributions

See `CLA.md` for full terms.

---

## Contributor License Agreement (CLA)

All contributors must agree to the Kairo CLA.

By submitting a contribution, you confirm that you have read and agreed to the terms in `CLA.md`.

---

## Communication

- Use GitHub Issues for discussions
- Keep communication clear and technical
- Avoid vague or speculative proposals

---

## What Not to Do

- Do not submit large changes without prior discussion
- Do not introduce new patterns without justification
- Do not bypass core systems for quick fixes
- Do not include unrelated changes in a single PR

---

## Final Note

Kairo is being built as a serious compiler infrastructure.
Contributions should improve the system—not increase complexity without clear benefit.
If unsure, ask before building.