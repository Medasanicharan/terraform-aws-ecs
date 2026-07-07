## cluster ##

resource "aws_ecs_cluster" "this" {
  name = "${local.resource_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.common_tags, var.ecs_tags)
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.resource_name}"
  retention_in_days = var.environment == "prod" ? 90 : 14

  tags = merge(var.common_tags, var.ecs_tags)
}

## iam — execution role (pulls image / writes logs / reads secrets) ##

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.resource_name}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = merge(var.common_tags, var.ecs_tags)
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

## Scoped to exactly the one RDS secret ARN — least privilege, no wildcard.
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${local.resource_name}-execution-secrets-policy"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

## iam — task role (used BY the running app, kept separate from execution) ##

resource "aws_iam_role" "task" {
  name               = "${local.resource_name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = merge(var.common_tags, var.ecs_tags)
}

## task definition ##

resource "aws_ecs_task_definition" "app" {
  family                   = "${local.resource_name}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = var.container_image
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      ## Each secret key is pulled out individually with the `:key::`
      ## suffix, giving the app normal, directly-usable env vars instead of
      ## a raw JSON blob it would have to parse itself.
      secrets = [
        {
          name      = "DB_USER"
          valueFrom = "${var.db_secret_arn}:username::"
        },
        {
          name      = "DB_PASSWORD"
          valueFrom = "${var.db_secret_arn}:password::"
        }
      ]

      ## host/port/dbname are not secret on their own (RDS is unreachable
      ## from anywhere except this task's SG anyway), so they're passed as
      ## plain, non-sensitive environment variables.
      environment = [
        {
          name  = "DB_HOST"
          value = var.db_host
        },
        {
          name  = "DB_PORT"
          value = tostring(var.db_port)
        },
        {
          name  = "DB_NAME"
          value = var.db_name
        }
      ]

      ## Container-level health check lets ECS detect and cycle an
      ## unhealthy task on its own, independent of ALB deregistration.
      ## NOTE: the placeholder nginx image has no curl/wget; `nc` just
      ## confirms the process is listening. Swap for a real HTTP probe
      ## (`curl -f http://localhost:PORT/health`) once a real app image
      ## replaces the nginx placeholder.
      healthCheck = {
        command     = ["CMD-SHELL", "nc -z localhost ${var.container_port} || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])

  tags = merge(var.common_tags, var.ecs_tags)
}

## service ##

resource "aws_ecs_service" "app" {
  name            = "${local.resource_name}-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "app"
    container_port   = var.container_port
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  tags = merge(var.common_tags, var.ecs_tags)
}

## autoscaling ##

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.resource_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

## Basic service-level CPU alarm.

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${local.resource_name}-ecs-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ECS service CPU above 80% for 15 minutes"

  dimensions = {
    ClusterName = aws_ecs_cluster.this.name
    ServiceName = aws_ecs_service.app.name
  }

  tags = merge(var.common_tags, var.ecs_tags)
}
