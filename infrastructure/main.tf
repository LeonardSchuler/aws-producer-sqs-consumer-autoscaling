terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.65.0"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

provider "aws" {
  region = var.region
}

# Fetch the list of available Availability Zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Create a VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "app-vpc"
  }
}

# Create three public subnets
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true
  tags = {
    Name = "public-subnet-${count.index + 1}"
  }
}

# Create an Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "main-igw"
  }
}

# Create a route table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "public-route-table"
  }
}

# Associate the route table with the public subnets
resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}


resource "aws_sqs_queue" "task_queue" {
  name                      = "task-queue"
  delay_seconds             = 0
  max_message_size          = 262144
  message_retention_seconds = 86400
  receive_wait_time_seconds = 0
}

resource "aws_ssm_parameter" "sleep_time" {
  name  = "/app/producer/sleep_time"
  type  = "String"
  value = "30"
}

resource "aws_ssm_parameter" "wait_time" {
  name  = "/app/producer/wait_time"
  type  = "String"
  value = "5"
}

# IAM Role for EC2 Instances in Auto Scaling Group
resource "aws_iam_role" "ec2_role" {
  name = "ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "ec2_policy" {
  name = "ec2-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sqs:*",
          "ssm:GetParameter"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_attach_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ec2_policy.arn
}

# Fetch the latest Amazon Linux 2023 AMI ID from SSM Parameter Store
data "aws_ssm_parameter" "amazon_linux" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_launch_template" "producer_lt" {
  name_prefix            = "producer-"
  image_id               = data.aws_ssm_parameter.amazon_linux.value
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }
  network_interfaces {
    associate_public_ip_address = false
  }

  instance_type = "t3a.nano"
  instance_market_options {
    market_type = "spot"
  }

  user_data = base64encode(<<-EOF
  #!/bin/bash
  yum install -y aws-cli jq
  while true; do
    SLEEP_TIME=$(aws ssm get-parameter --name /app/producer/sleep_time --query "Parameter.Value" --output text)
    WAIT_TIME=$(aws ssm get-parameter --name /app/producer/wait_time --query "Parameter.Value" --output text)
    MESSAGE="{\"sleep\": $SLEEP_TIME}"
    aws sqs send-message --queue-url ${aws_sqs_queue.task_queue.url} --message-body "$MESSAGE"
    sleep $WAIT_TIME
  done
  EOF
  )
}

resource "aws_launch_template" "consumer_lt" {
  name_prefix            = "consumer-"
  image_id               = data.aws_ssm_parameter.amazon_linux.value
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }
  network_interfaces {
    associate_public_ip_address = false
  }

  instance_type = "t3a.nano"
  instance_market_options {
    market_type = "spot"
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum install -y aws-cli jq
    while true; do
      MESSAGE=$(aws sqs receive-message --queue-url ${aws_sqs_queue.task_queue.url} --max-number-of-messages 1 --wait-time-seconds 20)
      if [ -z "$MESSAGE" ]; then
        continue
      fi
      SLEEP_TIME=$(echo $MESSAGE | jq -r '.Messages[0].Body | fromjson | .sleep')
      RECEIPT_HANDLE=$(echo $MESSAGE | jq -r '.Messages[0].ReceiptHandle')
      aws sqs delete-message --queue-url ${aws_sqs_queue.task_queue.url} --receipt-handle $RECEIPT_HANDLE
      sleep $SLEEP_TIME
    done
    EOF
  )
}

resource "aws_autoscaling_group" "producer_asg" {
  desired_capacity          = 0
  max_size                  = 5
  min_size                  = 0
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.producer_lt.id
    version = aws_launch_template.producer_lt.latest_version # $Latest does not trigger updates
  }

  target_group_arns = []
  #vpc_zone_identifier = [aws_subnet.public[0].id, aws_subnet.public[1].id, aws_subnet.public[2].id]
  vpc_zone_identifier = aws_subnet.public[*].id
  tag {
    key                 = "Name"
    value               = "Producer"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group" "consumer_asg" {
  desired_capacity          = 0
  max_size                  = 5
  min_size                  = 0
  health_check_type         = "EC2"
  health_check_grace_period = 300
  launch_template {
    id      = aws_launch_template.consumer_lt.id
    version = aws_launch_template.producer_lt.latest_version # $Latest does not trigger updates
  }

  vpc_zone_identifier = aws_subnet.public[*].id
  tag {
    key                 = "Name"
    value               = "Consumer"
    propagate_at_launch = true
  }

}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ec2-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# Scaling Policies
resource "aws_autoscaling_policy" "producer_scale_up" {
  name                   = "producer-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.producer_asg.name
}

resource "aws_autoscaling_policy" "producer_scale_down" {
  name                   = "producer-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.producer_asg.name
}

resource "aws_autoscaling_policy" "consumer_scale_up" {
  name                   = "consumer-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.consumer_asg.name
}

resource "aws_autoscaling_policy" "consumer_scale_down" {
  name                   = "consumer-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.consumer_asg.name
}

resource "aws_cloudwatch_metric_alarm" "producer_alarm" {
  alarm_name          = "producer-sqs-backlog"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = "60"
  statistic           = "Average"
  threshold           = "5"
  dimensions = {
    QueueName = aws_sqs_queue.task_queue.name
  }

  alarm_actions = [aws_autoscaling_policy.producer_scale_down.arn]
  ok_actions    = [aws_autoscaling_policy.producer_scale_up.arn]
}


resource "aws_cloudwatch_metric_alarm" "producer_queue_empty_alarm" {
  alarm_name          = "producer-queue-empty"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = "60"
  statistic           = "Average"
  threshold           = "0"
  dimensions = {
    QueueName = aws_sqs_queue.task_queue.name
  }

  alarm_actions = [aws_autoscaling_policy.producer_scale_up.arn]
  ok_actions    = []
}


resource "aws_cloudwatch_metric_alarm" "consumer_alarm" {
  alarm_name          = "consumer-sqs-backlog"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = "60"
  statistic           = "Average"
  threshold           = "5"
  dimensions = {
    QueueName = aws_sqs_queue.task_queue.name
  }

  alarm_actions = [aws_autoscaling_policy.consumer_scale_up.arn]
  ok_actions    = [aws_autoscaling_policy.consumer_scale_down.arn]
}

output "SQS_QUEUE_URL" {
  value = aws_sqs_queue.task_queue.url
}
