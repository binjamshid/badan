# Why our Readiness number differs from WHOOP's Recovery

> An education page for the in-app "learn more" surface. Plain-language, honest, and non-defensive.
> Companion to the methodology in [readiness.md](readiness.md). This is not a medical evaluation.

If you have worn a WHOOP, you will notice BADAN's morning **Readiness** and WHOOP's **Recovery** are
not the same number. That is expected — and it does not mean either one is wrong. Here is the honest
explanation of why they differ, and how to read ours.

## They are different scores built by different people from different choices

WHOOP's Recovery and BADAN's Readiness both try to summarise overnight recovery signals into one
morning percentage, and they draw on overlapping inputs — heart-rate variability, resting heart rate,
respiratory rate, sleep. But two teams turning those signals into one number will make different,
defensible choices about **which inputs matter most, over what baseline, and on what scale**. Different
choices produce different numbers. That is true of any two recovery scores, not just these two.

We are not trying to reproduce WHOOP's number. We could not honestly claim to: **WHOOP's exact formula
and weightings are not published.** So rather than guess at someone else's undisclosed recipe, we
designed our own and **published all of it** — the inputs, the weights, the math, and the confidence
rules are in [readiness.md](readiness.md) and in the app's anatomy sheet on every score. If you ever
want to know why BADAN says what it says, you can read exactly how the number was built and which of
your own readings fed it. That transparency is the whole point of the number.

## The specific choices that move our number

- **Our weights are our own.** BADAN weights HRV most heavily (half the score), then resting heart
  rate and sleep performance, then respiratory rate — a deliberate, published set of launch weights,
  not a copy of anyone's. A score that leans differently on the same inputs lands on a different value.
  (These weights are still *provisional* — we will refine them against data and tell you, in an in-app
  changelog, whenever we do.)
- **We compare you only to yourself.** Every input is judged against **your own** personal baseline —
  your usual HRV, your usual resting heart rate — never against a population average. Where your
  personal "normal" sits, and how long a window we build it over (HRV over 60 days, for example),
  shapes the number. Two apps with different baseline windows will read the same night differently.
- **Sleep enters on its own terms.** BADAN folds in how much of *your* estimated sleep need last night
  covered. How much sleep counts, and how it is scored, is another honest design choice that shifts the
  result.
- **A missing signal changes the number honestly.** If your watch did not record HRV last night, we do
  **not** invent a value. We drop that input, redistribute its weight, label the result as a
  reduced-input estimate, and lower its confidence — rather than quietly filling the gap. That can make
  our number differ from a score that imputes missing data.

## How to read BADAN's Readiness

- **Watch your own trend, not a cross-app match.** The most useful signal is how today compares with
  *your* recent mornings on *one* consistent scale. Comparing a Readiness percentage against a Recovery
  percentage point-for-point is comparing two different rulers — the comparison will mislead you even
  when both are working perfectly.
- **Confidence is part of the number.** An early-calibration or reduced-input score is labelled as
  such. A lower-confidence morning is not a worse recovery — it means we had less to go on, and we would
  rather say so than pretend.
- **It is guidance, not a verdict.** Readiness is a wellness summary to help you plan your day gently —
  "a lighter day may suit you." It is never a diagnosis, never an instruction, and **not a medical
  evaluation.** If something about your health worries you, talk to a clinician, not an app.

We think WHOOP built a genuinely useful score, and we are glad recovery scoring exists. BADAN's answer
to it is not "ours is higher" or "ours is righter" — it is "ours is **yours to inspect**." A different
number you can fully see the reasons for is worth more than a matching number you cannot.
