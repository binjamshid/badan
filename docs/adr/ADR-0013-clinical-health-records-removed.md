# ADR-0013 — HealthKit Clinical Records removed; the lab notebook fills from documents

**Status:** Accepted — 2026-08-01
**Context:** App Review rejected BADAN 1.1 (5) under **Guideline 2.5.1 — Performance — Software
Requirements**, on submission `d3fd0270-abbc-448f-925f-0909044d9585`, reviewed 2026-08-01 on an
iPad Air 11-inch (M3). The finding: "The app uses the Clinical Health Records API but the app does
not appear to include any primary features that require the Clinical Health Records API." The
instruction was specific — uncheck the Health Records capability in App Store Connect while leaving
the HealthKit entitlement enabled, remove every reference to `HKClinicalRecord` from the code, and
remove references to Clinical Health Records from the app and its metadata.

This was the **second** round on the same submission. The first was a 2.1 information request about
how BADAN uses the API; it was answered in full (`docs/app-review/1.1.5-review-reply.md`,
`docs/app-review/chr-1.1.5/review-reply.txt`), with screenshots produced by feeding representative
FHIR through the shipping import path. Apple did not accept the answer as establishing a primary
feature; it escalated to a removal instruction.
**Decider:** Founder.

## The decision

**Remove the Clinical Health Records integration. Do not appeal.**

Apple's reading is defensible on its own terms, and that is the part worth writing down rather than
resenting. The Health Records API is scoped to apps whose *core* is a person's medical records.
BADAN's lab notebook is one feature among many, and the clinical import was one of three ways into
it — the other two being on-device OCR of a scanned document and manual entry. A feature with two
other working ingestion paths does not *require* the API, which is exactly the test 2.5.1 applies.
Appealing would have spent review cycles arguing a point Apple had already ruled on once.

**What was removed:**

| Surface | Disposition |
|---|---|
| `Platform/Health/HealthKitClinicalStore.swift` | deleted — the only file that named `HKClinicalRecord`/`HKClinicalType` |
| `Features/Labs/ClinicalRecordsImportScreen.swift` | deleted, with `ClinicalImportStrings` |
| `LabRoute.clinicalImport` + its Lab-notebook tile | deleted |
| `com.apple.developer.healthkit.access: [health-records]` | removed from `App/BADAN.entitlements`; the plain `com.apple.developer.healthkit` entitlement stays |
| `NSHealthClinicalHealthRecordsShareUsageDescription` | removed from `project.yml`, with a comment saying why it must stay absent |
| App Store Connect "Health Records" capability | **unchecked by the founder in ASC — not a repo change; the submission fails the same way again if this is missed** |

**What was deliberately kept:** `Ingest/Clinical/FHIRObservationParser.swift` and
`Ingest/Clinical/ClinicalRecordImporter.swift`. Neither has ever imported HealthKit or named
`HKClinicalRecord` outside a comment; both are pure functions over FHIR JSON and their own tests.
They are unwired today and their headers say so out loud. They are kept because a provider portal
that lets you download your own results hands you the same shape, and that path — a *file* the user
chose, not an OS-level records read — is not what 2.5.1 refused. Building on them is fine.
**Reintroducing a HealthKit clinical read on top of them is not, and needs a new ADR.**

## What replaces it — documents, on device

The lab notebook now has exactly three ways in: **the document camera, photos from the library, and
a PDF file**, all converging on the existing `LabDocumentOCR` (Vision, `VNRecognizeTextRequest`,
zero network calls) and the existing LAB-07 review screen where every field must be confirmed by
hand before it is committed. Nothing about the review discipline changed.

Three real gaps were closed in the process, because "PDF import already existed" was true only in
the thinnest sense:

1. **A PDF's pages past the first were never read.** `handlePickedPDF` rasterized page index 0 and
   nothing else. A four-page report imported as its cover sheet, and the app said nothing about the
   rest. All pages are now rasterized, bounded by `LabScanLimits.maxPages` (25), and when a
   document is longer the review screen states how many of how many pages were read rather than
   letting a short field list imply the lab reported less than it did.
2. **The photo picker took one image.** `selectionLimit` is now 0 (unlimited); pages load into a
   fixed-index array so page order survives out-of-order provider callbacks.
3. **There was no camera path at all** — the one path that works for a person holding a printed
   report and no file. `VNDocumentCameraViewController` supplies edge detection, perspective
   correction and multi-page capture, all in Apple's own on-device controller. This needs
   `NSCameraUsageDescription`, now present in `project.yml` and both `InfoPlist.strings`.

Recognition moved off the main actor (`Task.detached`) with a visible "Reading the pages on this
device…" state: one page was tolerable inline, and twenty-five would have read as a hang.

## What this does NOT change

- **No network.** Every path added here is Vision on device. `CLAUDE.md`'s two-file socket
  allowlist (`AICoachClient`, `FootprintClient`) is untouched, and no ingestion path acquired a
  network dependency.
- **The offline path.** Scanning, OCR, review and commit all work with no connectivity.
- **Where the data lands.** Imported results still go to `badan_sensitive.db` through the same
  repositories, with the same encryption, purge and export-gating behavior.
- **The four-concept law.** The provider's printed interval and flag are still preserved verbatim
  and never recomputed; BADAN still adds no verdict.

## Consequences, stated plainly

A user whose clinic shares results into Apple Health can no longer pull them in with one tap; they
must export or photograph the report instead. That is a genuine loss of convenience, and the honest
framing is that Apple ruled BADAN is not the kind of app that gets that affordance. The mitigation
is that the remaining paths work for **every** user — Health Records was region-gated and
institution-gated, and unavailable to most of BADAN's users in any case.
