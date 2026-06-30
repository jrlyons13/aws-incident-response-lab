output "ec2_instance_id" {
  description = "ID of the lab EC2 instance."
  value       = aws_instance.lab.id
}

output "ec2_public_ip" {
  description = "Public IP address of the lab EC2 instance."
  value       = aws_instance.lab.public_ip
}

output "normal_security_group_id" {
  description = "ID of the normal application security group."
  value       = aws_security_group.app.id
}

output "quarantine_security_group_id" {
  description = "ID of the quarantine security group."
  value       = aws_security_group.quarantine.id
}

output "sns_topic_arn" {
  description = "ARN of the incident notification SNS topic."
  value       = aws_sns_topic.incident.arn
}

output "simulator_lambda_name" {
  description = "Name of the simulator Lambda function."
  value       = aws_lambda_function.simulator.function_name
}

output "isolation_lambda_name" {
  description = "Name of the isolation Lambda function."
  value       = aws_lambda_function.isolate.function_name
}

output "cloudwatch_alarm_name" {
  description = "Name of the CloudWatch CPU utilization alarm."
  value       = aws_cloudwatch_metric_alarm.cpu_high.alarm_name
}

# Backward-compatible alias for v1.0 output name
output "lambda_function_name" {
  description = "Alias for isolation_lambda_name."
  value       = aws_lambda_function.isolate.function_name
}
