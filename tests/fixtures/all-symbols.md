# eqnav.nvim — all symbols

Every symbol family and every MathJax package the daemon loads, one display
equation per row. Open the index with `:Eqnav` and walk it with `j`/`k`: each
entry's header names the section it came from, so a broken row is identified by
the heading above it.

The authoritative package list this file tracks is `BUILTIN_PACKAGES` +
`EXTENSION_PACKAGES` in `scripts/mathjax-daemon.mjs`. If you add a package
there, add a section here.

Two things to know before you start:

- **Inline math is hidden by default.** `include_inline` is off, so the `$…$`
  rows below produce no entries unless you run `EQNAV_DEMO_INLINE=1 make demo`.
- **`\[…\]` and `\(…\)` are not markdown math.** tree-sitter-markdown only
  emits `latex_block` for `$…$` and `$$…$$`, so the bracket and paren forms in
  §1 are correctly *absent* from the index here. They are indexed in
  `all-symbols.tex`, which takes the regex scanner. That asymmetry is the
  behaviour, not a bug.

## Known findings (2026-09-13)

Surfaced by this fixture. Expected until the issues close — delete the
corresponding bullet as each is fixed.

None open right now: every finding this fixture has surfaced so far is fixed.

Fixed and deleted from this list: **#13** (`empheq`'s `box=` option, which
MathJax's `empheq` does not implement — section 20 asks for `left=` instead,
which it does), **#9** (a `cases`, `split` or `dcases` nested in an `equation`
indexed twice by the regex scanner — visible in `all-symbols.tex` rather than
here), **#10** (every environment error-boxing on
*"Erroneous nesting of equation structures"*, because the daemon coloured by
wrapping the source in `\color{...}{...}`), **#8** (`\mathbb`, `\mathfrak`,
`\mathcal`, `\mathsf`, `\mathtt`, `\leadsto`, `\checkmark` and the `\require`
/ autoload paths, which need `tex2svgPromise` because MathJax fetches those
font ranges and packages on demand) and **#11** (pandoc `{#eq:…}` labels
reaching MathJax and erroring on the `#`). `\require{mhchem}` was a third,
separate cause — MathJax 4 keeps mhchem's glyphs in
`@mathjax/mathjax-mhchem-font-extension`, now a declared dependency.

Rendering as a red error box **inside an image** is correct behaviour for
section 29 (`noundefined`, malformed `\frac{a}`) and is not a bug — that is the
graceful-degradation contract `tests/render_spec.lua` pins down.

## 1 · Delimiters

$$
\text{(a) dollar-dollar, the markdown display form} \quad E = mc^2
$$

$$\text{(b) dollar-dollar on one line} \quad \nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}$$

\[
\text{(c) bracket form — NOT indexed in markdown, see the note above}
\]

Inline paren \( \text{(d) paren form — also not indexed in markdown} \) mid-sentence.

Inline dollars $\text{(e) inline: } a^2 + b^2 = c^2$ mid-sentence — needs `EQNAV_DEMO_INLINE=1`.

More inline, so the inline run has something to show: the golden ratio
$\varphi = \tfrac{1+\sqrt5}{2}$, Euler's identity $e^{i\pi} + 1 = 0$, a limit
$\lim_{n\to\infty}(1+\tfrac1n)^n = e$, a matrix
$\left(\begin{smallmatrix}1&0\\0&1\end{smallmatrix}\right)$, and a subscripted
tensor $g_{\mu\nu}$ — five more entries when inline is on.

## 2 · Environments

$$\begin{equation} x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a} \end{equation}$$

$$\begin{equation*} \oint_{\partial \Sigma} \mathbf{B} \cdot d\boldsymbol{\ell} = \mu_0 I \end{equation*}$$

$$\begin{align} a &= b + c \\ d &= e + f \end{align}$$

$$\begin{align*} \sin^2\theta + \cos^2\theta &= 1 \\ \tan\theta &= \frac{\sin\theta}{\cos\theta} \end{align*}$$

$$\begin{alignat}{2} x &= 1 &\quad y &= 2 \\ z &= 3 &\quad w &= 4 \end{alignat}$$

$$\begin{gather} p = q \\ r = s + t \end{gather}$$

$$\begin{multline} a + b + c + d \\ + e + f + g \end{multline}$$

$$\begin{flalign} u &= v & w &= x \end{flalign}$$

$$\begin{eqnarray} \alpha & = & \beta + \gamma \\ \delta & = & \epsilon \end{eqnarray}$$

$$\begin{split} h &= i + j \\ &= k \end{split}$$

$$f(x) = \begin{cases} x^2 & x \geq 0 \\ -x^2 & x < 0 \end{cases}$$

$$g(x) = \begin{dcases} \int_0^x t \, dt & x > 0 \\ 0 & \text{otherwise} \end{dcases}$$

## 3 · Labels

$$
E = mc^2 \label{eq:mass-energy}
$$

$$
\hbar \omega = h \nu {#eq:planck}
$$

## 4 · Greek

$$\alpha \; \beta \; \gamma \; \delta \; \epsilon \; \zeta \; \eta \; \theta \; \iota \; \kappa \; \lambda \; \mu$$

$$\nu \; \xi \; o \; \pi \; \rho \; \sigma \; \tau \; \upsilon \; \phi \; \chi \; \psi \; \omega$$

$$\Gamma \; \Delta \; \Theta \; \Lambda \; \Xi \; \Pi \; \Sigma \; \Upsilon \; \Phi \; \Psi \; \Omega$$

$$\varepsilon \; \vartheta \; \varpi \; \varrho \; \varsigma \; \varphi \; \digamma$$

## 5 · Binary operators

$$\pm \; \mp \; \times \; \ast \; \star \; \circ \; \bullet \; \cdot \; \dagger \; \ddagger \; \amalg$$

$$\oplus \; \ominus \; \otimes \; \oslash \; \odot \; \bigcirc \; \uplus \; \sqcap \; \sqcup \; \wedge \; \vee$$

$$\setminus \; \wr \; \diamond \; \bigtriangleup \; \bigtriangledown \; \triangleleft \; \triangleright \; \cap \; \cup$$

$$\ltimes \; \rtimes \; \leftthreetimes \; \rightthreetimes \; \curlywedge \; \curlyvee \; \boxplus \; \boxminus \; \boxtimes \; \boxdot$$

## 6 · Relations

$$\leq \; \geq \; \equiv \; \sim \; \simeq \; \approx \; \cong \; \neq \; \doteq \; \asymp$$

$$\prec \; \succ \; \preceq \; \succeq \; \ll \; \gg \; \lll \; \ggg \; \lesssim \; \gtrsim$$

$$\subset \; \supset \; \subseteq \; \supseteq \; \subsetneq \; \supsetneq \; \sqsubseteq \; \sqsupseteq \; \in \; \ni$$

$$\propto \; \perp \; \parallel \; \mid \; \bowtie \; \models \; \vdash \; \dashv \; \smile \; \frown$$

$$\nless \; \ngtr \; \nleq \; \ngeq \; \nsim \; \ncong \; \nsubseteq \; \nsupseteq \; \nprec \; \nsucc$$

$$\notin \; \nmid \; \nparallel \; \nvdash \; \nvDash \; \ntriangleleft \; \ntriangleright \; \neq$$

## 7 · Arrows

$$\leftarrow \; \rightarrow \; \leftrightarrow \; \Leftarrow \; \Rightarrow \; \Leftrightarrow$$

$$\longleftarrow \; \longrightarrow \; \longleftrightarrow \; \Longleftarrow \; \Longrightarrow \; \Longleftrightarrow$$

$$\mapsto \; \longmapsto \; \hookleftarrow \; \hookrightarrow \; \leadsto \; \rightsquigarrow \; \multimap$$

$$\leftharpoonup \; \rightharpoonup \; \leftharpoondown \; \rightharpoondown \; \rightleftharpoons \; \leftrightharpoons$$

$$\uparrow \; \downarrow \; \updownarrow \; \Uparrow \; \Downarrow \; \Updownarrow \; \nearrow \; \searrow \; \swarrow \; \nwarrow$$

$$\nleftarrow \; \nrightarrow \; \nLeftarrow \; \nRightarrow \; \nleftrightarrow \; \nLeftrightarrow$$

$$A \xrightarrow{\;f\;} B \xleftarrow{\;g\;} C \xrightarrow[\text{below}]{\text{above}} D$$

## 8 · Big operators

$$\sum_{k=1}^{n} k \qquad \prod_{i=1}^{m} a_i \qquad \coprod_{j} X_j$$

$$\int_a^b f(x)\,dx \qquad \oint_C \mathbf{F} \cdot d\mathbf{r} \qquad \iint_D \qquad \iiint_V \qquad \idotsint$$

$$\bigcup_{n} A_n \qquad \bigcap_{n} B_n \qquad \bigsqcup_{n} C_n \qquad \biguplus_{n} D_n$$

$$\bigvee_{i} p_i \qquad \bigwedge_{i} q_i \qquad \bigoplus_{i} V_i \qquad \bigotimes_{i} W_i \qquad \bigodot_{i} Z_i$$

$$\lim_{x \to 0} \qquad \limsup_{n} \qquad \liminf_{n} \qquad \max_{x \in S} \qquad \min_{x \in S} \qquad \sup \qquad \inf$$

$$\sin \cos \tan \csc \sec \cot \arcsin \arccos \arctan \sinh \cosh \tanh \coth \exp \log \ln \lg$$

$$\deg \det \dim \gcd \hom \ker \Pr \arg \operatorname{sgn} \operatorname{rank} \bmod \pmod{n}$$

## 9 · Delimiters and sizing

$$( a ) \; [ b ] \; \{ c \} \; \langle d \rangle \; \lfloor e \rfloor \; \lceil f \rceil \; | g | \; \| h \|$$

$$\left( \frac{a}{b} \right) \; \left[ \frac{c}{d} \right] \; \left\{ \frac{e}{f} \right\} \; \left\langle \frac{g}{h} \right\rangle$$

$$\big( \Big( \bigg( \Bigg( \quad \big| \Big| \bigg| \Bigg| \quad \big\} \Big\} \bigg\} \Bigg\}$$

$$\lvert x \rvert \; \lVert v \rVert \; \ulcorner p \urcorner \; \llcorner q \lrcorner \; \left. \frac{dy}{dx} \right|_{x=0}$$

## 10 · Accents

$$\hat{a} \; \check{a} \; \tilde{a} \; \acute{a} \; \grave{a} \; \dot{a} \; \ddot{a} \; \dddot{a} \; \breve{a} \; \bar{a} \; \vec{a} \; \mathring{a}$$

$$\widehat{abc} \; \widetilde{abc} \; \overline{abc} \; \underline{abc} \; \overrightarrow{abc} \; \overleftarrow{abc} \; \overleftrightarrow{abc}$$

$$\overbrace{a + b + c}^{\text{upper}} \qquad \underbrace{d + e + f}_{\text{lower}}$$

## 11 · Fonts

$$\mathbb{ABCNQRZ} \qquad \mathcal{ABCLMX} \qquad \mathfrak{ABCgpq}$$

$$\mathsf{ABCxyz} \qquad \mathtt{ABCxyz} \qquad \mathrm{ABCxyz} \qquad \mathbf{ABCxyz} \qquad \mathit{ABCxyz}$$

$$\boldsymbol{\alpha\beta\gamma} \; \text{vs plain} \; \alpha\beta\gamma \qquad \pmb{\Sigma}$$

## 12 · Structures

$$\frac{a}{b} \qquad \dfrac{a}{b} \qquad \tfrac{a}{b} \qquad \cfrac{1}{1 + \cfrac{1}{1 + x}}$$

$$\binom{n}{k} \qquad \dbinom{n}{k} \qquad \tbinom{n}{k} \qquad \genfrac{[}{]}{0pt}{}{n}{k}$$

$$\sqrt{x} \qquad \sqrt[3]{y} \qquad \sqrt[n]{z} \qquad \sqrt{\frac{a}{b + \sqrt{c}}}$$

$$x_i^2 \quad x^{a^{b^c}} \quad x_{i_{j_k}} \quad {}^{12}_{\;6}\mathrm{C} \quad \sideset{_a^b}{_c^d}\sum$$

$$\sum_{\substack{0 < i < m \\ 0 < j < n}} P(i,j) \qquad \overset{!}{=} \qquad \underset{n \to \infty}{\lim}$$

## 13 · Matrices

$$\begin{matrix} a & b \\ c & d \end{matrix} \quad \begin{pmatrix} a & b \\ c & d \end{pmatrix} \quad \begin{bmatrix} a & b \\ c & d \end{bmatrix}$$

$$\begin{Bmatrix} a & b \\ c & d \end{Bmatrix} \quad \begin{vmatrix} a & b \\ c & d \end{vmatrix} \quad \begin{Vmatrix} a & b \\ c & d \end{Vmatrix}$$

$$\left(\begin{smallmatrix} a & b \\ c & d \end{smallmatrix}\right) \quad \begin{array}{c|cc} & x & y \\ \hline a & 1 & 2 \\ b & 3 & 4 \end{array}$$

## 14 · Miscellaneous symbols

$$\infty \; \partial \; \nabla \; \hbar \; \ell \; \Re \; \Im \; \wp \; \aleph \; \beth \; \gimel \; \daleth$$

$$\forall \; \exists \; \nexists \; \neg \; \emptyset \; \varnothing \; \top \; \bot \; \angle \; \measuredangle \; \sphericalangle$$

$$\triangle \; \square \; \blacksquare \; \lozenge \; \blacklozenge \; \diamondsuit \; \heartsuit \; \clubsuit \; \spadesuit$$

$$\flat \; \natural \; \sharp \; \prime \; \backprime \; \surd \; \complement \; \circledS \; \S \; \P \; \dag \; \ddag \; \checkmark$$

$$\dots \; \ldots \; \cdots \; \vdots \; \ddots \; \dotsb \; \dotsc \; \dotsi \; \dotsm$$

$$a \, b \: c \; d \! e \quad f \qquad g \hspace{2em} h \phantom{XX} i$$

## 15 · Package: ams

$$\boxed{a^2 + b^2 = c^2} \qquad \operatorname{Aut}(G) \qquad \text{tagged:} \quad x = y \tag{$\ast$}$$

$$\begin{align} \text{intertext demo} \quad a &= b \\ c &= d \end{align}$$

## 16 · Package: physics

Note: `physics` redefines `\div` as the divergence operator, so `\div` here is
**not** the `÷` sign. That is expected with this package set.

$$\dv{f}{x} \qquad \pdv{f}{x} \qquad \pdv[2]{f}{x} \qquad \dv*{f}{x}$$

$$\bra{\psi} \qquad \ket{\phi} \qquad \braket{\psi}{\phi} \qquad \ketbra{\psi}{\phi}$$

$$\abs{x} \qquad \norm{v} \qquad \eval{f}_0^1 \qquad \order{x^3}$$

$$\Tr(\rho) \qquad \tr(A) \qquad \comm{A}{B} \qquad \acomm{A}{B} \qquad \pb{f}{g}$$

$$\grad \phi \qquad \div \mathbf{F} \qquad \curl \mathbf{F} \qquad \laplacian \psi$$

## 17 · Package: braket

$$\Bra{\psi} \qquad \Ket{\phi} \qquad \Braket{\psi | \hat{H} | \phi} \qquad \Set{ x \in \mathbb{R} | x > 0 }$$

## 18 · Package: cancel

$$\cancel{x} \qquad \bcancel{y} \qquad \xcancel{z} \qquad \cancelto{0}{w} \qquad \frac{\cancel{a}b}{\cancel{a}c}$$

## 19 · Package: mathtools

$$a \coloneqq b \qquad c \eqqcolon d \qquad e \dblcolon f \qquad \prescript{14}{6}{\mathrm{C}}$$

$$\underbracket{a + b} \qquad \overbracket{c + d} \qquad \xleftrightharpoons{u} \qquad \xmapsto{\;\varphi\;}$$

## 20 · Package: empheq

MathJax's `empheq` takes `left=`/`right=` and not `box=`, so this row asks for
an option it implements. Plain `\begin{empheq}{align}` renders too.

$$\begin{empheq}[left=L\Rightarrow]{align} a &= b + c \\ d &= e \end{empheq}$$

## 21 · Package: cases (numcases)

$$\begin{numcases}{f(x)} x^2, & if x > 0 \\ 0, & otherwise \end{numcases}$$

## 22 · Package: enclose

$$\enclose{circle}{x} \quad \enclose{box}{y} \quad \enclose{updiagonalstrike}{z} \quad \enclose{longdiv}{123}$$

## 23 · Package: amscd

$$\begin{CD} A @>f>> B \\ @VgVV @VVhV \\ C @>k>> D \end{CD}$$

## 24 · Package: bbox

$$\bbox[5px, border: 1px solid]{a + b} \qquad \bbox[#ffddaa, 5px]{c + d}$$

## 25 · Package: unicode

$$\unicode{x22C6} \qquad \unicode{x2135} \qquad \unicode{x211D} \qquad \unicode{x2665}$$

## 26 · Package: textmacros

$$\text{plain, \textbf{bold}, \textit{italic}, \texttt{mono}, \textsf{sans}} \quad \text{and } \alpha \text{ inline}$$

## 27 · Packages: newcommand and configmacros

$$\newcommand{\Reals}{\mathbb{R}} \Reals^n \subset \Reals^{n+1}$$

$$\Reals^3 \quad \text{— the macro defined above must still resolve here}$$

## 28 · Packages: autoload and require

$$\require{mhchem} \ce{CO2 + C -> 2CO}$$

$$\require{color} \textcolor{red}{r} \textcolor{green}{g} \textcolor{blue}{b}$$

## 29 · Package: noundefined

These two must render as **red error text inside an image**, not as a failed
entry. `noundefined` is what buys that, and it is why a typo'd macro in a real
document degrades gracefully.

$$\notARealMacro{x} + \alsoNotReal$$

$$\frac{a}$$

## 30 · The XML escaping landmine

MathJax 4 writes raw TeX into `data-latex` attributes, so these serialize to
illegal XML unless the daemon uses `adaptor.serializeXML`. `rsvg-convert`
rejects the file outright if it does not — these four rows go blank or error
first. Guarded by `tests/render_spec.lua`.

$$a < b$$

$$\text{if } x < y \text{ then } z > w$$

$$A \xrightarrow{a<b} B$$

$$p \mathbin{\&} q \quad \text{and} \quad \# \quad \% \quad \_ \quad \{ \}$$

## 31 · Layout stress

One very wide equation — the header should truncate with `…` and the image
should not distort:

$$\zeta(s) = \sum_{n=1}^{\infty} \frac{1}{n^s} = \prod_{p \text{ prime}} \frac{1}{1 - p^{-s}} = \frac{1}{\Gamma(s)} \int_0^{\infty} \frac{x^{s-1}}{e^x - 1} \, dx \quad \text{for} \quad \Re(s) > 1$$

One very tall equation — `display/snacks.lua` must reserve the right number of
buffer lines for it:

$$
\mathbf{M} = \begin{pmatrix}
a_{11} & a_{12} & a_{13} & a_{14} \\
a_{21} & a_{22} & a_{23} & a_{24} \\
a_{31} & a_{32} & a_{33} & a_{34} \\
a_{41} & a_{42} & a_{43} & a_{44} \\
a_{51} & a_{52} & a_{53} & a_{54} \\
a_{61} & a_{62} & a_{63} & a_{64}
\end{pmatrix}
$$

## 32 · Must NOT be indexed

Nothing below this heading may produce an index entry. If any of it does, the
scanner is over-matching.

```python
# not math, even though it looks like it: $x$ and $$y$$
cost = "$5"
price = f"${amount:.2f}"
```

```
$$plain fence, also not math$$
```

A bare price of \$5 and another of \$7 in prose.

<!-- $$commented out in HTML$$ -->
