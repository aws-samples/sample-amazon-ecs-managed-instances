# ECS Managed Instances CloudFormation Templates

This repository contains CloudFormation templates for deploying Amazon ECS with Managed Instances capacity provider. The templates demonstrate how to set up a complete ECS infrastructure with managed instances for containerized workloads.

## Templates Overview

### 1. `nested-stack-coordinator.json`
**Master Template** - Orchestrates the deployment of VPC and ECS stacks using nested stacks.

- **Purpose**: Coordinates the deployment of infrastructure and ECS resources
- **Type**: Master/Parent template
- **Dependencies**: Requires S3 URLs for child templates

**Parameters:**
- `VpcStackTemplateUrl`: S3 URL for the VPC stack template
- `EcsStackTemplateUrl`: S3 URL for the ECS stack template

**Resources Created:**
- VPC Stack (nested)
- ECS Stack (nested) with VPC dependencies

### 2. `vpc-stack.json`
**VPC Infrastructure Stack** - Creates the networking foundation for ECS Managed Instances.

- **Purpose**: Provisions VPC, subnets, and networking components
- **CIDR Block**: 10.0.0.0/16
- **Multi-AZ**: Deploys across multiple availability zones

**Resources Created:**
- VPC with DNS support enabled
- Public subnets (2 AZs)
- Private subnets (2 AZs)
- Internet Gateway
- NAT Gateways
- Route tables and associations
- Security groups

**Outputs:**
- VPC ID
- Private Subnet IDs
- Public Subnet IDs

### 3. `ecs-stack.json`
**ECS Resources Stack** - Creates ECS cluster, capacity provider, and services for Managed Instances.

- **Purpose**: Deploys ECS cluster with Managed Instances capacity provider
- **Capacity Provider**: Custom managed instances capacity provider
- **Services**: Two ECS services with different configurations

**Key Components:**

#### ECS Cluster
- Cluster with Managed Instances capacity provider
- Supports both FARGATE and Managed Instances

#### Capacity Provider
- **Name**: ManagedInstancesCP
- **Type**: AWS::ECS::CapacityProvider
- Configured for managed instances workloads

#### Task Definitions
- **Task 1**: 1024 CPU, 9500 MB memory
- **Task 2**: 1024 CPU, 5500 MB memory
- **Compatibility**: MANAGED_INSTANCES
- **Network Mode**: awsvpc

#### ECS Services
- **Service 1**: Uses ManagedInstancesCP capacity provider
- **Service 2**: Uses ManagedInstancesCP capacity provider
- Both services configured with network configuration for private subnets

## Deployment Instructions

### Prerequisites
1. User with CloudFormation, ECS and EC2 permissions
2. AWS CLI

### Steps

1. **Download the CloudFormation templates from GitHub repository**
```bash
git clone https://github.com/aws-samples/sample-amazon-ecs-managed-instances
cd sample-amazon-ecs-managed-instances/cfn-templates
```

2. **Create a S3 bucket and push templates**
```bash
export AWS_REGION=us-west-2
export BUCKET_NAME=ecs-managed-instances-templates-$(date +%s%N | sha256sum | head -c 6)

aws s3 mb s3://$BUCKET_NAME --region $AWS_REGION
```

3. **Push the CloudFormation templates to S3 bucket**
```bash
aws s3 cp vpc-stack.json s3://$BUCKET_NAME
aws s3 cp ecs-stack.json s3://$BUCKET_NAME
aws s3 cp nested-stack-coordinator.json s3://$BUCKET_NAME
```

4. **Create CloudFormation stack**
```bash
aws cloudformation create-stack \
     --stack-name managed-instances-coordinator \
     --template-body file://nested-stack-coordinator.json \
     --parameters ParameterKey=VpcStackTemplateUrl,ParameterValue=https://$BUCKET_NAME.s3.amazonaws.com/vpc-stack.json \
                  ParameterKey=EcsStackTemplateUrl,ParameterValue=https://$BUCKET_NAME.s3.amazonaws.com/ecs-stack.json \
     --capabilities CAPABILITY_NAMED_IAM \
     --region $AWS_REGION
```

### Resources Created
- 1 ECS cluster with a Managed Instance Capacity Provider
- 2 ECS Services:
  - ManagedInstancesService1: 1 vCPU, 5.5GB memory per task
  - ManagedInstancesService2: 1 vCPU, 9.5GB memory per task
- 4 total tasks (2 per service) distributed across AZs
- 2 Managed EC2 instances in the Managed Instances Capacity Provider

## Architecture

The templates create the following architecture:

```
┌─────────────────────────────────────────────────────────────┐
│                        VPC (10.0.0.0/16)                   │
│                                                             │
│  ┌─────────────────┐              ┌─────────────────┐      │
│  │   Public AZ-1   │              │   Public AZ-2   │      │
│  │   NAT Gateway   │              │   NAT Gateway   │      │
│  └─────────────────┘              └─────────────────┘      │
│           │                                 │               │
│  ┌─────────────────┐              ┌─────────────────┐      │
│  │  Private AZ-1   │              │  Private AZ-2   │      │
│  │ ECS Managed     │              │ ECS Managed     │      │
│  │ Instances       │              │ Instances       │      │
│  └─────────────────┘              └─────────────────┘      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Key Features

- **Managed Instances**: Utilizes ECS Managed Instances for cost-effective container hosting
- **Multi-AZ Deployment**: Resources distributed across multiple availability zones
- **Nested Stacks**: Modular approach for easier management and reusability
- **Network Isolation**: Private subnets for ECS tasks with NAT gateway for outbound access
- **Capacity Provider Strategy**: Configurable capacity provider with different weights

## Demo Walkthrough

After deployment, you can demonstrate ECS Managed Instances intelligent resource management:

### Scale Down Service to Observe Optimization

Scale ManagedInstancesService1 to 0 tasks to create resource inefficiency:

```bash
aws ecs update-service \
  --cluster $(aws cloudformation describe-stacks \
    --stack-name managed-instances-coordinator \
    --query 'Stacks[0].Outputs[?OutputKey==`EcsClusterId`].OutputValue' \
    --output text) \
  --service ManagedInstancesService1 \
  --desired-count 0 \
  --region $AWS_REGION
```

**What happens:**
1. ECS detects underutilized instances (r5a.large running only 5.5GB tasks)
2. Capacity Provider drains one underutilized instance
3. Tasks consolidate onto remaining instance
4. Empty instance is automatically terminated
5. ECS rebalances across AZs with right-sized instances (r7a.medium)

This demonstrates:
- **Continuous optimization**: Automatic detection and remediation of resource inefficiency
- **Availability-first approach**: Gradual draining to maintain service availability
- **Right-sizing**: Provisioning optimal instance types based on actual workload requirements
- **AZ rebalancing**: Maintaining high availability across availability zones

## Customization

### Modifying Instance Types
The capacity provider configuration can be customized by modifying the `ManagedInstancesCP` resource in `ecs-stack.json`.

### Scaling Configuration
Adjust the capacity provider strategy weights in the ECS services to control task distribution.

### Network Configuration
Modify CIDR blocks and subnet configurations in `vpc-stack.json` to match your network requirements.

## Cleanup

To delete the resources:

```bash
# Delete CloudFormation stacks
aws cloudformation delete-stack \
     --stack-name managed-instances-coordinator \
     --region $AWS_REGION
     
# Delete CloudFormation templates and S3 bucket
aws s3 rb s3://$BUCKET_NAME --region $AWS_REGION --force
```

## Support

For issues or questions:
1. Check AWS CloudFormation documentation for ECS Managed Instances
2. Review AWS ECS capacity provider documentation
3. Verify IAM permissions for ECS and EC2 services

## Notes

- Ensure your AWS account has sufficient service limits for EC2 instances
- The templates create resources that may incur AWS charges
- Review security group configurations before deploying to production
- Consider implementing additional monitoring and logging for production workloads
