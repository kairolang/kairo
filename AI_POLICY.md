# AI Policy

Using AI (LLMs, coding assistants, agents run under your control) as a tool is welcome.
What matters is the contribution, and the person who stands behind it.

## A human is responsible for every contribution

- You are the author of what you submit. You must understand every line of it and be able
  to explain, defend and change it during review without going back to the tool.
- **Autonomous agents may not contribute.** Pull requests, issues and comments opened by an
  agent acting on its own, without a human who read and approved the result, will be
  closed, possibly without notice, and the account may be blocked.
- Review is a conversation between people. Maintainers' time spent on output nobody read
  first is time taken from every other contributor.

## Communication is written by people

- **Do not use AI to write issue descriptions, pull request descriptions, review replies
  or discussion posts.** Write them yourself, in your own words. Comments that read as
  generated may be hidden without notice.
- Do not paste an AI's answer as a reply to a maintainer's question. If you do not know the
  answer, say so.
- Using AI to translate or to fix the grammar of text you wrote is fine. Read the result and
  make sure it still says what you meant, in your voice.
- If an AI interaction is relevant context, quote it (a `>` block), say that it is AI output,
  and add your own explanation of why it matters. Keep it short.

## Kairo is a new language: check, do not trust

Models have seen little or no Kairo, and they confidently write syntax and library calls
that do not exist, or that come from C++, Rust or Swift.

- Every piece of Kairo you submit must compile with the current compiler and compile the compiler itself.
  Do not invent syntax: when unsure whether a form exists, check the
  [language reference](https://kairolang.org/docs/) or try it.
- Claims about the language ("Kairo does X", "this is undefined") must come from the
  reference or from running the compiler, not from a model.

## Code and tests

- AI-assisted code meets the same bar as any other: the standards in
  [CONTRIBUTING.md](CONTRIBUTING.md), tests that you ran and that fail without your change,
  and commits you can explain.
- Do not submit large generated changes (mass refactors, rewrites, "cleanups" across many
  files) that no one asked for. Open an issue first.
- Do not submit generated tests that only restate what the code currently does. A test
  states the behaviour it protects.
- You are responsible for the licence of what you submit. Do not submit code a tool
  reproduced from a source whose licence you cannot confirm is compatible.

## Bug and security reports

- A bug report must describe a problem you reproduced yourself, on a released or current
  compiler, with the smallest input that shows it. Do not file issues found by an AI
  reading the source that you have not confirmed.
- Security reports ([SECURITY.md](SECURITY.md)) follow the same rule, and must include a
  reproduction. Unverified, AI-generated vulnerability reports cost the maintainers real
  time and will be closed.

## Disclosure

Say in the pull request when a substantial part of it was produced with AI assistance.
This changes nothing about how it is reviewed; it helps reviewers know where to look.

---

This policy is adapted from [Zed's extensions AI policy][zed], itself adapted from
[ripgrep's][ripgrep] and [uv's][uv].

[zed]: https://github.com/zed-industries/extensions/blob/main/AI_POLICY.md
[ripgrep]: https://github.com/BurntSushi/ripgrep/blob/4857d6fa67db69a95cd4b6f2adda5d807d4d0119/AI_POLICY.md
[uv]: https://github.com/astral-sh/.github/blob/c5187e200db51bfe11d56e13053d29bd3793fdd8/AI_POLICY.md
