# ADR-0014 — Accounts arrive: Sign in with Apple, cross-platform entitlement sync, referrals

**Status:** Accepted — 2026-08-07
**Context:** The founder asked for Sign in with Apple, wired for cross-platform subscription sync
and referrals. This reverses accepted decisions rather than extending them, and the conflict was
raised before any code was written: **D-32** dropped SIWA *by name*, **D-40** extended the
no-accounts posture to Android, and **ADR-0002 / ADR-0010** state that this service holds no
accounts, no sync and no server-side user state. The founder confirmed the direction after the
conflict was stated. This ADR is what that confirmation is written down as.
**Decider:** Founder.
**Supersedes:** D-32 in full. Narrows ADR-0002 and ADR-0010. See "What this does NOT change".

## The decision

**BADAN gains an optional account, created with Sign in with Apple, whose only jobs are carrying a
subscription between platforms and running referrals.**

### Why the old decision was right, and why it stopped being sufficient

D-32's reasoning was factually correct and remains so: Guideline 4.8 requires SIWA only when an app
offers *other* third-party logins, StoreKit binds a purchase to the signed-in Apple ID by itself,
and Restore Purchases works with no account. Nothing about that has been discovered to be wrong.
An account is still not required to *sell* anything, and this ADR does not claim otherwise.

What D-32 did not have to answer, because iOS was the only surface, is what happens when the same
person pays on iOS and installs on Android. StoreKit's binding is to an Apple ID and stops at
Apple's boundary; Play's binding is to a Google account and stops at Google's. Nothing either store
offers spans the two. A user who bought a lifetime tier on an iPhone and later switched to Android
would, under D-32, be asked to buy it again — and would be right to call that a bug.

So the account is not being added to satisfy a guideline (it never was required for that), and not
to enable server-side history (there is none). It is being added because **entitlement is the one
piece of state that genuinely has to outlive a single vendor's ecosystem**, and there is no
mechanism that does it without an identity of some kind.

Referrals ride the same account for the same reason: a referral is a claim about a relationship
between two installs, and there is nowhere else to put it.

### What the account holds

The whole of it, on the server:

| Column | Why |
|---|---|
| `account_id` | opaque, server-minted, unrelated to anything Apple issued |
| `subject_hash` | **HMAC-SHA256 of Apple's `sub` claim under a server-held salt.** Never the claim itself |
| `created_at` | the referral claim window |
| `referral_code` | the user's own code |
| `referred_by`, `claimed_at` | one claim per account, ever |
| `rewarded_referrals`, `referral_grant_expires_at` | the reward, capped |
| `account_entitlements(platform, product_id, is_lifetime, expires_at, observed_at)` | one row per platform |

There is no name, no email, no Apple identifier in the clear, no device list, no IP, no request
history, and no health datum. `backend/api/tests/test_accounts.py::test_the_accounts_schema_holds_no_health_column`
pins that column list; a migration that adds a health-shaped column fails CI.

### Three choices worth defending

**No scopes are requested.** `ASAuthorizationAppleIDRequest.requestedScopes` is left empty.
Apple would hand over `fullName` and `email` for the asking and every tutorial asks. BADAN has no
use for either, and a field never collected cannot leak, cannot appear in a breach, and cannot
quietly start being used by a feature written two years from now.

**The subject is hashed, not stored.** A dump of `accounts.db` does not reveal which Apple IDs use
BADAN, even to someone who can enumerate them, because the salt never leaves the server. The
`sub` claim is opaque but it is not secret — it is stable across every app on the same team.

**The remote may grant access; it may never revoke it.** `EntitlementMerge.resolve` returns
`.localStore` unconditionally and first, so every subsequent line is unreachable for a user who
owns the product on this device. This is the single rule that makes reversing the no-backend
posture survivable: a server outage, a bad deploy, a revoked session, or a bug in a route added
years from now cannot lock a paying user out of their own health app. It is enforced structurally,
not by care, and `EntitlementMergeTests.testARemoteThatSaysNothingCanNeverRevokeALocalPurchase`
is the test.

A synced entitlement is nonetheless weaker than a local one — Apple signs its cache, we do not —
so it stops granting 30 days after the last successful server read (`offlineGraceDays`). That
bound never applies to a local purchase, so the plane scenario `SubscriptionPolicy` was written for
is untouched.

## What this costs, stated before it is discovered

- **Account deletion is now mandatory.** App Review 5.1.1(v) requires in-app deletion from any app
  offering account creation. Implemented (`AccountSettingsScreen`, `DELETE /v1/account`); removing
  it fails review rather than merely disappointing.
- **The privacy nutrition label changes.** BADAN now collects a user identifier. `PrivacyInfo.xcprivacy`
  and the App Store Connect privacy answers must say so. "Zero network calls" was already false
  after ADR-0010; "no accounts" is false as of this ADR, and both hosted policies are updated.
- **BADAN becomes a data controller for something.** Not health data — but an account is personal
  data under GDPR, which is why deletion is real rather than a local clear.
- **A third socket-opening file.** `.github/workflows/ci.yml`'s `NET_ALLOWLIST` grows by one entry,
  for `Platform/Account/AccountClient.swift`. A fourth still requires a new ADR.
- **A referral reward is real money.** Minting an account costs one sign-in tap, so the referrer
  reward is capped at 10 (`ReferralPolicy.maxRewardedReferrals`), the claim window is 30 days, and
  the server enforces both — nothing a client says about its own eligibility is trusted.

## What this does NOT change

**"Send no health data off device" survives completely intact.** This is the important sentence in
this document. D-44 changed the *accounts* Never. It did not touch the health-data one, and two
tests exist specifically to keep the second true now that the first is gone:
`AccountPayloadShapeTests` (the encoded shape of every request the client can build) and
`test_the_accounts_schema_holds_no_health_column` (the server's columns). What crosses this wire is
a statement about a *purchase* — a store, a product id, an expiry. Never a reading, a score, a
metric id, a source, or a date that says anything about a body.

**Signed out remains a complete, permanent, first-class state.** Every reading, derivation, log and
export within the D-33 window works identically with no account. `AccountState` has no case that
could express "blocked until you sign in", and nothing in the app may acquire one.

**D-33 remains the only gate on a user's own records.** Referrals grant premium *time*; they gate
nothing new. A user who never refers anyone loses nothing they would otherwise have had.

**No sync of anything else.** This authorises accounts and entitlement state. It does not authorise
health-data sync, server-side history, backup, or a second backend surface. ADR-0002's core claim —
on-device SQLite is the sole source of truth for health data, and ingestion, scores and export
generation are zero-network — is unchanged and still enforced by the same lint gates.

## Scope actually shipped

**iOS only.** The founder scoped this build to iOS after the direction was confirmed. The backend
already speaks Android's half of the wire (`PLATFORMS` includes `"android"`, entitlements are keyed
by `(account_id, platform)`, and the tests exercise an Android push), so the gap is client-side —
plus an Apple **Services ID** and **.p8 key** that do not exist in the developer account yet and
cannot be created from the repository. Android has no Play Billing integration either (D-40 specced
the product-id space; nothing was built), so it has no local entitlement to report even in
principle.

Until that lands, "cross-platform" describes what the *service* supports, not what a user can do
today. `docs/android-parity-status.md` carries the full gap list. Do not describe this feature to
users as working across platforms before the Android client ships.
