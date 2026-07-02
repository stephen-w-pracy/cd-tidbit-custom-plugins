# Custom Plugins — Build Spec

This spec describes the learner instructions, the video script, and the reproducible repo that demonstrates **Custom Plugins** (JIRA: PRODEDU-1568).

Target audience: **CD practitioners extending an existing pipeline** — viewers comfortable with stages and steps who need to learn how to drop in a custom plugin and what the contract between the plugin and Harness looks like.

See [README.md](../README.md) for the learner's instructions and [video/script.md](../video/script.md) / [video/production-spec.md](../video/production-spec.md) for the video.

## Skill Statement and Interpretation

> Extend Harness pipelines with a containerized plugin that drives an external ITSM workflow.

The tidbit treats the Plugin step as five coordinate sub-skills demonstrated in the order a learner encounters them in a real pipeline: (1) **the step itself** (image + reference), (2) **the image's source** (Dockerfile + entrypoint), (3) **secrets injected as env vars**, (4) **the externally-visible effect** (an ITSM state change), and (5) **per-environment parameterization** of the same image. The ITSM target is [Kanboard](https://kanboard.org/) — an open-source Kanban board hosted in the learner's own cluster — and the externally-visible effect is one task hopping across columns as the pipeline progresses Dev → QA → Prod.

## Learning Objectives

After completing this tidbit, a learner can:

1. Build a containerized Harness Plugin step from a Dockerfile inside a Harness CI stage.
2. Push the plugin image to a registry (GHCR) and reference it from a pipeline.
3. Pass per-environment configuration to a single plugin image via env vars.
4. Inject Harness secrets into a Plugin step's environment.
5. Observe the plugin's effect on an external ITSM system (Kanboard).

## Documentation Resources

- [Harness Plugin step](https://developer.harness.io/docs/continuous-integration/use-ci/use-drone-plugins/run-a-drone-plugin-in-ci/) — the Plugin step is a Drone-style plugin (image + settings → env vars)
- [Kanboard docs](https://docs.kanboard.org/)
- [Kanboard Python client](https://github.com/kanboard/kanboard-api-python)
- [Kanboard Helm chart (kube-the-home)](https://github.com/kube-the-home/kanboard-helm)

## Repo Structure

See the Repository Structure block in the README for the authoritative file tree. The high-level layout:

- `app/` — the Python stdlib web app being deployed to Dev / QA / Prod
- `plugin/` — the containerized Kanboard plugin (Dockerfile + entrypoint.py)
- `k8s/` — Kubernetes manifests for the demo app (Go-templated)
- `.harness/` — Harness resources (pipeline, service, environments, infras, connectors, secrets)
- `scripts/` — `setup.sh`, `cleanup.sh`, `validate-setup.sh`, `port-forward.sh`
- `docs/` — resource map, placeholder table, parity matrix
- `specs/` — this spec
- `video/` — narrator script and production spec

## Design Decisions

- **Deployed app is the exemplar's stdlib Python web app.** Keeps the deploy half of the demo familiar; viewer attention stays on the plugin step. Visible per-env badge color confirms the deploy worked at a glance.
- **Kanboard runs in the cluster via the `kube-the-home/kanboard-helm` chart.** Chart is actively maintained (v1.2.4 / app v1.2.52 as of 2026-06-25), defaults to SQLite (no external DB), no persistence by default (chart's RWX default fails on most demo clusters and board state can reset per teardown). One `helm upgrade -i` line in `setup.sh`. We chose this over hand-rolled manifests for two reasons: the chart handles healthchecks and the Service correctly, and a Helm-managed install is what a learner would do in production.
- **Kanboard bootstrap is non-interactive.** `setup.sh` injects a generated `API_AUTHENTICATION_TOKEN` into the Kanboard pod via the chart's `application.env[]`, then drives a JSON-RPC bootstrap pass (createProject / getColumns / updateColumn × 4 / createTask) over a transient `kubectl port-forward` using `admin:admin` basic auth. The captured project / column / task IDs are written back into `.env`. The learner sees Kanboard in the browser only to *watch* the card move — they never click to generate a token, rename columns, or create the demo task. Re-runs are no-ops (project lookup is by name; `.env` writes only fill blank keys).
- **Plugin uses the official `kanboard` Python client (`pip install kanboard`).** Accepted the small image-size cost in exchange for a one-line API call (`kb.move_task_position(...)`) on camera. Lifts the lesson out of "wrestling with JSON-RPC" and into "what the plugin does".
- **Credentials flow: two Harness secrets (`kanboard_url`, `kanboard_api_token`) injected as env vars into the Plugin step; a third (`ghcr_token`) backs the GHCR and GitHub connectors.** Demonstrates Harness's secret-reference syntax on camera and is the canonical pattern for plugin secrets. The `ghcr_token` secret is off-camera — it's the credential the connectors rely on, not one the plugin itself reads.
- **Single board state change per env: one task moves Backlog → Dev → QA → Prod, and the plugin also posts a comment.** Each successful deploy hops the card to the next column (`kb.move_task_position`) and appends a comment on the task (`kb.create_comment`) with the app version, image, and a link back to the Harness execution. The card-hop is the crisp visual payoff; the comment is the persistent traceability record. Resets cleanly between runs (move the card back to Backlog).
- **Pipeline shape: one Build stage followed by three deploy stages (Dev, QA, Prod).** The Build stage produces the app image; each deploy stage does `Deploy K8s` → `Plugin: notify Kanboard`. Gives the viewer a discrete plugin call per environment to read in the execution view.
- **Harness step type: dedicated `Plugin` step (not `Run` with `image:`).** The Plugin step *is* the lesson — pointing at the `Run` step would muddy the framing.
- **Plugin step in CD is wrapped in a Container Step Group; in CI it isn't.** CI stages come with their own container runtime (`runtime.type: Cloud`), so a bare Plugin step runs directly. CD Deployment stages have no such runtime, so a bare Plugin step fails — the step must be nested inside a `stepGroup` whose `stepGroupInfra: KubernetesDirect` block points at a K8s connector + namespace where the plugin container can spin up. This tidbit surfaces that asymmetry as an explicit lesson rather than hiding it.
- **Plugin image tag: `:latest` for demo simplicity, with the trade-off named in the README.** The app pipeline cannot know the plugin pipeline's `sequenceId` at run time, so referencing `:latest` avoids a manual coordination step every time the plugin changes. In production, three tighter alternatives are worth naming: (1) expose `plugin_image` as `<+input>` and pass the exact tag when triggering the CD pipeline, (2) reference the plugin by content-addressable digest (`@sha256:...`), or (3) have the plugin build pipeline update the CD pipeline's `plugin_image` variable via a webhook/trigger. The tidbit teaches the trade-off honestly rather than picking one and pretending it's universal.
- **Plugin and app images are built in Harness CI on Harness Cloud (`runtime.type: Cloud`).** No local `docker` required, no buildx, no arch flags, no `docker login ghcr.io`. The viewer also sees the Plugin image *being built* in the pipeline view before it's used, which previously happened off-camera. The plugin lives in its own short pipeline (`build_kanboard_plugin`, run once after setup); the app builds at the start of every demo run, tagged with `<+pipeline.sequenceId>` so each run gets a unique deterministic tag.
- **No approval gates in the demo run.** The pipeline runs straight through so the card-hopping is one continuous payoff. Approvals are listed in the README's "Future Enhancements" section as a follow-on the learner can layer in.

(Lessons-learned defaults from the first tidbit retained: no `executionInput()` prompts; demo app has no external runtime deps; five acts max.)

## Pipeline Architecture

```
┌────────────────┐    ┌────────────────┐    ┌────────────────┐    ┌────────────────┐
│ Stage: Build   │───▶│  Stage: Dev    │───▶│  Stage: QA     │───▶│  Stage: Prod   │
│ ─────────────  │    │ ─────────────  │    │ ─────────────  │    │ ─────────────  │
│ Build & Push   │    │ Deploy K8s     │    │ Deploy K8s     │    │ Deploy K8s     │
│ app:<seq>      │    │ Plugin: move   │    │ Plugin: move   │    │ Plugin: move   │
│  → GHCR        │    │  card → Dev    │    │  card → QA     │    │  card → Prod   │
└────────────────┘    └────────────────┘    └────────────────┘    └────────────────┘
```

The same plugin image (`ghcr.io/<user>/custom-plugins-kanboard:latest`) runs three times in one execution; the `KANBOARD_COL` setting differs per stage, and the per-run `APP_VERSION` / `ENV_NAME` / `IMAGE` / `EXECUTION_URL` settings feed the Kanboard comment. The app image is built once at the head of each run and tagged with `v<+pipeline.sequenceId>`. The plugin image itself is built by a separate `build_kanboard_plugin` pipeline (run once after setup, or whenever `plugin/` changes).

## Controls / Features Demonstrated

| Control / Feature | Where it's used | How the learner sees it |
|---|---|---|
| Plugin step (containerized) | `.harness/pipeline.yaml` — Plugin step wrapped in a Container Step Group inside each env stage | The pipeline YAML shows a `type: Plugin` step pointing at a Docker image; the execution view shows three Plugin step instances (nested under a "Kanboard Notification" step-group node) per run |
| Container Step Group (`stepGroupInfra`) | `.harness/pipeline.yaml` — `stepGroup` wrapping each env stage's Plugin step, with `stepGroupInfra: KubernetesDirect` | In a CD stage the Plugin step needs its own container runtime — the `stepGroupInfra: KubernetesDirect` block declares the K8s connector + namespace where the plugin container spins up. CI stages don't need this because `runtime.type: Cloud` provides the runtime. |
| Plugin image source | `plugin/Dockerfile` + `plugin/entrypoint.py`; built by `.harness/build-plugin-pipeline.yaml` | Tour at Act 2: 30 lines of Python and a 4-line Dockerfile. The image is built and pushed by the standalone `build_kanboard_plugin` pipeline (Harness Cloud, no local `docker`). |
| Harness secret reference in plugin env | `.harness/pipeline.yaml` — `settings:` of the Plugin step | `KANBOARD_API_TOKEN: <+secrets.getValue("kanboard_api_token")>` visible in the YAML view |
| ITSM state change (Kanboard task move + comment) | `plugin/entrypoint.py` → `kb.move_task_position(...)` **and** `kb.create_comment(...)` | A live Kanboard tab next to the pipeline view; the demo card hops Backlog → Dev → QA → Prod as each stage finishes, and each stage appends a comment on the task with the app version, image, and a link back to the Harness execution |
| Per-environment plugin parameter | `.harness/pipeline.yaml` — `KANBOARD_COL: <+env.variables.column_id>` (plus `APP_VERSION`, `ENV_NAME`, `IMAGE`, `EXECUTION_URL` that vary per run) | Same image, three runs, three different column IDs — visible by hovering the `settings` map in each stage; the varying per-run values show up in the Kanboard comment |

## Pipeline Variables

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `github_user` | string | (set per learner from `${GITHUB_USERNAME}`) | Used in the plugin image path and as the GHCR namespace |
| `plugin_image` | string | `ghcr.io/<+pipeline.variables.github_user>/custom-plugins-kanboard:latest` | The plugin image the CD pipeline pulls. See the README's *About the plugin image tag* callout for why `:latest` and how to tighten it for production. |
| `kanboard_project_id` | string | (set per learner from `${KANBOARD_PROJECT_ID}`) | The Kanboard project the plugin moves a task within |
| `kanboard_task_id` | string | (set per learner from `${KANBOARD_TASK_ID}`) | The Kanboard task the plugin moves between columns |

## Harness Resources Required

| Resource | Name (suggested) | Purpose |
|---|---|---|
| Project | `custom-plugins` | Container for all tidbit resources |
| Service | `custom-plugins-demo` | The Python web app being deployed |
| Environment (PreProduction) | `Dev` | Dev target |
| Environment (PreProduction) | `QA` | QA target |
| Environment (Production) | `Prod` | Prod target |
| Infrastructure (KubernetesDirect) | `Dev_Infra`, `QA_Infra`, `Prod_Infra` | Per-env namespaces (web-dev, web-qa, web-prod) |
| K8s connector | `pipelinedemocluster` | InheritFromDelegate |
| GHCR connector | `ghcrconn` | Pulls the demo app image AND the plugin image |
| GitHub connector | `github` | Fetches the codebase for both pipelines |
| Secret (text) | `ghcr_token` | Backs `connector-github.yaml` (`tokenRef`) and `connector-ghcr.yaml` (`passwordRef`); the GitHub PAT value |
| Secret (text) | `kanboard_url` | Plugin step env var — the in-cluster JSON-RPC endpoint |
| Secret (text) | `kanboard_api_token` | Plugin step env var — same value as the Kanboard pod's `API_AUTHENTICATION_TOKEN` |
| Pipeline | `build_and_deploy_demo_app` | Build stage + three Deployment stages (Dev / QA / Prod), each with Deploy + Plugin step |
| Pipeline | `build_kanboard_plugin` | Standalone CI pipeline that builds and pushes the plugin image. Run once after setup, or when `plugin/` changes |
| Env variable (per env) | `column_id` | The Kanboard column id this environment maps to |

## See Also

- [README.md](../README.md) — the learner-facing runbook (setup, golden path, troubleshooting).
- [docs/parity-matrix.md](../docs/parity-matrix.md) — controls × docs mapping and change-impact checklist.
- [docs/resource-map.md](../docs/resource-map.md) — identifier registry, reference graph, and templating layers.
- [docs/placeholders.md](../docs/placeholders.md) — `${VAR}` → `.env` → consumers.
- [video/script.md](../video/script.md) and [video/production-spec.md](../video/production-spec.md) — narrator script and production reference.
