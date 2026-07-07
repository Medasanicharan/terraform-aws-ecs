## project ##

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "common_tags" {
  type    = map(any)
  default = {}
}

## ecs ##

variable "private_subnet_ids" {
  type = list(any)
}

variable "ecs_sg_id" {
  type = string
}

variable "target_group_arn" {
  type = string
}

variable "container_image" {
  type    = string
  default = "public.ecr.aws/nginx/nginx:1.27" # pinned tag, never :latest
}

variable "container_port" {
  type    = number
}

variable "task_cpu" {
  type    = number
  default = 256
}

variable "task_memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "min_capacity" {
  type    = number
  default = 1
}

variable "max_capacity" {
  type    = number
  default = 2
}

variable "db_secret_arn" {
  description = "ARN of the RDS master-user secret (AWS-managed, contains only username + password)."
  type        = string
}

## Needed because the managed RDS secret does not bundle host/port/dbname. ##

variable "db_host" {
  description = "RDS endpoint address. Not sensitive on its own - the DB is unreachable from anywhere except the ECS security group."
  type        = string
  default     = ""
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  type    = string
  default = "bookings"
}

variable "ecs_tags" {
  type    = map(any)
  default = {}
}
