# ECS Managed Instances Patterns

A collection of task definitions, configs, and utilities for operating ECS
Managed Instance clusters. These patterns cover host-level observability,
build tooling, and debugging capabilities on Bottlerocket-based Managed
Instance nodes.

> **Note**: These are sample patterns and are not officially supported by Amazon Web Services.

## Patterns

| Directory | Type | Purpose |
|-----------|------|---------|
| [mi-init](./mi-init/) | Init container | Fetches config from S3 and injects instance metadata (cluster, instance ID, capacity provider) into daemon configs |
| [adot](./adot/) | Daemon | Host metrics collection (CPU, memory, disk, network, filesystem) exported to Amazon Managed Prometheus |
| [fluentbit](./fluentbit/) | Daemon | Host log collection (ECS agent, containerd, kernel) shipped to CloudWatch Logs |
| [sheltie](./sheltie/) | Service | Privileged host access task for interactive debugging via ECS Exec |
| [dind](./dind/) | Run task | Docker-in-Docker for building and pushing container images from within ECS tasks |