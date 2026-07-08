# ADOT Host Metrics Daemon

A daemon that collects host-level metrics from ECS Managed Instance nodes and exports them to Amazon Managed Service for Prometheus (AMP).

## Architecture

The daemon runs three containers:

1. **mi-init** — fetches config from S3, templates instance metadata into it, then exits
2. **node-exporter** — Prometheus node exporter collecting host CPU, memory, disk, filesystem, network, and load metrics
3. **adot-collector** — upstream AWS Distro for OpenTelemetry Collector that scrapes node-exporter and remote-writes to AMP

```
┌──────────────────────────────────────────────────────────┐
│ Daemon Task                                              │
│                                                          │
│  ┌──────────┐   ┌───────────────┐   ┌────────────────┐  │
│  │ mi-init  │   │ node-exporter │   │ adot-collector │  │
│  │ (exits)  │   │  :9100        │──▶│ prometheus rx  │──▶ AMP
│  └────┬─────┘   └───────────────┘   └────────────────┘  │
│       │                                      ▲           │
│       └──── /config volume ──────────────────┘           │
└──────────────────────────────────────────────────────────┘
```

## Metrics collected

| Category | Metrics | Source |
|----------|---------|--------|
| CPU | `node_cpu_seconds_total` (user, system, iowait) | `/proc/stat` |
| Memory | `node_memory_MemTotal_bytes`, `MemAvailable_bytes`, `MemFree_bytes` | `/proc/meminfo` |
| Filesystem | `node_filesystem_size_bytes`, `node_filesystem_avail_bytes` | `statfs()` on `/host/data` and `/host/os` |
| Disk I/O | `node_disk_read_bytes_total`, `node_disk_written_bytes_total` | `/proc/diskstats` |
| Network | `node_network_receive_bytes_total`, `transmit_bytes`, `errs`, `drop` | `/proc/net/dev` |
| Load | `node_load1`, `node_load5`, `node_load15` | `/proc/loadavg` |

All metrics include resource labels: `ClusterName`, `CapacityProviderName`, `ContainerInstanceId`, `EC2InstanceId`, `InstanceType`, `RegisteredCPU`, `RegisteredMemory`.

## Disk monitoring on Bottlerocket

Managed Instances run Bottlerocket with a two-disk layout:

| Disk | Device | Size | Mounted at (host) | Container mount | Purpose |
|------|--------|------|-------------------|----------------|---------|
| OS | `/dev/nvme0n1p8` | 3GB | `/local` | `/host/os` | ECS agent state, SSM, host configs |
| Data | `/dev/nvme1n1` | 80GB | `/mnt/task` | `/host/data` | Container images, workload storage |

## Before you deploy

The files in this directory use placeholders that you need to substitute with your own values:

| Placeholder | Found in | Description |
|-------------|----------|--------------|
| `<AWS_ACCOUNT_ID>` | all `.json` files, `adot-collector-config.yaml` | Your AWS account ID |
| `<AWS_REGION>` | all `.json` files, `adot-collector-config.yaml` | The region your cluster runs in |
| `<AMP_WORKSPACE_ID>` | `adot-collector-config.yaml` | Your Amazon Managed Prometheus workspace ID (`aws amp list-workspaces`) |
| `<CLUSTER_NAME>` | `task-role-policy.json`, `daemon-adot-service.json` | Your ECS cluster name |
| `<CAPACITY_PROVIDER_NAME>` | `daemon-adot-service.json` | Your Managed Instances capacity provider name |
| `<CONFIG_BUCKET_NAME>` | `task-role-policy.json`, `daemon-taskdef-adot.json` | S3 bucket where you upload `adot-collector-config.yaml` |

Set each value as an environment variable, then run this from inside the `adot/` directory to substitute them in place. `CONFIG_BUCKET_NAME` is generated with a random suffix so it doesn't collide with an existing bucket — S3 bucket names must be globally unique:

```bash
export AWS_ACCOUNT_ID="<your-account-id>"
export AWS_REGION="<your-region>"
export AMP_WORKSPACE_ID="<your-amp-workspace-id>"           # aws amp list-workspaces
export CLUSTER_NAME="<your-cluster-name>"
export CAPACITY_PROVIDER_NAME="<your-capacity-provider-name>"
export CONFIG_BUCKET_NAME="ecs-adot-config-$(date +%s%N | sha256sum | head -c 8)"

for f in *.json *.yaml; do
  sed -i.bak \
    -e "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
    -e "s|<AWS_REGION>|${AWS_REGION}|g" \
    -e "s|<AMP_WORKSPACE_ID>|${AMP_WORKSPACE_ID}|g" \
    -e "s|<CLUSTER_NAME>|${CLUSTER_NAME}|g" \
    -e "s|<CAPACITY_PROVIDER_NAME>|${CAPACITY_PROVIDER_NAME}|g" \
    -e "s|<CONFIG_BUCKET_NAME>|${CONFIG_BUCKET_NAME}|g" \
    "$f"
done
rm -f *.bak
```

## Deployment

### 1. Create the IAM task role

```bash
aws iam create-role \
    --role-name EcsAdotTaskRole \
    --assume-role-policy-document file://trust-policy.json

aws iam put-role-policy \
    --role-name EcsAdotTaskRole \
    --policy-name AdotCollectorPolicy \
    --policy-document file://task-role-policy.json
```

### 2. Create the config bucket and upload the config

```bash
aws s3 mb "s3://${CONFIG_BUCKET_NAME}" --region "${AWS_REGION}"
aws s3 cp adot-collector-config.yaml "s3://${CONFIG_BUCKET_NAME}/adot-collector-config.yaml" --region "${AWS_REGION}"
```

### 3. Register the daemon task definition

```bash
aws ecs register-daemon-task-definition --region "${AWS_REGION}" --cli-input-json file://daemon-taskdef-adot.json
```

### 4. Create the daemon

```bash
aws ecs create-daemon --region "${AWS_REGION}" --cli-input-json file://daemon-adot-service.json
```

### 5. Update the daemon (after config or task def changes)

```bash
export REVISION="<daemon-task-definition-revision>"

aws ecs update-daemon \
    --region "${AWS_REGION}" \
    --daemon-arn "arn:aws:ecs:${AWS_REGION}:${AWS_ACCOUNT_ID}:daemon/${CLUSTER_NAME}/adot-collector" \
    --daemon-task-definition-arn "arn:aws:ecs:${AWS_REGION}:${AWS_ACCOUNT_ID}:daemon-task-definition/daemon-adot-collector:${REVISION}" \
    --capacity-provider-arns "arn:aws:ecs:${AWS_REGION}:${AWS_ACCOUNT_ID}:capacity-provider/${CAPACITY_PROVIDER_NAME}" \
    --deployment-configuration drainPercent=100,bakeTimeInMinutes=0
```

## PromQL examples

```promql
# CPU utilization per instance
1 - avg by (EC2InstanceId) (rate(node_cpu_seconds_total{mode="idle"}[5m]))

# Memory utilization
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

# Data volume usage percentage
1 - (node_filesystem_avail_bytes{mountpoint="/host/data"} / node_filesystem_size_bytes{mountpoint="/host/data"})

# OS partition usage percentage
1 - (node_filesystem_avail_bytes{mountpoint="/host/os"} / node_filesystem_size_bytes{mountpoint="/host/os"})

# Network throughput
rate(node_network_receive_bytes_total{device="eth0"}[5m])
```

## Cleanup

```bash
# Delete the daemon (drains and removes daemon tasks from container instances)
aws ecs delete-daemon --region "${AWS_REGION}" --daemon-arn "arn:aws:ecs:${AWS_REGION}:${AWS_ACCOUNT_ID}:daemon/${CLUSTER_NAME}/adot-collector"

# Deregister task definitions
aws ecs list-task-definitions --region "${AWS_REGION}" --family-prefix daemon-adot-collector \
    --query 'taskDefinitionArns[]' --output text | tr '\t' '\n' | \
    while read -r arn; do aws ecs deregister-task-definition --region "${AWS_REGION}" --task-definition "$arn"; done

# Delete the config object and bucket
aws s3 rm "s3://${CONFIG_BUCKET_NAME}/adot-collector-config.yaml" --region "${AWS_REGION}"
aws s3 rb "s3://${CONFIG_BUCKET_NAME}" --region "${AWS_REGION}"

# Delete the IAM role
aws iam delete-role-policy --role-name EcsAdotTaskRole --policy-name AdotCollectorPolicy
aws iam delete-role --role-name EcsAdotTaskRole
```
