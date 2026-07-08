# Fluent Bit Host Log Collection Daemon

A daemon that collects host-level logs from ECS Managed Instance nodes and ships them to Amazon CloudWatch Logs.

## Architecture

The daemon runs two containers:

1. **[mi-init](../mi-init/)** — fetches Fluent Bit config from S3, templates instance metadata into it, then exits
2. **fluent-bit** — AWS for Fluent Bit v3 (based on Fluent Bit 5.x) reading host logs and journal entries

```
┌──────────────────────────────────────────────────────────────────┐
│ Daemon Task                                                      │
│                                                                  │
│  ┌──────────┐   ┌──────────────────────────────────────────────┐ │
│  │ mi-init  │   │ fluent-bit                                   │ │
│  │ (exits)  │   │                                              │ │
│  └────┬─────┘   │  tail: /host/logs/ecs/ecs-agent.log ──────┐ │ │
│       │         │  systemd: _COMM=containerd ────────────────┤ │ │
│       │         │  systemd: _TRANSPORT=kernel ───────────────┤ │ │
│       │         │                                            ▼ │ │
│       │         │                              CloudWatch Logs │ │
│       │         └──────────────────────────────────────────────┘ │
│       └──── /config volume                                       │
└──────────────────────────────────────────────────────────────────┘
```

## Log sources

| Source | Input plugin | Tag | Format | What it captures |
|--------|-------------|-----|--------|-----------------|
| ECS Agent | `tail` | `ecs-agent` | JSON (structured) | Task scheduling, placement, credential vending, container lifecycle |
| Containerd | `systemd` | `containerd` | Journal (structured) | Image pulls, shim creation, overlay mounts, container start/stop |
| Kernel | `systemd` | `kernel` | Journal (structured) | OOM kills, ENA driver events, disk errors, bridge/veth creation |

## CloudWatch log structure

All logs go to a single log group with per-instance, per-source streams:

```
/ecs/<CLUSTER_NAME>/host-logs
├── ecs-agent/<ContainerInstanceId>
├── containerd/<ContainerInstanceId>
└── kernel/<ContainerInstanceId>
```

Each log entry includes `ClusterName`, `ContainerInstanceId`, and `EC2InstanceId` as fields.

## Key design decisions

### read_from_tail settings

| Input | read_from_tail | Why |
|-------|---------------|-----|
| ECS Agent (tail) | `read_from_head: false` | Only capture new log entries; historical agent logs are large and noisy |
| Containerd (systemd) | `true` | Only new container lifecycle events; historical shim creation isn't actionable |
| Kernel (systemd) | `false` | Capture boot messages and any prior OOM kills — these are rare and always relevant |

### Volume mounts

| Volume | Host path | Container path | Purpose |
|--------|-----------|---------------|---------|
| `host-logs` | `/var/log` | `/host/logs` (read-only) | ECS agent logs + systemd journal |
| `fluentbit-state` | (ephemeral) | `/var/lib/fluent-bit` | Cursor DB files for resuming after restart |
| `config` | (ephemeral) | `/config` | Templated config from mi-init |

The state volume stores Fluent Bit's DB files that track read position. This means after a restart (via `restartPolicy`), Fluent Bit resumes from where it left off rather than re-reading.

### Why not use the aws-for-fluent-bit init process?

The `aws-for-fluent-bit:init-*` image has a built-in init process that can download configs from S3 and inject ECS task metadata as env vars. However, it only queries the **task metadata endpoint** (`169.254.170.2`) which provides task-level context (cluster name, task ARN, family, region).

It does NOT provide:
- Container Instance ID
- EC2 Instance ID
- Instance Type
- Capacity Provider Name
- Registered CPU/Memory

For infrastructure-level daemons that need to identify which physical host they're running on, you need the ECS agent endpoint (`169.254.172.1:51678`) + `DescribeContainerInstances` — which is what this init container provides.

## Before you deploy

The files in this directory use placeholders that you need to substitute with your own values:

| Placeholder | Found in | Description |
|-------------|----------|--------------|
| `<AWS_ACCOUNT_ID>` | all `.json` files | Your AWS account ID |
| `<AWS_REGION>` | all `.json` files, `fluentbit-config.yaml` | The region your cluster runs in |
| `<CLUSTER_NAME>` | `task-role-policy.json`, `daemon-fluentbit-service.json`, `fluentbit-config.yaml` | Your ECS cluster name |
| `<CAPACITY_PROVIDER_NAME>` | `daemon-fluentbit-service.json` | Your Managed Instances capacity provider name |
| `<CONFIG_BUCKET_NAME>` | `task-role-policy.json`, `daemon-taskdef-fluentbit.json` | S3 bucket where you upload `fluentbit-config.yaml` |

Set each value as an environment variable, then run this from inside the `fluentbit/` directory to substitute them in place. `CONFIG_BUCKET_NAME` is generated with a random suffix so it doesn't collide with an existing bucket — S3 bucket names must be globally unique:

```bash
export AWS_ACCOUNT_ID="<your-account-id>"
export AWS_REGION="<your-region>"
export CLUSTER_NAME="<your-cluster-name>"
export CAPACITY_PROVIDER_NAME="<your-capacity-provider-name>"
export CONFIG_BUCKET_NAME="ecs-fluentbit-config-$(date +%s%N | sha256sum | head -c 8)"

for f in *.json *.yaml; do
  sed -i.bak \
    -e "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
    -e "s|<AWS_REGION>|${AWS_REGION}|g" \
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
    --role-name EcsFluentBitTaskRole \
    --assume-role-policy-document file://trust-policy.json

aws iam put-role-policy \
    --role-name EcsFluentBitTaskRole \
    --policy-name FluentBitPolicy \
    --policy-document file://task-role-policy.json
```

### 2. Create the config bucket and upload the config

```bash
aws s3 mb "s3://${CONFIG_BUCKET_NAME}" --region "${AWS_REGION}"
aws s3 cp fluentbit-config.yaml "s3://${CONFIG_BUCKET_NAME}/fluentbit-config.yaml" --region "${AWS_REGION}"
```

### 3. Register the daemon task definition

```bash
aws ecs register-daemon-task-definition --region "${AWS_REGION}" --cli-input-json file://daemon-taskdef-fluentbit.json
```

### 4. Create the daemon

```bash
aws ecs create-daemon --region "${AWS_REGION}" --cli-input-json file://daemon-fluentbit-service.json
```

### 5. Update the daemon (after config or task def changes)

```bash
export REVISION="<daemon-task-definition-revision>"

aws ecs update-daemon \
    --region "${AWS_REGION}" \
    --daemon-arn "arn:aws:ecs:${AWS_REGION}:${AWS_ACCOUNT_ID}:daemon/${CLUSTER_NAME}/fluentbit" \
    --daemon-task-definition-arn "arn:aws:ecs:${AWS_REGION}:${AWS_ACCOUNT_ID}:daemon-task-definition/daemon-fluentbit:${REVISION}" \
    --capacity-provider-arns "arn:aws:ecs:${AWS_REGION}:${AWS_ACCOUNT_ID}:capacity-provider/${CAPACITY_PROVIDER_NAME}" \
    --deployment-configuration drainPercent=100,bakeTimeInMinutes=0
```

## Verifying logs are flowing

```bash
export CONTAINER_INSTANCE_ID="<container-instance-id>"

# Check log streams exist
aws logs describe-log-streams \
    --region "${AWS_REGION}" \
    --log-group-name "/ecs/${CLUSTER_NAME}/host-logs" \
    --query 'logStreams[].logStreamName'

# Read recent kernel logs
aws logs get-log-events \
    --region "${AWS_REGION}" \
    --log-group-name "/ecs/${CLUSTER_NAME}/host-logs" \
    --log-stream-name "kernel/${CONTAINER_INSTANCE_ID}" \
    --limit 10 \
    --query 'events[].message'
```

## Cleanup

```bash
# Delete the daemon (drains and removes daemon tasks from container instances)
aws ecs delete-daemon --region "${AWS_REGION}" --daemon-arn "arn:aws:ecs:${AWS_REGION}:${AWS_ACCOUNT_ID}:daemon/${CLUSTER_NAME}/fluentbit"

# Deregister task definitions
aws ecs list-task-definitions --region "${AWS_REGION}" --family-prefix daemon-fluentbit \
    --query 'taskDefinitionArns[]' --output text | tr '\t' '\n' | \
    while read -r arn; do aws ecs deregister-task-definition --region "${AWS_REGION}" --task-definition "$arn"; done

# Delete the config object and bucket
aws s3 rm "s3://${CONFIG_BUCKET_NAME}/fluentbit-config.yaml" --region "${AWS_REGION}"
aws s3 rb "s3://${CONFIG_BUCKET_NAME}" --region "${AWS_REGION}"

# Delete the IAM role
aws iam delete-role-policy --role-name EcsFluentBitTaskRole --policy-name FluentBitPolicy
aws iam delete-role --role-name EcsFluentBitTaskRole
```
