# BADAN Laboratory Test Results Notebook Research

## 1. Executive framing

BADAN's Laboratory Test Results Notebook should not be conceived as a thin "lab dashboard" layered on top of uploaded PDFs. It should be designed as a durable, provenance-first personal laboratory record system: a place where users can ingest laboratory reports from multiple channels, retain original source documents, normalize structured observations where safe, preserve original wording where normalization is unsafe, inspect every value with source context, and export the resulting record in both human-readable and machine-readable forms. This aligns directly with BADAN's repository-first thesis and its existing architectural direction toward a user-owned health ledger rather than a closed wellness app.[cite:65][cite:68][cite:73]

The product opportunity is unusually strong because mainstream consumer health apps still treat lab data as peripheral. Apple Health supports Health Records and exposes clinical records as `HKClinicalRecord` samples when providers participate, but provider availability is uneven and access remains dependent on health-system FHIR integrations rather than a universal lab notebook model.[web:106][web:148][web:151] Android Health Connect's new Medical Records APIs introduce a promising FHIR-based path for laboratory records, but the APIs remain experimental, Play policy is still evolving, changelog-style syncing is incomplete, and ecosystem coverage is still far from universal.[web:176][web:138] That leaves a large product gap for a privacy-focused, user-controlled system that can unify structured FHIR imports, PDF/image ingestion, manual entry, and exportable notebook workflows without pretending to diagnose disease.

BADAN should therefore treat laboratory data as a first-class repository domain with five obligations. First, preserve the original clinical artifact and source context. Second, maintain analyte-level structure where possible, but never discard source wording to force structure. Third, separate source reference intervals from BADAN's personal-baseline analytics and from any optional user-defined thresholds. Fourth, make every explanation explicitly non-diagnostic and evidence-traceable back to visible records. Fifth, assume multilingual, cross-lab, cross-unit, and cross-format messiness as the default rather than the edge case.[web:109][web:116][web:177]

The practical implication is that BADAN needs a notebook, not a chart. The notebook must support: report-level storage, panel-level grouping, analyte-level normalization, qualitative result handling, OCR review, version/correction history, notes and clinician questions, export bundles, privacy controls, and explainable AI summaries grounded in user-visible records. This document defines that system in product, data-model, interoperability, UX, privacy, and implementation terms.

## 2. Product thesis

The thesis is that laboratory results are among the most valuable and most poorly organized classes of personal health data. They are high-trust, high-sensitivity, episodic rather than continuous, highly heterogeneous in naming and unit systems, and deeply important for longitudinal reasoning. Yet in most consumer experiences they are either buried in provider portals, trapped inside PDFs, or flattened into a few trend lines without sufficient provenance or uncertainty framing. BADAN can differentiate by turning laboratory data into a durable personal notebook with inspectable structure, calm interpretation, and strong portability.[cite:65][cite:73][web:156]

A successful laboratory notebook for BADAN should satisfy two altitudes from one model. At casual altitude, the user should be able to answer: what was tested, what changed since last time, which results were outside that lab's stated interval, what still looks incomplete or uncertain, and what questions may be worth asking a clinician. At power-user altitude, the same user should be able to inspect the exact source report, original units, normalized units, coding systems, specimen type, collection time, performer/lab organization, assay notes, reference-range metadata, import confidence, OCR extraction lineage, correction history, and export schema. That dual-altitude requirement mirrors BADAN's broader product principles.[cite:65]

The core positioning choice is important: BADAN should not try to be a consumer diagnostic engine. It should be a structured personal health record and interpretation assistant. That means the product value comes from organization, comparability, provenance, user baseline analysis, exportability, and gentle explanation—not from pretending that one threshold crossing automatically means illness. Source-lab high/low flags should be preserved; BADAN may also describe trends or deviations from personal history; but it must not collapse those different concepts into a single traffic-light health score.

The lab notebook also extends BADAN's export and automation strategy. The HAE research established that exportability becomes a trust feature when the underlying schema and provenance are well designed.[cite:73] Laboratory data is especially suited to this because users often want exports for clinician visits, second opinions, personal analysis, family recordkeeping, or research. BADAN should therefore design the lab notebook and export system together from day one rather than bolt export onto an opaque internal model later.

## 3. User archetypes and jobs to be done

### 3.1 Archetypes

| Archetype | Core need | Typical data sources | Primary fears | What BADAN must optimize |
|---|---|---|---|---|
| Casual checker | "Tell me what changed since last time" | PDF/photo uploads, occasional provider sync | Intimidating jargon, panic, clutter | Calm summaries, clear deltas, simple organization |
| Chronic-condition organizer | Consolidate recurring labs across visits | Provider portals, PDFs, manual corrections | Missing history, scattered records | Longitudinal notebook, panel organization, question prep |
| Quantified-self user | Compare markers with sleep/training/nutrition | CSV, lab portals, Health exports, manual tags | Lost raw context, weak exports | Raw data access, configurable trends, correlations |
| Caregiver/family archivist | Keep a reliable record for another person (if supported later) | PDFs, images, portals | Privacy leakage, accidental mixing | Strong identity boundaries, sharing controls, redaction |
| Arabic-first user | Understand imported labs in Arabic/English contexts | Arabic PDFs, images, mixed-language clinics | Broken RTL, mistranslations, unit confusion | bilingual naming, RTL layouts, preserved source text |
| Research-minded power user | Machine-readable archive + reproducible exports | FHIR, CSV, APIs | Vendor lock-in, schema loss | canonical JSON/CSV/FHIR export, provenance, versioning |

### 3.2 Jobs to be done

Primary jobs:
- Import and retain lab reports regardless of source format.
- Find a specific marker quickly across years of reports.
- Compare the latest result to the prior result and to a longer personal baseline.
- Understand when a value is outside the source lab's interval without overinterpreting it.
- Preserve the original report and wording for later review.
- Generate a clinician-friendly packet for appointments.
- Export raw and normalized data for independent analysis.

Secondary jobs:
- Annotate unusual context (fasting, illness, menstrual phase, supplement change, medication change, training load spike).
- Group markers into personal collections or custom panels.
- Draft questions to discuss with a clinician.
- Track corrections when OCR or manual entry was wrong.
- Relate lab changes to other BADAN domains without implying causal certainty.

### 3.3 Jobs BADAN should explicitly not claim

- Diagnosing causes of abnormal results.
- Recommending treatment or dosage changes.
- Telling users that a normal range automatically means healthy or an out-of-range result automatically means disease.
- Offering emergency triage based on imported labs alone.

## 4. Product positioning and differentiation

BADAN's lab notebook should differentiate across seven axes.

### 4.1 Repository-first vs portal-fragmented

Provider portals are source systems, not user-controlled longitudinal notebooks. Apple Health Records centralizes some provider data, but availability depends on participating institutions and supported FHIR endpoints.[web:151][web:165] Android Health Connect's Medical Records similarly depends on ecosystem adoption and is still experimental.[web:176] BADAN's differentiator is source-agnostic permanence: if the portal disappears, changes vendors, or removes historical records, BADAN's notebook still exists.

### 4.2 Provenance-first vs flattened trend apps

Many health apps flatten a lab result into a name, number, unit, and arrow. BADAN should retain report ID, organization, specimen, collection timestamp, issue timestamp, raw source text, original PDF/image, method notes if available, source coding, source interpretation flags, import path, and correction history. "Provenance or it did not happen" is especially critical in labs because names and intervals vary across labs, and later interpretation often depends on that context.[web:109][web:116]

### 4.3 Dual-altitude UX vs one-size dashboards

BADAN can make the same record accessible in two modes: a calm summary view and an inspectable expert view. That design principle already exists in the blueprint's casual/power-user framing and should extend naturally to lab data.[cite:65]

### 4.4 Explainable interpretation vs pseudo-diagnostic scoring

BADAN should surface phrases like:
- "Outside this laboratory's stated reference interval."
- "Changed materially relative to your last three measurements."
- "Reference interval missing in source document; comparison uses your prior values only."

It should avoid phrases like:
- "This means you have..."
- "Dangerously low/high" absent verified urgent source language.
- "Optimal" unless explicitly user-defined and clearly not clinical.

### 4.5 Exportability vs lock-in

Apple Health exports all health data in XML, but that export is machine-oriented and not specialized for a lab notebook workflow on its own.[web:156][web:164] BADAN should provide targeted exports by marker, panel, date range, source, original documents, and normalized records. This is a concrete trust and product advantage.

### 4.6 Cross-format ingestion vs single-source dependency

A serious lab notebook must ingest structured FHIR, PDFs, images/scans, manual entry, CSV/JSON, and later API/webhook feeds. BADAN should assume mixed-quality inputs and design confidence and review workflows accordingly.[web:177][web:163]

### 4.7 Arabic and RTL readiness as a product differentiator

Most consumer health apps still treat Arabic terminology and RTL layout as afterthoughts. For lab records—where abbreviations, units, and bilingual clinical phrasing matter—BADAN can stand out by preserving source-language content, supporting bilingual aliases, and ensuring RTL chart labels, report exports, and question-prep documents work correctly.

## 5. User trust, privacy, and sensitivity model

Laboratory results are more sensitive than steps or sleep logs because they can reveal reproductive status, infectious disease testing, medication monitoring, endocrine status, cancer-related workups, genetic implications, or other intimate clinical information. BADAN should therefore classify laboratory records as high-sensitivity by default, with elevated controls for certain subcategories such as HIV/STI-related markers, pregnancy-related results, fertility markers, toxicology/drug monitoring, and culture/pathogen findings.

### 5.1 Sensitivity tiers

| Tier | Examples | Default handling |
|---|---|---|
| Standard-sensitive | CBC, CMP, lipids, HbA1c | Encrypted at rest, hidden from widgets by default, explicit export/share confirmation |
| High-sensitive | reproductive hormones, pregnancy-related labs, STI labs, cultures, drug screens | Additional redaction defaults, no ambient surfaces, stronger share/export warnings |
| Very high-sensitive / future policy-gated | genomic reports, pathology narratives, HIV-specific results, fertility treatment records | Separate consent gates, optional local-only storage preference, stricter sharing templates |

### 5.2 Trust obligations

- Every displayed insight must link back to visible source records.
- Every normalized value must preserve the original value and unit.
- Every OCR-derived field must show confidence or review state.
- Every imported high/low flag must be labeled as source-provided if it came from the lab document or FHIR `interpretation` field.[web:109][web:116]
- Every manual correction must be auditable and reversible.
- Any AI summary must state whether it relied on structured records only or also OCR-extracted text.

### 5.3 Privacy defaults

- No ad/marketing use of lab data, ever.
- No model training on user lab content without explicit separate opt-in.
- Default local-first processing for OCR pre-processing, parsing, and trending where feasible.
- Separate consent for cloud OCR or cloud LLM summarization if offered.
- Fine-grained share/export scopes at report, panel, marker, and date-range levels.
- Explicit lock-screen and screenshot warnings for shared PDFs/exports.

## 6. Complete laboratory data ontology

This section defines the domain taxonomy BADAN should use. The ontology should support canonical groupings, aliases, coding-system links, data-type distinctions, and extensibility for unrecognized markers.

### 6.1 Ontology design rules

1. **Canonical category != diagnosis.** Categories are organizational only.
2. **Analyte definitions are reference objects.** User records link to them but preserve source wording.
3. **Multiple identifier systems can coexist.** LOINC when available, source code/local code otherwise.[web:109][web:134]
4. **Data types vary.** Numeric, ordinal, qualitative, binary, ratio, textual narrative, semi-structured micro/culture results.
5. **Unit conversion is not always safe.** Some analytes permit exact conversion; others depend on assay or scale.
6. **Unknown markers are first-class.** BADAN must not force everything into a closed dictionary.

### 6.2 Category taxonomy matrix

| Category | Canonical display name | Example aliases / variants | Identifier strategy | Common result types | Common unit patterns | Reference-range structure | Conversion safety | Trend meaningful | Baseline meaningful | Privacy sensitivity |
|---|---|---|---|---|---|---|---|---|---|---|
| Hematology / CBC | Complete Blood Count | CBC, FBC, Hemogram | LOINC where available + BADAN analyte slug + source code | Numeric | x10^3/uL, x10^6/uL, g/dL, %, fL, pg | Numeric low/high, sex/age-specific possible | Conditional | Yes | Yes | Standard-sensitive |
| Iron studies | Iron Studies | Ferritin, Iron panel, transferrin studies | same | Numeric | ng/mL, ug/dL, % saturation | numeric intervals | Conditional | Yes | Yes | Standard-sensitive |
| Metabolic panels | Basic/Comprehensive Metabolic Panel | BMP, CMP, chemistry panel | same | Numeric | mmol/L, mg/dL, U/L | numeric intervals | Conditional | Yes | Yes | Standard-sensitive |
| Liver-related | Liver markers | AST, ALT, ALP, bilirubin, GGT | same | Numeric | U/L, mg/dL, umol/L | numeric intervals | Conditional | Yes | Yes | Standard-sensitive |
| Kidney-related | Renal markers | creatinine, BUN, eGFR, uric acid | same | Numeric / calculated | mg/dL, umol/L, mL/min/1.73m² | numeric; eGFR may use threshold bands | Conditional; eGFR derived caution | Yes | Yes | Standard-sensitive |
| Lipids | Lipid panel | total chol, HDL-C, LDL-C, TG | same | Numeric | mg/dL, mmol/L | numeric intervals / target-style text | Exact for many | Yes | Yes | Standard-sensitive |
| Glucose-related | Glucose markers | fasting glucose, random glucose | same | Numeric | mg/dL, mmol/L | numeric intervals | Exact | Yes | Yes | Standard-sensitive |
| Glycemic markers | Glycemic control | HbA1c, A1c | same | Numeric | %, mmol/mol | source interval; target-like text possible | Conditional exact if standardized | Yes | Yes | Standard-sensitive |
| Thyroid | Thyroid-related markers | TSH, FT4, FT3, TPO Ab | same | Numeric / qualitative | mIU/L, ng/dL, pmol/L, IU/mL | numeric intervals, sex/pregnancy context may matter | Conditional | Yes | Yes | High-sensitive |
| Sex hormones / reproductive | Reproductive markers | testosterone, estradiol, progesterone, LH, FSH, AMH, prolactin, hCG | same + life-stage metadata | Numeric / qualitative | ng/dL, pg/mL, IU/L, mIU/mL | sex/life-stage/cycle/pregnancy aware source intervals | Conditional | Yes | Yes | High-sensitive |
| Vitamins/minerals | Vitamins and minerals | vitamin D, B12, folate, magnesium, zinc | same | Numeric | ng/mL, nmol/L, pg/mL | numeric intervals | Conditional | Yes | Yes | Standard-sensitive |
| Inflammation | Inflammation markers | CRP, hs-CRP, ESR | same | Numeric | mg/L, mm/hr | numeric intervals | Exact/conditional | Yes | Yes | Standard-sensitive |
| Urinalysis | Urinalysis | UA, urine chemistry/microscopy | same | Numeric + qualitative + semi-quantitative | varies | mixed low/high, presence/absence, ordinal | Often unsafe | Some markers yes | Some yes | High-sensitive |
| Microbiology / culture | Microbiology / culture | urine culture, throat culture, susceptibility | report-level + observation-level local identifiers | Textual, coded, binary, susceptibility tables | often N/A | no simple interval | Unsafe | Limited | Limited | High-sensitive |
| Allergy-related | Allergy-related results | IgE panels, skin/blood allergy assay summaries | same | Numeric / coded / textual | kU/L, class scale | categorical / graded | Unsafe/conditional | Limited | Limited | High-sensitive |
| Medication monitoring | Therapeutic drug monitoring | lithium, valproate, tacrolimus, INR | same | Numeric | ng/mL, ug/mL, INR ratio | method/collection-time sensitive | Conditional | Yes | Yes | High-sensitive |
| Genetic metadata (future) | Genetic or genomic report metadata | pharmacogenomics, carrier screen metadata | future only; report-level metadata first | textual / coded | N/A | not interval-based | Unsafe | Usually no | Limited | Very high-sensitive |
| Custom / unrecognized | Unrecognized marker | source-specific analytes | BADAN custom ID + original text | any | any | any | Unknown | Maybe | Maybe | inherits source context |
| User-defined research | User-defined experimental marker | self-study marker | custom ID | numeric / text | user-defined | optional user-defined only | User responsibility | Maybe | Maybe | configurable |
| Derived / calculated | Derived marker | non-HDL, albumin/globulin ratio, calculated LDL | derived ID + lineage | numeric | computed | not source-provided unless imported | Exact if formula valid | Yes | Yes | inherits parents |

### 6.3 Detailed category guidance

#### Complete blood count / hematology

Canonical marker families should include WBC, RBC, hemoglobin, hematocrit, MCV, MCH, MCHC, RDW, platelets, neutrophils, lymphocytes, monocytes, eosinophils, basophils, and immature granulocyte markers when present. BADAN should support both absolute and percentage differentials and preserve whether the source reported each one or both. Trending and baseline analysis are meaningful. Conversion is often unsafe between absolute and percent because they are not direct unit conversions but different measurement expressions.

Safe casual-user presentation: "Blood count markers" with a concise status such as "2 values outside this lab's interval." Power-user presentation: analyte table with differential subtype, absolute vs percent distinction, specimen, method notes, and exact source interval text.

#### Iron studies

Support ferritin, serum iron, transferrin, total iron-binding capacity, unsaturated iron-binding capacity, and transferrin saturation. Derived saturation should be markable as source-provided or BADAN-derived, with formula lineage. Trending is meaningful. Conversion is conditionally safe depending on mass/concentration unit compatibility.

#### Metabolic, liver, and kidney markers

These often arrive in panels (BMP/CMP) but should still be analyte-addressable. BADAN must preserve panel grouping and panel date while allowing marker-level trend pages. eGFR needs special treatment: it is often already source-derived and may change methodology over time; BADAN should preserve the source formula/method text if present and avoid recalculating historical values unless explicitly requested and well justified.

#### Lipids and glycemic markers

These are common consumer-facing markers where apps often overstep into simplistic scoring. BADAN should resist generic green/yellow/red framing. Display interval status, prior change, and personal trend, but avoid words like "excellent" or "poor" unless user-created labels. HbA1c supports both % and IFCC mmol/mol; conversion is standardized, so normalized dual-view can be offered while preserving original source units.

#### Thyroid and reproductive markers

These require especially careful interval context because source ranges may vary by sex, age, cycle phase, pregnancy, assay, or lab policy. BADAN should preserve source interval metadata and never silently substitute a generalized range. For casual mode, the product should emphasize comparison to source interval and prior measurements, not broad medical interpretation.

#### Urinalysis and microbiology

These are structurally messy. Urinalysis may contain numeric, semi-quantitative, binary, microscopic, and textual fields in the same report. Microbiology/culture results often include organism identification, susceptibilities, comments, and narrative text. BADAN should support these report classes as first-class documents even when full analyte normalization is partial. For v1, culture/susceptibility should likely be document-centric with limited structured extraction; later phases can add susceptibility table modeling.

#### Custom and unrecognized markers

Unrecognized markers must be storable without blocking import. BADAN should create a temporary analyte stub with original label, source code if any, source unit, source result type, and a pending classification state. Users may later map it to an existing analyte or keep it custom.

### 6.4 Export fields by analyte

Every analyte export row should support, where available:
- canonical analyte ID
- canonical display name
- source analyte label
- source/local code
- LOINC code
- panel/report IDs
- specimen type
- collection time
- issued/result time
- raw value text
- normalized numeric value
- raw unit
- normalized unit
- source interpretation flag(s)
- source reference range low/high/text
- source organization
- source document ID
- import method
- confidence/review state
- correction/version markers
- derived lineage refs if computed

## 7. Laboratory report ingestion strategy

BADAN should support six ingestion classes at launch or soon after, each with different structure quality and trust characteristics.

### 7.1 Ingestion routes overview

| Route | User flow | Structure quality | Provenance confidence | MVP suitability | Complexity |
|---|---|---|---|---|---|
| Apple Health Records / HealthKit clinical records | connect Health access, authorize lab records, import FHIR-backed results | High when available | High | MVP+ | Medium |
| Android Health Connect Medical Records | grant medical-record permissions, read lab Observations | Medium-high but ecosystem-limited | High | Phase 2 | Medium-high |
| Direct FHIR / provider portal import | connect provider or upload FHIR bundle/JSON | High | High | Phase 2 | High |
| PDF upload | select/share a PDF into BADAN | Medium/low unless structured | Medium | MVP | Medium |
| Photo / scan OCR | camera capture or image import | Low-medium | Medium-low until reviewed | MVP | Medium-high |
| Manual entry | add report, panel, or marker manually | User-defined | Medium | MVP | Medium |
| CSV / JSON import | upload structured spreadsheet/file | Variable | Medium | Phase 2 | Medium |
| Email attachment import (opt-in) | monitored inbox / share sheet | Variable | Medium | Later | High |
| Personal API / webhook | send normalized records to BADAN | High if schema-compliant | depends on source | Later | High |

### 7.2 Apple Health / HealthKit clinical records

Apple HealthKit exposes clinical records as `HKClinicalRecord` samples, each representing a single condition, procedure, vital sign, or result. Health Records supports FHIR R4 and DSTU2 on the provider side, and lab result records can be accessed as clinical records when the user has authorized Health Records from a participating organization.[web:105][web:106][web:148][web:151][web:165] This is BADAN's strongest near-term structured iOS source because it arrives as genuine clinical data rather than OCR.

User flow:
1. User enables Health access for clinical records.
2. BADAN requests permission for lab result records.
3. BADAN imports allowed records, extracting raw FHIR payloads and mapping to the canonical model.
4. BADAN stores the original FHIR blob, source record metadata, and normalized analyte records.

Consent/privacy model: explicit HealthKit permission gate; no access without the user choosing it. BADAN should explain that source availability depends on participating health systems.

Failure modes:
- no participating provider
- no lab records present
- partial provider history
- inconsistent FHIR coding/interval quality
- updated/amended records arriving later

MVP suitability: yes on iOS, but not as sole strategy because coverage is uneven.

### 7.3 Android Health Connect Medical Records

Android Health Connect now provides experimental Medical Records APIs with FHIR R4/R4B support and a dedicated laboratory-results permission based on `Observation` resources categorized as laboratory.[web:176][web:138] The APIs allow reading/writing supported medical resources, but remain experimental, require Android 16 SDK compilation for the Jetpack path described, and lack some synchronization conveniences such as changelog-style APIs.[web:176]

This is strategically important but should be treated as Phase 2 because of ecosystem maturity. BADAN should design its canonical model to ingest these resources cleanly, but should not assume immediate cross-device parity.

Failure modes:
- feature unavailable on device
- unsupported source app/vendor
- permission denied
- incompatible/filtered observations not written into Health Connect because only certain categories are mapped
- evolving API/policy requirements

### 7.4 Direct FHIR / provider import

FHIR is the best interoperability target for clinically structured lab data. In FHIR workflows, laboratory results are typically represented with `DiagnosticReport` as the report container and `Observation` resources for individual analytes or grouped panels, with links to `Specimen`, `Encounter`, `Organization`, and related metadata.[web:113][web:109][web:116] BADAN should support importing FHIR Bundles/JSON and, later, direct patient-authorized provider connections where legally and technically viable.

This is not necessarily MVP because provider-specific auth, patient matching, and maintenance overhead are substantial. But the canonical data model should be designed FHIR-aware from the start so imports and exports do not require later schema surgery.

### 7.5 PDF uploads

PDF upload should be a first-class MVP route because it is universal. Many users can obtain PDFs even when structured APIs are absent. The PDF workflow should support:
- file picker import
- iOS/Android share sheet import
- attaching multiple documents to one report or one visit
- document classification (lab report, culture report, requisition, pathology-adjacent, non-lab/unknown)
- text extraction if embedded text exists
- OCR if PDF is image-based

Quality varies from excellent (digital PDFs with selectable tables) to poor (scanned faxes). BADAN should therefore separate document ingestion from analyte extraction. A PDF can be stored successfully even if analyte extraction is partial or deferred.

### 7.6 Photo / scan OCR

Paper-based reports and photos are common, but extraction quality suffers when layouts vary, scans are skewed, lighting is poor, decimal separators are ambiguous, or unit/reference columns are misread.[web:177][web:163] BADAN should use a staged OCR workflow:
1. ingest image
2. pre-process on-device (crop, de-skew, contrast)
3. run OCR
4. detect table regions and likely analyte rows
5. extract candidate analyte/value/unit/range fields
6. present human review UI before normalization

The system should never silently trust OCR for clinically sensitive fields. OCR-derived records should default to `review_required` unless confidence and layout conditions are unusually high.

### 7.7 Manual entry

Manual entry is essential, not a fallback embarrassment. Users often receive results verbally, from paper copies, or from sources that cannot be imported. Manual entry should support both quick entry and detailed entry.

Quick entry: one marker, one value, one date, optional unit.
Detailed entry: full report, panel, specimen, source lab, source interval, notes, and attached photo/PDF.

Manual entry must preserve that the source was user-entered. BADAN should support later attaching a source document or replacing the provisional manual record with a verified imported record while keeping the edit history.

### 7.8 CSV / JSON structured imports

This is high leverage for power users and labs exported from other apps. CSV imports should use mapping templates and preview screens. JSON imports should support BADAN's own schema and optionally FHIR Bundle input. MVP can defer this; the canonical model should not.

### 7.9 Duplicate detection and correction

All routes need duplicate logic. BADAN should use a weighted duplicate score based on:
- source document hash
- source record identifier
- organization
- collection timestamp
- panel/analyte set overlap
- result values and units
- issued timestamp
- import origin

Duplicates should never auto-delete. They should be merged, linked, or flagged for review with provenance preserved.

## 8. HealthKit, Health Records, FHIR, and Android capability analysis

### 8.1 Apple HealthKit and Health Records reality

Apple's Health Records feature is the main structured iPhone path for clinical records including lab results, immunizations, medications, procedures, and vitals.[web:148][web:106] HealthKit represents each FHIR record as an `HKClinicalRecord`, allowing apps with permission to access the underlying clinical data.[web:106][web:111] Apple's provider program supports FHIR R4 and DSTU2, with R4 recommended and newer capabilities tied to that path.[web:151][web:165][web:166]

Strategic implications for BADAN:
- iOS can support true clinical-record ingestion without BADAN becoming an EHR integrator for every source.
- Coverage is excellent where provider participation exists and poor where it does not.
- BADAN must keep the raw FHIR clinical record or a faithful preserved form, not just flatten imported labs.
- Apple Health alone does not eliminate the need for PDFs/manual entry because many labs will still never arrive through Health Records.

### 8.2 FHIR lab result structure

FHIR and US Core make it clear that laboratory results are best modeled with `DiagnosticReport` as a grouping/report layer and `Observation` as the analyte/result layer.[web:113][web:109][web:116] Each `Observation` should include a laboratory category, a lab code (preferably LOINC), a value or data-absent reason, optional interpretation, optional reference ranges, and specimen linkage when available.[page:1] Observations may also use `component` or `hasMember` for grouped or nested results.[page:1]

This matters because BADAN should not design a simplistic row-only schema. A robust notebook needs report-level, observation-level, component-level, and specimen/source relationships.

### 8.3 Android Health Connect reality

Health Connect now has Medical Records support for laboratory results based on FHIR Observations in the laboratory category, with dedicated permissions and support for reading/writing medical resources.[web:176][page:1] But the APIs are explicitly marked experimental, the app policy environment is still evolving, and not all supporting features are mature.[web:176] Therefore BADAN should architect for this path but phase it behind more universal document/manual routes.

### 8.4 HealthKit vs Android parity

There is no clean parity today. iOS has more mature consumer clinical-record integration via Apple Health Records. Android has a promising but newer standards-based Medical Records path. BADAN should expose the same notebook model on both platforms, but the ingestion source ranking will differ:
- iOS: Health Records + PDF/image/manual
- Android: PDF/image/manual first, Health Connect Medical Records second as availability expands

### 8.5 Health export implications

Apple Health exports data in XML, which is useful for archival interoperability but not sufficient as a specialized lab notebook workflow on its own.[web:156][web:164] BADAN should treat system exports as one input path and its own focused exports as a core product.

## 9. Data source and provenance architecture

BADAN needs a provenance architecture that separates source identity, import path, transformed state, and user correction history.

### 9.1 Provenance principles

- Preserve original artifacts (FHIR JSON, PDF, image, CSV row, manual note).
- Preserve source-level identifiers and timestamps.
- Preserve import-job metadata and parser version.
- Preserve transformation lineage from raw source to normalized record.
- Preserve user edits as overlays, not destructive rewrites.

### 9.2 Provenance layers

| Layer | Example |
|---|---|
| Source system | Apple Health Records, Health Connect, PDF from clinic, manual entry |
| Source organization | hospital, clinic, lab company |
| Source artifact | FHIR Bundle, Observation JSON, PDF file, JPEG image |
| Extraction layer | direct structured parse, OCR parse, manual field entry |
| Normalization layer | analyte mapping, unit normalization, interval parsing |
| User correction layer | fixed decimal, changed unit, merged duplicate |
| Derived layer | trend summary, baseline deviation, derived marker |

### 9.3 Provenance fields to carry everywhere

Every LabResult should carry, directly or by relation:
- source type
- source artifact ID
- source organization ID
- import job ID
- parser/OCR version
- review state
- confidence class
- original value text
- original unit text
- original interval text
- original interpretation text
- original analyte label
- original code(s)
- correction/version references

## 10. Canonical laboratory data model

This section proposes the core entities.

### 10.1 LabReport

**Purpose:** container for one laboratory report document or report bundle.

Core fields:
- `lab_report_id`
- `user_id`
- `title`
- `report_type` (lab_report, culture_report, urinalysis_bundle, unknown)
- `source_document_id`
- `source_system_type`
- `source_external_id`
- `laboratory_organization_id`
- `collection_event_id`
- `issued_at`
- `status` (preliminary, final, amended, corrected, entered_in_error, unknown)
- `language_code`
- `review_state`
- `sensitivity_tier`
- `created_at`, `updated_at`

Optional fields:
- encounter/visit refs
- ordering clinician
- performer
- accession number
- notes summary
- panel count/result count

Relationships:
- has many `LabPanel`
- has many `LabResult`
- has many `SourceDocument`
- has many `Annotation`
- belongs to `CollectionEvent`
- belongs to `LaboratoryOrganization`

Versioning: new corrected or amended source versions should create a new report version relation rather than destructive overwrite.

### 10.2 LabPanel

**Purpose:** logical grouping of analytes as reported together (e.g., CBC, CMP, lipid panel) or as BADAN/user-defined collection.

Core fields:
- `lab_panel_id`
- `lab_report_id` nullable for virtual collections
- `panel_type` (source_panel, virtual_collection, derived_panel)
- `canonical_panel_key` nullable
- `source_panel_label`
- `display_name`
- `sequence_index`
- `result_count`

Optional:
- source code / LOINC panel code
- panel narrative
- panel status

### 10.3 LabResult

**Purpose:** one analyte-level result or one textual/qualitative result entry.

Core fields:
- `lab_result_id`
- `lab_report_id`
- `lab_panel_id` nullable
- `analyte_definition_id` nullable
- `source_result_identifier`
- `source_analyte_label`
- `source_code_system`, `source_code`
- `loinc_code` nullable
- `result_type` (numeric, qualitative, coded, text, ratio, range, binary, narrative)
- `raw_value_text`
- `normalized_numeric_value` nullable
- `normalized_text_value` nullable
- `raw_unit_text`
- `normalized_unit_id` nullable
- `raw_interpretation_text`
- `source_flag_high_low` nullable
- `observation_time_id`
- `specimen_id` nullable
- `reference_range_id` nullable
- `provenance_id` / import refs
- `review_state`
- `sensitivity_tier`

Optional:
- comparator (`<`, `<=`, `>`, `>=`, approx)
- method text
- note text
- component/group parent refs
- derived_from_result_ids

Correction rules: retain original fields; corrected values live in overlay/version records.

### 10.4 AnalyteDefinition

**Purpose:** dictionary entry describing a canonical analyte concept.

Core fields:
- `analyte_definition_id`
- `canonical_slug`
- `canonical_display_name_en`
- `canonical_display_name_ar`
- `category`
- `preferred_result_type`
- `preferred_ucum_unit`
- `conversion_policy` (safe, conditional, unsafe, none)
- `trend_supported`
- `baseline_supported`
- `sensitivity_default`

Optional:
- aliases
- LOINC mappings list
- known source labels
- description copy for casual mode
- power-user notes on unit caveats

### 10.5 Unit

Fields:
- `unit_id`
- `ucum_code` nullable
- `display_symbol`
- `display_name_en`
- `display_name_ar`
- `dimension_family`
- `conversion_group`
- `to_base_formula`
- `safety_policy`

### 10.6 ReferenceRange

Fields:
- `reference_range_id`
- `source_scope` (source_lab, imported_structured, user_defined, BADAN_none)
- `low_value`, `high_value`, `unit_id`
- `text_range`
- `applies_to_text`
- `age_low`, `age_high`
- `sex_context`
- `life_stage_context`
- `method_context`
- `source_flag_policy`
- `effective_start`, `effective_end`

### 10.7 ResultInterpretationMetadata

Purpose: store imported flags and BADAN-generated descriptive metadata separately.

Fields:
- source interpretation code/text
- source high/low/abnormal flags
- BADAN trend descriptors
- baseline deviation class
- confidence class
- wording template version

### 10.8 SourceDocument

Fields:
- `source_document_id`
- file path/blob ref
- mime type
- original filename
- SHA-256 hash
- page count
- language detection
- OCR status
- redaction status
- imported_at

### 10.9 DataSource

Fields:
- `data_source_id`
- type (healthkit_clinical, health_connect_medical, pdf_upload, image_capture, manual_entry, csv_import, api_import)
- vendor/system name
- account label
- organization linkage
- authorization scope
- last_sync_at
- stale_state

### 10.10 LaboratoryOrganization

Fields:
- `laboratory_organization_id`
- display_name
- aliases
- address fields optional
- source portal URL optional
- code/system identifiers optional
- country/region

### 10.11 Specimen

Fields:
- `specimen_id`
- specimen_type_text / coded type
- collection_method_text
- body_site_text if relevant
- fasting status text if source provides
- specimen_received_at

### 10.12 CollectionEvent

Fields:
- `collection_event_id`
- collected_at_start
- collected_at_end
- issued_at
- encounter_id optional
- fasting_context user/source
- source_timezone

### 10.13 ObservationTime

Purpose: distinguish collection, effective, and issued times.

Fields:
- `observation_time_id`
- effective_type (datetime, period, instant, unknown)
- effective_start
- effective_end
- issued_at
- recorded_at

### 10.14 ImportJob

Fields:
- `import_job_id`
- source type
- started_at, completed_at
- parser version
- total docs/results
- warnings count
- errors count
- review queue count

### 10.15 OCRExtraction

Fields:
- `ocr_extraction_id`
- source_document_id
- OCR engine/version
- page index
- text blocks JSON
- extraction confidence
- table detection confidence
- decimal ambiguity flag
- unit ambiguity flag
- range ambiguity flag

### 10.16 UserCorrection

Fields:
- `user_correction_id`
- target entity type/id
- corrected_field
- old_value
- new_value
- reason optional
- created_at
- actor = user

### 10.17 Annotation

Fields:
- annotation text
- attached entity refs
- timestamp
- visibility (private, include_in_export, include_in_share)

### 10.18 UserQuestion

Fields:
- question text
- related report/result refs
- status (draft, to_discuss, answered, archived)
- appointment tag/date optional

### 10.19 Tag

Fields:
- tag_id
- label
- color optional
- system/user-defined

### 10.20 DerivedTrend

Fields:
- derived_trend_id
- analyte/panel scope
- algorithm version
- date window
- trend direction
- confidence
- baseline delta
- narrative snippet

### 10.21 ExportBundle

Fields:
- export_bundle_id
- template type
- included scopes
- encrypted flag
- created_at
- file refs

### 10.22 SharingGrant

Future entity for scoped sharing permissions.

### 10.23 AuditEvent

Fields:
- audit_event_id
- actor type
- action type
- entity refs
- timestamp
- device/app version

### 10.24 RetentionPolicy

Fields:
- local retention mode
- synced retention mode
- source-document retention rules
- deleted-at / purge-at

### 10.25 Sample pseudo-schema

```json
{
  "lab_report": {
    "lab_report_id": "lr_01J...",
    "title": "Comprehensive Metabolic Panel",
    "status": "final",
    "issued_at": "2026-07-18T09:14:00+04:00",
    "collection_event_id": "ce_01J...",
    "laboratory_organization_id": "lab_01J...",
    "source_document_id": "doc_01J...",
    "source_system_type": "pdf_upload"
  },
  "lab_results": [
    {
      "lab_result_id": "res_01J...",
      "source_analyte_label": "Creatinine",
      "loinc_code": "2160-0",
      "result_type": "numeric",
      "raw_value_text": "1.08",
      "normalized_numeric_value": 1.08,
      "raw_unit_text": "mg/dL",
      "normalized_unit_id": "unit_mg_per_dL",
      "source_flag_high_low": null,
      "reference_range_id": "rr_01J...",
      "review_state": "verified_structured"
    }
  ]
}
```

## 11. Unit normalization and conversion strategy

Unit normalization must be rigorous and conservative.

### 11.1 Principles

- Preserve original value and original unit always.
- Normalize only when the conversion is mathematically safe and semantically appropriate.
- Never hide that normalization occurred.
- Allow power users to choose preferred display units where safe.
- Keep BADAN's normalized value distinct from source value when the source is textual or semi-quantitative.

### 11.2 Conversion policy classes

| Policy | Meaning | Example |
|---|---|---|
| Safe exact | direct mathematical conversion with stable semantics | glucose mg/dL <-> mmol/L |
| Conditional | mathematically convertible but interpretive or assay caveats apply | vitamin D, ferritin, hormones in varied assays |
| Unsafe | should not auto-convert or compare directly | semi-quantitative urinalysis classes, qualitative microbiology |
| None | not applicable | positive/negative, narrative text |

### 11.3 Pitfalls

- Same analyte name can represent different specimen types.
- Same unit symbol may be ambiguously OCR-read.
- Reference ranges in source units may no longer match if normalized display unit differs; BADAN must normalize ranges too or show source ranges alongside source units.
- Methodology changes can break longitudinal comparability even with same units.
- Derived source values such as eGFR may embed demographic assumptions or formula changes.

### 11.4 Product behavior

Casual view: show preferred unit only if conversion is safe and range is also coherently transformed.
Power view: show source value/unit, normalized value/unit, and conversion note.

## 12. Reference-range model

Reference intervals are source metadata, not truth about the user.

### 12.1 Core distinctions

BADAN must separately model:
1. **Source lab reference interval**: what the lab report says.
2. **Source interpretation flag**: e.g. H, L, abnormal, positive.[page:1]
3. **User baseline**: what is typical for this user historically.
4. **User-defined threshold/goal**: optional and clearly labeled as user-defined.

### 12.2 Wording model

Preferred labels:
- "Outside this laboratory's stated reference interval"
- "Within this laboratory's stated reference interval"
- "No reference interval provided in source"
- "Compared with your recent history" 

Avoid:
- "Normal" as the only label
- "Healthy/unhealthy"
- "Danger" absent source-critical wording and explicit safety review

### 12.3 Range structures

Reference ranges may be:
- low/high numeric bounds
- text-only interval
- age/sex/life-stage scoped
- method-specific
- qualitative text (e.g. negative)
- missing entirely

FHIR supports low/high/text plus age/appliesTo/type metadata in `referenceRange`, which matches BADAN's need to preserve source context rather than over-standardize it.[page:1]

### 12.4 Missing range behavior

When absent:
- do not invent one
- trend against prior values only
- allow source document view for manual inspection
- show neutral message: "No source interval available for this result"

### 12.5 Qualitative handling

For positive/negative, detected/not detected, reactive/non-reactive, and ordinal grades, BADAN should preserve source text and optionally canonicalize to a controlled semantic field while keeping the raw wording. No numeric chart should be forced unless there is a valid ordinal model and the user explicitly chooses it.

## 13. Longitudinal trend analysis

Trend analysis is a major value layer, but it must be careful and analyte-aware.

### 13.1 Timeline model

Each marker timeline should distinguish:
- collection date/time
- effective measurement window (e.g. 24-hour urine period)
- issued/result date
- source lab
- unit system used
- report status (final, amended)

### 13.2 Trend outputs

- latest vs prior delta
- latest vs median of last N results
- range of recent results
- source-lab interval overlay
- personal baseline band overlay
- source-lab color encoding only where explicitly tied to source interval

### 13.3 Confidence model

Trend confidence should consider:
- number of data points
- unit consistency
- assay/lab consistency
- spacing of observations
- corrected/amended records
- source quality (structured > OCR reviewed > OCR unreviewed > manual)

### 13.4 Summary templates

Examples:
- "Compared with your previous measurement, this value is higher by 0.4 mg/dL."
- "Across your last five measurements, this marker has usually been between X and Y."
- "Recent comparisons are limited because results came from different labs and units were normalized."

### 13.5 Panel-over-time views

Panels like CBC/CMP should support "panel snapshots over time" rather than only analyte pages. Users often remember "my lipid panel last year" more than each analyte.

## 14. User-baseline analysis

Personal baseline is different from source interval analysis.

### 14.1 Baseline definition

A baseline should be computed only when enough historical results exist and the analyte is reasonably comparable across time. BADAN should require configurable minimum data points and allow exclusion of outliers or known special contexts.

### 14.2 Baseline caveats

- Baselines can be misleading if the user changed labs, units, specimen type, life stage, or collection context.
- Some markers fluctuate cyclically or situationally.
- A personal baseline outside a lab interval is not reassurance.

### 14.3 UX language

- "Relative to your recent history"
- "Compared with your typical range in this notebook"
- "Baseline confidence low due to limited history / mixed laboratories"

## 15. Panel, marker, and collection system

BADAN should support three grouping systems.

### 15.1 Source panels

Imported panels from reports: CBC, CMP, lipid panel, iron studies, thyroid panel.

### 15.2 Virtual collections

User-created cross-report collections: "metabolic health", "fertility workup", "thyroid journey", "pre-competition labs".

### 15.3 Smart collections

Rule-based collections: all markers tagged `kidney`, all results from Lab X, all results outside source intervals in last 12 months.

## 16. Lab Results Notebook information architecture

Primary IA should include:
- Notebook Home
- Latest Results Timeline
- Reports
- Panels
- Markers
- Collections
- Imports & Review Queue
- Notes & Questions
- Exports
- Settings & Privacy

Secondary navigation within an entity should allow switching between Summary / Trend / Raw / Source / Notes / Related Context.

## 17. Screen-by-screen product blueprint

### 17.1 Laboratory Notebook home

Purpose: overview entry point.
Primary user: all.
Primary action: see recent changes and continue review.
Data shown: latest reports, results needing review, notable deltas, collections, quick import.
Source/provenance visibility: compact source chips.
Advanced affordances: jump to raw exports, sync status.
Confusion risks: overwhelming with too many markers; must prioritize calm cards.
RTL: mirrored card layout, right-aligned metadata.

### 17.2 Latest results timeline

Purpose: chronological report/event stream.
Actions: open report, compare to prior, tag, note.
Data shown: report title, source lab, specimen date, counts of out-of-interval results, review state.

### 17.3 Panel browser

Purpose: browse recurring panel types.
Display: panel cards with latest date and completeness.
Advanced: filter by source lab, date range, sensitivity tier.

### 17.4 Marker browser

Purpose: browse analytes across time.
Must support search, aliases, bilingual names, category filters.

### 17.5 Marker detail

Purpose: one analyte's full longitudinal story.
Sections: latest value, trend chart, source interval history, baseline band, report list, notes, related contexts.
Power features: source-unit toggle, per-lab overlays, raw rows table, export this marker.
Anti-intimidation: default to one calm sentence + simple chart.

### 17.6 Lab report detail

Purpose: reconstruct the report as a navigable object.
Sections: source doc preview, panel list, analyte table, report metadata, import provenance, notes/questions.

### 17.7 Source-document viewer

Purpose: preserve the original artifact.
Features: page thumbnails, text layer, highlight extracted rows, confidence indicators, redact/share actions.

### 17.8 OCR review/correction screen

Purpose: human-in-the-loop verification.
Layout: side-by-side document crop and extracted fields.
Actions: confirm, edit, split/merge rows, flag unknown marker, set unit, mark unreadable.

### 17.9 Manual-entry form

Modes: quick marker entry, full report entry.
Guardrails: explicit field labels for value, unit, source interval, collection date.

### 17.10 Compare results screen

Purpose: compare two or more time points, reports, or labs.
Features: side-by-side rows, delta column, range differences, source lab column.

### 17.11 Trend charts

Variants: line, point-only, banded interval overlay, per-lab color overlay, small multiple panels.
Must handle sparse data gracefully.

### 17.12 Reference-range explainer

Purpose: teach users the difference between source interval and personal baseline.
Tone: calm, neutral, not medical-advice oriented.

### 17.13 Personal baseline explainer

Purpose: explain how BADAN computed the user's own typical range and its limits.

### 17.14 Appointment preparation workspace

Purpose: select results, add questions, generate a visit packet.

### 17.15 Upload/import flow

Entry points: plus button, share sheet, camera, Health sync source screen.
States: source choice, permissions, upload progress, parsing progress, review queue.

### 17.16 Data source management

Purpose: manage Health/Health Connect/FHIR/manual sources, auth status, last sync, stale warnings.

### 17.17 Export flow

Purpose: choose scope, format, encryption, redaction, and template.

### 17.18 Sharing flow

Optional in later phases; must be tightly scoped and revocable.

### 17.19 Settings and privacy controls

Settings: default unit preferences, redaction, cloud OCR opt-in, AI privacy, retention, export templates.

### 17.20 Empty/error/permission/conflict states

All should be calm and actionable:
- "No lab reports yet"
- "Import needs review"
- "Clinical records access not available from your providers"
- "Two records may represent the same report—review before merging"

## 18. Casual-user experience

Casual mode should emphasize five primitives:
- latest result summary
- what changed since last time
- outside-source-interval count
- simple trend for selected markers
- questions to ask / notes to bring

The experience should avoid dense tables by default. A user opening a marker should first see a one-sentence neutral summary, then a simple chart, then an expandable details section. Casual users should never be forced into code systems, LOINC, or OCR confidence details unless they ask.

## 19. Power-user experience

Power mode should surface:
- raw analyte rows
- source and normalized units
- source code/LOINC
- report status and version history
- review/correction history
- per-lab overlays
- CSV/JSON/FHIR exports
- filter builder
- custom collections
- derived marker lineage
- data freshness and source sync status

Power mode should not be a separate silo; it should be a reveal layer over the same entities.

## 20. AI-assisted explanation and report generation

### 20.1 AI use cases

- per-report neutral summary
- per-panel summary
- per-marker longitudinal summary
- date-range notebook report
- explanation of units/reference intervals/provenance
- draft questions for clinician discussion
- export cover letter / human-readable packet narrative

### 20.2 Prompt input contract

AI inputs should be structured and bounded:
- selected records only
- visible user-approved fields only
- provenance summary
- confidence summary
- explicit instruction: non-diagnostic, do not infer disease, distinguish source interval vs baseline

### 20.3 Output schema

Suggested schema:
```json
{
  "summary_mode": "short|standard|verbose",
  "overview": "...",
  "changes": [{"result_ref": "res_...", "text": "..."}],
  "uncertainties": ["..."],
  "questions_to_discuss": ["..."],
  "citations": ["res_...", "report_..."]
}
```

### 20.4 Citation requirement

Every AI sentence about a result should trace to visible record refs. BADAN should make those refs tappable in the UI.

### 20.5 On-device vs cloud

Default strategy:
- on-device templates and deterministic summaries where possible
- optional cloud LLM only with explicit consent for richer narrative generation
- user control over whether documents or only structured extracts can be sent

### 20.6 Guardrails

- no diagnosis
- no medication/dose advice
- no emergency advice beyond soft wording like "consider reviewing this result with a qualified clinician" when warranted by source text or obvious uncertainty
- always disclose missing context or limited data

## 21. Correlation and contextual exploration

BADAN should allow users to explore associations between labs and adjacent domains—sleep, recovery, training load, nutrition, symptoms, cycle phase, body composition, medication changes—while being explicit that these are context overlays, not causal claims.

Safe features:
- timeline overlays
- "what else changed around this period?"
- tagged context notes (fasting, illness, supplement change)
- optional correlation cards with sample-size warnings

Unsafe features to avoid early:
- auto-causal claims
- strong lifestyle prescriptions based on weak correlations

## 22. Search, filtering, and tagging

Search must support:
- canonical and alias names
- bilingual names
- source labels
- panel names
- lab organization names
- result values / flagged states / date ranges
- tags / notes / question status

Filter dimensions:
- category
- source lab
- report type
- collection period
- sensitivity tier
- review state
- outside source interval
- unit family
- structured vs OCR vs manual

## 23. Manual entry and correction workflows

Manual entry and correction need explicit product dignity because they are central to trust.

### 23.1 Manual entry modes

- quick add marker
- add full panel
- add full report from paper copy
- add qualitative result

### 23.2 Correction workflow

When BADAN extracted "7.0" but the user corrects to "1.0", the system should keep:
- original extracted field
- corrected field
- correction reason optional
- timestamp
- actor
- whether downstream normalized/derived fields were recalculated

### 23.3 Override policy

User corrections should override display and derived analytics while preserving original source lineage.

## 24. PDF, image, OCR, and document-ingestion workflows

### 24.1 Pipeline

1. document capture/import
2. file integrity/hash
3. MIME and page analysis
4. embedded-text extraction if possible
5. OCR if needed
6. layout segmentation
7. candidate analyte extraction
8. confidence scoring
9. duplicate check
10. review queue
11. canonical normalization

### 24.2 OCR design requirements

- locale-aware decimal/comma parsing
- unit dictionary with fuzzy matching
- reference-range parser
- symbol handling for `<`, `>`, `≤`, `≥`, plus/minus
- row bounding-box retention for visual review
- multilingual OCR support including Arabic and English

### 24.3 Failure handling

- unreadable page -> store document, mark extraction failed
- partial parse -> store what was extracted, mark remainder unknown
- conflicting rows -> require review
- non-lab document -> route to "unclassified clinical document"

## 25. Export, portability, and personal API strategy

### 25.1 Export classes

- original documents export
- marker CSV export
- report JSON export
- notebook JSON export
- FHIR-compatible export where practical
- human-readable PDF report
- appointment packet export
- research-style export (de-identified if user chooses)

### 25.2 Raw vs normalized vs derived

Every export should clearly separate:
- raw source fields
- normalized fields
- derived fields
- user annotations
- provenance metadata

### 25.3 Auditability

Every export bundle should log:
- who triggered it
- when
- scope
- whether encrypted
- target/share path if known locally

### 25.4 Personal API

Long-term, BADAN can expose a user-owned personal API where authorized clients query lab records in canonical form. This should be future work after core notebook trust is mature.

## 26. Annotations, questions, notes, and visit preparation

This is one of the strongest differentiators versus generic lab dashboards.

Features:
- private note on result/report
- "question to discuss" item with appointment tags
- contextual note (fasting, illness, supplement, cycle day)
- clinician packet builder selecting results + questions + notes
- export template optimized for appointments

## 27. Visualization and charting language

BADAN should use restrained visuals.

### 27.1 Chart rules

- default point + line with clearly labeled units
- source interval band optionally shown
- baseline band optionally shown
- lab/source color overlay optional
- sparse data gets point-only charts
- qualitative results get timeline badges, not fake numeric axes

### 27.2 Anti-panic color system

Do not use aggressive red for every out-of-range result. Prefer:
- neutral primary line
- subtle source-interval shading
- muted attention markers for outside-source-interval
- explicit labels rather than implied severity

## 28. Accessibility, Arabic, RTL, localization, and cultural design

### 28.1 Accessibility

- dynamic type support
- chart alternative text
- screen-reader descriptions of trend and interval status
- high-contrast modes
- touch targets for dense tables

### 28.2 Arabic and RTL

- bilingual analyte dictionary
- preserve original Arabic source labels where present
- mirrored layouts for tables where appropriate
- numerals/date conventions configurable
- PDF export templates with proper RTL paragraph shaping
- unit display should remain scientifically stable while surrounding text follows RTL

### 28.3 Localization caveat

Do not over-translate medical abbreviations blindly. Many users know mixed Arabic-English marker names; BADAN should support dual display rather than forced replacement.

## 29. Data quality, uncertainty, and conflict handling

### 29.1 Quality states

| State | Meaning |
|---|---|
| verified_structured | imported from structured clinical source |
| parsed_text_high_confidence | machine parsed with high confidence |
| needs_review | extracted but unverified |
| user_entered | manual entry |
| corrected | user-corrected after import |
| conflict_flagged | overlapping/conflicting records present |

### 29.2 Conflict types

- same report imported twice
- same marker same date different values
- corrected/amended lab report
- source and OCR disagree
- unit mismatch prevents direct comparison

### 29.3 Resolution patterns

- merge duplicates preserving all sources
- supersede with corrected source version but keep old version hidden-by-default
- maintain separate parallel records when truly conflicting

## 30. Privacy, consent, retention, deletion, and sharing

Laboratory records require explicit retention and deletion semantics.

### 30.1 Consent

Separate toggles for:
- Health/Health Connect clinical access
- cloud OCR
- cloud AI summaries
- scoped sharing/export
- future API/webhook use

### 30.2 Retention

Users should be able to choose:
- keep documents and extracted data
- keep extracted data only after deleting documents
- local-only storage for high-sensitivity categories
- synchronized encrypted backup allowed/disallowed

### 30.3 Deletion

Deletion must consider linked exports and derived analytics. If a source record is deleted, BADAN should remove or re-evaluate affected derived trends and indicate that historical summaries changed.

### 30.4 Sharing

If sharing is added, it must be scoped by report/panel/marker/date range and revocable. Never share unrelated notebook data by default.

## 31. Compliance-aware boundaries

BADAN should stay squarely on the personal-health-record / wellness-organization side in MVP and near-term phases. The product may display source lab data, organize it, summarize change over time, and help users prepare clinician questions. It should not claim diagnosis, treatment, triage, or clinician replacement.

Guardrails:
- no diagnostic labels based solely on BADAN rules
- no dosage recommendations
- no simplistic severity scoring
- no "clinically significant" claim unless tied to explicit source language and framed as source-provided

## 32. Backend, local storage, encryption, and sync architecture

This should align with BADAN's existing architectural direction: native-first clients, shared contracts/schemas, and strong local storage control rather than a cloud-first data dependency.[cite:65]

### 32.1 Storage model

- local encrypted relational store for canonical notebook entities
- file/blob store for source documents
- append-only audit and correction tables
- search index for aliases/text
- derived cache tables for trend summaries

### 32.2 Encryption

- encrypt structured records at rest
- encrypt source documents separately with file-level key management
- app-group/shared-file concerns should be minimized because lab docs are highly sensitive

### 32.3 Sync

If sync exists, it should sync canonical entities + encrypted document blobs + audit lineage. Conflict resolution should prefer source-versioning over destructive last-write-wins for clinical artifacts.

### 32.4 Backend optionality

An optional backend can assist with account sync, encrypted backup metadata, export jobs, and optionally cloud OCR/AI. But BADAN should preserve a meaningful local-only mode.

## 33. On-device intelligence architecture

On-device intelligence should include:
- alias matching
- unit normalization
- duplicate candidate scoring
- trend calculations
- baseline calculations
- deterministic summary templates
- document pre-processing for OCR

Optional cloud intelligence:
- advanced OCR for complex tables
- narrative generation
- multilingual summarization

## 34. Third-party libraries, services, and build-vs-buy options

### 34.1 Candidate areas

- OCR engine(s)
- PDF text extraction
- FHIR parsing libraries
- terminology services for LOINC/UCUM support
- charting libraries
- encrypted file storage utilities

### 34.2 Build vs buy stance

- Build canonical model, provenance, notebook UX, and export architecture in-house.
- Consider buying/using libraries for OCR and FHIR parsing.
- Avoid dependence on a vendor that stores raw lab documents unless that is a clearly optional user-consented path.

## 35. Analytics and experimentation plan

BADAN should measure usefulness, not surveillance.

Key product analytics:
- import completion rate by source type
- review-required rate for OCR imports
- duplicate-resolution rate
- top searched markers/panels
- export usage by format
- question-prep usage before appointments
- AI summary acceptance/correction rate

No ad-targeting analytics. Sensitive payload minimization is essential.

## 36. Edge cases and failure-mode inventory

| Edge case | Required handling |
|---|---|
| Same marker different names | alias mapping + preserve source text |
| Same marker incompatible units | separate display until safely normalized |
| No reference interval | no invented interval |
| Report date differs from collection date | preserve both distinctly |
| Corrected lab result later arrives | version relation, supersede display |
| Same PDF imported twice | hash + metadata duplicate check |
| OCR misreads decimal | review state, source crop display |
| OCR misreads unit/range/symbol | row-level correction UI |
| Handwritten forms | likely document-only + manual extraction |
| Multilingual or Arabic report | language-aware OCR, preserve source label |
| Poor scan quality | store doc, extraction failed state |
| Qualitative result no numeric value | preserve text, timeline badge |
| `<` / `>` bounded values | comparator field, no fake exact value |
| not detected / positive / negative | coded/text result model |
| user changes sex/age metadata later | do not rewrite source intervals retroactively; maybe affect user baseline contextual views |
| portal unavailable | source stale state, cached records remain |
| PDF cannot be parsed | document retained, manual entry fallback |
| misleading chart colors | neutral palette + legend |
| mistaken causal interpretation | explicit correlation disclaimer |
| deletion/export conflict | warn that existing exports outside app may persist |
| misleading custom thresholds | separate user-defined labels from source intervals |
| role-based sharing scope | enforce object-level export bundles |

## 37. MVP, phased roadmap, and dependency map

### MVP

- source-document storage (PDF/image)
- manual entry
- iOS HealthKit clinical-record import if practical
- report/panel/marker model
- marker detail with trend charts
- source interval display
- OCR review queue (basic)
- notes/questions
- CSV/JSON/PDF export basics
- Arabic/RTL-ready data model and UI copy structure

### Phase 2

- Android Health Connect Medical Records import
- robust OCR table extraction
- duplicate merge UI
- virtual collections
- clinician packet builder
- AI report summaries with citations
- per-lab overlays and baseline bands

### Phase 3

- direct FHIR bundle import and/or provider connectors
- smart collections
- scoped sharing grants
- personal API/export automation
- advanced correlations with context logs

### Long-term

- richer microbiology/culture structuring
- genetic metadata support
- advanced visit-prep and longitudinal packet generation

## 38. Detailed epic and backlog seed

| ID | Capability | Phase | Owner | Dependencies | Approval needed | Proposed files/modules | Acceptance criteria |
|---|---|---|---|---|---|---|---|
| LAB-01 | Canonical lab schema | MVP | core/data | ontology decisions | yes | domain/labs/* | schema supports report/panel/result/provenance |
| LAB-02 | Source document vault | MVP | mobile/core | encrypted files | yes | storage/docs/* | PDF/image stored with hash and metadata |
| LAB-03 | Manual entry flows | MVP | product/mobile | LAB-01 | no | ui/labs/manual/* | user can add marker and report manually |
| LAB-04 | Marker browser/detail | MVP | mobile/design | LAB-01 | no | ui/labs/markers/* | search + trend + raw details |
| LAB-05 | Report detail/viewer | MVP | mobile | LAB-02 | no | ui/labs/reports/* | original document visible with metadata |
| LAB-06 | OCR pipeline basic | MVP | data/ML/mobile | LAB-02 | yes | ingest/ocr/* | text extracted and review queue created |
| LAB-07 | OCR review/correction UI | MVP | mobile | LAB-06 | no | ui/labs/review/* | user can correct rows before save |
| LAB-08 | Unit normalization engine | MVP | core/data | ontology | yes | domain/labs/units/* | safe conversions only |
| LAB-09 | Reference range engine | MVP | core/data | LAB-01 | yes | domain/labs/ranges/* | source intervals displayed distinctly |
| LAB-10 | Export v1 | MVP | backend/mobile | LAB-01/02 | yes | export/labs/* | CSV/JSON/PDF exports work |
| LAB-11 | HealthKit clinical import | MVP+ | iOS | entitlements | yes | ios/clinical/* | imports lab clinical records |
| LAB-12 | Baseline + trend summaries | P2 | core/data | historical data | yes | analytics/labs/* | summary text generated with confidence |
| LAB-13 | Android Medical Records import | P2 | Android | API maturity | yes | android/medical/* | imports Health Connect lab results |
| LAB-14 | AI notebook summaries | P2 | AI/product | structured prompts | yes | ai/labs/* | cited non-diagnostic summaries |
| LAB-15 | Collections + smart filters | P2 | mobile/core | LAB-01 | no | ui/labs/collections/* | user collections supported |
| LAB-16 | Duplicate/conflict resolver | P2 | core/data | import jobs | yes | ingest/dedupe/* | candidates surfaced and merge rules work |
| LAB-17 | FHIR bundle import | P3 | core/backend | parser | yes | ingest/fhir/* | bundle imported losslessly |
| LAB-18 | Sharing grants | P3 | product/backend | export scope model | yes | sharing/labs/* | scoped sharing revocable |

## 39. Risks, anti-patterns, and what not to build

### 39.1 Major risks

- over-normalizing heterogeneous lab data and losing source nuance
- OCR confidence overestimation leading to wrong structured results
- pseudo-diagnostic summaries that erode trust
- poor duplicate/version handling corrupting longitudinal views
- weak Arabic/RTL support causing medical misreading
- cloud dependency for sensitive documents without clear consent

### 39.2 Anti-patterns

- one giant green/yellow/red health score for labs
- replacing source wording with BADAN interpretations
- hiding original units/ranges
- auto-merging records without audit trail
- using a closed analyte dictionary that rejects unknown markers
- assuming one universal reference interval per analyte
- exposing sensitive lab results in ambient surfaces/widgets by default

## 40. Long-term future opportunities

- richer FHIR-native sync with provider ecosystems
- pathology-adjacent structured document support with stricter safety review
- research-study export templates
- family/guardian record architecture with hard identity boundaries
- clinician collaboration packets and redaction presets
- advanced multilingual OCR and bilingual medical glossary features
- local knowledge graph connecting labs, visits, symptoms, and medications through explicit provenance edges

## 41. Final product recommendations

1. Build the lab notebook as a first-class repository subsystem, not a dashboard feature.
2. Make PDF/image/manual ingestion universal in MVP; add structured clinical imports where platform reality permits.[web:106][web:176]
3. Preserve original artifacts and source wording always.
4. Separate source intervals, source flags, user baselines, and user-defined thresholds in both data model and UI.
5. Treat OCR as assistive extraction, never silent truth.
6. Design exports alongside storage so the repository remains user-owned.
7. Use calm, non-diagnostic language and make every summary traceable back to user-visible records.
8. Invest early in bilingual analyte aliasing and RTL-safe UI/export behavior.
9. Delay advanced causal/correlation claims until the notebook's provenance and uncertainty architecture is mature.
10. Use BADAN's lab notebook to become the user's enduring longitudinal record—even when portals change, labs vary, and documents are messy.
