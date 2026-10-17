#!/usr/bin/env bash
# Confirms every region the StackSet runs in has exactly one instance, in
# service, on VERSION, then probes both Elastic IPs of every region over UDP
# from outside AWS. The instance only signals CloudFormation once its own
# health check passes, so a finished StackSet operation already implies the
# server is up; this also proves the old instance is gone, the new one carries
# the new version, and the real UDP path answers.
#
# Env: VERSION (required), STACK_SET_NAME, STACK_SET_REGION, TIMEOUT_SECONDS,
#      PROBE_SECONDS (how long to keep retrying each UDP probe)
set -euo pipefail

VERSION=${VERSION:?}
STACK_SET_NAME=${STACK_SET_NAME:-stunserver}
STACK_SET_REGION=${STACK_SET_REGION:-us-east-1}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-600}
PROBE_SECONDS=${PROBE_SECONDS:-120}
HERE=$(cd "$(dirname "$0")" && pwd)

regions=$(aws cloudformation list-stack-instances --region "$STACK_SET_REGION" \
  --stack-set-name "$STACK_SET_NAME" --query 'Summaries[].Region' --output text | tr '\t' '\n' | sort -u)
[ -n "$regions" ] || { echo "::error::The StackSet has no instances"; exit 1; }

# Prints the reason and returns 1 while a region is not yet on VERSION.
check_region() {
  local region=$1 instances count id state served
  instances=$(aws autoscaling describe-auto-scaling-groups --region "$region" \
    --auto-scaling-group-names "stunserver-asg-${region}" \
    --query 'AutoScalingGroups[0].Instances[].[InstanceId,LifecycleState]' --output text)
  count=$(echo "$instances" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$count" != 1 ]; then
    echo "$region: $count instances, waiting for exactly 1"
    return 1
  fi
  id=$(echo "$instances" | cut -f1)
  state=$(echo "$instances" | cut -f2)
  if [ "$state" != InService ]; then
    echo "$region: $id is $state, waiting for InService"
    return 1
  fi
  served=$(aws ec2 describe-instances --region "$region" --instance-ids "$id" \
    --query "Reservations[0].Instances[0].Tags[?Key=='Version'].Value | [0]" --output text)
  if [ "$served" != "$VERSION" ]; then
    echo "$region: $id is on '$served', waiting for $VERSION"
    return 1
  fi
  echo "$region: $id InService on $VERSION"
}

pending=$regions
deadline=$(($(date +%s) + TIMEOUT_SECONDS))
while :; do
  still=""
  for region in $pending; do
    check_region "$region" || still="$still $region"
  done
  pending=${still# }
  [ -z "$pending" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::Not on ${VERSION} within ${TIMEOUT_SECONDS}s in: ${pending}"
    exit 1
  fi
  sleep 15
done
echo "Every region is running ${VERSION}."

# The instance is up on the new version; now ask it a real question from
# outside, on both addresses and both ports, over UDP.
failed=""
for region in $regions; do
  ip1=$(aws ec2 describe-addresses --region "$region" \
    --filters "Name=tag:Name,Values=stunserver-eip1-${region}" --query 'Addresses[0].PublicIp' --output text)
  ip2=$(aws ec2 describe-addresses --region "$region" \
    --filters "Name=tag:Name,Values=stunserver-eip2-${region}" --query 'Addresses[0].PublicIp' --output text)
  if [ -z "$ip1" ] || [ "$ip1" = None ] || [ -z "$ip2" ] || [ "$ip2" = None ]; then
    echo "::error::$region: could not find both Elastic IPs"
    failed="$failed $region"
    continue
  fi
  echo "$region:"
  python3 -I "$HERE/probe-stun.py" --wait "$PROBE_SECONDS" "eip1=$ip1" "eip2=$ip2" || failed="$failed $region"
done
if [ -n "$failed" ]; then
  echo "::error::UDP probe failed in:${failed}"
  exit 1
fi
echo "Every region answers STUN on both addresses and both ports."
