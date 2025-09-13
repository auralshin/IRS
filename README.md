# Interest Rate Swap (Hook) on Uniswap v4

This project is a prototype **Interest Rate Swap (IRS)** protocol built using **Uniswap v4 hooks**.  
The system enables traders to take **fixed vs. floating exposure** on an index (e.g. ETH base rate).  
Funding is accrued continuously and settled in **token1** through the Router.

---

## What is an IRS?

An **Interest Rate Swap** allows participants to exchange:

- **Fixed leg**: pays a predetermined fixed rate.  
- **Floating leg**: pays or receives based on an evolving index (e.g. ETH staking yield).  

In this design:

- Pools have a **maturity date**; swaps/adds are blocked after maturity.  
- **Funding** accumulates over time as the difference between the pool’s implied fixed rate and the floating index.  
- When positions are closed or settled, the funding owed is netted and paid in **token1**.  

---

## Unique Math

### 1. Exponential Weighted Index

The floating index is smoothed with EWMA to avoid noise:

$$
I_t = I_{t-1} + \alpha\,(r_t - I_{t-1}), \qquad \alpha = \frac{\mathrm{alphaPPM}}{10^6}
$$

- **Deviation clamp:** the raw observation $r_t$ is compared to the previous smoothed index $I_{t-1}$ and the change is clamped multiplicatively to ±`maxDeviationPPM` (parts-per-million) around $I_{t-1}$. Equivalently,

$$
\tilde{r}_{t} = \mathrm{clamp}\Big(r_t,\; I_{t-1}\cdot\big(1 - \tfrac{\mathrm{maxDeviationPPM}}{10^6}\big),\; I_{t-1}\cdot\big(1 + \tfrac{\mathrm{maxDeviationPPM}}{10^6}\big)\Big)
$$

and then the EWMA update uses $\tilde{r}_{t}$ in place of $r_t$.

- **Staleness guard:** ignore updates older than `maxStale`.

---

### 2. Funding Rate

The funding rate is the spread between floating index and pool-implied fixed:

$$
f_t = \mathrm{clamp}\big(I_t - R^{\mathrm{pool}}_{t},\; \pm\,\mathrm{maxDeviationPPM}\big)
$$

---

### 3. Funding Index Integration

Funding is integrated over time to build a **cumulative index**:

$$
\Phi_t = \Phi_{t-1} + f_t\cdot\frac{\Delta t}{\mathrm{SECONDS\_PER\_YEAR}}
$$

Each position stores a snapshot $\Phi_{\mathrm{pos}}$, which is the value of the cumulative funding index $\Phi$ taken when the position was last created or updated; the position's funding owed is computed from the difference $\Phi_t - \Phi_{\mathrm{pos}}$.

---

### 4. Funding Owed Per Position

For liquidity \(L\):

$$
\Delta\mathrm{owed}_{\mathrm{token1}} = (\Phi_t - \Phi_{\mathrm{pos}})\cdot L\cdot \kappa
$$

- Positive = trader receives token1  
- Negative = trader pays token1  
- $\kappa$ is a scaling factor from liquidity to notional.

---

### 5. Flash Accounting Settlement

After a swap/add/remove, Uniswap v4 returns `BalanceDelta (d0, d1)`.  
The Router enforces conservation:

- If \(d_i < 0\): pay in token \(i\) (`sync → transferFrom → settle`)
- If \(d_i > 0\): collect out token \(i\) (`take`)

$$
\sum\mathrm{pays} - \sum\mathrm{collects} = d_0 \oplus d_1
$$

This guarantees **no stranded credits**

---

## License

[MIT](LICENSE)
