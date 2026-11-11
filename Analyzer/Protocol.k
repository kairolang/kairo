/// --- The Kairo Project --------------------------- Analyzer/Protocol.k --- ///
///
///   The wire constants: LSP method and notification names, error codes, code-action
///   kinds, commands and the LSP enums the server writes. One definition each; the
///   token legend (types, modifiers, bit positions) is Index/Legend.k.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


// --- methods and notifications ----------------------------------------------
pub const M_INITIALIZE: string = "initialize"
pub const M_INITIALIZED: string = "initialized"
pub const M_SHUTDOWN: string = "shutdown"
pub const M_EXIT: string = "exit"
pub const M_DID_OPEN: string = "textDocument/didOpen"
pub const M_DID_CHANGE: string = "textDocument/didChange"
pub const M_DID_CLOSE: string = "textDocument/didClose"
pub const M_DID_SAVE: string = "textDocument/didSave"
pub const M_DID_CHANGE_WATCHED: string = "workspace/didChangeWatchedFiles"
pub const M_CANCEL_REQUEST: string = "$/cancelRequest"
pub const M_PROGRESS: string = "$/progress"
pub const M_DOLLAR_PREFIX: string = "$/"
pub const M_KALS_TEXT: string = "$/kals/text"
pub const M_KALS_ANALYSED: string = "$/kals/analysed"
pub const M_TEXT_DOCUMENT_PREFIX: string = "textDocument/"
pub const M_HOVER: string = "textDocument/hover"
pub const M_DEFINITION: string = "textDocument/definition"
pub const M_DECLARATION: string = "textDocument/declaration"
pub const M_TYPE_DEFINITION: string = "textDocument/typeDefinition"
pub const M_IMPLEMENTATION: string = "textDocument/implementation"
pub const M_REFERENCES: string = "textDocument/references"
pub const M_DOCUMENT_HIGHLIGHT: string = "textDocument/documentHighlight"
pub const M_DOCUMENT_LINK: string = "textDocument/documentLink"
pub const M_DOCUMENT_SYMBOL: string = "textDocument/documentSymbol"
pub const M_RENAME: string = "textDocument/rename"
pub const M_PREPARE_RENAME: string = "textDocument/prepareRename"
pub const M_CODE_ACTION: string = "textDocument/codeAction"
pub const M_CODE_LENS: string = "textDocument/codeLens"
pub const M_INLAY_HINT: string = "textDocument/inlayHint"
pub const M_COMPLETION: string = "textDocument/completion"
pub const M_COMPLETION_RESOLVE: string = "completionItem/resolve"
pub const M_SIGNATURE_HELP: string = "textDocument/signatureHelp"
pub const M_FORMATTING: string = "textDocument/formatting"
pub const M_RANGE_FORMATTING: string = "textDocument/rangeFormatting"
pub const M_ON_TYPE_FORMATTING: string = "textDocument/onTypeFormatting"
pub const M_FOLDING_RANGE: string = "textDocument/foldingRange"
pub const M_SELECTION_RANGE: string = "textDocument/selectionRange"
pub const M_SEMANTIC_TOKENS_PREFIX: string = "textDocument/semanticTokens/"
pub const M_SEMANTIC_TOKENS_FULL: string = "textDocument/semanticTokens/full"
pub const M_SEMANTIC_TOKENS_DELTA: string = "textDocument/semanticTokens/full/delta"
pub const M_SEMANTIC_TOKENS_RANGE: string = "textDocument/semanticTokens/range"
pub const M_PREPARE_CALL_HIERARCHY: string = "textDocument/prepareCallHierarchy"
pub const M_INCOMING_CALLS: string = "callHierarchy/incomingCalls"
pub const M_OUTGOING_CALLS: string = "callHierarchy/outgoingCalls"
pub const M_PREPARE_TYPE_HIERARCHY: string = "textDocument/prepareTypeHierarchy"
pub const M_SUPERTYPES: string = "typeHierarchy/supertypes"
pub const M_SUBTYPES: string = "typeHierarchy/subtypes"
pub const M_WORKSPACE_SYMBOL: string = "workspace/symbol"
pub const M_PUBLISH_DIAGNOSTICS: string = "textDocument/publishDiagnostics"
pub const M_SEMANTIC_TOKENS_REFRESH: string = "workspace/semanticTokens/refresh"
pub const M_INLAY_HINT_REFRESH: string = "workspace/inlayHint/refresh"
pub const M_WORK_DONE_PROGRESS_CREATE: string = "window/workDoneProgress/create"
pub const M_SHOW_MESSAGE: string = "window/showMessage"
pub const M_LOG_MESSAGE: string = "window/logMessage"

// --- code-action kinds and commands ----------------------------------------
pub const KIND_QUICKFIX: string = "quickfix"
pub const KIND_REFACTOR_INLINE: string = "refactor.inline"
pub const KIND_REFACTOR_EXTRACT: string = "refactor.extract"
pub const CMD_SHOW_MACRO_EXPANSION: string = "kairo.showMacroExpansion"

// --- JSON-RPC / LSP error codes --------------------------------------------
pub const ERR_METHOD_NOT_FOUND:   i64 = -32601
pub const ERR_REQUEST_CANCELLED:  i64 = -32800
pub const ERR_CONTENT_MODIFIED:   i64 = -32801
pub const ERR_REQUEST_FAILED:     i64 = -32803

// --- MessageType (window/logMessage, window/showMessage) --------------------
pub const MSG_ERROR:   i64 = 1
pub const MSG_WARNING: i64 = 2
pub const MSG_INFO:    i64 = 3
pub const MSG_LOG:     i64 = 4

// --- DiagnosticSeverity ------------------------------------------------------
pub const DS_ERROR:       usize = 1
pub const DS_WARNING:     usize = 2
pub const DS_INFORMATION: usize = 3
pub const DS_HINT:        usize = 4

// --- SymbolKind ------------------------------------------------------------
pub const SK_CLASS:     i64 = 5
pub const SK_METHOD:    i64 = 6
pub const SK_ENUM:      i64 = 10
pub const SK_INTERFACE: i64 = 11
pub const SK_FUNCTION:  i64 = 12
pub const SK_STRUCT:    i64 = 23

// --- CompletionItemKind ----------------------------------------------------
pub const CIK_FUNCTION: i64 = 3
pub const CIK_VARIABLE: i64 = 6
pub const CIK_MODULE:   i64 = 9
pub const CIK_KEYWORD:  i64 = 14
pub const CIK_FOLDER:   i64 = 19

// --- semantic tokens -------------------------------------------------------
/// Integers per token in the LSP encoding: deltaLine, deltaStart, length,
/// tokenType, tokenModifiers.
pub const SEMTOK_STRIDE: usize = 5
/// The tokenModifiers bit set's position within a token's five.
pub const SEMTOK_MODS:   usize = 4
