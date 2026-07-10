#!/usr/bin/env bash
#
# verify-setup.sh — Post-run verification of the Harness resources setup.sh creates.
#
# Where validate-setup.sh is a *pre-flight* check (tools, .env, cluster), this
# script confirms that setup.sh actually *created* each Harness resource by
# issuing read-only GETs against the Harness NG API. Run it after setup.sh (or
# `make verify`) to catch a run that stopped partway — e.g. one that provisioned
# the project + delegate but silently skipped the pipeline/env/service/infra.
#
# Exits non-zero if any required resource is missing.
#
# Profile: cd-k8s
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BASE_URL="${HARNESS_BASE_URL:-https://app.harness.io}"

PASS=0
WARN=0
FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
warn() { echo "  ⚠ $1"; WARN=$((WARN+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
step() { echo; echo "=== $1 ==="; }

# --- Load .env ---
if [ ! -f "$REPO_ROOT/.env" ]; then
  echo "  ✗ .env not found — copy .env.example to .env and fill it in." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"
set +a

for v in HARNESS_ACCOUNT_ID HARNESS_API_KEY HARNESS_ORG HARNESS_PROJECT; do
  [ -n "${!v:-}" ] || { echo "  ✗ $v not set in .env" >&2; exit 1; }
done

# Query-string fragments reused on every Harness API call (same as setup.sh).
ACCT="accountIdentifier=$HARNESS_ACCOUNT_ID"
ORG="orgIdentifier=$HARNESS_ORG"
PROJ="projectIdentifier=$HARNESS_PROJECT"

# check <label> <url> [extra-header]  — PASS if the GET returns 2xx, else FAIL.
# Harness returns 400 with code RESOURCE_NOT_FOUND_EXCEPTION (not a clean 404)
# for missing entities, so we read the body's `code` to distinguish a genuine
# "not found" from an auth/malformed error and surface it in the message.
check() {
  local label="$1" url="$2" extra="${3:-}" resp code body reason
  local -a hdr=(-H "x-api-key: $HARNESS_API_KEY")
  [ -n "$extra" ] && hdr+=(-H "$extra")
  resp="$(curl -sS -w $'\n%{http_code}' "$url" "${hdr[@]}" 2>/dev/null || printf '\n000')"
  code="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d')"
  if [[ "$code" =~ ^2 ]]; then
    ok "$label ($code)"
    return
  fi
  reason="$(printf '%s' "$body" | jq -r '.code // empty' 2>/dev/null || true)"
  case "$reason" in
    *NOT_FOUND*) fail "$label missing (HTTP $code, $reason)" ;;
    "")          fail "$label unreachable (HTTP $code)" ;;
    *)           fail "$label error (HTTP $code, $reason)" ;;
  esac
}

step "Project"
check "Project $HARNESS_PROJECT" \
  "$BASE_URL/ng/api/projects/$HARNESS_PROJECT?$ACCT&$ORG"

step "Secrets"
for s in ghcr_token kanboard_url kanboard_api_token; do
  check "Secret $s" "$BASE_URL/ng/api/v2/secrets/$s?$ACCT&$ORG&$PROJ"
done

step "Connectors"
for c in github ghcrconn pipelinedemocluster; do
  check "Connector $c" "$BASE_URL/ng/api/connectors/$c?$ACCT&$ORG&$PROJ"
done

step "Service"
check "Service custom_plugins_demo" \
  "$BASE_URL/ng/api/servicesV2/custom_plugins_demo?$ACCT&$ORG&$PROJ"

step "Environments"
for e in Dev QA Prod; do
  check "Environment $e" "$BASE_URL/ng/api/environmentsV2/$e?$ACCT&$ORG&$PROJ"
done

step "Infrastructures"
# Infra GET is scoped by its environment — pass environmentIdentifier.
for spec in Dev_Infra:Dev QA_Infra:QA Prod_Infra:Prod; do
  ident="${spec%%:*}"; envid="${spec#*:}"
  check "Infrastructure $ident" \
    "$BASE_URL/ng/api/infrastructures/$ident?$ACCT&$ORG&$PROJ&environmentIdentifier=$envid"
done

step "Pipelines"
# The pipeline GET can serve a cached copy; ask for the live entity.
for p in build_kanboard_plugin build_and_deploy_demo_app; do
  check "Pipeline $p" \
    "$BASE_URL/pipeline/api/pipelines/$p?$ACCT&$ORG&$PROJ" \
    "Load-From-Cache: false"
done

echo
echo "Pass: $PASS  Warn: $WARN  Fail: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo
  echo "  ✗ Some resources are missing. Re-run ./scripts/setup.sh (check setup.log for the"
  echo "    step that failed), then run this again."
  exit 1
fi
echo "  ✓ All Harness resources present."
