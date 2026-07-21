# Sleep efficiency → see [sleep.md](sleep.md) and [baselines.md](baselines.md)

`sleep.efficiency` is the share of time in bed actually spent asleep. It is a composite the
baseline pipeline appends (`BaselineEngine.appendSleepEfficiency`) and is documented alongside
the rest of the EPIC-24 sleep cluster in **[sleep.md](sleep.md)**; the baseline banding it feeds
is in **[baselines.md](baselines.md)**.

This file exists because `algorithms.json` records
`methodologyUrl: docs/algorithms/sleep-efficiency.md` for the `composite.sleep_efficiency` entry
(the in-app anatomy sheet follows that link), while the canonical write-up lives in `sleep.md`.
It mirrors the redirect-stub convention used by [sleep-need.md](sleep-need.md) and
[sleep-consistency.md](sleep-consistency.md).
