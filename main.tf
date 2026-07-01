terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "http" "myip" {
  url = "https://checkip.amazonaws.com"
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ssh_cidr = coalesce(var.allowed_ssh_cidr, "${chomp(data.http.myip.response_body)}/32")
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "Normal application security group for the lab EC2 instance"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-app-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_ssh" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = local.ssh_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  description       = "SSH from operator IP"
}

resource "aws_vpc_security_group_ingress_rule" "app_http" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "HTTP from anywhere"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound traffic"
}

resource "aws_security_group" "quarantine" {
  name        = "${var.project_name}-quarantine-sg"
  description = "Quarantine security group with no inbound or outbound access"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-quarantine-sg"
  }
}

resource "tls_private_key" "ec2_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ec2_key" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ec2_key.public_key_openssh

  tags = {
    Name = "${var.project_name}-key"
  }
}

resource "local_file" "private_key" {
  content         = tls_private_key.ec2_key.private_key_pem
  filename        = "${path.module}/${var.project_name}-key.pem"
  file_permission = "0400"
}

resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ec2-role"
  }
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = {
    Name = "${var.project_name}-ec2-profile"
  }
}

resource "aws_instance" "lab" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = aws_key_pair.ec2_key.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    dnf install -y httpd amazon-ssm-agent
    systemctl enable httpd amazon-ssm-agent
    systemctl start httpd amazon-ssm-agent
    echo "<h1>IR Isolation Lab</h1>" > /var/www/html/index.html
  EOF

  tags = {
    Name = "${var.project_name}-lab-instance"
  }
}

resource "aws_sns_topic" "incident" {
  name = "${var.project_name}-incident-notifications"

  tags = {
    Name = "${var.project_name}-incident-notifications"
  }
}

resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-lambda-role"
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_isolate" {
  name = "${var.project_name}-lambda-isolate-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeInstances"
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Sid      = "DescribeVolumes"
        Effect   = "Allow"
        Action   = "ec2:DescribeVolumes"
        Resource = "*"
      },
      {
        Sid    = "CreateSnapshots"
        Effect = "Allow"
        Action = "ec2:CreateSnapshot"
        Resource = [
          "arn:aws:ec2:${var.aws_region}:*:volume/*",
          "arn:aws:ec2:${var.aws_region}:*:snapshot/*",
        ]
      },
      {
        Sid      = "TagSnapshots"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "arn:aws:ec2:${var.aws_region}:*:snapshot/*"
      },
      {
        Sid      = "DescribeIamInstanceProfileAssociations"
        Effect   = "Allow"
        Action   = "ec2:DescribeIamInstanceProfileAssociations"
        Resource = "*"
      },
      {
        Sid      = "DisassociateIamInstanceProfile"
        Effect   = "Allow"
        Action   = "ec2:DisassociateIamInstanceProfile"
        Resource = "*"
      },
      {
        Sid    = "ModifyInstanceSecurityGroups"
        Effect = "Allow"
        Action = "ec2:ModifyInstanceAttribute"
        Resource = [
          "arn:aws:ec2:${var.aws_region}:*:instance/*",
          aws_security_group.app.arn,
          aws_security_group.quarantine.arn,
        ]
      },
      {
        Sid      = "PublishIncidentNotification"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.incident.arn
      }
    ]
  })
}

resource "aws_iam_role" "lambda_simulator" {
  name = "${var.project_name}-simulator-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-simulator-lambda-role"
  }
}

resource "aws_iam_role_policy_attachment" "lambda_simulator_basic" {
  role       = aws_iam_role.lambda_simulator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_simulator_ssm" {
  name = "${var.project_name}-simulator-ssm-policy"
  role = aws_iam_role.lambda_simulator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SendSSMCommand"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
        ]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:*:instance/${aws_instance.lab.id}",
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
        ]
      },
      {
        Sid      = "DescribeInstanceInformation"
        Effect   = "Allow"
        Action   = "ssm:DescribeInstanceInformation"
        Resource = "*"
      }
    ]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

data "archive_file" "simulator_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/simulator_lambda.py"
  output_path = "${path.module}/simulator_lambda.zip"
}

resource "aws_lambda_function" "isolate" {
  function_name    = "${var.project_name}-isolate-instance"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 180

  environment {
    variables = {
      QUARANTINE_SG_ID    = aws_security_group.quarantine.id
      SNS_TOPIC_ARN       = aws_sns_topic.incident.arn
      AWS_REGION_NAME     = var.aws_region
      TARGET_INSTANCE_ID  = aws_instance.lab.id
    }
  }

  tags = {
    Name = "${var.project_name}-isolate-instance"
  }
}

resource "aws_lambda_function" "simulator" {
  function_name    = "${var.project_name}-simulate-incident"
  role             = aws_iam_role.lambda_simulator.arn
  handler          = "simulator_lambda.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.simulator_lambda_zip.output_path
  source_code_hash = data.archive_file.simulator_lambda_zip.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      TARGET_INSTANCE_ID      = aws_instance.lab.id
      AWS_REGION_NAME         = var.aws_region
      STRESS_DURATION_SECONDS = tostring(var.cpu_stress_duration_seconds)
      STRESS_VCPU_COUNT       = tostring(var.cpu_stress_vcpu_count)
    }
  }

  tags = {
    Name = "${var.project_name}-simulate-incident"
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project_name}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.cpu_alarm_evaluation_periods
  datapoints_to_alarm = var.cpu_alarm_datapoints_to_alarm
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = var.cpu_alarm_period_seconds
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold
  alarm_description   = "Lab alarm for simulated cryptojacking CPU spike"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.incident.arn]

  dimensions = {
    InstanceId = aws_instance.lab.id
  }

  tags = {
    Name = "${var.project_name}-cpu-high"
  }
}

resource "aws_lambda_permission" "sns_invoke_isolate" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.isolate.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.incident.arn
}

resource "aws_sns_topic_subscription" "isolate_lambda" {
  topic_arn = aws_sns_topic.incident.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.isolate.arn

  depends_on = [aws_lambda_permission.sns_invoke_isolate]
}

resource "aws_secretsmanager_secret" "slack_webhook" {
  name        = "${var.project_name}/slack-webhook-url"
  description = "Slack incoming webhook URL for incident notifications. Set the value manually after apply."

  tags = {
    Name = "${var.project_name}-slack-webhook-url"
  }
}

resource "aws_iam_role" "lambda_slack" {
  name = "${var.project_name}-slack-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-slack-lambda-role"
  }
}

resource "aws_iam_role_policy_attachment" "lambda_slack_basic" {
  role       = aws_iam_role.lambda_slack.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_slack_secrets" {
  name = "${var.project_name}-slack-secrets-policy"
  role = aws_iam_role.lambda_slack.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSlackWebhookSecret"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.slack_webhook.arn
      }
    ]
  })
}

data "archive_file" "slack_notifier_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/slack_notifier_lambda.py"
  output_path = "${path.module}/slack_notifier_lambda.zip"
}

resource "aws_lambda_function" "slack_notifier" {
  function_name    = "${var.project_name}-slack-notifier"
  role             = aws_iam_role.lambda_slack.arn
  handler          = "slack_notifier_lambda.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.slack_notifier_lambda_zip.output_path
  source_code_hash = data.archive_file.slack_notifier_lambda_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      SLACK_WEBHOOK_SECRET_ARN = aws_secretsmanager_secret.slack_webhook.arn
      AWS_REGION_NAME          = var.aws_region
    }
  }

  tags = {
    Name = "${var.project_name}-slack-notifier"
  }
}

resource "aws_lambda_permission" "sns_invoke_slack" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.incident.arn
}

resource "aws_sns_topic_subscription" "slack_lambda" {
  topic_arn = aws_sns_topic.incident.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notifier.arn

  depends_on = [aws_lambda_permission.sns_invoke_slack]
}
