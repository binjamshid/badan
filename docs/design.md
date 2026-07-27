---
version: alpha
name: BADAN
description: A privacy-respecting, local-first personal health app rendered at two altitudes — calm and casual by default, deep and inspectable for power users — bilingual (English/Arabic) with RTL as a first-order concern.

colors:
  background: "#FAFAF8"
  backgroundDark: "#0C0E11"
  surface: "#FFFFFF"
  surfaceDark: "#16191E"
  surfaceElevated: "#F1F1EE"
  surfaceElevatedDark: "#1E2228"
  primary: "#157A6E"
  primaryDark: "#5BC5BA"
  onPrimary: "#FFFFFF"
  onPrimaryDark: "#08201D"
  textPrimary: "#17191C"
  textPrimaryDark: "#F2F3F5"
  textSecondary: "#5C636D"
  textSecondaryDark: "#9AA1AB"
  border: "#E5E5E0"
  borderDark: "#252A31"
  success: "#2E9E63"
  successDark: "#57C785"
  warning: "#B97A14"
  warningDark: "#E8A13A"
  info: "#2678C4"
  infoDark: "#4C9FE8"
  error: "#C9353B"
  errorDark: "#E5484D"
  logoNoorGround: "#F3EDE3"
  logoNoorMark: "#F3D9A6"
  logoMizanGround: "#0C0F14"
  logoMizanSignal: "#35D0C0"
  logoHilalGround: "#16112E"
  logoHilalGradientStart: "#2FC79A"
  logoHilalGradientEnd: "#17A0B8"
  logoHilalGold: "#E6B667"

typography:
  heroNumeral:
    fontFamily: "SF Pro Rounded"
    fontSize: 44px
    fontWeight: 600
    lineHeight: 1.05
    fontFeature: tabular lining, monospaced digits
  numeralM:
    fontFamily: "SF Pro"
    fontSize: 28px
    fontWeight: 500
    lineHeight: 1.1
    fontFeature: tabular lining
  sectionTitle:
    fontFamily: "SF Pro"
    fontSize: 20px
    fontWeight: 700
    lineHeight: 1.2
  body:
    fontFamily: "SF Pro"
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.4
  bodyCompact:
    fontFamily: "SF Pro"
    fontSize: 15px
    fontWeight: 400
    lineHeight: 1.35
  chip:
    fontFamily: "SF Pro"
    fontSize: 13px
    fontWeight: 500
    lineHeight: 1.2
  caption:
    fontFamily: "SF Pro"
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.3
  link:
    fontFamily: "SF Pro"
    fontSize: 15px
    fontWeight: 500
    lineHeight: 1.3

rounded:
  chip: 10px
  control: 12px
  card: 20px
  sheet: 24px

spacing:
  space1: 4px
  space2: 8px
  space3: 12px
  space4: 16px
  space5: 20px
  space6: 24px
  space7: 32px
  space8: 40px
  cardPadding: 16px
  touchMin: 44px
  touchGap: 16px

components:
  card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.textPrimary}"
    rounded: "{rounded.card}"
    padding: "{spacing.cardPadding}"
  statusChip-inBand:
    backgroundColor: "{colors.success}"
    textColor: "{colors.success}"
    typography: "{typography.chip}"
    rounded: "{rounded.chip}"
    padding: "6px 10px"
  statusChip-outOfBand:
    backgroundColor: "{colors.warning}"
    textColor: "{colors.warning}"
    typography: "{typography.chip}"
    rounded: "{rounded.chip}"
    padding: "6px 10px"
  statusChip-info:
    backgroundColor: "{colors.info}"
    textColor: "{colors.info}"
    typography: "{typography.chip}"
    rounded: "{rounded.chip}"
    padding: "6px 10px"
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.onPrimary}"
    typography: "{typography.link}"
    rounded: "{rounded.control}"
    padding: "12px 20px"
    height: 44px
  sectionHeader:
    textColor: "{colors.textPrimary}"
    typography: "{typography.sectionTitle}"
    padding: "0"
  metricTile:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.textPrimary}"
    typography: "{typography.numeralM}"
    rounded: "{rounded.card}"
    padding: "{spacing.cardPadding}"
  tabBarItem:
    textColor: "{colors.textSecondary}"
    typography: "{typography.caption}"
    size: 44px
  appIconOption:
    backgroundColor: "{colors.surfaceElevated}"
    textColor: "{colors.textPrimary}"
    typography: "{typography.bodyCompact}"
    rounded: "{rounded.control}"
    padding: "{spacing.space3}"
---

# BADAN Design System

## Overview

BADAN unifies wearable, behavioral, and self-reported health data into one user-controlled model. It's used daily, often at a glance — checking a readiness score before getting out of bed — so the product has to read calmly at speed while still holding up under close inspection from users who want the full instrument panel. Casual and power modes are presentation layers over one component library, never two designs, and the whole system is bilingual (English/Arabic) with RTL as a first-order concern, not a localization afterthought. The tone is "warm instrument": precise, data-forward information delivered with human warmth, dark-first but fully dual-theme. Anti-patterns: never moralize a reading with red/green alarm language, never let Arabic/RTL feel like a bolted-on translation, never let "power user" density come at the cost of accessibility (WCAG AA, Dynamic Type, Reduce Motion) on the casual surface.

## Colors

`background`/`surface`/`surfaceElevated` form a three-layer light scale (warm off-white ground, white cards, light-gray overlays for sheets/chips/inputs) that inverts to a near-black scale in dark mode — every token ships both values from day one. `primary` is a calm teal used for every interactive accent: buttons, links, selected states. It is not literal in the source blueprint (which left global primary unspecified, using per-pillar accents) — it was derived and verified at WCAG AA (5.2:1 on white in light mode; the dark-mode value is a lighter teal for legibility against a near-black base). `onPrimary` is the color painted *on* a primary-filled surface (save buttons, selected chips); in dark mode this is a near-black teal rather than plain white, because white-on-primary measures ~2.07:1 against the light-teal dark-mode primary — well under AA — on exactly the controls that commit a health record.

Status colors follow one hard rule: BADAN never moralizes a reading. `success` marks "in your personal band." Both above-range and below-range use the *same* `warning` amber — direction is carried by an arrow and a text label, never by a second hue, so out-of-band never reads as "bad." `error` is reserved and deliberately almost never used, to keep its signal meaningful if it's ever needed. `info` is a neutral blue for informational, no-judgment content. Every color pair (text or icon against its background) meets WCAG AA — 4.5:1 for text, 3:1 for graphics — in both light and dark, including a further high-contrast variant for status-chip text under the system's "Increase Contrast" setting.

The `logo*` tokens are a separate, narrower palette used only by the selectable app-icon system (see **Logo & App Icon System** below) — they never appear in app chrome, cards, or UI controls.

## Typography

The type ramp is data-forward: numerals throughout the app use tabular/monospaced lining digits so values never jitter as they update, with Eastern-Arabic digit parity per locale. Every token maps to the nearest iOS Dynamic Type text style (with an explicit weight/design override to preserve the mined visual hierarchy) rather than a fixed point size, so the whole ramp scales with the user's preferred text size. `heroNumeral` (rounded, semibold) is reserved for the single biggest number on a screen — ring centers, metric heroes. `numeralM` is for stat-card values. `sectionTitle` heads a card or section. `body`/`bodyCompact` carry narrative prose and dense power-user tables respectively. `chip` is for passive status/pill labels only; `link` is visually similar but reserved for tappable text actions ("See all", "Why") so a glance can't confuse a label for a button.

## Layout

Spacing runs on a strict 4pt scale (`space1`…`space8`, 4px–40px) plus two named exceptions: `cardPadding` (16px, the interior padding of every card) and `touchMin` (44px, the iOS minimum tappable target — non-negotiable). `touchGap` (16px) is the minimum gap between two adjacent tappable targets, distinct from a single target's own minimum size. Density is comfortable, not tight: the casual altitude shows at most 5 modules on Home; the power altitude raises that ceiling but reuses the same card and grid components rather than shrinking type or padding. On iPad's regular horizontal size class, module cards that stack full-width on iPhone pair up into a 2-column tile grid instead (`AdaptiveTiles`) — the same components, just re-flowed, so the iPhone layout is never the fallback case of a two-platform system built iPad-first.

## Elevation & Depth

One elevation cue for the whole app: a soft, low-opacity shadow (`black @ 5% opacity, 8pt blur, 6pt y-offset`) plus a 1px `border` hairline, applied via a single `badanElevation` modifier so every card-adjacent custom surface opts into the same language instead of silently sitting flat next to a real card. The hairline exists because `card` is an opaque content container the eye needs to parse as a distinct region. Tinted "signal" shapes — status pills, chart bands — deliberately do *not* get a stroke: their translucent fill against the surface already reads as bounded, and a border on top of a soft tint would compete with, rather than support, the calm/non-alarming status language.

## Shapes

Corners are soft and generous across the board: `chip` (10px) for pills and small controls, `control` (12px) for buttons/inputs, `card` (20px) for the standard content container, `sheet` (24px) for modals. There is no sharp/0px corner anywhere in the system — BADAN's "tactile" principle means nothing reads as a hard instrument edge, even on the power-user density surfaces. Radius scales *up* with a surface's size and prominence, never down.

## Components

`card` is the single grouped-content surface used everywhere — casual and power altitudes are two densities over this one container, never two designs. `statusChip-*` renders a value's relationship to the user's personal range: `inBand` (green), `outOfBand` (amber, used for both above *and* below), `info` (blue, neutral). Status chips always pair color with an icon/arrow and a text label — hue is never the only signal. `button-primary` is the one filled call-to-action style, always `primary`-filled with `onPrimary` content. `sectionHeader` titles a card or section with an optional trailing action. `metricTile` is the stat-card building block for both the casual module list and the power `MetricGridCell` 2-column grid — same component, different grid arity. `tabBarItem` is the 5-item root tab bar (Today/Body/Log/Insights/Settings — Arabic: اليوم/الجسم/تسجيل/ملاحظات/الإعدادات); RTL mirrors the whole bar, not just the icons. `appIconOption` is the row style used in Settings → Personalization to preview and select among the 5 app-icon identities.

## Do's and Don'ts

- ✓ Do pair every status color with an icon and a text label — never rely on hue alone.
- ✓ Do use the same `card`/`statusChip`/grid components at both casual and power altitude; change density and information depth, not the design language.
- ✓ Do treat RTL as a full mirror (chrome, chevrons, tab bar order) with numeric/time-axis data staying LTR inside it.
- ✓ Do route every color pair through the light/dark token pair — never hardcode a hex that only works in one theme.
- ✓ Do keep every tappable target at or above `touchMin` (44px), even in dense power-user grids.
- ✗ Don't introduce a second "severity" color for out-of-band readings — one calm amber covers every magnitude; escalation is carried by text, not a redder hue.
- ✗ Don't ship a screen, chip, or empty/error state without an Arabic string and a verified RTL layout pass.
- ✗ Don't reach for `error`/`critical` red outside its reserved, near-never-used case — using it casually erodes the one signal it's meant to carry.
- ✗ Don't add a sharp (0px) corner anywhere — it reads as clinical/alarming against the rest of the system's soft, tactile language.
- ✗ Don't let power-mode density shrink type below the Dynamic-Type-scaled ramp or drop a target under 44px — "more altitude," not "smaller text."

## Logo & App Icon System

BADAN ships 5 selectable home-screen icons (`AppIconOption.swift`, backed by `.appiconset` assets in `Assets.xcassets`), switched live via `UIApplication.setAlternateIconName` from Settings → Personalization. **Noor** (نور, "light") is the shipped default: a dawn arc rising over a solid dot — sunrise over the body (بدن) — on a warm sand ground (`logoNoorGround` #F3EDE3) with a soft gold mark (`logoNoorMark` #F3D9A6); the dot never turns red, and the arc warms toward gold as the day settles into range. Two monochrome/calligraphic variants of the same mark ship alongside it: **Noor Line** (clean monoline) and **Noor Qalam** (calligraphic pen stroke) — same identity, different line treatment, no separate palette.

Two further alternate identities exist as distinct visual directions, evaluated alongside Noor and kept as selectable options rather than discarded: **Mizan** (ميزان, "balance/scale of measure") — an instrument-black ground (`logoMizanGround` #0C0F14) with an electric-teal balance-beam mark (`logoMizanSignal` #35D0C0), whose centered node doubles as the dot of ب (the first letter of بدن); and **Hilal** (هلال, "crescent") — an indigo-night ground (`logoHilalGround` #16112E) with a crescent rendered as negative space inside a khatam eight-point star, in a jewel emerald-teal gradient (`logoHilalGradientStart` #2FC79A → `logoHilalGradientEnd` #17A0B8) with a gold spark accent (`logoHilalGold` #E6B667).

These three micro-palettes are **icon-only** — none of them replace `colors.primary` or any other app-chrome token; the shipped UI stays on the teal `primary` (#157A6E) regardless of which icon is active. Full mockups, wordmarks, and bilingual screen studies for all three directions live in `design/badan-three-design-directions.html`; the compiled option list (titles, concepts, asset-catalog names) lives in `design/design-tokens.json`'s `logo` block, which this section mirrors.
