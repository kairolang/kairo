((inline_block
   language: (string) @_lang
   body: (raw_block) @injection.content)
 (#match? @_lang "c\\+\\+|cpp|cxx")
 (#set! injection.language "cpp"))

((inline_block
   language: (string) @_lang
   body: (raw_block) @injection.content)
 (#match? @_lang "\"c\"")
 (#set! injection.language "c"))
