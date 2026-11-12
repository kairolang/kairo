/// --- The Kairo Project ------------------------ Diagnostic/NoteText.k --- ///
///
///   The note wordings many checks share, one spelling each. A message is
///   built at its report site by design (the .diag.toml files hold briefs
///   and explanations, not messages); only a note that says the same thing
///   from dozens of sites is worth a name, so the wording cannot drift
///   between them. A note that adds anything after "declared here" is its
///   own message and stays at its site.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// "declared here", on the declaration a diagnostic is about.
pub fn declared_here() -> string {
    return "declared here"
}

/// "'name' is declared here", naming the declaration.
pub fn named_declared_here(const name: string) -> string {
    return f"'{name}' is declared here"
}

/// "type declared here", on the type a diagnostic is about.
pub fn type_declared_here() -> string {
    return "type declared here"
}

/// "previously declared here", on the earlier of two declarations.
pub fn previously_declared_here() -> string {
    return "previously declared here"
}
