# Walking an LCG backwards

Notes from a CTF challenge whose "random" padding came
from a linear congruential generator. One leaked state
and the generator's constants are enough to recover
every state before it, the seed included.

## Setup

The generator keeps a single number, its state,
reduced modulo $M$:

$$
s_t \in \mathbb{Z}_M = \{0, 1, \dots, M - 1\}
$$

The constants $A$, $B$ and $M$ were hard-coded in the
binary, and the fourth output leaked in an error
message.

## Observation

The generator advances by one multiply and one add:

$$
s_{t+1} \equiv s_t \cdot A + B \pmod{M}
$$

which means we can walk it backwards, as long as the
multiplier has an inverse modulo $M$:

$$
\gcd(A, M) = 1
$$

$M$ is prime here, so any $A \neq 0$ qualifies.

## Action

Undoing one step is a subtraction and a multiplication
by the inverse:

$$
s_t \equiv (s_{t+1} - B) \cdot A^{-1} \pmod{M}
$$

Rather than loop, undo $k$ steps from the leaked state
$s_n$ at once:

$$
s_{n-k} \equiv A^{-k}
\left( s_n - B \sum_{i=0}^{k-1} A^{i} \right) \pmod{M}
$$

The sum is geometric, so it has a closed form whenever
$A - 1$ is invertible too:

$$
\sum_{i=0}^{k-1} A^{i}
\equiv \frac{A^{k} - 1}{A - 1} \pmod{M}
$$

## Checking

Stepping the recovered seed forward has to reproduce
the leak:

$$
\begin{align*}
s_1 &\equiv s_0 \cdot A + B \\
s_2 &\equiv s_0 \cdot A^2 + B (A + 1) \\
s_3 &\equiv s_0 \cdot A^3 + B (A^2 + A + 1)
\end{align*}
$$

It did, and $s_0$ was the Unix timestamp of the
server's start-up.
