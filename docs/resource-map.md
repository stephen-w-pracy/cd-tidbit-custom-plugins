# Harness Resource Map

The single source of truth for **how the `.harness/` resources reference each other**, and **which templating engine owns each token**. Use it to answer "who references this identifier?" and "what resolves this `${...}` / `<+...>` / `{{...}}`?" without grepping every file.

> Keep this in sync when you rename an identifier, add a cross-reference, or change a templated value. Referenced from `CLAUDE.md`.

---

## 1. Identifier registry

Every Harness resource has a stable **identifier** (account-independent — these are *not* templated). Display `name`s may differ from identifiers; both are listed where they diverge.

| Resource | File | `identifier` | `name` |
|---|---|---|---|
| Project | created inline in `setup.sh` (via `.env`'s `HARNESS_PROJECT`) | `custom_plugins` | `custom_plugins` |
| Pipeline | `.harness/pipeline.yaml` | `build_and_deploy_demo_app` | `Build and Deploy Demo App` |
| Pipeline (CI) | `.harness/build-plugin-pipeline.yaml` | `build_kanboard_plugin` | `Build Kanboard Plugin` |
| Service | `.harness/service.yaml` | `custom_plugins_demo` | `custom-plugins-demo` |
| Environment (Dev) | `.harness/environment-dev.yaml` | `Dev` | `Dev` |
| Environment (QA) | `.harness/environment-qa.yaml` | `QA` | `QA` |
| Environment (Prod) | `.harness/environment-prod.yaml` | `Prod` | `Prod` |
| Infrastructure | `.harness/infra-dev.yaml` | `Dev_Infra` | `Dev_Infra` |
| Infrastructure | `.harness/infra-qa.yaml` | `QA_Infra` | `QA_Infra` |
| Infrastructure | `.harness/infra-prod.yaml` | `Prod_Infra` | `Prod_Infra` |
| Connector (K8s) | `.harness/connector-k8s.yaml` | `pipelinedemocluster` | `pipeline-demo-cluster` |
| Connector (GHCR) | `.harness/connector-ghcr.yaml` | `ghcrconn` | `custom-plugins-ghcr` |
| Connector (GitHub) | `.harness/connector-github.yaml` | `github` | `custom-plugins-github` |
| Secret (text) | created inline in `setup.sh` | `ghcr_token` | `ghcr_token` |
| Secret (text) | created inline in `setup.sh` | `kanboard_url` | `kanboard_url` |
| Secret (text) | created inline in `setup.sh` | `kanboard_api_token` | `kanboard_api_token` |

**Load-bearing names** (not free to rename):
- Environment names `Dev`, `QA`, `Prod` are also used as `<+env.name>` in `service.yaml`'s `valuesPaths: k8s/<+env.name>.yaml` — renaming requires renaming the matching `k8s/<env>.yaml` values file.
- Infrastructure identifiers `Dev_Infra` / `QA_Infra` / `Prod_Infra` are referenced by name from `pipeline.yaml`'s per-stage `infrastructureDefinitions`.
- Secret identifiers `kanboard_url`, `kanboard_api_token`, `ghcr_token` are referenced from `pipeline.yaml`'s Plugin step `settings` (`<+secrets.getValue("…")>`) and from `connector-github.yaml` / `connector-ghcr.yaml`'s `tokenRef` / `passwordRef`.

---

## 2. Reference graph (who points at whom)

```
pipeline.yaml (build_and_deploy_demo_app)
├─ Build_App_Image step connectorRef: ghcrconn      → connector-ghcr.yaml
├─ properties.ci.codebase.connectorRef: github      → connector-github.yaml
├─ serviceRef: custom_plugins_demo                  → service.yaml
├─ environmentRef: Dev | QA | Prod                  → environment-*.yaml
├─ infrastructureDefinitions: Dev_Infra | …         → infra-*.yaml
├─ Plugin step image / connectorRef: ghcrconn       → connector-ghcr.yaml
└─ <+secrets.getValue("kanboard_url" | …)>          → text secrets created in setup.sh

build-plugin-pipeline.yaml (build_kanboard_plugin)
├─ Build_and_Push step connectorRef: ghcrconn       → connector-ghcr.yaml
└─ properties.ci.codebase.connectorRef: github      → connector-github.yaml

service.yaml (custom_plugins_demo)
├─ manifest store connectorRef: github              → connector-github.yaml
└─ artifact source connectorRef: ghcrconn           → connector-ghcr.yaml

infra-*.yaml (Dev_Infra | QA_Infra | Prod_Infra)
└─ connectorRef: pipelinedemocluster                → connector-k8s.yaml

connector-github.yaml (github)
├─ tokenRef: ghcr_token                             → text secret
└─ apiAccess.tokenRef: ghcr_token                   → text secret

connector-ghcr.yaml (ghcrconn)
└─ passwordRef: ghcr_token                          → text secret

connector-k8s.yaml (pipelinedemocluster)
└─ delegateSelectors: [${DELEGATE_SELECTOR}]        → matches a tag on the installed delegate
```

**Provisioning / dependency order** (used by `scripts/setup.sh`):
`project → secrets → connectors → service → environments → infrastructures → pipeline → input sets`. Each resource must exist before anything that references it.

---

## 3. Templating layers — who resolves what

Three engines resolve tokens, in this order. They never overlap; knowing the owner tells you *when* and *by what* a token is replaced.

| Token form | Engine | Resolved when | Resolved by | Example |
|---|---|---|---|---|
| `${VAR}` | **envsubst** | Setup time | `scripts/setup.sh` (restricted var list) | `${HARNESS_ORG}` |
| `<+...>` | **Harness expressions** | Run / deploy time | Harness pipeline engine | `<+pipeline.sequenceId>`, `<+artifact.image>` |
| `{{.Values.x}}` | **Go templating** | Deploy time (after Harness resolves values) | Harness K8s manifest renderer | `{{.Values.image}}` |

### Where each appears

- **`${VAR}` (envsubst):** account/org/project, delegate selector, GitHub username/repo, Kanboard project/task/column IDs. See [placeholders.md](placeholders.md) for the full list and which file consumes each.
- **`<+...>` (Harness expressions):** appear in `pipeline.yaml` (`<+secrets.getValue(...)>`, `<+pipeline.variables.*>`, `<+env.variables.column_id>`, `<+pipeline.sequenceId>` for the artifact tag), `service.yaml` (`<+env.name>` in valuesPaths, `<+input>` for artifact tag), `k8s/<env>.yaml` (`<+artifact.tag>`, `<+artifact.image>`), `infra-*.yaml` (`<+INFRA_KEY_SHORT_ID>` in releaseName).
- **`{{.Values.x}}` (Go templating):** appear in `k8s/deployment.yaml` etc.; values come from `k8s/<env>.yaml` (selected by `<+env.name>`).

---

## 4. Quick lookups

**"What references identifier X?"** — see §2 graph.

**"Which file feeds this `${VAR}`?"** — see [placeholders.md](placeholders.md).

**"If I edit a demo step, what else changes?"** — see [parity-matrix.md](parity-matrix.md).

**"Which secret does what?"**
- `ghcr_token` — the GitHub PAT. `connector-github.yaml` uses it as `tokenRef` (and `apiAccess.tokenRef`) so Harness can fetch the pipeline codebase; `connector-ghcr.yaml` uses it as `passwordRef` so the CI stage can push the app image and the plugin container can be pulled at run time.
- `kanboard_url` — the in-cluster JSON-RPC endpoint the plugin talks to. Injected into the Plugin step's `settings:` via `<+secrets.getValue("kanboard_url")>`.
- `kanboard_api_token` — the API token the plugin authenticates with (as the reserved `jsonrpc` user). Same value is present in the Kanboard pod as `API_AUTHENTICATION_TOKEN`, injected by the Helm chart via `application.env[]`.
