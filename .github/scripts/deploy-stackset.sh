#!/usr/bin/env bash
# Rolls VERSION out to the service StackSet and, when RECONCILE=true, first
# makes its regions match infra/regions.json. Waits for every operation to
# finish, so it returns only when every region has finished (or one failed).
#
# Order: delete removed regions, update the StackSet (every existing region,
# one at a time, quietest first, stopping at the first failure), then create
# added regions. New instances are created after the update so they pick up the
# StackSet's current parameters. Per-instance parameter overrides are never
# used, because they silently stop later StackSet updates from reaching that
# instance; the script refuses to run while any exist.
#
# Env:
#   VERSION          release to deploy, e.g. 1.2.20 (required)
#   TEMPLATE         service.yaml to apply (required)
#   REGIONS_FILE     JSON array of regions (required when RECONCILE=true)
#   RECONCILE        true: add/remove regions to match REGIONS_FILE.
#                    false (default): update the existing instances only.
#   REMOVED_REGIONS  space-separated regions this release removed from
#                    REGIONS_FILE (visible in the approval summary). Only
#                    these may be deleted; any other mismatch is an error.
#   STACK_SET_NAME   default stunserver
#   STACK_SET_REGION default us-east-1
#   TRAFFIC_DAYS     window for ranking regions by inbound traffic, default 7
#   DRY_RUN          true: no StackSet operation is started, print what would run
set -euo pipefail

VERSION=${VERSION:?}
TEMPLATE=${TEMPLATE:?}
RECONCILE=${RECONCILE:-false}
REMOVED_REGIONS=${REMOVED_REGIONS:-}
STACK_SET_NAME=${STACK_SET_NAME:-stunserver}
STACK_SET_REGION=${STACK_SET_REGION:-us-east-1}
TRAFFIC_DAYS=${TRAFFIC_DAYS:-7}
DRY_RUN=${DRY_RUN:-false}
SECRET=artifactory/stunserver
VERSION_PARAM=StunServerVersion
# One region at a time; the first failure stops the rollout, so a bad build
# reaches at most one region.
SEQUENTIAL_PREFS='{"RegionConcurrencyType":"SEQUENTIAL","FailureToleranceCount":0}'

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::VERSION '$VERSION' is not like 1.2.3"; exit 1; }

export AWS_DEFAULT_REGION=$STACK_SET_REGION
cf() { aws cloudformation "$@"; }
words() { tr '\t ' '\n\n' | sed '/^$/d' | sort -u; }

fail=0
error() { echo "::error::$*"; fail=1; }

account=$(aws sts get-caller-identity --query Account --output text)
live=$(cf list-stack-instances --stack-set-name "$STACK_SET_NAME" --query 'Summaries[].Region' --output text | words)
[ -n "$live" ] || { echo "::error::The StackSet $STACK_SET_NAME has no stack instances"; exit 1; }

# Per-instance overrides win over the StackSet's own value, so an updated
# parameter would silently not reach that instance. Refuse to start.
for r in $live; do
  overrides=$(cf describe-stack-instance --stack-set-name "$STACK_SET_NAME" \
    --stack-instance-account "$account" --stack-instance-region "$r" \
    --query 'length(StackInstance.ParameterOverrides)' --output text)
  [ "$overrides" = 0 ] || error "$r has $overrides per-instance parameter override(s). Clear them (update-stack-instances with an empty override list) before deploying."
done
[ "$fail" = 0 ] || exit 1

to_add=""
to_remove=""
if [ "$RECONCILE" = true ]; then
  : "${REGIONS_FILE:?REGIONS_FILE is required when RECONCILE=true}"
  desired=$(jq -r '.[]' "$REGIONS_FILE" | words)
  [ -n "$desired" ] || { error "$REGIONS_FILE lists no regions"; exit 1; }
  for r in $desired; do
    [[ $r =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || error "'$r' in $REGIONS_FILE is not a region name"
  done
  to_add=$(comm -13 <(echo "$live") <(echo "$desired") | sed '/^$/d')
  to_remove=$(comm -23 <(echo "$live") <(echo "$desired") | sed '/^$/d')

  for r in $to_remove; do
    if ! grep -qxF "$r" <(echo "$REMOVED_REGIONS" | words); then
      error "The StackSet has an instance in $r that $REGIONS_FILE does not list, and this release did not remove it. Add $r back to $REGIONS_FILE, or remove it deliberately in a release."
    fi
  done

  # A new region's instances read the secret by name, so it must already be
  # replicated there.
  for r in $to_add; do
    status=$(aws secretsmanager describe-secret --secret-id "$SECRET" \
      --query "ReplicationStatus[?Region=='$r'].Status | [0]" --output text)
    [ "$status" = InSync ] || error "Cannot add $r: $SECRET is not replicated there (status: $status). Add $r to ReplicaRegions in infra/bootstrap.yaml and deploy that stack by hand first."
  done
fi
[ "$fail" = 0 ] || exit 1

add_text=${to_add//$'\n'/ }
remove_text=${to_remove//$'\n'/ }
{
  echo "## StackSet plan"
  echo
  echo "- Version: **${VERSION}**"
  echo "- Existing regions: ${live//$'\n'/ }"
  if [ "$RECONCILE" = true ]; then
    echo "- Adding: ${add_text:-none}"
    echo "- Removing: ${remove_text:-none}"
  else
    echo "- Regions are not reconciled: only the existing instances are updated."
  fi
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

# Quietest region first, so a bad build is caught where it hurts least. Ranked
# by the ASG's inbound packet count over TRAFFIC_DAYS. Only the resulting order
# is printed, never the counts: this log is public. If any region's metric
# cannot be read, falls back to the regions.json order rather than guessing.
fallback_order() {
  local r
  if [ -n "${REGIONS_FILE:-}" ] && [ -r "$REGIONS_FILE" ]; then
    for r in $(jq -r '.[]' "$REGIONS_FILE"); do
      grep -qxF "$r" <<<"$remaining" && echo "$r"
    done
  fi
  # Anything live that the file does not list, in a stable order.
  for r in $remaining; do
    if [ -z "${REGIONS_FILE:-}" ] || ! [ -r "$REGIONS_FILE" ] || ! jq -e --arg r "$r" 'index($r)' "$REGIONS_FILE" >/dev/null; then
      echo "$r"
    fi
  done
}

rank_regions() {
  local start end r total ranked="" ok=true
  end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  start=$(date -u -d "${TRAFFIC_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -v-"${TRAFFIC_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)
  for r in $remaining; do
    if total=$(aws cloudwatch get-metric-statistics --region "$r" --namespace AWS/EC2 \
      --metric-name NetworkPacketsIn \
      --dimensions "Name=AutoScalingGroupName,Value=stunserver-asg-${r}" \
      --start-time "$start" --end-time "$end" --period 86400 --statistics Sum \
      --query 'sum(Datapoints[].Sum)' --output text 2>/dev/null); then
      case $total in '' | None | null) total=0 ;; esac
      ranked="${ranked}${total%.*} ${r}"$'\n'
    else
      ok=false
    fi
  done
  if [ "$ok" = true ]; then
    printf '%s' "$ranked" | sort -k1,1n -k2,2 | awk '{print $2}'
  else
    echo "::warning::Could not read traffic for every region; using a fixed order (regions.json first) instead of quietest first." >&2
    fallback_order
  fi
}

wait_for() {
  local op=$1 status last=""
  while :; do
    status=$(cf describe-stack-set-operation --stack-set-name "$STACK_SET_NAME" \
      --operation-id "$op" --query StackSetOperation.Status --output text)
    if [ "$status" != "$last" ]; then
      echo "operation $op: $status"
      last=$status
    fi
    case $status in
      SUCCEEDED) return 0 ;;
      RUNNING | QUEUED | STOPPING) sleep 15 ;;
      *)
        cf list-stack-set-operation-results --stack-set-name "$STACK_SET_NAME" \
          --operation-id "$op" --query 'Summaries[].[Region,Status,StatusReason]' --output table || true
        error "StackSet operation $op ended $status"
        return 1
        ;;
    esac
  done
}

# run_op <description> <aws cloudformation subcommand and arguments...>
run_op() {
  local what=$1 op
  shift
  if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN ($what): aws cloudformation $*"
    return 0
  fi
  echo "$what"
  op=$(cf "$@" --query OperationId --output text)
  wait_for "$op"
}

if [ -n "$to_remove" ]; then
  # shellcheck disable=SC2086
  run_op "Removing regions: $(echo $to_remove)" delete-stack-instances \
    --stack-set-name "$STACK_SET_NAME" --accounts "$account" --regions $to_remove \
    --no-retain-stacks --operation-preferences "$SEQUENTIAL_PREFS"
fi

# Every parameter the new template still has keeps its current StackSet value,
# except the version; one the StackSet has never had takes the template's
# default. Passing a parameter the template lacks would fail the update, which
# matters when this applies an older release's template.
current_keys=$(cf describe-stack-set --stack-set-name "$STACK_SET_NAME" \
  --query 'StackSet.Parameters[].ParameterKey' --output text | words)
summary=$(cf get-template-summary --template-body "file://$TEMPLATE" --output json)
template_keys=$(jq -r '.Parameters[].ParameterKey' <<<"$summary" | sort -u)
grep -qxF "$VERSION_PARAM" <<<"$template_keys" || { error "$TEMPLATE has no $VERSION_PARAM parameter"; exit 1; }
params=()
for key in $template_keys; do
  if [ "$key" = "$VERSION_PARAM" ]; then
    params+=("ParameterKey=$key,ParameterValue=$VERSION")
  elif grep -qxF "$key" <<<"$current_keys"; then
    params+=("ParameterKey=$key,UsePreviousValue=true")
  elif [ -z "$(jq -r --arg k "$key" '.Parameters[] | select(.ParameterKey == $k) | .DefaultValue // empty' <<<"$summary")" ]; then
    error "$TEMPLATE has parameter $key, which the StackSet has no value for and the template gives no default. Set it once with a manual update-stack-set."
  fi
done
[ "$fail" = 0 ] || exit 1

# Regions still in the StackSet after any removal above.
remaining=$(comm -23 <(echo "$live") <(echo "$to_remove" | words | sed '/^$/d') | sed '/^$/d')
order=$(rank_regions | tr '\n' ' ')
order=${order% }
echo "Rollout order: ${order}"
update_prefs=$(jq -cn --arg order "$order" \
  '{RegionConcurrencyType: "SEQUENTIAL", FailureToleranceCount: 0, RegionOrder: ($order | split(" "))}')

run_op "Updating the StackSet to ${VERSION}" update-stack-set \
  --stack-set-name "$STACK_SET_NAME" --template-body "file://$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM --parameters "${params[@]}" \
  --operation-preferences "$update_prefs"

if [ -n "$to_add" ]; then
  # shellcheck disable=SC2086
  run_op "Adding regions: $(echo $to_add)" create-stack-instances \
    --stack-set-name "$STACK_SET_NAME" --accounts "$account" --regions $to_add \
    --operation-preferences "$SEQUENTIAL_PREFS"
fi

[ "$fail" = 0 ]
