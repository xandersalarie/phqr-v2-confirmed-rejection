# PHQR V2 — Confirmed Quartile Rejection

## 1. Changes made from previous V2

- Renamed the EA source to `PHQR_V2_ConfirmedRejection.mq5` and updated the displayed strategy name.
- Preserved the existing EA architecture: `CTrade`, symbol/magic ownership checks, broker safety checks, persistence/state recovery, chart objects, dashboard, CSV logging, tester audit output, netting/hedging handling, and duplicate-order protections.
- Reference candle remains the immediately previous fully closed H1 candle and quartiles are frozen from that candle.
- ATR filter defaults changed to ATR(14), 0.65–1.60 x ATR and are configurable.
- Bullish expansion defaults changed to body ratio 0.65 and close location 0.80.
- Sweep remains Q75 + 3% of the reference range, but the setup is now invalidated if the previous H1 high is traded at or above before a valid rejection completes.
- M5 rejection now additionally requires the closed rejection bar to have `High < previous H1 High` and to close in the lower half of its own range (`RejectionCloseLocationMax=0.50`).
- Pending sell-limit expiry uses `EntryExpiryM5Bars=2`, capped by the end of the setup H1 candle.
- Stop buffer defaults changed to 1% of reference range or 1.50 x current spread, whichever is larger.
- Minimum planned RR changed to 1.60.
- Removed fixed-lot sizing mode. Position sizing now uses 0.50% of current account equity by default and the symbol's own tick/volume properties.
- Break-even trigger changed from geometric Q50 logic to actual +1R based on the actual filled entry and original stop, confirmed only by a fully closed M5 candle.
- Removed the forced setup-H1 time exit after a filled position. Positions now resolve by TP, SL, or BE by default.
- Added optional `UseMaximumHoldingTime=false` / `MaximumHoldingMinutes=180` safety exit.
- Daily loss guard now uses realized net strategy R for the broker day and latches once the result reaches `-MaxDailyLossR`.
- Preserved native MT5 high-importance USD news filtering in live/demo. Strategy Tester compatibility remains available because MT5 does not provide its native calendar to tester runs.
- Expanded CSV fields to include the requested setup, rejection, order, BE, MFE, MAE, exit, profit, and R-result data.
- Expanded the dashboard/levels for the confirmed-rejection state, actual entry, initial/current SL, TP, +1R BE trigger and filter state.

## 2. Old rules removed/replaced

- Forced closing of an already-filled trade at the end of the setup H1 candle.
- Q50 as the direct break-even trigger.
- Default `StopBufferPercent=0.02`.
- Previous looser bullish-expansion defaults.
- Previous looser ATR bounds.
- Previous `MinRR=1.50` default.
- Rejection signals after the previous H1 high has already been broken.
- Rejection candles without the lower-half close requirement.
- Fixed-lot sizing as an active strategy mode.

## 3. Strategy-rule checklist

- [x] Previous fully closed H1 candle only.
- [x] Frozen H/L/R/Q75/Q50/Q25 for each setup.
- [x] Signal window is only the next H1 candle.
- [x] Maximum one trade attempt per reference H1 candle.
- [x] ATR(14) handle + CopyBuffer using closed H1 data.
- [x] ATR range filter defaults 0.65 to 1.60.
- [x] Strong bullish expansion rejection defaults 0.65 / 0.80.
- [x] Sweep level = Q75 + 0.03R.
- [x] Previous H1 high break invalidates the setup before rejection.
- [x] Rejection uses fully closed M5 candles only.
- [x] Rejection high >= sweep and < previous H1 high.
- [x] Rejection closes below Q75, above Q50, bearish, and in lower half of its own range.
- [x] SELL LIMIT at Q75 only; no market chase entry.
- [x] Pending expiry after 2 M5 bars or setup-H1 end, whichever first.
- [x] `SIGNAL_NO_FILL` recorded when an eligible pending entry expires unfilled.
- [x] SL = previous H1 high + max(1% R, 1.50 x current spread).
- [x] SL/TP normalized to symbol tick size and broker stop/freeze constraints checked.
- [x] TP = Q25 exactly.
- [x] Planned RR checked before order; minimum 1.60.
- [x] BE uses actual filled entry + actual original SL, with a closed-M5 +1R confirmation.
- [x] BE modification is one-way and one-time; no trailing stop.
- [x] No forced H1 exit after fill.
- [x] Optional max holding time exists and is disabled by default.
- [x] Equity-percent risk sizing defaults to 0.50%.
- [x] Uses `_Symbol`, tick-size/value and volume min/max/step.
- [x] No martingale, grid, averaging-down or recovery sizing.
- [x] Daily realized-R guard defaults to 2R and blocks only new entries.
- [x] Spread filter defaults to 3% of reference range.
- [x] Native MT5 USD high-importance news filter retained for live/demo.
- [x] Optional session filter retained, default off, server/GMT selectable.
- [x] Short-only; long strategy remains disabled/unimplemented.
- [x] Magic-number ownership, duplicate prevention and own-order/position management retained.
- [x] CTrade result and trade-server retcode checking retained around trade actions.
- [x] State machine and restart reconstruction retained.
- [x] Chart levels/dashboard retained and expanded.
- [x] CSV logging retained and expanded to required audit fields.
- [x] MFE/MAE measured relative to original trade risk.
- [x] Closed-H1 / closed-M5 / no-future-data model retained for tester integrity.

## 4. Unavoidable assumptions / implementation notes

- MT5's native Economic Calendar is not available inside Strategy Tester. `TesterAllowTradesWithoutNewsData=true` therefore permits otherwise-valid entries in tester runs while leaving live/demo news-filter behavior fail-closed by default. This means a tester run does not reproduce historical news blackout periods unless external historical calendar data is supplied separately.
- Session filtering in GMT during historical tests needs the correct server-vs-GMT offset. `TesterServerGMTOffsetMinutes` is exposed because historical DST offsets can vary by broker/date.
- The `EnableLongStrategy` input remains present for compatibility but the strategy contains no active long implementation, as specified.
- Static validation can verify source structure/defaults and rule markers, but only MetaEditor's compiler can conclusively certify 0 errors / 0 warnings on the user's installed MT5 build.

## 5. Recommended Strategy Tester settings

- Expert: `PHQR_V2_ConfirmedRejection`
- Symbol: broker's actual gold symbol (for example XAUUSD, XAUUSDm, XAUUSD.a, GOLD)
- Chart period: M5
- Model: Every tick based on real ticks, when available
- Deposit/account settings: match the intended trading account
- Inputs: use the supplied defaults for a clean falsifiable baseline; do not optimize parameters
- News: remember native calendar blackout periods are not historically reproduced in MT5 tester when `TesterAllowTradesWithoutNewsData=true`
- Run multiple non-overlapping periods before drawing conclusions; no profitability claim is made by this package.

## 6. CSV output field guide

The CSV records every reference H1 setup and event snapshots. Core fields include:

- `reference_timestamp`, `symbol`, reference OHLC, `range`, `Q75`, `Q50`, `Q25`
- `ATR14`, `range_ATR_ratio`, `body_ratio`, `close_location`
- ATR/expansion/spread/news/session filter results
- sweep detection/time and previous-high-broken flag
- rejection detection/time and rejection M5 OHLC/close-location
- order placement time, expiry/no-fill state
- actual entry, initial SL, TP, initial RR, lot size and account-currency risk
- BE trigger, activation and time
- maximum favorable/adverse excursion expressed in original R
- exit time/price/reason, account-currency P/L and final result in R
- final setup state/skip reason and broker order/position identifiers

The file is intended for deterministic audit and PHQR V1 vs V2 comparison, not for parameter optimization.