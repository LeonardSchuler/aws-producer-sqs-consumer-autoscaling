from flask import Flask, render_template, request, redirect, url_for
from flask_socketio import SocketIO, emit
import boto3
import os
import logging
import threading

app = Flask(__name__, template_folder="./")
app.logger.setLevel(logging.INFO)
socketio = SocketIO(app, cors_allowed_origins="*")

# Initialize AWS clients
region = "eu-central-1"
ec2_client = boto3.client("ec2", region_name=os.getenv("AWS_REGION", region))
sqs_client = boto3.client("sqs", region_name=os.getenv("AWS_REGION", region))
ssm_client = boto3.client("ssm", region_name=os.getenv("AWS_REGION", region))


# Global variable to track if the background task is running
background_task = None


@app.route("/", methods=["GET", "POST"])
def index():
    if request.method == "POST":
        sleep_time = request.form.get("sleep_time")
        wait_time = request.form.get("wait_time")
        if sleep_time:
            ssm_client.put_parameter(
                Name="/app/producer/sleep_time",
                Value=sleep_time,
                Type="String",
                Overwrite=True,
            )
        if wait_time:
            ssm_client.put_parameter(
                Name="/app/producer/wait_time",
                Value=wait_time,
                Type="String",
                Overwrite=True,
            )
        return redirect(url_for("index"))

    metrics = get_metrics()
    return render_template("index.html", **metrics)


@socketio.on("connect")
def handle_connect(auth):
    emit("update", get_metrics(), broadcast=True)
    start_background_task()


def start_background_task():
    global background_task
    if background_task is None or not background_task.is_alive():
        background_task = threading.Thread(target=update_metrics)
        background_task.daemon = True
        background_task.start()


def get_metrics():
    # Get producer and consumer instance counts
    producer_instances = ec2_client.describe_instances(
        Filters=[{"Name": "tag:Name", "Values": ["Producer"]}]
    )
    consumer_instances = ec2_client.describe_instances(
        Filters=[{"Name": "tag:Name", "Values": ["Consumer"]}]
    )

    producer_count = sum(
        len(reservation["Instances"])
        for reservation in producer_instances["Reservations"]
        if any(
            instance["State"]["Name"] == "running"
            for instance in reservation["Instances"]
        )
    )
    consumer_count = sum(
        len(reservation["Instances"])
        for reservation in consumer_instances["Reservations"]
        if any(
            instance["State"]["Name"] == "running"
            for instance in reservation["Instances"]
        )
    )

    # Get SQS queue message count
    queue_url = os.getenv("SQS_QUEUE_URL")
    queue_attributes = sqs_client.get_queue_attributes(
        QueueUrl=queue_url, AttributeNames=["ApproximateNumberOfMessages"]
    )
    message_count = queue_attributes["Attributes"].get(
        "ApproximateNumberOfMessages", "0"
    )

    return {
        "producer_count": producer_count,
        "consumer_count": consumer_count,
        "sqs_message_count": message_count,
        "sleep_time": get_ssm_parameter("/app/producer/sleep_time"),
        "wait_time": get_ssm_parameter("/app/producer/wait_time"),
    }


def get_ssm_parameter(name):
    try:
        response = ssm_client.get_parameter(Name=name)
        return response["Parameter"]["Value"]
    except ssm_client.exceptions.ParameterNotFound:
        return "Not set"


def update_metrics():
    while True:
        socketio.sleep(10)
        metrics = get_metrics()
        app.logger.info(metrics)
        socketio.emit("update", metrics)


if __name__ == "__main__":
    socketio.run(app, host="0.0.0.0", port=80)
