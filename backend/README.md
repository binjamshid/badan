# backend/ — Dormant in MVP

**Intentionally empty.** BADAN's MVP ships with **zero backend** (ADR-0002): the on-device
SQLite store is the sole source of truth, there are no accounts, and the app makes no network
calls. Local-first is the strongest proof of the privacy posture and removes an entire risk
class (auth, hosting, compliance).

The first backend work item is **sync** or the **first vendor integration**, whichever is
scheduled first — and not before the M4 review. Until then this directory stays dormant.
