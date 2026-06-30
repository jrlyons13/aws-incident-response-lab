import json
import os
import re
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

INSTANCE_ID_PATTERN = re.compile(r"^i-[0-9a-f]{8,17}$")
INCIDENT_TYPE = "SimulatedCryptoJacking"


def _get_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise ValueError(f"Missing required environment variable: {name}")
    return value


def _validate_instance_id(instance_id: str) -> str:
    if not instance_id:
        raise ValueError("instance_id is required")

    instance_id = instance_id.strip()
    if not INSTANCE_ID_PATTERN.match(instance_id):
        raise ValueError(
            f"Invalid instance_id format: {instance_id!r}. Expected something like i-0123456789abcdef0"
        )

    return instance_id


def _parse_instance_id(event) -> str | None:
    if not isinstance(event, dict):
        raise ValueError("Event payload must be a JSON object")

    if event.get("instance_id"):
        return _validate_instance_id(event["instance_id"])

    records = event.get("Records", [])
    if records and records[0].get("EventSource") == "aws:sns":
        message_raw = records[0].get("Sns", {}).get("Message", "")
        try:
            message = json.loads(message_raw)
        except json.JSONDecodeError:
            message = {}

        if message.get("event") == "ec2_instance_isolated" or message.get("final_status"):
            return None

        trigger = message.get("Trigger", {})
        for dimension in trigger.get("Dimensions", []):
            if dimension.get("name") == "InstanceId" and dimension.get("value"):
                return _validate_instance_id(dimension["value"])

        alarm_state = message.get("NewStateValue")
        alarm_name = message.get("AlarmName")
        if alarm_name and alarm_state and alarm_state != "ALARM":
            return None

    fallback = os.environ.get("TARGET_INSTANCE_ID")
    if fallback:
        return _validate_instance_id(fallback)

    raise ValueError(
        "Could not determine instance_id from event. Provide instance_id, an SNS alarm payload, or TARGET_INSTANCE_ID."
    )


def _get_attached_volume_ids(ec2, instance_id: str) -> list[str]:
    response = ec2.describe_instances(InstanceIds=[instance_id])
    reservations = response.get("Reservations", [])
    if not reservations:
        raise ValueError(f"Instance not found: {instance_id}")

    instances = reservations[0].get("Instances", [])
    if not instances:
        raise ValueError(f"Instance not found: {instance_id}")

    volume_ids = []
    for block_device in instances[0].get("BlockDeviceMappings", []):
        volume_id = block_device.get("Ebs", {}).get("VolumeId")
        if volume_id:
            volume_ids.append(volume_id)

    if not volume_ids:
        raise ValueError(f"No attached EBS volumes found for instance {instance_id}")

    return volume_ids


def _create_tagged_snapshots(ec2, instance_id: str, volume_ids: list[str], timestamp: str) -> list[dict]:
    snapshots = []

    for volume_id in volume_ids:
        snapshot_response = ec2.create_snapshot(
            VolumeId=volume_id,
            Description=f"IR lab snapshot for {instance_id} volume {volume_id}",
            TagSpecifications=[
                {
                    "ResourceType": "snapshot",
                    "Tags": [
                        {"Key": "Incident", "Value": "true"},
                        {"Key": "IncidentType", "Value": INCIDENT_TYPE},
                        {"Key": "InstanceId", "Value": instance_id},
                        {"Key": "VolumeId", "Value": volume_id},
                        {"Key": "CreatedBy", "Value": "IncidentResponseLab"},
                        {"Key": "Timestamp", "Value": timestamp},
                    ],
                }
            ],
        )
        snapshots.append(
            {
                "snapshot_id": snapshot_response["SnapshotId"],
                "volume_id": volume_id,
            }
        )

    return snapshots


def _disassociate_instance_profile(ec2, instance_id: str) -> str:
    associations = ec2.describe_iam_instance_profile_associations(
        Filters=[{"Name": "instance-id", "Values": [instance_id]}]
    ).get("IamInstanceProfileAssociations", [])

    if not associations:
        return "no_iam_instance_profile_found"

    for association in associations:
        ec2.disassociate_iam_instance_profile(AssociationId=association["AssociationId"])

    return "disassociated_iam_instance_profile"


def handler(event, context):
    instance_id = _parse_instance_id(event)
    if instance_id is None:
        return {
            "statusCode": 200,
            "body": json.dumps({"message": "Ignored non-alarm SNS notification"}),
        }

    quarantine_sg_id = _get_env("QUARANTINE_SG_ID")
    sns_topic_arn = _get_env("SNS_TOPIC_ARN")
    region = os.environ.get("AWS_REGION_NAME") or os.environ.get("AWS_REGION", "us-east-1")

    ec2 = boto3.client("ec2", region_name=region)
    sns = boto3.client("sns", region_name=region)

    timestamp = datetime.now(timezone.utc).isoformat()
    actions_taken = []
    snapshot_ids = []
    iam_profile_result = "not_attempted"
    final_status = "failed"

    try:
        volume_ids = _get_attached_volume_ids(ec2, instance_id)
        actions_taken.append("discovered_attached_volumes")

        snapshots = _create_tagged_snapshots(ec2, instance_id, volume_ids, timestamp)
        snapshot_ids = [snapshot["snapshot_id"] for snapshot in snapshots]
        actions_taken.append("created_tagged_ebs_snapshots")

        iam_profile_result = _disassociate_instance_profile(ec2, instance_id)
        actions_taken.append(iam_profile_result)

        ec2.modify_instance_attribute(
            InstanceId=instance_id,
            Groups=[quarantine_sg_id],
        )
        actions_taken.append("attached_quarantine_security_group")

        notification = {
            "event": "ec2_instance_isolated",
            "incident_type": INCIDENT_TYPE,
            "instance_id": instance_id,
            "snapshot_ids": snapshot_ids,
            "snapshots": snapshots,
            "iam_profile_removal_result": iam_profile_result,
            "quarantine_security_group_id": quarantine_sg_id,
            "actions_taken": actions_taken,
            "timestamp_utc": timestamp,
            "final_status": "isolated",
        }

        sns.publish(
            TopicArn=sns_topic_arn,
            Subject=f"EC2 Isolation Alert: {instance_id}",
            Message=json.dumps(notification, indent=2),
        )
        actions_taken.append("published_sns_notification")
        final_status = "isolated"

        return {
            "statusCode": 200,
            "body": json.dumps(
                {
                    "message": "Instance isolated successfully",
                    "incident_type": INCIDENT_TYPE,
                    "instance_id": instance_id,
                    "snapshot_ids": snapshot_ids,
                    "iam_profile_removal_result": iam_profile_result,
                    "quarantine_security_group_id": quarantine_sg_id,
                    "actions_taken": actions_taken,
                    "timestamp_utc": timestamp,
                    "final_status": final_status,
                }
            ),
        }

    except ClientError as error:
        error_code = error.response["Error"].get("Code", "Unknown")
        error_message = error.response["Error"].get("Message", str(error))
        final_status = "failed"

        failure_message = {
            "event": "ec2_instance_isolated",
            "incident_type": INCIDENT_TYPE,
            "instance_id": instance_id,
            "snapshot_ids": snapshot_ids,
            "iam_profile_removal_result": iam_profile_result,
            "quarantine_security_group_id": quarantine_sg_id,
            "actions_taken": actions_taken,
            "timestamp_utc": timestamp,
            "final_status": final_status,
            "error": f"{error_code}: {error_message}",
        }

        try:
            sns.publish(
                TopicArn=sns_topic_arn,
                Subject=f"EC2 Isolation Failed: {instance_id}",
                Message=json.dumps(failure_message, indent=2),
            )
        except ClientError:
            pass

        raise RuntimeError(
            f"Failed to isolate instance {instance_id}: {error_code} - {error_message}"
        ) from error
