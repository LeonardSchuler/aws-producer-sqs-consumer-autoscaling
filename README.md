# AWS Autoscaling - Producer-SQS-Consumer

## Overview

This project sets up a producer and consumer auto scaling groups in AWS. Both scale according to the SQS queue length metric found in CloudWatch. Furthermore a monitoring dashboard web app is provided to monitor and influence the operations of the producer and consumers. It uses AWS services and Flask with Socket.IO for real-time updates every 10s.

## Directory Structure

- **webapp/**
  - `index.html` - HTML file for the monitoring dashboard.
  - `requirements.txt` - List of Python dependencies.
  - `app.py` - Flask application with Socket.IO for real-time metrics.

- **infrastructure/**
  - `main.tf` - Terraform configuration for setting up AWS infrastructure.

## Application Details

### `webapp/index.html`

This file contains the HTML for the monitoring dashboard. It includes:
- Real-time metrics updates using Socket.IO.
- A form to update the SSM parameters for producer and consumer configurations.

### `webapp/app.py`

A Flask application that:
- Renders the dashboard and handles form submissions.
- Connects to Socket.IO for real-time updates.
- Interacts with AWS services to get metrics and update SSM parameters.

### `webapp/requirements.txt`

Contains the Python dependencies for the Flask application:
- boto3
- flask
- flask-socketio



## Infrastructure Setup

### `infrastructure/main.tf`

This Terraform configuration sets up the AWS infrastructure, including:

1. **VPC and Subnets**
   - A VPC with three public subnets.

2. **Internet Gateway and Route Table**
   - An Internet Gateway and a public route table for the VPC.

3. **SQS Queue**
   - An SQS queue to handle messages from producers and consumers.

4. **SSM Parameters**
   - Parameters for configuring producer and consumer settings.

5. **IAM Roles and Policies**
   - An IAM role and policy for EC2 instances to interact with SQS and SSM.

6. **Launch Templates**
   - Launch templates for producer and consumer EC2 instances with user data to continuously send and receive messages from SQS.

7. **Auto Scaling Groups**
   - Auto Scaling Groups for producers and consumers with policies to scale based on SQS metrics.

8. **CloudWatch Alarms**
   - CloudWatch alarms to trigger scaling policies based on the number of messages in the SQS queue.

## Running the Application

1. **Deploy the Infrastructure**
   - Navigate to the `infrastructure` directory and use Terraform to deploy the infrastructure:
     ```sh
     terraform init
     terraform apply
     ```
   - Take note of the SQS_QUEUE_URL output

2. **Start the Flask Application**
   - Navigate to the `webapp` directory and create a new virtual environment:
     ```sh
     python -m venv .venv
     ```
   - Activate the environment
     ```sh
     source .venv/bin/activate
     ```
   - Install the dependencies:
     ```sh
     pip install -r requirements.txt
     ```
   - Run the Flask application with the SQS_QUEUE_URL correctly set:
     ```sh
     SQS_QUEUE_URL="" python app.py
     ```

3. **Access the Dashboard**
   - Open your web browser and navigate to `http://localhost` to view the monitoring dashboard.

4. **Optional: SSH/SSM access to individual instances**
   - Search for the instance id in the AWS management console and then execute:
   ```sh
   aws ssm start-session --target i-xxxxxxxxxxxxxxxxx
   ```
   - Inside a producer you can view its logs
   ```sh
   cat /var/log/producer.log
   ```
   Alternatively
   ```sh
   journalctl -u producer.service
   ```

## Environment Variables

Ensure the following environment variables are set:
- `AWS_REGION` - AWS region (e.g., `eu-central-1`)
- Valid AWS credentials: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
- `SQS_QUEUE_URL` - URL of the SQS queue

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
