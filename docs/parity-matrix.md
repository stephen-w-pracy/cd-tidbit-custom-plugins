# Parity Matrix

This is the **exact mapping** of what tracks with what across the README, video script, production spec, build spec, and `.harness/` files. A change in one place tells you precisely which other places to update.

> Referenced from `CLAUDE.md`. When you edit any row, check every cell in that row.

---

## 1. Features / controls → where each is defined and demonstrated

| Feature | Source of truth (`.harness/` or `plugin/`) | README | `video/script.md` act | `video/production-spec.md` act | `specs/build.md` |
|---|---|---|---|---|---|
| Plugin step (containerized) | `.harness/pipeline.yaml` (Plugin step wrapped in a Container Step Group inside each env stage) | "Run the Demo" steps 2–4 | Act 3 | Act 3 | §Controls row 1 |
| Container Step Group (`stepGroupInfra`) | `.harness/pipeline.yaml` (`stepGroup` wrapping each env stage's Plugin step) | "Run the Demo" step 1 (callout) | Act 2 (callout) | Act 2 (callout) | §Controls row 2 |
| Plugin image source | `plugin/Dockerfile` + `plugin/entrypoint.py` | "Setup" step 8 (build/push); "Run the Demo" step 1 (tour) | Act 2 | Act 2 | §Controls row 3 |
| Harness secret reference in plugin env | `.harness/pipeline.yaml` — `settings:` (`<+secrets.getValue("kanboard_api_token")>`) | "Setup" step 7 (secret creation); "Run the Demo" step 1 | Act 2 | Act 2 | §Controls row 4 |
| ITSM state change (Kanboard task move) | `plugin/entrypoint.py` → `kb.move_task_position(...)` | "Run the Demo" steps 2–4 | Acts 3, 4, 5 | Acts 3, 4, 5 | §Controls row 5 |
| Per-environment plugin parameter | `.harness/pipeline.yaml` — `KANBOARD_COL: <+env.variables.column_id>` | "Run the Demo" step 1 (callout); steps 2–4 (effect) | Act 2 (callout); Act 4 (reinforcement) | Act 2 (callout); Act 4 (reinforcement) | §Controls row 6 |

---

## 2. Golden-path runs → narrative beats

The demo is **one** pipeline run with three sequential stages. The four narrative beats correspond to: (1) pre-run tour, (2) Dev stage finishing, (3) QA stage finishing, (4) Prod stage finishing.

| Beat | What happens | Kanboard state after | README | `video/script.md` | `video/production-spec.md` |
|---|---|---|---|---|---|
| 1. Tour | Walk through plugin code + Kanboard board before triggering the pipeline | Card in **Backlog** | Step 1 | Act 2 | Act 2 |
| 2. Dev stage finishes | Deploy step rolls a new pod into `web-dev`; Plugin step moves the card | Card in **Dev** | Step 2 | Act 3 | Act 3 |
| 3. QA stage finishes | Deploy step rolls a new pod into `web-qa`; Plugin step moves the card | Card in **QA** | Step 3 | Act 4 | Act 4 |
| 4. Prod stage finishes | Deploy step rolls a new pod into `web-prod`; Plugin step moves the card; pipeline green | Card in **Prod** | Step 4 | Act 5 | Act 5 |

**Invariants:**
- The card MUST start in Backlog before each run. Re-running the demo requires manually dragging the card back (or having a reset script).
- The same plugin image (`ghcr.io/<user>/custom-plugins-kanboard:v1`) must already exist in GHCR before the pipeline runs — the plugin is *not* built by this pipeline.
- All three environments must point at the same Kanboard project, just different column IDs.

---

## 3. Document roles (don't duplicate across these)

| Doc | Role | Contains | Does **not** contain |
|---|---|---|---|
| `README.md` | Learner-facing runbook | Setup steps, golden-path instructions, troubleshooting, future enhancements | Narration, shot lists, design rationale |
| `video/script.md` | Narrator script | Spoken words (blockquotes) + bracketed on-screen actions, by act | Shot framing, camera notes |
| `video/production-spec.md` | Production spec | Act structure, shot lists, key callouts, production notes | Spoken narration (lives in `script.md`) |
| `specs/build.md` | Design spec | Skill interpretation, objectives, decisions, controls/variables/resources tables | Step-by-step learner instructions |
| `docs/resource-map.md` | Identifier graph + templating layers | Who references whom; `${}`/`<+>`/`{{}}` ownership | Demo narrative |
| `docs/placeholders.md` | `${VAR}` → `.env` → consumers | Placeholder table, render verification | — |

---

## 4. Change-impact checklist

When you change… | …re-check these
---|---
`pipeline.yaml` stage/variable names or conditions | README controls table + "Run the Demo"; `video/script.md` acts; `video/production-spec.md` callouts; `specs/build.md` tables; `docs/resource-map.md` §2
The plugin image (Dockerfile / entrypoint / version tag) | README "Prerequisites" + "Run the Demo"; `specs/build.md` Controls table; `video/script.md` Act 2; `video/production-spec.md` Act 2 shots
A Kanboard column rename / project rename | `.env.example` (`KANBOARD_COL_*`); `setup.sh` Kanboard bootstrap block (`KB_PROJECT_NAME`, `KB_COL_NAMES`); `specs/build.md` Controls table; `video/script.md` Act 1+2 board-tour shots; parity §2 column names
The Kanboard bootstrap method (UI vs API, token source, ID source) | `scripts/setup.sh` Kanboard bootstrap block; `.env.example` Kanboard section + comments; `docs/placeholders.md` Kanboard rows; `README.md` "Setup" steps; `specs/build.md` Design Decisions "Kanboard bootstrap is non-interactive" bullet
A `${VAR}` placeholder (add/remove/rename) | `docs/placeholders.md`; `.env.example`; `scripts/setup.sh` (`ENVSUBST_VARS`); the consuming `.harness/` file
A resource identifier (rename) | `docs/resource-map.md` §1–2; every cross-referencing `.harness/` file; `scripts/setup.sh` (endpoint IDs)
Number of stages (e.g. drop QA, add Staging) | README "Run the Demo" step count; `video/script.md` act count; `video/production-spec.md` act table; parity §2 beat count; `.harness/environment-*.yaml`, `infra-*.yaml`, `k8s/*.yaml`
The skill framing | `specs/build.md` "Skill Statement and Interpretation"; CLAUDE.md conventions; README "What You'll Learn"; §1 above
