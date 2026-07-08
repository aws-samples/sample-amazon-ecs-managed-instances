# Sheltie — Host Access Task for ECS Managed Instances

A privileged ECS task that provides full host-level access to Bottlerocket Managed Instance nodes via ECS Exec. Named after the Bottlerocket admin container's `sheltie` command which drops you into the host root namespace.

## What it does

Sheltie runs as a long-lived service (REPLICA with `desiredCount: 1`) that sleeps forever. Its purpose is to give you an interactive shell on the underlying Bottlerocket host via `aws ecs execute-command`. From there you can:

- Inspect host filesystems, processes, and network configuration
- Run `sudo sheltie` to enter the host's root namespace (PID 1)
- Debug containerd, the ECS agent, and kernel state
- Check disk usage, mount points, and device layout
- Inspect systemd journal logs with `journalctl`

## Why it's needed

ECS Managed Instances run Bottlerocket, which has no SSH access and no admin container by default. The only way to inspect the host is through a privileged task with `pidMode: "host"` and `networkMode: "host"` that mounts the host root filesystem.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Sheltie Task (privileged, host PID/network namespace)   │
│                                                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │ bottlerocket-admin container                      │  │
│  │                                                   │  │
│  │  entrypoint: sleep infinity                       │  │
│  │  mounts: /.bottlerocket/rootfs → host /           │  │
│  │          /run/api.sock → Bottlerocket API         │  │
│  │          /usr/bin/apiclient → API client binary   │  │
│  │                                                   │  │
│  │  exec → bash → sudo sheltie → host root ns       │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## Key task definition settings

| Setting | Value | Why |
|---------|-------|-----|
| `pidMode` | `host` | See host processes, enable `nsenter` into PID 1 |
| `networkMode` | `host` | See host network interfaces, no daemon bridge isolation |
| `privileged` | `true` | Access all devices, mount namespaces, kernel features |
| `/.bottlerocket/rootfs` mount | Host `/` | Required path for `sheltie` command to find host root |
| `/run/api.sock` mount | Bottlerocket API socket | Allows `apiclient` to query/modify Bottlerocket settings |
| `initProcessEnabled` | `true` | Proper signal handling for the sleep process |

## Before you deploy

The files in this directory use placeholders that you need to substitute with your own values:

| Placeholder | Found in | Description |
|-------------|----------|--------------|
| `<AWS_ACCOUNT_ID>` | `taskdef-sheltie.json` | Your AWS account ID |
| `<CLUSTER_NAME>` | `service-sheltie.json`, usage examples below | Your ECS cluster name |
| `<CAPACITY_PROVIDER_NAME>` | `service-sheltie.json` | Your Managed Instances capacity provider name |

Set each value as an environment variable, then run this from inside the `sheltie/` directory to substitute them in place. `AWS_REGION` isn't baked into any file here, but keep it exported alongside the others — the usage commands below pass it explicitly to `aws ecs`/`aws s3` calls:

```bash
export AWS_ACCOUNT_ID="<your-account-id>"
export AWS_REGION="<your-region>"
export CLUSTER_NAME="<your-cluster-name>"
export CAPACITY_PROVIDER_NAME="<your-capacity-provider-name>"

for f in *.json; do
  sed -i.bak \
    -e "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
    -e "s|<CLUSTER_NAME>|${CLUSTER_NAME}|g" \
    -e "s|<CAPACITY_PROVIDER_NAME>|${CAPACITY_PROVIDER_NAME}|g" \
    "$f"
done
rm -f *.bak
```

Keep `AWS_ACCOUNT_ID`, `AWS_REGION`, and `CLUSTER_NAME` exported in your shell session — the usage commands below reference them as `${CLUSTER_NAME}` and `${AWS_REGION}`.

## Deployment

### 1. Create the IAM task role

```bash
aws iam create-role \
    --role-name EcsExecRole \
    --assume-role-policy-document file://trust-policy.json

aws iam put-role-policy \
    --role-name EcsExecRole \
    --policy-name EcsExecPolicy \
    --policy-document file://task-role-policy.json
```

### 2. Register the task definition

```bash
aws ecs register-task-definition --region "${AWS_REGION}" --cli-input-json file://taskdef-sheltie.json
```

### 3. Create the service

```bash
aws ecs create-service --region "${AWS_REGION}" --cli-input-json file://service-sheltie.json
```

## Usage

### Get a shell on the host

```bash
# Find the sheltie task
TASK_ARN=$(aws ecs list-tasks --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" --service mi-sheltie --query taskArns[0] --output text)

# Exec into the container
aws ecs execute-command \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --task "${TASK_ARN}" \
    --container bottlerocket-admin \
    --interactive \
    --command "/bin/bash"
```

### Drop into the host root namespace

Once inside the container:

```bash
sudo sheltie
```

This gives you a shell as root in the host's PID/mount/network namespace — equivalent to SSH into the instance.

### Run one-off commands without interactive shell

```bash
# Check disk usage
aws ecs execute-command --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" --task "${TASK_ARN}" \
    --container bottlerocket-admin --interactive \
    --command "sudo sheltie df -hT"

# View kernel logs
aws ecs execute-command --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" --task "${TASK_ARN}" \
    --container bottlerocket-admin --interactive \
    --command "sudo sheltie journalctl -k --no-pager -n 20"

# List all systemd services
aws ecs execute-command --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" --task "${TASK_ARN}" \
    --container bottlerocket-admin --interactive \
    --command "sudo sheltie systemctl list-units --type=service --no-pager"

# Check block devices
aws ecs execute-command --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" --task "${TASK_ARN}" \
    --container bottlerocket-admin --interactive \
    --command "sudo sheltie lsblk -f"
```

## Security considerations

- This task has **full root access** to the host. Only deploy it when you need host-level debugging.
- The task role only needs SSM permissions (for ECS Exec). No AWS API access beyond that.
- Consider setting `desiredCount: 0` when not actively debugging and scaling up on demand.
- On production clusters, restrict who can call `ecs:ExecuteCommand` via IAM policies.

## Cleanup

```bash
# Delete the service (scales tasks to 0 and removes the service)
aws ecs delete-service --region "${AWS_REGION}" --cluster "${CLUSTER_NAME}" --service mi-sheltie --force

# Deregister task definitions
aws ecs list-task-definitions --region "${AWS_REGION}" --family-prefix mi-sheltie \
    --query 'taskDefinitionArns[]' --output text | tr '\t' '\n' | \
    while read -r arn; do aws ecs deregister-task-definition --region "${AWS_REGION}" --task-definition "$arn"; done

# Delete the IAM role
aws iam delete-role-policy --role-name EcsExecRole --policy-name EcsExecPolicy
aws iam delete-role --role-name EcsExecRole
```

## Useful commands once inside sheltie

| Command | Purpose |
|---------|---------|
| `df -hT` | Disk usage with filesystem types |
| `lsblk -f` | Block device layout |
| `journalctl -u containerd --no-pager -n 50` | Containerd logs |
| `journalctl -u ecs.service --no-pager -n 50` | ECS agent service logs |
| `journalctl -k --no-pager -n 50` | Kernel messages |
| `cat /proc/mounts` | All mount points |
| `ctr namespaces list` | Containerd namespaces |
| `ctr -n fargate.task containers list` | Running containers |
| `cat /var/log/ecs/ecs-agent.log \| tail -20` | Recent ECS agent log |
| `systemctl status containerd` | Containerd service status |
