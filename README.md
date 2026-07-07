# terraform-aws-ecs-module

Creates an ECS (Fargate) cluster, task execution/task IAM roles, a task
definition, the service itself, ALB target-group registration, CPU-based
autoscaling, and a CloudWatch high-CPU alarm.

## Security & credential handling

- **Execution role**: gets the AWS-managed
  `AmazonECSTaskExecutionRolePolicy` plus an inline policy scoped to
  **exactly one** Secrets Manager ARN (`db_secret_arn`) — no wildcards.
- **Task role**: kept separate from the execution role, for permissions the
  running application itself needs (currently empty — attach policies to
  `aws_iam_role.task` as the app grows).
- **DB credentials**: pulled out of the Secrets Manager secret key-by-key
  (`:username::`, `:password::`) into normal env vars (`DB_USER`,
  `DB_PASSWORD`) — the app never has to parse a JSON blob.
- **DB host/port/name**: passed as plain (non-secret) environment
  variables — safe, since RDS is only reachable from the ECS security
  group.

## Usage

```hcl
module "ecs" {
  source = "git::https://github.com/<YOUR_GITHUB_ORG>/terraform-aws-ecs-module.git?ref=main"

  project_name = "hotel-bookings"
  environment  = "dev"
  common_tags  = { Project = "hotel-bookings", Environment = "dev" }

  private_subnet_ids = module.vpc.private_subnet_ids
  ecs_sg_id          = module.sg[1].sg_id
  target_group_arn   = module.alb.target_group_arn

  container_image = "public.ecr.aws/nginx/nginx:1.27"
  container_port  = 80
  task_cpu        = 256
  task_memory     = 512
  desired_count   = 1
  min_capacity    = 1
  max_capacity    = 2

  db_secret_arn = module.rds.secret_arn
  db_host       = module.rds.db_address
  db_port       = module.rds.db_port
  db_name       = "bookings"
}
```

## Inputs

| Name                  | Type       | Default                                    | Description                                        |
|-------------------------|------------|---------------------------------------------|-------------------------------------------------------|
| `project_name`             | string      | –                                             | Used in resource naming and tags.                        |
| `environment`                | string      | –                                             | e.g. `dev`, `prod`. Controls log retention (14 vs 90 days).|
| `common_tags`                  | map(any)     | `{}`                                          | Tags applied to every resource.                              |
| `private_subnet_ids`               | list(any)      | –                                             | Subnets the Fargate tasks run in.                                |
| `ecs_sg_id`                          | string          | –                                             | Security group attached to the tasks.                                |
| `target_group_arn`                     | string          | –                                             | ALB target group to register tasks with.                                |
| `container_image`                        | string          | `public.ecr.aws/nginx/nginx:1.27`               | Pinned image tag — never `:latest`.                                        |
| `container_port`                            | number          | `8080`                                            | Port the container listens on.                                               |
| `task_cpu` / `task_memory`                     | number          | `256` / `512`                                       | Fargate task sizing.                                                            |
| `desired_count`                                   | number          | `1`                                                    | Baseline task count.                                                              |
| `min_capacity` / `max_capacity`                       | number          | `1` / `2`                                               | Autoscaling bounds (target-tracking on CPU, target 60%).                              |
| `db_secret_arn`                                          | string          | –                                                          | ARN of the RDS master-user secret.                                                       |
| `db_host` / `db_port` / `db_name`                            | string/number/string | `""` / `5432` / `bookings`                              | Passed to the container as plain env vars.                                                |
| `ecs_tags`                                                     | map(any)         | `{}`                                                          | Extra tags merged onto ECS resources.                                                        |

## Outputs

| Name             | Description                |
|--------------------|-------------------------------|
| `cluster_name`         | Name of the ECS cluster.          |
| `service_name`           | Name of the ECS service.            |

## Notes

- The container health check uses `nc -z` as a placeholder because the
  `nginx` demo image has no `curl`/`wget`. Replace it with
  `curl -f http://localhost:<port>/health` once a real application image
  is deployed.
- `deployment_minimum_healthy_percent = 100` /
  `deployment_maximum_percent = 200` gives a full-capacity rolling deploy
  with no downtime, at the cost of briefly running up to 2x the task count
  during deploys.
