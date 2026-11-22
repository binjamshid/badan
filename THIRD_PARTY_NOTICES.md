# Third-party notices

Third-party material in Badan is subject to its own terms. The [Badan source license](LICENSE) applies to material released under that license by a copyright holder with authority to do so.

## Gradle Wrapper

The Gradle Wrapper scripts (`apps/android/gradlew` and `apps/android/gradlew.bat`) retain their original copyright and Apache-2.0 notices. The checked-in `apps/android/gradle/wrapper/gradle-wrapper.jar` declares Apache-2.0 in its manifest and includes `META-INF/LICENSE`. A matching wrapper JAR checksum is published for Gradle 9.5.0 and 9.6.1. The wrapper configuration selects the separate Gradle 8.11.1 distribution for builds. [Apache License 2.0](LICENSE-APACHE-2.0) · [Gradle release checksums](https://gradle.org/release-checksums/)

## Material Icons

The Android app adapts these Google Material Icons as white-tinted vector drawables:

- `apps/android/app/src/main/res/drawable/ic_shortcut_export.xml` uses a file-upload glyph.
- `apps/android/app/src/main/res/drawable/ic_shortcut_score.xml` uses a bar-chart glyph.
- `apps/android/app/src/main/res/drawable/ic_shortcut_water.xml` uses a water-drop glyph.

These adaptations use Material Icons under the [Apache License 2.0](LICENSE-APACHE-2.0). [Google Material Icons license](https://github.com/google/material-design-icons/blob/master/LICENSE)

## LOINC

Badan references LOINC codes in `packages/contracts/analytes/analytes.json` and its iOS resource mirror `apps/ios/Sources/Resources/analytes.json`. LOINC codes are copyright © Regenstrief Institute, Inc. and the LOINC Committee. LOINC® is a registered trademark of Regenstrief Institute, Inc. The upstream license gives the prescribed inclusion notice in Section 10 and describes any additional attribution specific to an included term. [LOINC Copyright Notice and License](https://loinc.org/kb/license/#copyright-notice-and-license)

## UCUM

Badan references the Unified Code for Units of Measure (UCUM) in `packages/contracts/analytes/units.json` and its iOS resource mirror `apps/ios/Sources/Resources/lab_units.json`. UCUM is copyright © 1999–2024, Regenstrief Institute, Inc. All rights reserved. The publisher’s license gives the terms of use and the warranty disclaimer. [UCUM Copyright Notice and License](https://ucum.org/license)
