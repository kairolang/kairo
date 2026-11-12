/// --- The Kairo Project --------------------------- Analyzer/Protocol.k --- ///
///
///   The wire constants: LSP method and notification names, error codes, code-action
///   kinds, commands, the LSP enums the server writes and the JSON member
///   names of the LSP objects it reads and writes (K_*), with one writer per
///   shape that repeats (a position, a range, a location). One definition
///   each; the token legend (types, modifiers, bit positions) is
///   Index/Legend.k, the snapshot's own members are Index/Snapshot.k (SK_*).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///


import Json::{
    JsonDoc,
    JsonWriter,
}

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
/// Sent after each completion answer: `how` it was computed (`live`: the
/// live worker tried the marked buffer aside; `run`: a process per
/// request; `text`: from the buffer and the filesystem alone) and `us`,
/// the server's own time from the request to the answer. For tests and
/// benchmarks, as `$/kals/analysed` is.
pub const M_KALS_COMPLETED: string = "$/kals/completed"
pub const K_HOW:    string = "how"   ///< M_KALS_COMPLETED: a HOW_* word
pub const K_US:     string = "us"    ///< M_KALS_COMPLETED: microseconds
pub const HOW_LIVE: string = "live"
pub const HOW_RUN:  string = "run"
pub const HOW_TEXT: string = "text"
/// `index`: from the entry's declaration tables and the buffer's text,
/// with no compile and no worker (LanguageServer.md section 8).
pub const HOW_INDEX: string = "index"
/// M_KALS_COMPLETED: what was completed, a WHAT_* word, and how many items
/// were sent.
pub const K_WHAT:  string = "what"
pub const K_COUNT: string = "count"
pub const WHAT_NAME:      string = "name"       ///< a bare name: locals, the file, imports, keywords, macros
pub const WHAT_MEMBER:    string = "member"     ///< after `.`, `->`, `::`
pub const WHAT_ATTRIBUTE: string = "attribute"  ///< after `@`
pub const WHAT_IMPORT:    string = "import"     ///< a Kairo import's path or names
pub const WHAT_HEADER:    string = "header"     ///< an ffi import's header path
pub const WHAT_NONE:      string = "none"       ///< nothing is offered there (a comment, a string, a name being declared)
/// Debug: the installed snapshot of a buffer's entry (the rows of every
/// indexed file, the diagnostics, the files of the graph), for a test that
/// compares what two ways of analysing the same text installed.
pub const M_KALS_SNAPSHOT: string = "$/kals/snapshot"
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
pub const M_REGISTER_CAPABILITY: string = "client/registerCapability"

/// What the server asks every client to watch: the C and C++ sources (the
/// clangd bridge reads their `#include "x.k"` lines) and the compilation
/// database that lists them. Kairo files are the client's own configuration.
pub const WATCH_REGISTRATION: string = "{\"registrations\":[{\"id\":\"kals-watch-cxx\",\"method\":\"workspace/didChangeWatchedFiles\",\"registerOptions\":{\"watchers\":[{\"globPattern\":\"**/*.{c,cc,cpp,cxx,h,hh,hpp,hxx}\"},{\"globPattern\":\"**/compile_commands.json\"}]}}]}"
pub const M_SHOW_MESSAGE: string = "window/showMessage"
pub const M_LOG_MESSAGE: string = "window/logMessage"

// --- code-action kinds and commands ----------------------------------------
pub const KIND_QUICKFIX: string = "quickfix"
pub const KIND_REFACTOR_INLINE: string = "refactor.inline"
pub const KIND_REFACTOR_EXTRACT: string = "refactor.extract"
pub const CMD_SHOW_MACRO_EXPANSION: string = "kairo.showMacroExpansion"

// --- JSON-RPC ---------------------------------------------------------------
pub const JSONRPC_VERSION: string = "2.0"

// --- JSON-RPC / LSP error codes --------------------------------------------
pub const ERR_INVALID_REQUEST:    i64 = -32600
pub const ERR_METHOD_NOT_FOUND:   i64 = -32601
pub const ERR_SERVER_NOT_INITIALIZED: i64 = -32002
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
pub const SYM_NAMESPACE:      i64 = 3
pub const SYM_CLASS:          i64 = 5
pub const SYM_METHOD:         i64 = 6
pub const SYM_FIELD:          i64 = 8
pub const SYM_CONSTRUCTOR:    i64 = 9
pub const SYM_ENUM:           i64 = 10
pub const SYM_INTERFACE:      i64 = 11
pub const SYM_FUNCTION:       i64 = 12
pub const SYM_VARIABLE:       i64 = 13
pub const SYM_CONSTANT:       i64 = 14
pub const SYM_ENUM_MEMBER:    i64 = 22
pub const SYM_STRUCT:         i64 = 23
pub const SYM_TYPE_PARAMETER: i64 = 26

// --- CompletionItemKind ----------------------------------------------------
pub const CIK_TEXT:           i64 = 1
pub const CIK_METHOD:         i64 = 2
pub const CIK_FUNCTION:       i64 = 3
pub const CIK_FIELD:          i64 = 5
pub const CIK_VARIABLE:       i64 = 6
pub const CIK_CLASS:          i64 = 7
pub const CIK_INTERFACE:      i64 = 8
pub const CIK_MODULE:         i64 = 9
pub const CIK_ENUM:           i64 = 13
pub const CIK_KEYWORD:        i64 = 14
pub const CIK_SNIPPET:        i64 = 15
pub const CIK_FILE:           i64 = 17
pub const CIK_FOLDER:         i64 = 19
pub const CIK_ENUM_MEMBER:    i64 = 20
pub const CIK_CONSTANT:       i64 = 21
pub const CIK_STRUCT:         i64 = 22
pub const CIK_TYPE_PARAMETER: i64 = 25

// --- InlayHintKind (0: the member is left out) ------------------------------
pub const IHK_TYPE:      i64 = 1
pub const IHK_PARAMETER: i64 = 2

// --- DocumentHighlightKind ---------------------------------------------------
pub const DHK_TEXT: i64 = 1

// --- TextDocumentSyncKind ----------------------------------------------------
pub const TDS_INCREMENTAL: i64 = 2

// --- FoldingRangeKind --------------------------------------------------------
pub const FRK_COMMENT: string = "comment"

// --- semantic tokens -------------------------------------------------------
/// Integers per token in the LSP encoding: deltaLine, deltaStart, length,
/// tokenType, tokenModifiers.
pub const SEMTOK_STRIDE: usize = 5
/// The tokenModifiers bit set's position within a token's five.
pub const SEMTOK_MODS:   usize = 4

// --- JSON member names ------------------------------------------------------
//
// The LSP objects' member names, read and written. The snapshot rows that are
// LSP objects (a symbol, an inlay hint, a diagnostic, a completion item) use
// the same names, since the server forwards them as they are.

// JSON-RPC envelope
pub const K_JSONRPC: string = "jsonrpc"
pub const K_ID:      string = "id"
pub const K_METHOD:  string = "method"
pub const K_PARAMS:  string = "params"
pub const K_RESULT:  string = "result"
pub const K_ERROR:   string = "error"
pub const K_CODE:    string = "code"
pub const K_MESSAGE: string = "message"

// documents, positions, ranges, locations
pub const K_TEXT_DOCUMENT:   string = "textDocument"
pub const K_URI:             string = "uri"
pub const K_VERSION:         string = "version"
pub const K_TEXT:            string = "text"
pub const K_CONTENT_CHANGES: string = "contentChanges"
pub const K_POSITION:        string = "position"
pub const K_POSITIONS:       string = "positions"
pub const K_RANGE:           string = "range"
pub const K_START:           string = "start"
pub const K_END:             string = "end"
pub const K_LINE:            string = "line"
pub const K_CHARACTER:       string = "character"
pub const K_LOCATION:        string = "location"
pub const K_TARGET:          string = "target"

// edits
pub const K_NEW_TEXT:  string = "newText"
pub const K_TEXT_EDIT: string = "textEdit"
pub const K_EDIT:      string = "edit"
pub const K_EDITS:     string = "edits"
pub const K_CHANGES:   string = "changes"
pub const K_NEW_NAME:  string = "newName"

// symbols, hovers, completion, signature help
pub const K_NAME:            string = "name"
pub const K_DETAIL:          string = "detail"
pub const K_KIND:            string = "kind"
pub const K_SELECTION_RANGE: string = "selectionRange"
pub const K_CHILDREN:        string = "children"
pub const K_CONTENTS:        string = "contents"
pub const K_VALUE:           string = "value"
pub const K_LABEL:           string = "label"
pub const K_ITEMS:           string = "items"
pub const K_ITEM:            string = "item"
pub const K_IS_INCOMPLETE:   string = "isIncomplete"
pub const K_SORT_TEXT:       string = "sortText"
pub const K_DOCUMENTATION:   string = "documentation"
pub const K_DATA:            string = "data"
pub const K_CONTEXT:            string = "context"           ///< a completion request's: why it was sent
pub const K_TRIGGER_CHARACTER:  string = "triggerCharacter"  ///< context: the character that sent it, when one did
pub const K_ITEM_DEFAULTS:      string = "itemDefaults"      ///< a CompletionList's: what every item shares
pub const K_EDIT_RANGE:         string = "editRange"         ///< itemDefaults: the range each item replaces
pub const K_TEXT_EDIT_TEXT:     string = "textEditText"      ///< an item's text when the range is the default's
pub const K_INSERT_TEXT_FORMAT: string = "insertTextFormat"
pub const K_FILTER_TEXT:        string = "filterText"
pub const ITF_SNIPPET: i64 = 2  ///< InsertTextFormat.Snippet
pub const K_PADDING_LEFT:    string = "paddingLeft"
pub const K_PADDING_RIGHT:   string = "paddingRight"

// diagnostics, code actions, commands, progress
pub const K_DIAGNOSTICS:         string = "diagnostics"
pub const K_SEVERITY:            string = "severity"
pub const K_SOURCE:              string = "source"
pub const K_RELATED_INFORMATION: string = "relatedInformation"
pub const K_TITLE:               string = "title"
pub const K_COMMAND:             string = "command"
pub const K_TOKEN:               string = "token"
pub const K_TYPE:                string = "type"

// initialize
pub const K_CAPABILITIES:    string = "capabilities"
pub const K_WORKSPACE:       string = "workspace"
pub const K_REFRESH_SUPPORT: string = "refreshSupport"

// initializationOptions: kals' own settings (LanguageServer.md)
pub const OPT_DEBOUNCE_MS:        string = "debounceMs"
pub const OPT_SYNTAX_DEBOUNCE_MS: string = "syntaxDebounceMs"
pub const OPT_HIGHLIGHT_PANICS:   string = "highlightPanics"
pub const OPT_LIVE_CHECK:         string = "liveCheck"
/// false: every completion is the marked buffer's compile (the live copy
/// or a run), none is answered from the index. For comparing the two.
pub const OPT_INDEX_COMPLETION:   string = "indexCompletion"
pub const OPT_MAX_WORKERS:        string = "maxWorkers"

/// MarkupKind of every hover and documentation string the server writes.
pub const MARKUP_MARKDOWN: string = "markdown"

// --- shapes -----------------------------------------------------------------

/// Writes the Position `{"line":L,"character":C}`.
pub fn write_lsp_position(w: *JsonWriter, line: i64, ch: i64) {
    w->begin_object()
    w->field_int(K_LINE, line)
    w->field_int(K_CHARACTER, ch)
    w->end_object()
}

/// Writes the Range from (\p sl, \p sc) to (\p el, \p ec).
pub fn write_lsp_range(w: *JsonWriter, sl: i64, sc: i64, el: i64, ec: i64) {
    w->begin_object()
    w->key(K_START)
    write_lsp_position(w, sl, sc)
    w->key(K_END)
    write_lsp_position(w, el, ec)
    w->end_object()
}

/// Writes the Location `{"uri":U,"range":R}`, with \p range already JSON.
pub fn write_lsp_location_raw(w: *JsonWriter, const uri: string, const range: string) {
    w->begin_object()
    w->field(K_URI, uri)
    w->field_raw(K_RANGE, range)
    w->end_object()
}

/// Writes the TextEdit `{"range":R,"newText":T}`, with \p range already JSON.
pub fn write_lsp_text_edit_raw(w: *JsonWriter, const range: string, const text: string) {
    w->begin_object()
    w->field_raw(K_RANGE, range)
    w->field(K_NEW_TEXT, text)
    w->end_object()
}

/// `params.textDocument.uri`: the document nearly every request is about.
pub fn text_document_uri(d: *const JsonDoc, params: u32) -> string {
    return d->get_str(d->get(params, K_TEXT_DOCUMENT), K_URI)
}
