# Variance ledger — one file per task

This directory records every place the Android parity port deliberately substitutes a different
Android capability for something iOS does, rather than porting the iOS behaviour unchanged. It
exists because release gate G6 permits "feature-list parity **or labeled variance**" — variance is
an accepted outcome, but only if it is *labeled*, i.e. written down by the agent that made the
call, with the reason, at the time it made it.

## The convention: one file per task id, never a shared ledger

Every task that produces a variance writes exactly one file here: `docs/variance/<task-id>.md`
(e.g. `docs/variance/B3-ambient.md`, `docs/variance/B2-1-sqlcipher.md`). **Not** a shared,
appended-to `docs/android-variance-ledger.md` that every task edits.

This is deliberate, not a style preference:

- **The agent that made the substitution is the one holding the context.** It knows *why* Play
  Integrity stands in for App Attest, what was tried, what iOS actually does versus what the
  Android platform makes possible, and what the honest boundary of the substitution is. That
  context is expensive to reconstruct later and cheap to write down now, while the agent that just
  finished the work still has it loaded.
- **A shared file is a magnet.** If every task appended to one ledger file, that file would need
  to be either frozen (defeating the purpose — the whole point is to capture variance as it's
  discovered, not through a registry someone pre-allocates slots in) or contested (multiple
  concurrent tasks editing the same file, the exact collision `scripts/check_task_ownership.sh`
  exists to catch). A file with your task's own id in its name is trivially inside your task's
  declared owned paths — `docs/variance/<task-id>.md` — with no coordination needed.
- **Aggregation is a separate, later, deliberate step.** Batch 4's final task
  (`docs/android-variance-ledger.md` per the plan) reads every `docs/variance/*.md` file and
  produces the single consolidated document G6's checklist is actually answered against. That
  aggregation step owns the shared file; individual tasks never do.

## What every task must do

- If your task substitutes, drops, or otherwise diverges from the iOS behaviour it's porting,
  write `docs/variance/<task-id>.md` describing the substitution, the reason, and what a user
  or reviewer sees as a result.
- If your task has **no** variance, still create the file, with content to that effect (e.g. "No
  variances. This area ports iOS behaviour unchanged."). The file's existence is itself a signal —
  the aggregation step and any human auditing G6 needs to know a task *considered* the question,
  not just that it didn't happen to answer it. A missing file is ambiguous between "nothing to
  report" and "the task never got there"; an explicit "no variances" file is not.
- Use the task id exactly as assigned (matching the id used in the task's own contract header,
  e.g. `B3-cycle`, `B2-6`), so the aggregation step can find every file mechanically rather than by
  guessing at naming.

## What belongs in a variance file

A short markdown document, no fixed template required, but each one should make these things
findable:

- **What iOS does** that this substitutes for (name the source file/behaviour).
- **What Android does instead**, and why (a real platform constraint — "Android Keystore cannot
  store arbitrary bytes," "Health Connect has no push observer," "`setAlternateIconName` has no
  Android analogue" — not "this was faster to build").
- **What a user or reviewer notices**, if anything — a different permission prompt, a differently
  worded consent screen, a capability that's simply absent.
- **Whether it's revisitable** — e.g. "not available at connect-client 1.1.0; revisit on SDK bump"
  is a stated substitution with a future condition, which is different from a permanent claim like
  "Android has no FHIR." Say which kind it is.

Do not write a false permanent claim where a narrower, dated one is true. "Not available today, for
this stated reason" is honest; "Android can't do this" foreclosing something that is really just
unimplemented or version-gated is not.
