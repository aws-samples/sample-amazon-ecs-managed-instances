# Amazon ECS Managed Instances Samples

Sample code and patterns for Amazon ECS Managed Instances.

## Background

[Amazon ECS Managed Instances](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/managed-instances-capacity-providers-concept.html) is a capacity provider that gives you EC2-level flexibility (instance types, reserved capacity, security/observability configuration) while AWS handles instance provisioning, OS/software patching, scaling, and lifecycle management on your behalf. See the [announcement post](https://aws.amazon.com/about-aws/whats-new/2025/09/amazon-ecs-managed-instances) for more background.

[ECS Managed Daemons](https://aws.amazon.com/about-aws/whats-new/2026/04/amazon-ecs-managed-daemons/) extend Managed Instances with a `create-daemon`/`update-daemon` API that runs exactly one task per container instance across a capacity provider, for cross-cutting agents like log shippers, metrics collectors, and security monitoring (the [announcement blog](https://aws.amazon.com/blogs/aws/announcing-managed-daemon-support-for-amazon-ecs-managed-instances/) has more detail). The `adot` and `fluentbit` patterns in this repo are built as managed daemons.

## Contents

### [patterns](./patterns/)

A growing collection of task definitions, configs, and utilities for operating ECS Managed Instances clusters day to day. Samples include: host metrics, host log collection, an init container for injecting instance metadata into daemon configs, privileged host access for debugging, and Docker-in-Docker builds.

### [cfn-templates](./cfn-templates/)

CloudFormation templates accompanying the blog post [Deep dive: Amazon ECS Managed Instances provisioning and optimization](https://aws.amazon.com/blogs/containers/deep-dive-amazon-ecs-managed-instances-provisioning-and-optimization/). Deploys a VPC, an ECS cluster with a Managed Instances capacity provider, and two demo services. This directory is not under active development; changes are limited to breaking-change and security fixes.

## Contributing

Contributions are welcome. See [CONTRIBUTING](./CONTRIBUTING.md) for how to report issues and submit pull requests. This project has adopted the [Amazon Open Source Code of Conduct](./CODE_OF_CONDUCT.md).

## License

See [LICENSE](./LICENSE).
