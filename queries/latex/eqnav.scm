; Math in LaTeX. `displayed_equation` covers \[..\] and $$..$$,
; `inline_formula` covers \(..\) and $..$.
(displayed_equation) @eqnav.equation
(inline_formula) @eqnav.equation

; tree-sitter-latex gives the math environments (equation, align, gather,
; multline, flalign, eqnarray, displaymath, split, aligned, ...) a dedicated
; node whose name the grammar already restricts, so no filter is needed and
; figures and tables cannot match. Environments nested inside another capture
; are dropped by the scanner, not here.
(math_environment) @eqnav.equation

; cases/dcases are not in the grammar's math_environment list, so they arrive
; as generic environments and are matched by name.
((generic_environment
   (begin
     name: (curly_group_text (text) @_name)))
 @eqnav.equation
 (#any-of? @_name "cases" "cases*" "dcases" "dcases*"))
