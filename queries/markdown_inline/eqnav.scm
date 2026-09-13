; Math in Markdown. tree-sitter-markdown wraps both $x$ and $$x$$ in
; (latex_block); the delimiter width tells them apart, which the Lua side
; reads off the first (latex_span_delimiter) child.
;
; Using treesitter rather than a regex is what keeps `$x$` inside a fenced
; code block out of the index: the fence is injected as its own language, so
; it is never part of this tree.
(latex_block) @eqnav.equation
