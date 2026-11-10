#!/bin/sh
set -e

CONFIG_SOURCE="${CONFIG_SOURCE:-s3://ecs-daemon-configs/config.yaml}"
CONFIG_DEST="${CONFIG_DEST:-/config/config.yaml}"
METADATA_TIMEOUT="${METADATA_TIMEOUT:-3}"
ECS_AGENT_ENDPOINT="${ECS_AGENT_ENDPOINT:-http://169.254.172.1:51678}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Defaults if metadata unavailable
CLUSTER_NAME="unknown"
CONTAINER_INSTANCE_ID="unknown"
EC2_INSTANCE_ID="unknown"
CAPACITY_PROVIDER_NAME="unknown"
REGISTERED_CPU="0"
REGISTERED_MEMORY="0"
INSTANCE_TYPE="unknown"
AVAILABILITY_ZONE="unknown"

# --- Fetch ECS agent metadata ---
echo "Fetching ECS agent metadata from ${ECS_AGENT_ENDPOINT}..."
METADATA=$(wget -qO- -T "${METADATA_TIMEOUT}" "${ECS_AGENT_ENDPOINT}/v1/metadata" 2>/dev/null || true)

if [ -z "$METADATA" ] || ! echo "$METADATA" | jq -e . >/dev/null 2>&1; then
  echo "WARNING: Unable to fetch ECS agent metadata. Using defaults."
  echo "  endpoint: ${ECS_AGENT_ENDPOINT}/v1/metadata"
else
  CLUSTER_ARN=$(echo "$METADATA" | jq -r '.Cluster')
  CLUSTER_NAME=$(echo "$CLUSTER_ARN" | sed 's|.*/||')
  CONTAINER_INSTANCE_ARN=$(echo "$METADATA" | jq -r '.ContainerInstanceArn')
  CONTAINER_INSTANCE_ID=$(echo "$CONTAINER_INSTANCE_ARN" | sed 's|.*/||')

  echo "ECS metadata OK: cluster=${CLUSTER_NAME} instance=${CONTAINER_INSTANCE_ID}"

  # --- Describe container instance for EC2 details ---
  echo "Fetching instance details from ECS API..."
  DESCRIBE_OUTPUT=$(timeout 10 aws ecs describe-container-instances \
    --cluster "$CLUSTER_NAME" \
    --container-instances "$CONTAINER_INSTANCE_ARN" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null || true)

  if echo "$DESCRIBE_OUTPUT" | jq -e '.containerInstances[0]' >/dev/null 2>&1; then
    EC2_INSTANCE_ID=$(echo "$DESCRIBE_OUTPUT" | jq -r '.containerInstances[0].ec2InstanceId')
    CAPACITY_PROVIDER_NAME=$(echo "$DESCRIBE_OUTPUT" | jq -r '.containerInstances[0].capacityProviderName // "unknown"')
    REGISTERED_CPU=$(echo "$DESCRIBE_OUTPUT" | jq -r '.containerInstances[0].registeredResources[] | select(.name=="CPU") | .integerValue')
    REGISTERED_MEMORY=$(echo "$DESCRIBE_OUTPUT" | jq -r '.containerInstances[0].registeredResources[] | select(.name=="MEMORY") | .integerValue')
    INSTANCE_TYPE=$(echo "$DESCRIBE_OUTPUT" | jq -r '.containerInstances[0].attributes[] | select(.name=="ecs.instance-type") | .value')
    AVAILABILITY_ZONE=$(echo "$DESCRIBE_OUTPUT" | jq -r '[.containerInstances[0].attributes[] | select(.name=="ecs.availability-zone") | .value][0] // "unknown"')

    echo "Instance: ${EC2_INSTANCE_ID} (${INSTANCE_TYPE}) in ${AVAILABILITY_ZONE}"
    echo "Capacity Provider: ${CAPACITY_PROVIDER_NAME}"
    echo "Registered CPU: ${REGISTERED_CPU}, Memory: ${REGISTERED_MEMORY}MiB"
  else
    echo "WARNING: Unable to describe container instance. Using defaults for instance details."
  fi
fi

# --- Fetch config files from S3 ---
# File 1 always runs (CONFIG_SOURCE / CONFIG_DEST, with the defaults above).
# Files 2 and 3 are optional. A file is fetched only if CONFIG_SOURCE_<n> is set and not
# empty. If it is set, CONFIG_DEST_<n> must be set too. If CONFIG_SOURCE_<n> is not set,
# the pair is ignored.
fetch_config() {
  src="$1"
  dst="$2"
  echo "Fetching config from ${src} to ${dst}..."
  mkdir -p "$(dirname "$dst")"
  aws s3 cp "$src" "$dst" --region "$AWS_REGION"

  # Template values into the file
  sed -i "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" "$dst"
  sed -i "s|__CONTAINER_INSTANCE_ID__|${CONTAINER_INSTANCE_ID}|g" "$dst"
  sed -i "s|__EC2_INSTANCE_ID__|${EC2_INSTANCE_ID}|g" "$dst"
  sed -i "s|__CAPACITY_PROVIDER_NAME__|${CAPACITY_PROVIDER_NAME}|g" "$dst"
  sed -i "s|__REGISTERED_CPU__|${REGISTERED_CPU}|g" "$dst"
  sed -i "s|__REGISTERED_MEMORY__|${REGISTERED_MEMORY}|g" "$dst"
  sed -i "s|__INSTANCE_TYPE__|${INSTANCE_TYPE}|g" "$dst"
  sed -i "s|__AVAILABILITY_ZONE__|${AVAILABILITY_ZONE}|g" "$dst"
  echo "Config ready at ${dst}"
}

fetch_config "$CONFIG_SOURCE" "$CONFIG_DEST"

for n in 2 3; do
  eval "extra_src=\${CONFIG_SOURCE_${n}:-}"
  eval "extra_dst=\${CONFIG_DEST_${n}:-}"
  if [ -z "$extra_src" ]; then
    if [ -n "$extra_dst" ]; then
      echo "WARNING: CONFIG_DEST_${n} is set but CONFIG_SOURCE_${n} is not. Ignoring file ${n}."
    fi
    continue
  fi
  if [ -z "$extra_dst" ]; then
    echo "ERROR: CONFIG_SOURCE_${n} is set but CONFIG_DEST_${n} is not." >&2
    exit 1
  fi
  fetch_config "$extra_src" "$extra_dst"
done
