# PHQR V2 — Confirmed Quartile Rejection

PHQR V2 is a **short-only MetaTrader 5 Expert Advisor** built around a confirmed quartile-rejection setup using the immediately previous fully closed H1 candle as its reference.

This version is intended to be **deterministic, auditable, and suitable for direct comparison against PHQR V1**. It is not an optimization project, does not use adaptive indicators or recovery systems, and does not claim profitability.

## Strategy summary

For each setup, PHQR V2 uses the previous fully closed H1 candle and freezes:

- **H** = previous H1 high
- **L** = previous H1 low
- **R** = H - L
- **Q75** = L + 0.75R
- **Q50** = L + 0.50R
- **Q25** = L + 0.25R

The setup is valid only during the immediately following H1 candle.

A short setup requires:

1. The reference H1 range to pass the ATR(14) filter.
2. The reference candle not to qualify as an unusually strong bullish expansion.
3. Price to sweep above Q75 by the configured amount.
4. Price to remain below the previous H1 high before a valid rejection completes.
5. A fully closed bearish M5 rejection candle that:
   - reaches or exceeds the sweep level,
   - stays below the previous H1 high,
   - closes below Q75,
   - closes above Q50,
   - closes bearish,
   - closes in the lower half of its own range.
6. A **SELL LIMIT at Q75** after that rejection candle has closed.

The EA does not chase price with a market entry.

## Default trade management

- Pending entry expiry: **2 M5 bars**, capped by the setup-H1 end
- Stop loss: previous H1 high + max(**1% of R**, **1.5 × current spread**)
- Take profit: **Q25**
- Minimum planned RR: **1.60**
- Position risk: **0.50% of current account equity**
- Break-even trigger: actual **+1R**, confirmed by a fully closed M5 candle
- Forced end-of-H1 exit: **removed**
- Optional maximum holding time: **disabled by default**
- Daily loss guard: blocks new entries after realized daily result reaches **-2R**
- Session filter: available but **disabled by default**
- Strategy direction: **short only**

## Important behavior changes from earlier PHQR V2

This version replaces several earlier rules:

- no forced close when the setup H1 candle ends after a position has filled;
- Q50 is no longer the direct break-even trigger;
- default stop buffer is now 1% of the reference range rather than 2%;
- previous-H1-high breaks invalidate the setup before rejection;
- rejection candles must close in the lower half of their own range;
- minimum planned RR is 1.60;
- position sizing is equity-risk based rather than fixed-lot based.

See [IMPLEMENTATION_NOTES.md](IMPLEMENTATION_NOTES.md) for the full rule checklist and change log.

## Files

| File | Purpose |
| --- | --- |
| `PHQR_V2_ConfirmedRejection.mq5` | Complete Expert Advisor source |
| `PHQR_V2_ConfirmedRejection.defaults.set` | Baseline input values |
| `IMPLEMENTATION_NOTES.md` | Detailed implementation notes, rule checklist, tester notes, and CSV field guide |
| `LICENSE` | Repository license |

## Installation

1. Open MetaTrader 5.
2. Open **MetaEditor**.
3. Copy `PHQR_V2_ConfirmedRejection.mq5` into your MT5 `MQL5/Experts` directory.
4. Open the file in MetaEditor and compile it with **F7**.
5. Attach the EA to the broker's actual gold symbol, such as `XAUUSD`, `XAUUSDm`, `XAUUSD.a`, or `GOLD`.
6. Use the supplied `PHQR_V2_ConfirmedRejection.defaults.set` file if you want the baseline configuration.

The EA uses `_Symbol` and the symbol's own tick size, tick value, volume limits, and volume step rather than assuming one fixed gold contract specification.

## Recommended Strategy Tester settings

- **Expert:** `PHQR_V2_ConfirmedRejection`
- **Chart period:** M5
- **Model:** Every tick based on real ticks, when available
- **Symbol:** your broker's actual gold symbol
- **Inputs:** baseline defaults, without optimization
- **Deposit/account settings:** match the intended trading account as closely as practical

Run multiple non-overlapping periods before drawing conclusions from any backtest.

## News-filter limitation in Strategy Tester

Live/demo operation retains the native MT5 high-importance USD economic-calendar filter.

MT5's native Economic Calendar is not available inside Strategy Tester. With:

`TesterAllowTradesWithoutNewsData=true`

otherwise-valid tester entries are allowed so the strategy can be backtested. As a result, Strategy Tester runs **do not reproduce historical news blackout periods** unless an external historical news source is added separately.

Live/demo news handling remains fail-closed by default when calendar data is unavailable.

## Audit and logging

The EA retains:

- CSV logging
- chart levels and status dashboard
- tester audit output
- MagicNumber ownership checks
- duplicate-order protection
- broker trade-result and retcode checks
- restart/state recovery
- netting and hedging account handling
- MFE/MAE tracking relative to original risk

CSV output includes reference-candle data, quartile levels, filters, sweep/rejection details, order state, actual entry, initial SL, TP, planned RR, risk, break-even state, MFE/MAE, exit information, P/L, and result in R.

## Backtest integrity

The implementation is designed around closed-bar decisions:

- reference H1 candle: closed candle only;
- rejection M5 candle: closed candle only;
- break-even confirmation: closed M5 candle only;
- entry occurs only after the rejection candle has closed;
- no future-data access or intentional look-ahead logic.

## Disclaimer

This repository contains experimental trading-system software for research and testing. It does **not** make any claim of profitability, robustness, or future performance.

Backtests can differ materially from live execution because of spread, slippage, liquidity, broker rules, data quality, execution timing, commissions, swaps, and the Strategy Tester news limitation described above.
