import json
import os
import urllib.error
import urllib.request

import boto3
from botocore.exceptions import ClientError


def _get_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise ValueError(f"Missing required environment variable: {name}")
    return value


def _get_webhook_url() -> str:
    region = os.environ.get("AWS_REGION_NAME") or os.environ.get("AWS_REGION", "us-east-1")
    secret_id = _get_env("SLACK_WEBHOOK_SECRET_ARN")

    client = boto3.client("secretsmanager", region_name=region)
    response = client.get_secret_value(SecretId=secret_id)
    webhook_url = response.get("SecretString", "").strip()

    if not webhook_url:
        raise ValueError("Slack webhook secret is empty. Add the webhook URL in Secrets Manager.")

    return webhook_url


def _instance_id_from_alarm(message: dict) -> str:
    trigger = message.get("Trigger", {})
    for dimension in trigger.get("Dimensions", []):
        if dimension.get("name") == "InstanceId" and dimension.get("value"):
            return dimension["value"]
    return "unknown"


def _format_alarm_message(message: dict) -> str:
    state = message.get("NewStateValue", "UNKNOWN")
    alarm_name = message.get("AlarmName", "unknown-alarm")
    instance_id = _instance_id_from_alarm(message)
    trigger = message.get("Trigger", {})
    metric_name = trigger.get("MetricName", "unknown-metric")
    threshold = trigger.get("Threshold", "unknown")
    comparison = trigger.get("ComparisonOperator", "unknown")
    reason = message.get("NewStateReason", "No reason provided.")
    timestamp = message.get("StateChangeTime", message.get("Timestamp", "unknown"))

    if state == "ALARM":
        header = "CloudWatch Alarm Triggered"
    elif state == "OK":
        header = "CloudWatch Alarm Cleared"
    else:
        header = f"CloudWatch Alarm Update ({state})"

    return (
        f"*{header}*\n"
        f"Alarm:     {alarm_name}\n"
        f"State:     {state}\n"
        f"Instance:  {instance_id}\n"
        f"Metric:    {metric_name} {comparison} {threshold}\n"
        f"Reason:    {reason}\n"
        f"Time:      {timestamp}"
    )


def _format_isolation_message(message: dict) -> str:
    final_status = message.get("final_status", "unknown")
    if final_status == "isolated":
        header = "Isolation Has Occurred"
    elif final_status == "failed":
        header = "Isolation Failed"
    else:
        header = "Isolation Update"

    snapshot_ids = message.get("snapshot_ids") or []
    snapshots_text = ", ".join(snapshot_ids) if snapshot_ids else "none"

    lines = [
        f"*{header}*",
        f"Incident Type: {message.get('incident_type', 'unknown')}",
        f"Instance ID:   {message.get('instance_id', 'unknown')}",
        f"Snapshots:     {snapshots_text}",
        f"IAM Profile:   {message.get('iam_profile_removal_result', 'unknown')}",
        f"Quarantine SG: {message.get('quarantine_security_group_id', 'unknown')}",
        f"Status:        {final_status}",
        f"Time (UTC):    {message.get('timestamp_utc', 'unknown')}",
    ]

    error = message.get("error")
    if error:
        lines.append(f"Error:         {error}")

    return "\n".join(lines)


def _format_generic_message(subject: str, message_raw: str) -> str:
    return (
        "*SNS Notification Received*\n"
        f"Subject: {subject or 'none'}\n"
        f"Message: {message_raw}"
    )


def _build_slack_text(subject: str, message_raw: str) -> str:
    try:
        message = json.loads(message_raw)
    except json.JSONDecodeError:
        return _format_generic_message(subject, message_raw)

    if not isinstance(message, dict):
        return _format_generic_message(subject, message_raw)

    if message.get("event") == "ec2_instance_isolated" or message.get("final_status"):
        return _format_isolation_message(message)

    if message.get("AlarmName") and message.get("NewStateValue"):
        return _format_alarm_message(message)

    return _format_generic_message(subject, message_raw)


def _post_to_slack(webhook_url: str, text: str) -> None:
    payload = json.dumps({"text": text}).encode("utf-8")
    request = urllib.request.Request(
        webhook_url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            if response.status >= 400:
                raise RuntimeError(f"Slack webhook returned HTTP {response.status}")
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Slack webhook HTTP {error.code}: {body}") from error


def handler(event, context):
    records = event.get("Records", [])
    if not records:
        raise ValueError("Expected SNS event with Records")

    sns_record = records[0].get("Sns", {})
    subject = sns_record.get("Subject", "")
    message_raw = sns_record.get("Message", "")

    slack_text = _build_slack_text(subject, message_raw)
    webhook_url = _get_webhook_url()
    _post_to_slack(webhook_url, slack_text)

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "message": "Slack notification sent",
                "subject": subject,
            }
        ),
    }
