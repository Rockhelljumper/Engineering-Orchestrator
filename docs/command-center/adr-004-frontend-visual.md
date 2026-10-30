# ADR-004 — Command Center frontend stack and visual direction

| | |
|---|---|
| Status | **Accepted (design), 2026-10-30**, as part of CC0 final acceptance (owner, 2026-10-30 02:20Z). Not implemented; dependencies **not approved for installation** (OD-4) |
| Source | `proposal.md` §4.2, §5.4; `visual-direction.html`; `wireframes.html`; owner decisions OD-4, OD-11 |

## Context

The Command Center must be engaging without implying certainty it does not have. Every state shown must come from a recorded source (§3.4, I-18), and trust levels must look different (I-26). It is served only through the SSH tunnel, so it must make no runtime requests outside the gateway.

## Decision

1. **Stack (approved in principle, OD-4):** React, Radix primitives, TanStack Query, elkjs for DAG layout, built with Vite, in `apps/command-center/`. Two SIL OFL font families bundled as woff2 with `font-src 'self'`: **Archivo** (UI) and **IBM Plex Mono** (numbers, ids, code). Installation needs the owner's go-ahead at CC1, with the lockfile and versions shown first. Anything added to the set needs its own approval.
2. **Visual direction: "Telemetry Console" is the CC1 baseline (OD-11).** Blueprint grid, title-strip panels, annunciator-lamp states, tabular monospaced figures, and saturation used only for the six signal colours (`verified`, `recorded`, `unverified`, `no-data`, `blocked`, `integrity`). Light and dark themes follow the system setting.
3. **Refinement allowed within the rules.** Further visual refinement and agent identities (for example per-agent marks or accent glyphs) are allowed if they keep signal colours reserved for state, keep I-26 trust styling, and pass VX-1…VX-10.
4. **Truthful motion:** a state-change animation starts only after the event has been applied (I-26); motion respects reduced-motion settings.
5. **Accessibility and budgets:** WCAG 2.2 AA (§4.2.9) and the performance budgets of §4.2.11 are acceptance criteria, not goals.

## Consequences

- Hi-fi versions of the six wireframed screens need owner sign-off before the CC1 front-end build starts (VX-10).
- No CDN, analytics or font service at runtime; the bundle is self-contained.
- A token validator (VX-1) and DOM audits (CC1-7, VX-3, VX-4) become build-breaking checks.

## Rejected

Cream-and-terracotta and purple/blue-gradient palettes, glassmorphism, Inter or Space Grotesk, rounded "card soup", runtime Google Fonts, and heavyweight component frameworks that hide state styling.
