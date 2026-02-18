## Contributing to Kairo

---

### Table of Contents

- [Contributing to Kairo](#contributing-to-kairo)
  - [Table of Contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Ways to Contribute](#ways-to-contribute)
    - [Contributing to Language Design](#contributing-to-language-design)
    - [Contributing to Language Implementation](#contributing-to-language-implementation)
    - [Improving Documentation](#improving-documentation)
  - [Contributor Workflow](#contributor-workflow)
    - [Submitting Changes](#submitting-changes)
    - [Writing Tests](#writing-tests)
    - [Using Pre-Commit Hooks](#using-pre-commit-hooks)
  - [Contributor License Agreement (CLA)](#contributor-license-agreement-cla)
  - [Style Guide](#style-guide)
    - [Commit Messages](#commit-messages)
    - [Code Formatting](#code-formatting)
    - [Documentation](#documentation)
  - [Resources](#resources)
  - [Acknowledgements](#acknowledgements)

---

### Introduction

Thank you for your interest in contributing to Kairo! We welcome contributions from everyone, and we value all forms of contributions. Whether you are fixing a bug, adding a new feature, improving documentation, or participating in discussions, your involvement is appreciated.

Before you start contributing, please read our [Code of Conduct](CODE_OF_CONDUCT.md) to ensure a welcoming and inclusive environment for all participants.

### Ways to Contribute

#### Contributing to Language Design

**Comment on Proposals:**

- Providing feedback on existing proposals helps improve the design of the language. Look for issues labeled ["proposal"](https://github.com/kairolang/kairo-lang/issues?q=is%3Aissue+is%3Aopen+label%3Aproposal) and share your thoughts.
- Keep comments constructive and concise. Aim to help authors refine their ideas.

**Submit Design Ideas:**

- If you have an idea for a new feature or improvement, start a discussion in our [GitHub Discussions](https://github.com/kairolang/kairo-lang/discussions).
- If the idea gains traction, you can write a proposal and submit it as a pull request. Before writing a proposal, discuss the idea with the community to get feedback and ensure it aligns with Kairo's goals.

#### Contributing to Language Implementation

**Review and Comment on Pull Requests:**

- Reviewing pull requests is a great way to understand the codebase and help others improve their contributions.
- Look for open pull requests [here](https://github.com/kairolang/kairo-lang/pulls) and provide feedback.

**Implement Features or Fix Bugs:**

- Check out issues labeled ["good first issue"](https://github.com/kairolang/kairo-lang/labels/good%20first%20issue) if you're new to the project. These are typically smaller tasks that are well-suited for new contributors.
- For larger tasks, discuss your approach with the community before you start working on it. This helps ensure that your work aligns with the project's direction and that you're not duplicating effort.

**Triage, Analyze, or Address Bugs:**

- Help us triage, analyze, and address bugs. Look for open issues [here](https://github.com/kairolang/kairo-lang/issues).
- When triaging issues, verify that they are reproducible, provide additional context if necessary, and label them appropriately.

#### Improving Documentation

**Update Existing Documentation:**

- If you find any inaccuracies or areas that need improvement in our documentation, feel free to submit a pull request with your changes.

**Write New Documentation:**

- New features or significant changes to existing features often need new documentation. Follow the existing style and structure of our documentation.

### Contributor Workflow

#### Submitting Changes

1. **Fork the Repository:** Fork the [Kairo repository](https://github.com/kairolang/kairo-lang) to your GitHub account.

2. **Clone Your Fork:** Clone your forked repository to your local machine.
   ```sh
   git clone https://github.com/your-username/kairo.git
   cd kairo
   ```

3. **Create a Branch:** Create a new branch for your changes.
   ```sh
   git checkout -b feature-or-bugfix-description
   ```

4. **Make Changes:** Make your changes to the codebase.

5. **Commit Your Changes:** Commit your changes with a clear and descriptive commit message.
   ```sh
   git commit -am "feat: Add feature X / fix: Fix bug Y"
   ```

6. **Push to Your Fork:** Push your changes to your forked repository.
   ```sh
   git push origin feature-or-bugfix-description
   ```

7. **Submit a Pull Request:** Open a pull request from your branch to the main Kairo repository.

#### Writing Tests

- All new features and bug fixes should include tests to ensure that they work as expected and to prevent regressions.
- Write tests that cover a variety of scenarios, including edge cases.
- Run the tests to ensure they pass before submitting your pull request.
- Use the existing test suite as a guide for writing your tests. Ensure that your tests are clear and well-documented.

#### Using Pre-Commit Hooks

- We use [pre-commit](https://pre-commit.com/) hooks to ensure code quality and consistency.
- Install pre-commit hooks by running:
  ```sh
  pre-commit install
  ```
- The hooks will automatically run checks on your code before each commit. This helps catch issues early and ensures that your code adheres to our style guide.

### Contributor License Agreement (CLA)

- We require all contributors to sign a [Contributor License Agreement (CLA)](https://cla.developers.google.com/).
- This agreement is necessary for legal reasons and helps protect both you and the project.
- Sign the CLA online before submitting your first contribution. This ensures that we can accept your contributions and that they are properly attributed.

### Style Guide

#### Commit Messages

- Follow the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) specification for commit messages.
- Format your commit messages as `type(scope): subject`, where `type` is one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, and `scope` is optional but recommended.

#### Code Formatting

- Use 4 spaces per indentation level, no tabs.
- Use meaningful variable and function names.
- Keep lines under 80 characters if possible.
- Write comments to explain non-obvious code.
- Ensure that your code is readable and maintainable. Avoid overly complex or convoluted constructs.

#### Documentation

- Follow the existing style and structure.
- Use Markdown for documentation files.
- Ensure examples and code snippets are correct and up-to-date.
- Provide clear and concise explanations. Avoid jargon and technical language that might be difficult for new contributors to understand.

### Resources

- **Kairo Documentation:** [Kairo Docs](https://kairo-lang.com/docs)
- **Kairo GitHub Repository:** [Kairo on GitHub](https://github.com/kairolang/kairo-lang)
- **Kairo Discord Community:** [Join the Kairo Discord](https://discord.gg/kairo-lang)
- **GitHub Help:** [GitHub Documentation](https://help.github.com)
- **Pre-Commit:** [Pre-Commit Documentation](https://pre-commit.com)
- **Conventional Commits:** [Conventional Commits Specification](https://www.conventionalcommits.org/en/v1.0.0/)

### Acknowledgements

This contributing guide is inspired by the [Carbon Language Contributing Guide](https://github.com/carbon-language/carbon-lang/blob/trunk/docs/project/contributing.md) and the [Julia Contributing Guide](https://github.com/JuliaLang/julia/blob/master/CONTRIBUTING.md). We thank these communities for their excellent contributions to open-source development practices.
