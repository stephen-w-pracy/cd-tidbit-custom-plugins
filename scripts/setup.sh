#!/usr/bin/env bash
#
# setup.sh — Provision the Custom Plugins tidbit in your Harness account.
#
# Reads values from .env (copy .env.example → .env first), renders the
# templated YAML in .harness/, and creates everything via the Harness NG API.
# Re-runnable: existing resources are updated (PUT) rather than duplicated.
#
# Also installs the Kanboard Helm chart (kube-the-home/kanboard-helm) into the
# learner's cluster — the ITSM target the plugin step talks to.
#
# Usage:
#   cp .env.example .env      # then fill in your values
#   ./scripts/setup.sh
#   ./scripts/setup.sh --dry-run            # print every API call; change nothing
#
# Re-runs are no-ops: the script reads .env, only writes back keys that are blank,
# and skips Kanboard bootstrap when a "Deployments" project already exists.
#
# On failure the script stops immediately (set -e) and prints a loud banner
# naming the step, command, and exit code that failed. A full transcript is
# written to setup.log in the repo root (gitignored). Secret values are not
# echoed to stdout/log; dry-run output is redacted. After a run, verify the
# Harness resources with ./scripts/verify-setup.sh (or `make verify`).
#
# Profile: cd-k8s
#
set -euo pipefail

# --- Parse args ---
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
      exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# --- Locate repo root ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HARNESS_DIR="$REPO_ROOT/.harness"

BASE_URL="${HARNESS_BASE_URL:-https://app.harness.io}"

# --- Log file: tee everything to setup.log while still printing to console ---
# Secret values are never echoed to stdout (real API bodies go out via
# curl --data-binary; dry-run output is redacted), so the log is safe — but it
# is gitignored as defense-in-depth.
LOG_FILE="${SETUP_LOG:-$REPO_ROOT/setup.log}"
exec > >(tee "$LOG_FILE") 2>&1

# --- Output helpers ---
CURRENT_STEP="startup"
info()  { echo "  → $1"; }
ok()    { echo "  ✓ $1"; }
warn()  { echo "  ⚠ $1"; }
die()   { echo "  ✗ $1" >&2; exit 1; }
step()  { CURRENT_STEP="$1"; echo; echo "=== $1 ==="; }

# --- Loud failure banner ---
# set -e aborts on any unhandled non-zero command. Without this trap the exit
# is silent (no per-resource "failed" line) — which is exactly how a first run
# could stop after the delegate/Kanboard steps yet before the Harness REST
# resources with no visible error. The ERR trap names the failing step,
# command, and exit code, and points at the log. It is additive: the Kanboard
# port-forward EXIT trap installed later still runs.
on_err() {
  local ec=$?
  echo >&2
  echo "  ✗ FAILED during step: ${CURRENT_STEP}" >&2
  echo "    exit code : ${ec}" >&2
  echo "    command   : ${BASH_COMMAND}" >&2
  echo "    log       : ${LOG_FILE}" >&2
  echo "    Resources created before this point remain (setup.sh is re-runnable)." >&2
  echo "    Fix the cause and run ./scripts/setup.sh again, then ./scripts/verify-setup.sh." >&2
}
trap on_err ERR

# --- Load .env ---
[ -f "$REPO_ROOT/.env" ] || die ".env not found. Copy .env.example to .env and fill it in."
set -a
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"
set +a

# --- Validate required vars ---
REQUIRED=(HARNESS_ACCOUNT_ID HARNESS_API_KEY HARNESS_ORG HARNESS_PROJECT
          GITHUB_USERNAME GITHUB_PAT DELEGATE_SELECTOR DELEGATE_NAME
          KANBOARD_URL)
missing=()
for v in "${REQUIRED[@]}"; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
[ ${#missing[@]} -eq 0 ] || die "Missing required .env values: ${missing[*]}"
CREATE_PROJECT="${CREATE_PROJECT:-true}"

# Generate a Kanboard API token on first run if the learner hasn't supplied one.
# Injected into the Kanboard pod via Helm and consumed by the plugin step.
if [ -z "${KANBOARD_API_TOKEN:-}" ]; then
  KANBOARD_API_TOKEN=$(openssl rand -hex 16)
  export KANBOARD_API_TOKEN
  KANBOARD_API_TOKEN_GENERATED=true
else
  KANBOARD_API_TOKEN_GENERATED=false
fi

if [ "$DRY_RUN" = true ]; then
  echo "### DRY RUN — no API calls will be executed. ###"
fi

# --- Check dependencies ---
step "Checking dependencies"
for tool in curl envsubst jq yq kubectl helm openssl; do
  command -v "$tool" &>/dev/null && ok "$tool" || die "$tool not found — please install it"
done

# --- Redaction helper for dry-run output ---
redact() {
  sed -E \
    -e "s|${HARNESS_API_KEY}|<HARNESS_API_KEY>|g" \
    -e "s|${GITHUB_PAT}|<GITHUB_PAT>|g" \
    -e "s|${KANBOARD_API_TOKEN:-__none__}|<KANBOARD_API_TOKEN>|g"
}

# --- envsubst with restricted variable list ---
# CRITICAL: keep this list in sync with docs/placeholders.md. Every ${VAR}
# that appears in any .harness/ YAML must be listed here, or envsubst will
# leave it as a literal "${VAR}" in the rendered output and the upload will
# fail (or worse — silently succeed with broken refs).
ENVSUBST_VARS='${HARNESS_ACCOUNT_ID} ${HARNESS_ORG} ${HARNESS_PROJECT} ${DELEGATE_SELECTOR} ${GITHUB_USERNAME} ${GITHUB_REPO} ${KANBOARD_PROJECT_ID} ${KANBOARD_TASK_ID} ${KANBOARD_COL_DEV} ${KANBOARD_COL_QA} ${KANBOARD_COL_PROD}'

render() {
  local file="$1"
  envsubst "$ENVSUBST_VARS" < "$file"
}

# Convert a rendered .harness/connector-*.yaml to JSON for the connectors API.
render_connector_json() { render "$1" | yq -o=json; }

# Wrap a rendered entity YAML in the JSON envelope the v2 endpoints expect:
#   { yaml: "...", identifier: "...", orgIdentifier: "...", projectIdentifier: "..." }
# Usage: render_entity_json <file> <k=v>...
render_entity_json() {
  local file="$1"; shift
  local y; y="$(render "$file")"
  local args=(--arg yaml "$y")
  local filter='{yaml: $yaml'
  for kv in "$@"; do
    args+=(--arg "${kv%%=*}" "${kv#*=}")
    filter+=", ${kv%%=*}: \$${kv%%=*}"
  done
  filter+='}'
  jq -n "${args[@]}" "$filter"
}

# --- Harness API helpers --------------------------------------------------
# api_send <method> <url> <ctype> <data>  — body on stdout, HTTP code on last line.
# Honors DRY_RUN by redacting + printing the would-be call and emitting a fake 200.
api_send() {
  local method="$1" url="$2" ctype="$3" data="$4"
  if [ "$DRY_RUN" = true ]; then
    {
      echo "    curl -X $method '$url'"
      echo "      -H 'x-api-key: <REDACTED>' -H 'Content-Type: $ctype'"
      printf '%s\n' "$data" | redact | sed 's/^/        /'
    } >&2
    printf '\n200'
    return 0
  fi
  curl -sS -X "$method" "$url" \
    -H "x-api-key: $HARNESS_API_KEY" \
    -H "Content-Type: $ctype" \
    -w $'\n%{http_code}' \
    --data-binary "$data"
}

# upsert <label> <create-url> <update-url> <ctype> <data>
# Tries POST; if the server says "already exists" (409 or duplicate body), PUTs instead.
upsert() {
  local label="$1" create_url="$2" update_url="$3" ctype="$4" data="$5"
  local resp code body
  resp="$(api_send POST "$create_url" "$ctype" "$data")"
  code="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d')"
  if [[ "$code" =~ ^2 ]]; then
    ok "$label created"; return 0
  fi
  if [[ "$code" == "409" ]] || printf '%s' "$body" | grep -qi "already exists\|duplicate"; then
    resp="$(api_send PUT "$update_url" "$ctype" "$data")"
    code="$(printf '%s' "$resp" | tail -n1)"
    body="$(printf '%s' "$resp" | sed '$d')"
    if [[ "$code" =~ ^2 ]]; then
      ok "$label updated"; return 0
    fi
  fi
  warn "$label failed (HTTP $code): $(printf '%s' "$body" | head -c 300)"
  return 1
}

# Query-string fragments reused on every Harness API call.
ACCT="accountIdentifier=$HARNESS_ACCOUNT_ID"
ORG="orgIdentifier=$HARNESS_ORG"
PROJ="projectIdentifier=$HARNESS_PROJECT"

# --- .env writer (idempotent): only writes keys whose current value is blank ---
# Usage: env_write KEY VALUE
# Reads $REPO_ROOT/.env, sets KEY=VALUE iff the key exists with an empty value.
# Preserves comments and formatting. No-op (with a "→ KEY already set" note) if the
# key already has a value or doesn't appear in the file.
env_write() {
  local key="$1" value="$2"
  local file="$REPO_ROOT/.env"
  if [ "$DRY_RUN" = true ]; then
    info "[.env] $key=$value"
    return 0
  fi
  if ! grep -q "^${key}=" "$file"; then
    warn ".env has no '${key}=' line — skipping (add the key to .env.example first)"
    return 0
  fi
  if grep -q "^${key}=." "$file"; then
    info "$key already set in .env — leaving as-is"
    return 0
  fi
  # macOS sed needs -i ''; the .bak suffix is portable and we delete the backup.
  sed -i.bak "s|^${key}=$|${key}=${value}|" "$file"
  rm -f "${file}.bak"
  ok "$key written to .env"
}

# =====================================================================
# Provisioning — in dependency order:
#   cluster prep (namespaces, ghcr secret, delegate, kanboard) →
#   project → secrets → connectors → service → environments →
#   infrastructures → pipeline
# =====================================================================

step "Cluster: namespaces"
for ns in web-dev web-qa web-prod kanboard; do
  if [ "$DRY_RUN" = true ]; then
    info "kubectl create namespace $ns"
  else
    kubectl get ns "$ns" &>/dev/null || kubectl create namespace "$ns"
    ok "namespace $ns"
  fi
done

step "Cluster: ghcr-cred imagePullSecret"
for ns in web-dev web-qa web-prod; do
  if [ "$DRY_RUN" = true ]; then
    info "kubectl -n $ns create secret docker-registry ghcr-cred --docker-server=ghcr.io --docker-username=$GITHUB_USERNAME --docker-password=<GITHUB_PAT>"
  else
    kubectl -n "$ns" create secret docker-registry ghcr-cred \
      --docker-server=ghcr.io \
      --docker-username="$GITHUB_USERNAME" \
      --docker-password="$GITHUB_PAT" \
      --dry-run=client -o yaml | kubectl apply -f -
    ok "ghcr-cred in $ns"
  fi
done

step "Project"
# Must come before the Delegate step because delegate-token-ng is
# project-scoped: that GET 404s if the project doesn't yet exist.
if [ "$CREATE_PROJECT" = "true" ]; then
  proj_body=$(cat <<JSON
{"project":{"identifier":"$HARNESS_PROJECT","name":"$HARNESS_PROJECT","orgIdentifier":"$HARNESS_ORG","modules":["CD","CI"]}}
JSON
)
  upsert "Project $HARNESS_PROJECT" \
    "$BASE_URL/ng/api/projects?$ACCT&$ORG" \
    "$BASE_URL/ng/api/projects/$HARNESS_PROJECT?$ACCT&$ORG" \
    "application/json" "$proj_body" || true
else
  info "CREATE_PROJECT=false — using existing $HARNESS_ORG/$HARNESS_PROJECT"
fi

step "Delegate (Helm)"
# A delegate must exist and be tagged $DELEGATE_SELECTOR before the K8s
# connector can resolve. We fetch the project-scoped default delegate token
# via API and run helm upgrade --install into the fixed release name
# `harness-delegate`. Because that release name is static, helm upgrades the
# same release in place on a re-run — it never creates a second delegate.
#
# The previous guard short-circuited on a pod already in status.phase=Running.
# That was fragile: on a first run the delegate has no time to reach Running
# before the script moves on, so a re-run saw "not running", skipped nothing,
# and rolled a *duplicate* delegate registration. We now let the idempotent
# helm upgrade --install always run (in dry-run we just print what it would do).
if [ "$DRY_RUN" = true ]; then
  info "GET $BASE_URL/ng/api/delegate-token-ng?$ACCT&$ORG&$PROJ&name=default_token"
  info "helm upgrade --install harness-delegate harness-delegate/harness-delegate-ng \\"
  info "    --namespace harness-delegate --create-namespace --force-conflicts \\"
  info "    --set delegateName=$DELEGATE_NAME --set accountId=$HARNESS_ACCOUNT_ID \\"
  info "    --set delegateToken=<REDACTED> --set managerEndpoint=$BASE_URL \\"
  info "    --set tags=$DELEGATE_SELECTOR"
else
  if helm status harness-delegate -n harness-delegate >/dev/null 2>&1; then
    info "delegate helm release 'harness-delegate' present — upgrading in place (no duplicate)"
  fi
  info "fetching default delegate token"
  # Race: Harness creates default_token asynchronously after the project is
  # provisioned. On a first run we may hit the endpoint before that side-effect
  # lands, getting back resource:[] or RESOURCE_NOT_FOUND. Retry with backoff.
  DELEGATE_TOKEN=""
  for attempt in 1 2 3 4 5 6 7 8; do
    tok_resp="$(curl -sS "$BASE_URL/ng/api/delegate-token-ng?$ACCT&$ORG&$PROJ&name=default_token" \
      -H "x-api-key: $HARNESS_API_KEY")"
    DELEGATE_TOKEN="$(printf '%s' "$tok_resp" | jq -r '.resource[0].value // empty' 2>/dev/null || true)"
    [ -n "$DELEGATE_TOKEN" ] && break
    info "  default_token not yet readable (attempt $attempt/8) — waiting 3s"
    sleep 3
  done
  if [ -z "$DELEGATE_TOKEN" ]; then
    warn "Could not read default delegate token after 8 attempts. Ensure your API key has delegate-edit permission, or install the delegate manually via the Harness UI. Continuing — the K8s connector will be unhealthy until a delegate registers."
    # Skip the helm install but keep the script going so the rest of the
    # resources still get provisioned; the learner can install the delegate
    # manually and re-run setup.sh.
    DELEGATE_TOKEN=""
  fi

  if [ -n "$DELEGATE_TOKEN" ]; then
    helm repo add harness-delegate https://app.harness.io/storage/harness-download/delegate-helm-chart/ >/dev/null 2>&1 || true
    helm repo update harness-delegate >/dev/null 2>&1 || true
    # The Harness delegate-upgrader sidecar takes ownership of the container
    # image field once the delegate self-updates, so subsequent helm upgrades
    # report a field-manager conflict. --force-conflicts handles that on
    # Helm 4 (server-side apply by default) and on Helm 3.13+.
    if ! helm upgrade --install harness-delegate harness-delegate/harness-delegate-ng \
        --namespace harness-delegate --create-namespace --force-conflicts \
        --set delegateName="$DELEGATE_NAME" \
        --set accountId="$HARNESS_ACCOUNT_ID" \
        --set delegateToken="$DELEGATE_TOKEN" \
        --set managerEndpoint="$BASE_URL" \
        --set "tags=$DELEGATE_SELECTOR" >/dev/null 2>&1; then
      warn "helm upgrade failed — if a delegate is already running, this is usually safe to ignore. Check 'helm list -n harness-delegate' and 'kubectl get pods -n harness-delegate'."
    else
      ok "delegate installed (tag: $DELEGATE_SELECTOR) — it may take a minute to register"
    fi
  fi
fi

step "Kanboard (Helm chart)"
# kube-the-home/kanboard-helm — actively maintained, SQLite by default.
# API_AUTHENTICATION_TOKEN is injected via application.env[] so the plugin step
# can authenticate as the reserved `jsonrpc` user without a UI-generated token.
if [ "$DRY_RUN" = true ]; then
  info "helm repo add kanboard https://kube-the-home.github.io/kanboard-helm/"
  info "helm upgrade -i kanboard kanboard/kanboard -n kanboard --create-namespace \\"
  info "    --set service.{enabled=true,type=ClusterIP,port=8080} \\"
  info "    --set-string application.env[0].name=API_AUTHENTICATION_TOKEN \\"
  info "    --set-string application.env[0].value=<KANBOARD_API_TOKEN>"
else
  helm repo add kanboard https://kube-the-home.github.io/kanboard-helm/ 2>/dev/null || true
  helm repo update kanboard >/dev/null
  helm upgrade -i kanboard kanboard/kanboard \
    --namespace kanboard --create-namespace \
    --set service.enabled=true \
    --set service.type=ClusterIP \
    --set service.port=8080 \
    --set-string "application.env[0].name=API_AUTHENTICATION_TOKEN" \
    --set-string "application.env[0].value=${KANBOARD_API_TOKEN}" >/dev/null
  ok "Kanboard chart applied in namespace 'kanboard'"
  info "Waiting for Kanboard rollout…"
  # Drop the >/dev/null so pull/scheduling progress is visible in console + log.
  # On a fresh cluster the image pull can be slow — allow 180s and, on timeout,
  # dump pod state and fail loudly instead of letting set -e abort bare (which
  # would silently skip every Harness REST resource that follows).
  if ! kubectl -n kanboard rollout status deploy/kanboard --timeout=180s; then
    kubectl -n kanboard get pods >&2 || true
    die "Kanboard did not become ready in time. Check image pull / node capacity above, then re-run setup.sh."
  fi
  ok "Kanboard pod ready"
fi

step "Kanboard bootstrap (project / columns / task)"
# Idempotent JSON-RPC bootstrap. Uses admin:admin basic auth over a transient
# port-forward (admin password defaults to 'admin' on a fresh install — never
# leaves localhost). The plugin step at run-time uses the env-injected
# API_AUTHENTICATION_TOKEN as the `jsonrpc` reserved user; it never sees admin.
KB_PROJECT_NAME="Deployments"
KB_TASK_TITLE="Deploy custom-plugins-demo"
KB_COL_NAMES=(Backlog Dev QA Prod)

if [ "$DRY_RUN" = true ]; then
  info "kubectl -n kanboard port-forward svc/kanboard 18090:8080 (background)"
  info "POST createProject {name: '$KB_PROJECT_NAME'} → KANBOARD_PROJECT_ID"
  info "POST getColumns → 4 column ids"
  info "POST updateColumn x4 → rename to ${KB_COL_NAMES[*]}"
  info "POST createTask {title: '$KB_TASK_TITLE'} → KANBOARD_TASK_ID"
  info "Write KANBOARD_PROJECT_ID, KANBOARD_TASK_ID, KANBOARD_COL_* to .env"
else
  # Background port-forward to localhost so we can hit JSON-RPC from the script.
  # The plugin step itself uses the in-cluster KANBOARD_URL — this forward is
  # bootstrap-only and torn down on exit.
  kubectl -n kanboard port-forward svc/kanboard 18090:8080 >/tmp/_kb_pf.log 2>&1 &
  KB_PF_PID=$!
  trap 'kill ${KB_PF_PID} 2>/dev/null; wait ${KB_PF_PID} 2>/dev/null; true' EXIT
  # Wait for the forward to accept connections.
  for _ in {1..20}; do
    curl -sS -o /dev/null -w '' http://127.0.0.1:18090/ 2>/dev/null && break
    sleep 0.5
  done

  KB_RPC=http://127.0.0.1:18090/jsonrpc.php
  kb_rpc() {
    # Usage: kb_rpc METHOD '{"k":"v"}'  →  prints the JSON-RPC `result` (raw via jq)
    local method="$1" params="$2"
    curl -sS -u "admin:admin" -H 'Content-Type: application/json' "$KB_RPC" \
      -d "$(jq -nc --arg m "$method" --argjson p "$params" \
            '{jsonrpc:"2.0",id:1,method:$m,params:$p}')" \
      | jq -r '.result'
  }

  # Step 1: ensure the project exists. getProjectByName returns `false` if
  # absent and an object {id, name, ...} when present.
  # NB: don't reuse the names PROJ / PROJ_ID — those are the Harness URL
  # fragments defined above (projectIdentifier=...). Bash variables are global.
  KB_PROJ=$(kb_rpc getProjectByName "{\"name\":\"$KB_PROJECT_NAME\"}")
  if [ "$KB_PROJ" = "false" ] || [ "$KB_PROJ" = "null" ] || [ -z "$KB_PROJ" ]; then
    KB_PROJ_ID=$(kb_rpc createProject "{\"name\":\"$KB_PROJECT_NAME\"}")
    ok "Project '$KB_PROJECT_NAME' created (id=$KB_PROJ_ID)"
  else
    KB_PROJ_ID=$(jq -r '.id' <<<"$KB_PROJ")
    info "Project '$KB_PROJECT_NAME' exists (id=$KB_PROJ_ID)"
  fi

  # Step 2: rename the 4 default columns by position.
  COLS=$(kb_rpc getColumns "{\"project_id\":$KB_PROJ_ID}")
  for i in 0 1 2 3; do
    COL_ID=$(jq -r ".[$i].id" <<<"$COLS")
    CUR_TITLE=$(jq -r ".[$i].title" <<<"$COLS")
    DESIRED="${KB_COL_NAMES[$i]}"
    if [ "$CUR_TITLE" = "$DESIRED" ]; then
      info "column $((i+1)) already '$DESIRED' (id=$COL_ID)"
    else
      kb_rpc updateColumn "{\"column_id\":$COL_ID,\"title\":\"$DESIRED\"}" >/dev/null
      ok "column $((i+1)) renamed '$CUR_TITLE' → '$DESIRED' (id=$COL_ID)"
    fi
    eval "COL_${DESIRED}_ID=$COL_ID"
  done

  # Step 3: ensure the demo task exists in the Backlog column.
  TASKS=$(kb_rpc getAllTasks "{\"project_id\":$KB_PROJ_ID,\"status_id\":1}")
  # jq's `first(...)` avoids the head -1 / SIGPIPE-under-pipefail trap.
  TASK_ID=$(jq -r --arg t "$KB_TASK_TITLE" 'first(.[] | select(.title==$t) | .id) // empty' <<<"$TASKS")
  if [ -z "$TASK_ID" ] || [ "$TASK_ID" = "null" ]; then
    TASK_ID=$(kb_rpc createTask \
      "{\"project_id\":$KB_PROJ_ID,\"title\":\"$KB_TASK_TITLE\",\"column_id\":${COL_Backlog_ID},\"owner_id\":1,\"date_started\":\"$(date '+%Y-%m-%d %H:%M')\"}")
    ok "task '$KB_TASK_TITLE' created (id=$TASK_ID)"
  else
    info "task '$KB_TASK_TITLE' exists (id=$TASK_ID)"
  fi

  # Step 4: write captured IDs back into .env (only blank keys are filled).
  # Backlog column id is not persisted — the plugin only ever moves the task
  # to Dev/QA/Prod, and "reset the demo" means dragging the card back manually.
  env_write KANBOARD_PROJECT_ID "$KB_PROJ_ID"
  env_write KANBOARD_TASK_ID    "$TASK_ID"
  env_write KANBOARD_COL_DEV     "$COL_Dev_ID"
  env_write KANBOARD_COL_QA      "$COL_QA_ID"
  env_write KANBOARD_COL_PROD    "$COL_Prod_ID"

  # If we generated the token on this run, persist it too.
  if [ "$KANBOARD_API_TOKEN_GENERATED" = true ]; then
    env_write KANBOARD_API_TOKEN "$KANBOARD_API_TOKEN"
    info "Generated KANBOARD_API_TOKEN written to .env"
  fi

  # Tear down the bootstrap port-forward; the plugin step uses the in-cluster URL.
  kill ${KB_PF_PID} 2>/dev/null; wait ${KB_PF_PID} 2>/dev/null; true
  trap - EXIT
fi

step "Secrets"
# Three text secrets the connectors / plugin step reference. Bodies are built
# inline (not from a .harness/ template) because the secret value itself must
# be embedded in the JSON — keeping that off disk avoids accidental commits.
for s in \
  "ghcr_token=$GITHUB_PAT" \
  "kanboard_url=$KANBOARD_URL" \
  "kanboard_api_token=$KANBOARD_API_TOKEN"; do
  sid="${s%%=*}"; sval="${s#*=}"
  secret_body=$(jq -nc --arg id "$sid" --arg org "$HARNESS_ORG" --arg proj "$HARNESS_PROJECT" --arg val "$sval" \
    '{secret:{type:"SecretText",name:$id,identifier:$id,orgIdentifier:$org,projectIdentifier:$proj,
              spec:{secretManagerIdentifier:"harnessSecretManager",valueType:"Inline",value:$val,type:"SecretText"}}}')
  upsert "Secret $sid" \
    "$BASE_URL/ng/api/v2/secrets?$ACCT&$ORG&$PROJ" \
    "$BASE_URL/ng/api/v2/secrets/$sid?$ACCT&$ORG&$PROJ" \
    "application/json" "$secret_body"
done

step "Connectors"
for c in connector-github connector-ghcr connector-k8s; do
  upsert "Connector $c" \
    "$BASE_URL/ng/api/connectors?$ACCT" \
    "$BASE_URL/ng/api/connectors?$ACCT" \
    "application/json" \
    "$(render_connector_json "$HARNESS_DIR/$c.yaml")"
done

step "Service"
upsert "Service custom-plugins-demo" \
  "$BASE_URL/ng/api/servicesV2?$ACCT" \
  "$BASE_URL/ng/api/servicesV2?$ACCT" \
  "application/json" \
  "$(render_entity_json "$HARNESS_DIR/service.yaml" \
      identifier=custom_plugins_demo name=custom-plugins-demo \
      orgIdentifier="$HARNESS_ORG" projectIdentifier="$HARNESS_PROJECT")"

step "Environments"
# <yaml-file>:<identifier>:<display-name>:<type(PreProduction|Production)>
for envspec in environment-dev.yaml:Dev:Dev:PreProduction \
               environment-qa.yaml:QA:QA:PreProduction \
               environment-prod.yaml:Prod:Prod:Production; do
  IFS=: read -r file ident name etype <<<"$envspec"
  upsert "Environment $ident" \
    "$BASE_URL/ng/api/environmentsV2?$ACCT" \
    "$BASE_URL/ng/api/environmentsV2?$ACCT" \
    "application/json" \
    "$(render_entity_json "$HARNESS_DIR/$file" \
        identifier="$ident" name="$name" type="$etype" \
        orgIdentifier="$HARNESS_ORG" projectIdentifier="$HARNESS_PROJECT")"
done

step "Infrastructures"
# <yaml-file>:<identifier>:<display-name>:<environmentIdentifier>
for infspec in infra-dev.yaml:Dev_Infra:Dev_Infra:Dev \
               infra-qa.yaml:QA_Infra:QA_Infra:QA \
               infra-prod.yaml:Prod_Infra:Prod_Infra:Prod; do
  IFS=: read -r file ident name envid <<<"$infspec"
  upsert "Infrastructure $ident" \
    "$BASE_URL/ng/api/infrastructures?$ACCT" \
    "$BASE_URL/ng/api/infrastructures?$ACCT" \
    "application/json" \
    "$(render_entity_json "$HARNESS_DIR/$file" \
        identifier="$ident" name="$name" type=KubernetesDirect \
        orgIdentifier="$HARNESS_ORG" projectIdentifier="$HARNESS_PROJECT" \
        environmentIdentifier="$envid")"
done

step "Pipelines"
# Pipelines use a different endpoint shape than services/envs/infras — raw
# YAML body (no JSON envelope), Content-Type: application/yaml. Update path
# also differs: PUT /pipeline/api/pipelines/<identifier>.
BUILD_PLUGIN_YAML="$(render "$HARNESS_DIR/build-plugin-pipeline.yaml")"
upsert "Pipeline build_kanboard_plugin" \
  "$BASE_URL/pipeline/api/pipelines/v2?$ACCT&$ORG&$PROJ" \
  "$BASE_URL/pipeline/api/pipelines/build_kanboard_plugin?$ACCT&$ORG&$PROJ" \
  "application/yaml" "$BUILD_PLUGIN_YAML"

PIPELINE_YAML="$(render "$HARNESS_DIR/pipeline.yaml")"
upsert "Pipeline build_and_deploy_demo_app" \
  "$BASE_URL/pipeline/api/pipelines/v2?$ACCT&$ORG&$PROJ" \
  "$BASE_URL/pipeline/api/pipelines/build_and_deploy_demo_app?$ACCT&$ORG&$PROJ" \
  "application/yaml" "$PIPELINE_YAML"

echo
ok "Setup complete."
