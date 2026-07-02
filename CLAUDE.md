# CLAUDE.md

Guidance for Claude Code when working with this repo.

## What This Repo Is

A companion repository for a 10–15 minute Harness "Technical Tidbit" video on **Custom Plugins** (JIRA: PRODEDU-1568).

The tidbit demonstrates the feature in a single concrete workflow a learner can reproduce in their own Harness account. All documentation (README, specs, video script) must stay in parity. See `specs/build.md` for the design rationale and `docs/parity-matrix.md` for the cross-doc change-impact checklist.

## Architecture

### Application
- `app/server.py` — Python stdlib HTTP server (~20 lines). Serves HTML from `/app/content/index.html` (mounted ConfigMap) or `PAGE_CONTENT` env var.
- `app/Dockerfile` — python:3.12-alpine image, exposes port 8080.

### Plugin
- `plugin/entrypoint.py` — Kanboard plugin (~60 lines). Reads `PLUGIN_*` env vars (Harness `settings:` keys get a `PLUGIN_` prefix, Drone convention), calls `kb.move_task_position(...)` to move the demo task and `kb.create_comment(...)` to post a per-deploy comment. Two effects, one plugin invocation.
- `plugin/Dockerfile` — 4 lines. `python:3.12-alpine` base, `pip install kanboard`, copies entrypoint.

### Kubernetes Manifests (Go-templated, resolved by Harness at deploy time)
- `k8s/deployment.yaml` — Deployment using `{{.Values.image}}` for the container image. Includes `imagePullSecrets: ghcr-cred` for private GHCR packages. Mounts ConfigMap at `/app/content`.
- `k8s/service.yaml` — ClusterIP Service (port 80 → 8080).
- `k8s/configmap.yaml` — HTML page template rendered with Go templating. Uses `{{.Values.app_version}}`, `{{.Values.env_name}}`, `{{.Values.env_color}}`, `{{.Values.image}}`.
- `k8s/Dev.yaml`, `k8s/QA.yaml`, `k8s/Prod.yaml` — Per-environment values files. Selected by the Service's Values YAML path `k8s/<+env.name>.yaml`. Set `env_name`, `env_color` (Dev blue `#0d6efd`, QA orange `#fd7e14`, Prod green `#198754`), and read artifact details: `app_version` from `<+artifact.tag>`, `image` from `<+artifact.image>`.

### Harness Resources (`.harness/`)
- `pipeline.yaml` — Main CD pipeline (`build_and_deploy_demo_app`): Build App Image (CI) → Deploy to Dev → Deploy to QA → Deploy to Prod. Each deploy stage does `K8sRollingDeploy` then a `stepGroup` (`Kanboard_Notification_*`) with `stepGroupInfra: KubernetesDirect` (connectorRef `pipelinedemocluster`) wrapping a `Plugin` step (`Notify_Kanboard_*`). Pipeline variables: `github_user`, `plugin_image` (`:latest`), `kanboard_project_id`, `kanboard_task_id`.
- `build-plugin-pipeline.yaml` — Standalone CI pipeline (`build_kanboard_plugin`) that builds `plugin/Dockerfile` on Harness Cloud and pushes `ghcr.io/<github_user>/custom-plugins-kanboard:v<sequenceId>` and `:latest` to GHCR. Run once after setup, or when `plugin/` changes.
- `service.yaml` — Kubernetes Service entity (`custom_plugins_demo`). Manifest paths from GitHub, values path `k8s/<+env.name>.yaml`, DockerRegistry artifact source with `tag: <+input>`.
- `environment-dev.yaml`, `environment-qa.yaml`, `environment-prod.yaml` — Dev (PreProduction), QA (PreProduction), Prod (Production). Each carries an env variable `column_id` referenced by the pipeline as `<+env.variables.column_id>`.
- `infra-dev.yaml`, `infra-qa.yaml`, `infra-prod.yaml` — KubernetesDirect infrastructure definitions (`Dev_Infra` / `QA_Infra` / `Prod_Infra`), namespaces `web-dev` / `web-qa` / `web-prod`, releaseName `release-<+INFRA_KEY_SHORT_ID>`.
- `connector-github.yaml` — GitHub code connector (`github`). `tokenRef` and `apiAccess.tokenRef` both point at the `ghcr_token` secret.
- `connector-ghcr.yaml` — GHCR Docker registry connector (`ghcrconn`). `passwordRef` is `ghcr_token`.
- `connector-k8s.yaml` — K8s cluster connector (`pipelinedemocluster`), InheritFromDelegate with selector from `${DELEGATE_SELECTOR}` in `.env`.
- Secrets (created inline in `setup.sh`, not `.harness/` files): `ghcr_token` (GitHub PAT), `kanboard_url`, `kanboard_api_token`.

### Supporting Files
- `scripts/setup.sh` — Automated provisioning: renders `.harness/` templates and creates every Harness resource via the NG REST API, plus cluster namespaces, the GHCR imagePullSecret, a Helm-installed delegate, and a Helm-installed Kanboard with a non-interactive JSON-RPC bootstrap that creates the project, columns, and demo task. Idempotent (POST → PUT on conflict). Honors `--dry-run`.
- `scripts/validate-setup.sh` — Pre-flight checks (tools, `.env`, cluster reachability, namespaces, delegate).
- `scripts/cleanup.sh` — Tears down the full tutorial: Harness project (cascade-deletes children), Kanboard Helm release, `web-*` namespaces, delegate Helm release. Honors `--dry-run` and `-y`.
- `scripts/port-forward.sh` — Foreground port-forward: Dev (8080), QA (8081), Prod (8082), Kanboard (8090). Auto-reconnects on pod rotation.
- `specs/build.md` — Design spec: skill interpretation, learning objectives, decisions, controls/variables/resources tables.
- `video/script.md` — Narrator script (5 acts), read while performing the on-screen actions.
- `video/production-spec.md` — Video production reference: act structure, shot lists, key callouts, production notes.

### Navigation Aids (read these first)
- `docs/resource-map.md` — The `.harness/`/`k8s/` identifier graph (who references whom) and which templating engine (`${VAR}` envsubst / `<+...>` Harness / `{{.Values}}` Go) owns each token. Start here before tracing a reference or changing an ID.
- `docs/placeholders.md` — Canonical `${VAR}` → `.env` key → consuming-files table, with render-verification commands.
- `docs/parity-matrix.md` — Maps each feature/golden-path beat to its README anchor, `video/script.md` act, `video/production-spec.md` act, and `specs/build.md` row, plus a change-impact checklist. Consult before editing demo steps to know what else must change.

## Common Commands

```bash
make validate          # Pre-flight checks
make cleanup           # Tear down what setup.sh created
make port-forward      # Foreground port-forward to Dev (8080), QA (8081), Prod (8082), and Kanboard (8090)
```

## Key Conventions

- **Parity.** Changes to README demo steps, pipeline YAML, or video script must be reflected across all of them and in `specs/build.md`. See `docs/parity-matrix.md` for the cross-doc change-impact checklist.
- **Three-engine templating** (only relevant if `.harness/` references envsubst placeholders and k8s manifests use Go templating):
  - `${VAR}` — resolved at setup time by `scripts/setup.sh` via `envsubst` (restricted whitelist).
  - `<+...>` — Harness pipeline expressions, resolved at run/deploy time.
  - `{{.Values.x}}` — Go templating in k8s manifests, resolved at deploy time after Harness fills the values.
- **No external dependencies** in the demo app. Prefer stdlib.
- (Add tidbit-specific conventions as the spec firms up.)

## Skill workflow

When iterating on this tidbit, lean on the `harness-tidbit` plugin:

- `/tidbit-spec` — draft or refine `specs/build.md`, README outline, and video script in parity.
- `/tidbit-resources` — regenerate `scripts/setup.sh`, `docs/resource-map.md`, `docs/placeholders.md` from current `.harness/`.
- `/tidbit-parity-check` — audit cross-doc drift before recording.
