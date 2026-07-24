# ADR-0010 — Approvals A9, A16, A17, A18, A21, A22, A24, A25 (WHOOP/HAE v1.1 gates)

**Status:** Accepted — 2026-07-23
**Context:** `BADAN_WHOOP_HAE_EXECUTION_PLAN.md` §25/§28.1 named A17–A25 as gates on Phase-3
planning and A9 as pre-approved "Phase-3 exit" (now reached). ADR-0009 explicitly left these
open pending "each gets its own memo." This is that memo, for the eight gates the founder
closed in this review; A19, A20, A23 are unchanged from the plan (not raised this round).
**Decider:** Founder.

## A25 — Standing clinical advisor + safety-copy review pipeline

**Decision:** Approved. The founder (RN, nursing background) is the retained clinical
advisor named in A25, covering the §44 safety-language matrix, pregnancy content, vitals-BLE
copy, and release-gate sign-offs.

This directly satisfies the "retained clinical advisor" precondition A18 and A21 name, and
the clinical half of A17's "founder+legal" approval. It does not substitute for GCC/Oman
legal review (A18/A17) — that stays a separate, founder-tracked action.

## A9 — AI coach hosting model

**Decision:** Approved — hybrid, as the plan recommended: on-device retrieval stays local;
hosted stateless inference calls an external LLM from a founder-operated server.

**Concrete parameters (this review):**
- Inference provider: OpenRouter, `gpt-4o`. API key lives server-side only, never shipped
  in the app binary or logged.
- Host: a new, isolated service at `badan.binjamshid.com`, on the founder's existing VPS
  (`159.195.136.45`) — its own systemd unit, own nginx server block, own TLS cert, own
  unprivileged system user. It shares the box but not the process/config/network namespace
  of the founder's other live services on that host (Supabase ×2, mail, WhatsApp bridge,
  Albayyan RAG server).
- **Opt-in only, default off.** No query leaves the device until the user explicitly enables
  the AI coach feature through its own consent screen (separate from onboarding), naming
  what is sent (the query + minimal retrieved context, never raw health rows, never an
  export bundle) and to which service.

**Consequence — this is BADAN's first network call.** It narrowly amends ADR-0002's "no
network calls anywhere in the app": the exception is scoped to this one explicitly-consented,
feature-gated pathway. Every other surface (ingestion, scores, export generation) stays
zero-network, unchanged. This is the "minimal broker" A4 anticipated, scoped to the AI-coach
feature only — it does not itself authorize vendor OAuth (Garmin/Oura), sync, or accounts;
those remain their own decisions (A4 more broadly, A20) if/when reached.
Requires, before ship: a privacy-policy section describing this data flow, an App Store /
Play Data Safety label update (AI coach queries collected, linked to user, when opted in),
and the consent screen copy passing the same wellness-safe/no-diagnosis lint every other
sensitive surface does.

## A16 — SQLCipher for the sensitive-plus database

**Decision:** Approved — adopt now, scoped to `badan_sensitive.db` only.

Pregnancy, glucose, and lab data are all landing on top of the sensitive namespace this
same review unblocks; the plan's own re-raised urgency ("automation + reproductive/lab data
increase unattended surface") is judged to have arrived. `badan.db` (the non-sensitive main
store) is unaffected — it stays on raw system SQLite behind OS-level file protection only,
per ADR-0004/ADR-0005, unchanged.

**Consequence:** amends ADR-0005's "zero external dependencies" posture for this one
dependency only (SQLCipher via SwiftPM on iOS; `net.zetetic:android-database-sqlcipher` on
Android) — the sensitive-DB connection wrapper is the sole seam this touches, per ADR-0005's
own stated reversal-cost design. `purgeSensitiveNamespace()` (D-4/D-18/I7) is unchanged in
behavior: deleting the file remains the purge mechanism, now deleting a SQLCipher-encrypted
file instead of an OS-encrypted one. A passphrase/key-derivation strategy is required (device
Keychain/Keystore-backed, not user-typed — this is at-rest encryption, not the export
passphrase flow of ADR-0008, which is unaffected and unchanged).

## A17 — Fertile-window estimation

**Decision:** Approved — three-mode (calendar / signal-assisted / suppressed),
non-contraceptive framing, per the plan's recommendation. Clinical sign-off: A25. Legal
review: founder's own action (see A18).

CYCLE-12, the one item Phase 3F slice 2 explicitly left gated, is now buildable.

## A18 — Pregnancy module (EPIC-40)

**Decision:** Approved to build, per the plan's own contingency ("Build, Phase 3 start,
contingent on retaining a clinical advisor and completing regional legal review first").
The clinical-advisor half is satisfied by A25. The GCC/Oman legal review is **not** waived —
the founder has taken personal responsibility for preparing and submitting that review to
the relevant regional bodies, in parallel with engineering work, rather than gating build
start on its completion. Engineering proceeds now; ship (App Store submission for this
surface) still requires that review to actually clear.

`docs/legal/reproductive-threat-model.md` (drafted Phase 3F) remains the scoping document
this review answers against; it explicitly said it does not itself authorize A18 — this ADR
entry is that authorization, with the legal-review completion still owed before release.

## A21 — Glucose / CGM

**Decision:** Approved on the plan's own split. Platform-written glucose ingestion/export
(HealthKit `bloodGlucose` / Health Connect `BloodGlucoseRecord` — data the user's own CGM
already wrote to the OS health store) is buildable now, same as any other widened metric.
Direct vendor integrations (Dexcom, Abbott Libre, Lingo — each needing their own OAuth,
developer-program approval, and the highest regulatory scrutiny in the plan) remain deferred
pending both the legal+clinical review (founder's action, as A18) and each vendor's own
developer-program lead time (same external-dependency class as Garmin/A20). "Never for
treatment decisions" stays load-bearing copy on every glucose surface.

## A22 — Watch app

**Decision:** Approved, accelerated to Phase 4 per the plan's recommendation. The founder
has a physical Apple Watch Series 10 for on-device testing (this build environment has no
paired Watch — physical-device verification is the founder's own step, same pattern as the
TestFlight upload boundary).

## A24 — Ambient copy governance

**Decision:** Approved as specced — "lightly interpretive within the wellness-safe
register," all band thresholds/labels and privacy defaults approved as one package, per the
plan's recommendation. Unblocks the copy flagged during Phase 3D (EPIC-33/44) and any
remaining ambient surfaces.

## Not decided here

A4 remains open in its general form (vendor OAuth/sync backend) — only the AI-coach-scoped
network exception above is decided. A5 (Vitality Trend), A19 (lab cloud-OCR/FHIR), A20
(Garmin commercial license), A23 (BLE doctrine — already effectively settled by Phase 3C's
implementation) are unchanged from the plan and were not raised in this review.
