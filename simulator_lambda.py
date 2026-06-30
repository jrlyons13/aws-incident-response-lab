import json
import os
import re

import boto3

INSTANCE_ID_PATTERN = re.compile(r"^i-[0-9a-f]{8,17}$")


def _validate_instance_id(instance_id: str) -> str:
    if not instance_id:
        raise ValueError("instance_id is required")

    instance_id = instance_id.strip()
    if not INSTANCE_ID_PATTERN.match(instance_id):
        raise ValueError(
            f"Invalid instance_id format: {instance_id!r}. Expected something like i-0123456789abcdef0"
        )

    return instance_id


def handler(event, context):
    instance_id = event.get("instance_id") or os.environ.get("TARGET_INSTANCE_ID")
    instance_id = _validate_instance_id(instance_id)

    region = os.environ.get("AWS_REGION_NAME") or os.environ.get("AWS_REGION", "us-east-1")
    duration = int(os.environ.get("STRESS_DURATION_SECONDS", "360"))
    vcpu_count = int(os.environ.get("STRESS_VCPU_COUNT", "2"))

    stress_command = "\n".join(
        [
            f"echo 'Starting simulated cryptojacking CPU stress for {duration} seconds'",
            f"for i in $(seq 1 {vcpu_count}); do",
            f"  nohup bash -c 'end=$((SECONDS+{duration})); while [ $SECONDS -lt $end ]; do :; done' >/dev/null 2>&1 &",
            "done",
            "echo 'CPU stress workers started'",
        ]
    )

    ssm = boto3.client("ssm", region_name=region)
    response = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": [stress_command]},
        Comment="IR lab simulated cryptojacking CPU stress",
        TimeoutSeconds=min(duration + 120, 600),
    )

    command_id = response["Command"]["CommandId"]

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "message": "CPU stress simulation started via SSM Run Command",
                "instance_id": instance_id,
                "command_id": command_id,
                "duration_seconds": duration,
                "vcpu_count": vcpu_count,
            }
        ),
    }
