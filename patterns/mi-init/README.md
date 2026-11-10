# MI Init Container

An init container for ECS Managed Instance daemons that fetches configuration from S3 and injects instance-level metadata as template values.

## Why it exists

On ECS Managed Instances, IMDS (169.254.169.254) is not available. This means standard approaches to discover instance identity (instance ID, instance type, region via IMDS) don't work. However, the ECS agent exposes a local introspection endpoint at `169.254.172.1:51678` on the daemon bridge network, which provides cluster and container instance information.

This init container:
1. Queries the ECS agent's `/v1/metadata` endpoint to get the cluster ARN and container instance ARN
2. Calls `ecs:DescribeContainerInstances` to resolve the EC2 instance ID, instance type, Availability Zone, capacity provider, and registered resources
3. Downloads a config file from S3
4. Templates instance metadata into the config using `sed` placeholder replacement

## How it works

```
┌─────────────────────────────────────────────────────┐
│ Daemon Task                                         │
│                                                     │
│  ┌──────────────┐    ┌────────────────────────────┐ │
│  │  mi-init     │    │  Main container            │ │
│  │  (essential: │    │  (depends on mi-init       │ │
│  │   false)     │    │   condition: SUCCESS)      │ │
│  │              │    │                            │ │
│  │ 1. ECS Agent │    │  Reads /config/config.yaml │ │
│  │ 2. Describe  │    │  with templated values     │ │
│  │ 3. S3 fetch  │    │                            │ │
│  │ 4. Template  │    │                            │ │
│  └──────┬───────┘    └────────────────────────────┘ │
│         │                        ▲                  │
│         └──── /config volume ────┘                  │
└─────────────────────────────────────────────────────┘
```

### Data sources

| Source | Endpoint | Data retrieved |
|--------|----------|---------------|
| ECS Agent | `http://169.254.172.1:51678/v1/metadata` | Cluster ARN, Container Instance ARN |
| ECS API | `ecs:DescribeContainerInstances` | EC2 Instance ID, Instance Type, Availability Zone, Capacity Provider, Registered CPU/Memory |
| S3 | `s3:GetObject` | Configuration file |

### Template placeholders

Config files stored in S3 can use these placeholders which get replaced at runtime:

| Placeholder | Example value | Description |
|-------------|---------------|-------------|
| `__CLUSTER_NAME__` | `mi` | ECS cluster name |
| `__CONTAINER_INSTANCE_ID__` | `ef5123464a134ee29891a2f88e0fa3ec` | Container instance ID |
| `__EC2_INSTANCE_ID__` | `i-04e53a40b2e2abdcd` | EC2 instance ID |
| `__CAPACITY_PROVIDER_NAME__` | `mi-prod` | Capacity provider name |
| `__INSTANCE_TYPE__` | `c6a.large` | EC2 instance type |
| `__AVAILABILITY_ZONE__` | `eu-west-1a` | Availability Zone of the instance (the `ecs.availability-zone` attribute) |
| `__REGISTERED_CPU__` | `2048` | Registered CPU units |
| `__REGISTERED_MEMORY__` | `3488` | Registered memory in MiB |

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CONFIG_SOURCE` | `s3://ecs-daemon-configs/config.yaml` | S3 URI of the config file to download |
| `CONFIG_DEST` | `/config/config.yaml` | Local path to write the templated config |
| `CONFIG_SOURCE_2`, `CONFIG_DEST_2` | not set | Optional second file, for example a Fluent Bit Lua script. Ignored when `CONFIG_SOURCE_2` is not set or empty |
| `CONFIG_SOURCE_3`, `CONFIG_DEST_3` | not set | Optional third file, same rules |
| `METADATA_TIMEOUT` | `3` | Timeout in seconds for ECS agent metadata fetch |
| `ECS_AGENT_ENDPOINT` | `http://169.254.172.1:51678` | ECS agent introspection endpoint |
| `AWS_REGION` | `us-east-1` | AWS region for API calls. Override this to match the region your cluster runs in |

## Before you deploy

This directory doesn't ship a task definition of its own (it's a container consumed by `adot` and `fluentbit`), but the commands below use placeholders you need to substitute with your own values:

| Placeholder | Found in | Description |
|-------------|----------|--------------|
| `<AWS_ACCOUNT_ID>` | build/push commands, IAM policy example | Your AWS account ID |
| `<AWS_REGION>` | build/push commands, IAM policy example | The region your cluster runs in |
| `<CLUSTER_NAME>` | IAM policy example | Your ECS cluster name |
| `<CONFIG_BUCKET_NAME>` | IAM policy example | S3 bucket holding your daemon configs (the same `CONFIG_BUCKET_NAME` you created for [adot](../adot/) or [fluentbit](../fluentbit/)) |

Set each value as an environment variable so you can copy/paste the commands below as-is:

```bash
export AWS_ACCOUNT_ID="<your-account-id>"
export AWS_REGION="<your-region>"
export CLUSTER_NAME="<your-cluster-name>"
export CONFIG_BUCKET_NAME="<your-config-bucket-name>"   # the CONFIG_BUCKET_NAME from adot/ or fluentbit/
```

## Build and push

### 1. Create the ECR repository

```bash
aws ecr create-repository --region "${AWS_REGION}" --repository-name mi-init
```

### 2. Build, tag, and push the image

```bash
docker build --tag mi-init .
docker tag mi-init:latest "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/mi-init:latest"
docker push "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/mi-init:latest"
```

## Usage in a daemon task definition

```json
{
    "name": "metadata-init",
    "image": "<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/mi-init:latest",
    "essential": false,
    "environment": [
        {
            "name": "CONFIG_SOURCE",
            "value": "s3://your-bucket/your-config.yaml"
        },
        {
            "name": "AWS_REGION",
            "value": "<AWS_REGION>"
        }
    ],
    "mountPoints": [
        {
            "sourceVolume": "config",
            "containerPath": "/config"
        }
    ]
}
```

### Fetching more than one file

`CONFIG_SOURCE` and `CONFIG_DEST` always fetch the first file. Up to two more files can be fetched with numbered pairs, for example a Fluent Bit config and a Lua script it loads:

```json
"environment": [
    { "name": "CONFIG_SOURCE",   "value": "s3://your-bucket/fluentbit-config.yaml" },
    { "name": "CONFIG_DEST",     "value": "/config/config.yaml" },
    { "name": "CONFIG_SOURCE_2", "value": "s3://your-bucket/enrich.lua" },
    { "name": "CONFIG_DEST_2",   "value": "/config/enrich.lua" },
    { "name": "AWS_REGION",      "value": "<AWS_REGION>" }
]
```

Rules:
- A pair is ignored when `CONFIG_SOURCE_<n>` is not set or is empty. A `CONFIG_DEST_<n>` on its own is ignored with a warning.
- If `CONFIG_SOURCE_<n>` is set, `CONFIG_DEST_<n>` must be set too, otherwise the init container exits with an error.
- A file that can't be downloaded fails the init container, so the main container, which depends on it, doesn't start.
- Every file gets the same placeholder replacement, and the destination directory is created if it doesn't exist.
- The task role needs `s3:GetObject` on each object. No `s3:ListBucket` is needed.

The main container should depend on the init container:

```json
"dependsOn": [
    {
        "containerName": "metadata-init",
        "condition": "SUCCESS"
    }
]
```

## IAM permissions required

The task role needs `ecs:DescribeContainerInstances` and `s3:GetObject`. Replace `<AWS_REGION>`, `<AWS_ACCOUNT_ID>`, `<CLUSTER_NAME>`, and `<CONFIG_BUCKET_NAME>`:

```json
{
    "Effect": "Allow",
    "Action": ["ecs:DescribeContainerInstances"],
    "Resource": "arn:aws:ecs:<AWS_REGION>:<AWS_ACCOUNT_ID>:container-instance/<CLUSTER_NAME>/*"
},
{
    "Effect": "Allow",
    "Action": ["s3:GetObject"],
    "Resource": "arn:aws:s3:::<CONFIG_BUCKET_NAME>/*"
}
```

## Cleanup

`mi-init` doesn't create an ECS task, service, or daemon of its own — it's only pulled in as a container by `adot` or `fluentbit`. Clean up those patterns' resources first (see their own Cleanup sections), then remove the `mi-init` image and repository:

```bash
aws ecr delete-repository --region "${AWS_REGION}" --repository-name mi-init --force
```
