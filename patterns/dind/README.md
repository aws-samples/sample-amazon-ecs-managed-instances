# Docker-in-Docker (DIND) on ECS Managed Instances

Run Docker-in-Docker on ECS Managed Instances to build and push container images from within an ECS task. Useful for CI/CD pipelines, dynamic image builds, and containerized build environments.

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│ DIND Task (awsvpc network mode)                            │
│                                                            │
│  ┌──────────────────────┐    ┌──────────────────────────┐  │
│  │ dind container       │    │ cli container            │  │
│  │ (docker:dind)        │    │ (docker:cli + ecr-login) │  │
│  │                      │    │                          │  │
│  │ Runs dockerd         │◀───│ DOCKER_HOST=unix://      │  │
│  │ privileged: true     │    │ /socket/docker.sock      │  │
│  │                      │    │                          │  │
│  │ healthCheck:         │    │ docker build --push      │  │
│  │   docker ps          │    │   → ECR                  │  │
│  └──────────┬───────────┘    └──────────────────────────┘  │
│             │                            │                  │
│             └──── /socket volume ────────┘                  │
└────────────────────────────────────────────────────────────┘
```

The `dind` container runs the Docker daemon with a shared socket. The `cli` container connects to it via the unix socket to build and push images. The cli container uses `docker-credential-ecr-login` for seamless ECR authentication.

## Why privileged mode is required

Docker-in-Docker needs `privileged: true` to run a nested Docker daemon. On ECS Managed Instances, privileged containers are supported and have access to create namespaces, mount filesystems, and manage cgroups — all required by the inner Docker daemon.

## Before you deploy

The files in this directory use placeholders that you need to substitute with your own values:

| Placeholder | Found in | Description |
|-------------|----------|--------------|
| `<AWS_ACCOUNT_ID>` | `taskdef-dind.json` | Your AWS account ID |
| `<AWS_REGION>` | `taskdef-dind.json` | The region your cluster runs in |
| `<CLUSTER_NAME>` | `runtask-dind.json` | Your ECS cluster name |
| `<CAPACITY_PROVIDER_NAME>` | `runtask-dind.json` | Your Managed Instances capacity provider name |
| `<SUBNET_ID>` | `runtask-dind.json` | A private subnet ID in your VPC |
| `<SECURITY_GROUP_ID>` | `runtask-dind.json` | A security group ID allowing outbound HTTPS (for git clone + ECR push) |
| `<ECR_REPO_URI>`, `<IMAGE_TAG>` | `taskdef-dind.json` | The ECR repo/tag you want the `cli` container to build and push |
| `<GIT_URL>#:<CONTEXT_PATH>` | `taskdef-dind.json` | The git build context to pass to `docker build` |

Set each value as an environment variable, then run this from inside the `dind/` directory to substitute them in place. Set `ECR_REPO_NAME` on its own line first — `ECR_REPO_URI` is built from it, so don't leave a literal placeholder embedded inside `ECR_REPO_URI` or `docker build` will fail with `invalid reference format`:

```bash
export AWS_ACCOUNT_ID="<your-account-id>"
export AWS_REGION="<your-region>"
export CLUSTER_NAME="<your-cluster-name>"
export CAPACITY_PROVIDER_NAME="<your-capacity-provider-name>"
export SUBNET_ID="<your-subnet-id>"
export SECURITY_GROUP_ID="<your-security-group-id>"
export ECR_REPO_NAME="<your-repo-name>"
export ECR_REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"
export IMAGE_TAG="<your-image-tag>"
export GIT_URL="https://github.com/<org>/<repo>.git"
export CONTEXT_PATH="<path-within-repo>"

for f in *.json; do
  sed -i.bak \
    -e "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" \
    -e "s|<AWS_REGION>|${AWS_REGION}|g" \
    -e "s|<CLUSTER_NAME>|${CLUSTER_NAME}|g" \
    -e "s|<CAPACITY_PROVIDER_NAME>|${CAPACITY_PROVIDER_NAME}|g" \
    -e "s|<SUBNET_ID>|${SUBNET_ID}|g" \
    -e "s|<SECURITY_GROUP_ID>|${SECURITY_GROUP_ID}|g" \
    -e "s|<ECR_REPO_URI>|${ECR_REPO_URI}|g" \
    -e "s|<IMAGE_TAG>|${IMAGE_TAG}|g" \
    -e "s|<GIT_URL>|${GIT_URL}|g" \
    -e "s|<CONTEXT_PATH>|${CONTEXT_PATH}|g" \
    "$f"
done
rm -f *.bak

# Also used directly by the commands below
export IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/docker:cli"
```

## Deployment

### 1. Create the ECR repository for the CLI helper image

The `cli` container's `image` field in `taskdef-dind.json` points at `docker:cli` — a fixed, literal repository name (not a placeholder). This repository has to exist before ECS can pull the image, so create it once:

```bash
aws ecr create-repository --region "${AWS_REGION}" --repository-name docker
```

`${ECR_REPO_NAME}` (used in `ECR_REPO_URI` above) is a *different* repository — it's the destination that the running `cli` container's `docker build --push` pushes its output image to. That's typically an existing application repository you already own, not something this pattern should create or delete for you. If you don't have one yet:

```bash
aws ecr create-repository --region "${AWS_REGION}" --repository-name "${ECR_REPO_NAME}"
```

### 2. Build the Docker CLI image with ECR credential helper

This directory already ships a `Dockerfile` and `config.json` that layer `docker-credential-ecr-login` onto `docker:cli`, so you can build and push directly:

```bash
docker build --tag "${IMAGE_URI}" .
docker push "${IMAGE_URI}"
```

### 3. Create the IAM task role

```bash
aws iam create-role \
    --role-name EcsDindTaskRole \
    --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser \
    --role-name EcsDindTaskRole
```

### 4. Register the task definition

```bash
aws ecs register-task-definition --region "${AWS_REGION}" --cli-input-json file://taskdef-dind.json
```

### 5. Run the task

```bash
aws ecs run-task --region "${AWS_REGION}" --cli-input-json file://runtask-dind.json
```

## Key design decisions

| Decision | Rationale |
|----------|-----------|
| Shared unix socket (not TCP) | Avoids exposing Docker API over network; simpler security model |
| ECR credential helper | No manual `docker login` needed; uses task role credentials automatically |
| Health check on dind container | CLI container waits for dockerd to be ready before building |
| `awsvpc` network mode | CLI container needs outbound internet for git clone + image push |
| Ephemeral socket volume | No host path needed; socket only shared between containers in the task |

## Customizing the build command

The `cli` container's `command` defines what gets built. Modify it to build your own image:

```json
"command": [
    "build",
    "--file", "Dockerfile",
    "--push",
    "--tag", "<AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<REPO>:<TAG>",
    "https://github.com/<ORG>/<REPO>.git#:<CONTEXT_PATH>"
]
```

Or for a multi-step build pipeline, override the entrypoint with a shell script:

```json
"entryPoint": ["/bin/sh", "-c"],
"command": [
    "docker build -t myimage:latest . && docker push myimage:latest"
]
```

## Cleanup

```bash
# Deregister task definitions
aws ecs list-task-definitions --region "${AWS_REGION}" --family-prefix dind \
    --query 'taskDefinitionArns[]' --output text | tr '\t' '\n' | \
    while read -r arn; do aws ecs deregister-task-definition --region "${AWS_REGION}" --task-definition "$arn"; done

# Delete the IAM role
aws iam detach-role-policy \
    --role-name EcsDindTaskRole \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
aws iam delete-role --role-name EcsDindTaskRole

# Delete the CLI helper repository (--force also removes any images in it)
aws ecr delete-repository --region "${AWS_REGION}" --repository-name docker --force

# Only delete this if you created it as a throwaway repo in step 1 above —
# don't delete ${ECR_REPO_NAME} if it's a real application repository you
# already owned before running this pattern.
# aws ecr delete-repository --region "${AWS_REGION}" --repository-name "${ECR_REPO_NAME}" --force
```
