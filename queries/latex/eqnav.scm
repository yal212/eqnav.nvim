; Math in LaTeX. `displayed_equation` covers \[..\] and $$..$$,
; `inline_formula` covers \(..\) and $..$.
(displayed_equation) @eqnav.equation
(inline_formula) @eqnav.equation

; Numbered/aligned environments arrive as generic environments; match on the
; environment name so we pick up align/gather/multline without also indexing
; every figure and table.
((generic_environment
   (begin
     name: (curly_group_text (text) @_name)))
 @eqnav.equation
 (#any-of? @_name
  "equation" "equation*" "align" "align*" "alignat" "alignat*"
  "gather" "gather*" "multline" "multline*" "flalign" "flalign*"
  "eqnarray" "eqnarray*" "displaymath" "split" "cases" "dcases"))
