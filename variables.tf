variable "aws_region" {
  description = "AWS region for all lab resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix used for resource names."
  type        = string
  default     = "ir-isolation-lab"
}

variable "instance_type" {
  description = "EC2 instance type for the lab instance."
  type        = string
  default     = "t3.micro"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access. If null, your current public IP is detected automatically."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "CIDR block for the lab VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "cpu_alarm_threshold" {
  description = "CloudWatch CPUUtilization threshold for the lab alarm."
  type        = number
  default     = 90
}

variable "cpu_alarm_period_seconds" {
  description = "CloudWatch alarm period in seconds."
  type        = number
  default     = 60
}

variable "cpu_alarm_evaluation_periods" {
  description = "Number of evaluation periods for the CPU alarm."
  type        = number
  default     = 2
}

variable "cpu_alarm_datapoints_to_alarm" {
  description = "Number of datapoints that must breach the threshold to trigger the alarm."
  type        = number
  default     = 2
}

variable "cpu_stress_duration_seconds" {
  description = "Duration of the simulated CPU stress command sent via SSM."
  type        = number
  default     = 360
}

variable "cpu_stress_vcpu_count" {
  description = "Number of CPU stress worker loops to start on the lab instance."
  type        = number
  default     = 2
}
