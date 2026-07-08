---
inclusion: fileMatch
fileMatchPattern: 'patterns/**'
---

# Patterns directory standards

Conventions for everything under `patterns/`. Each pattern is a self-contained
directory (task/service/policy JSON, configs, and a README) demonstrating one
operational capability on ECS Managed Instances. Apply these standards to any
new pattern and when editing existing ones, so the whole directory reads the
same way regardless of which pattern someone opens first.

## Placeholders

- Use angle-bracket placeholders for anything account/environment-specific:
  `<AWS_ACCOUNT_ID>`, `<AWS_REGION>`, `<CLUSTER_NAME>`, `<CAPACITY_PROVIDER_NAME>`.
- Never hardcode a real account ID, region, subnet ID, security group ID, or
  bucket name in a committed file.
- S3 config buckets use `<CONFIG_BUCKET_NAME>` everywhere (task role policies,
  task definitions, README) — not `<BUCKET_NAME>` or other variants. Bucket
  names must be globally unique, so generate them with a random suffix rather
  than asking the user to invent one:
  `ecs-<pattern>-config-$(date +%s%N | sha256sum | head -c 8)`.
- Every placeholder that appears in a pattern's files must be listed in that
  pattern's "Before you deploy" placeholder table, and the table's "Found in"
  column must list every file it actually appears in (check with grep before
  trusting the table).

## README structure

Each pattern README follows this section order:

1. Title + one-line description
2. `## Architecture` — ASCII diagram if there's more than one container
3. Pattern-specific explainer sections (metrics collected, log sources, why
   privileged mode is needed, etc.)
4. `## Before you deploy` — placeholder table, then a single bash block that
   exports every placeholder as an env var and `sed -i.bak ... ; rm -f *.bak`
   substitutes them into every file in the directory
5. `## Deployment` — numbered steps (`### 1.`, `### 2.`, ...) as bash blocks,
   one AWS CLI action per step
6. Pattern-specific extras (PromQL examples, customizing the build command,
   useful commands once inside, etc.)
7. `## Cleanup` — reverse of every resource created in Deployment

Don't rename `## Deployment` to `## Setup` or fold the placeholder block into
it — keep placeholders and deployment steps in separate sections across all
patterns.

## Bash command conventions

- Every `aws` CLI call must pass `--region "${AWS_REGION}"` explicitly. Don't
  rely on a default profile region.
- Reference exported variables as `"${VAR_NAME}"` (braced and quoted), not
  `$VAR_NAME` or literal `<VAR_NAME>` placeholders, in any command meant to be
  run as-is.
- Use `while read -r arn; do ... ; done`, not `while read arn`.
- Prefer real files over heredocs. If a pattern needs a Dockerfile, config
  file, or script to build something, commit it as an actual file in the
  pattern directory and reference it directly (`docker build --tag "${IMAGE_URI}" .`)
  instead of writing `cat > file <<EOF` in the README.

## IAM and resource naming

- Task role names use `Ecs<Pattern>TaskRole` (e.g. `EcsAdotTaskRole`,
  `EcsDindTaskRole`, `EcsFluentBitTaskRole`, `EcsExecRole`) — capital `E`,
  no other casing.
- CloudWatch log groups use `/ecs/<descriptive-name>` (e.g. `/ecs/dind`,
  `/ecs/daemon-adot-collector`, `/ecs/<CLUSTER_NAME>/host-logs`). Don't use
  `/aws/ecs/service/...` or other prefixes.
- Every container definition sets `essential` explicitly (`true` or `false`),
  even where `true` is the API default.

## Cleanup sections

Every pattern that creates AWS resources must have a `## Cleanup` section
that tears them down in reverse order of creation: stop/delete the
service/daemon, deregister task definitions, remove S3 objects/buckets if
created, then delete the IAM role (detach/delete policies first). A pattern
with no teardown instructions is incomplete.

## ECR repositories

If a pattern's deployment steps push an image to ECR (building a custom
image, tagging `mi-init`, `docker:cli`, etc.), the README must include an
explicit `aws ecr create-repository --region "${AWS_REGION}" --repository-name ...`
step before the first `docker push`. Don't assume the repository already
exists or that `docker push` will create it — ECR repos are not
auto-created on push and the deployment will fail with `RepositoryNotFoundException`
if this step is skipped.

Give the repo name its own `export ECR_REPO_NAME="<...>"` line, and build any
derived URI from it (`export ECR_REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"`).
Never embed a literal placeholder (`<your-repo>`) inside an otherwise-computed
`export` line — if a placeholder isn't on its own line as an obvious `export
VAR="<placeholder>"`, it's easy to miss during substitution and will get
baked into a task definition as literal text, which fails at
`docker build`/`docker push` time with `invalid reference format` since `<`
and `>` aren't valid in an image reference.

Add a matching `aws ecr delete-repository --region "${AWS_REGION}" --repository-name ... --force` to the pattern's `## Cleanup` section for every repository the pattern itself created.

Distinguish two categories of ECR repository, and don't treat them the same:
- **Infrastructure repos** — fixed, literal repository names the pattern needs
  in order to run at all (e.g. `mi-init`'s own `mi-init` repo, `dind`'s `docker`
  repo holding the `docker:cli` + `ecr-login` helper image referenced directly
  in a task definition's `image` field). These are always safe to create and
  delete in `## Deployment`/`## Cleanup` — the pattern owns their full
  lifecycle.
- **Destination repos** — a repo named via a user-supplied placeholder
  (`${ECR_REPO_NAME}` or similar) that receives output the running task
  builds and pushes at runtime, as in `dind`. This is very likely an existing
  application repository the user already owns. Offer creation as an
  optional step ("if you don't have one yet"), but never unconditionally
  `aws ecr delete-repository --force` it in Cleanup — that's a destructive
  action against a resource the pattern doesn't own. Comment it out or gate
  it with an explicit warning instead.
