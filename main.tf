provider "aws" {
  region = "ap-northeast-3"
}

# Data source for the existing Elastic IP
data "aws_eip" "g4_eip" {
  filter {
    name   = "tag:Name"
    values = ["Common EIP"]
  }
}

# Generate a private key
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Save the private key to a local file
resource "local_file" "private_key" {
  content  = tls_private_key.ssh_key.private_key_pem
  filename = "${path.module}/terraform-key.pem"
  file_permission = "0400"
}

# Create a new key pair
resource "aws_key_pair" "terraform_key" {
  key_name   = "terraform-key" # Name of the key pair
  public_key = tls_private_key.ssh_key.public_key_openssh
}

# Create EC2 instance
resource "aws_instance" "direct_instance" {
  ami             = "ami-08a7bc2c4efd0df53"
  instance_type   = "t3.medium"
  key_name        = aws_key_pair.terraform_key.key_name # Use the generated key pair
  subnet_id       = "subnet-0413f3df15e783cfc"
  security_groups = ["sg-0506e1cd26b03c89e"]
  associate_public_ip_address = false # Disable auto-assign public IP

  # User Data for the EC2 instance initialization
  user_data = base64encode(<<-EOF
    #!/bin/bash

    # Update and install basic dependencies
    sudo apt-get update -y
    sudo apt-get upgrade -y
    sudo apt-get install -y git curl wget unzip build-essential

    # Install Node.js and npm
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs

    # Install Java
    sudo apt-get install -y openjdk-21-jdk openjdk-17-jdk
    sudo update-alternatives --set java $(update-alternatives --list java | grep "java-21")

    # Install Docker & Docker Compose
    sudo apt install docker.io -y
    sudo apt install docker-compose -y

    # Install Git and clone your repository
    echo "Cloning the repository..."
    git clone https://github.com/devxenolinux0x11/Test.git /home/ubuntu/Test >> /home/ubuntu/git_clone.log 2>&1
    if [ $? -eq 0 ]; then
      echo "Repository cloned successfully."
    else
      echo "Failed to clone the repository."
      exit 1
    fi

    # Set correct permissions for the Test directory
    sudo chown -R ubuntu:ubuntu /home/ubuntu/Test
    sudo chmod -R 755 /home/ubuntu/Test

    # Npm Warning
    npm install -g npm@11.3.0

    # Create a marker file to indicate user_data completion
    echo "user_data script completed successfully."
    sudo touch /home/ubuntu/user_data_complete.marker
  EOF
  )

  tags = {
    Name = "G4-Terraform-Instance"
  }

  depends_on = [aws_key_pair.terraform_key]
}

# Associate the Elastic IP (G4-EIP) with the EC2 instance
resource "aws_eip_association" "direct_instance_eip_assoc" {
  instance_id   = aws_instance.direct_instance.id
  allocation_id = data.aws_eip.g4_eip.id
}

# Output the public IP address of the EC2 instance
output "public_ip" {
  value = aws_eip_association.direct_instance_eip_assoc.public_ip
}

# Create an HTTP API Gateway
resource "aws_apigatewayv2_api" "springboot_http_api" {
  name          = "SpringBootHTTPAPI"
  protocol_type = "HTTP"
  description   = "HTTP API Gateway for Spring Boot services"
}

# Define the services and their ports
locals {
  services = {
    admin     = 8085
    courses   = 8086
    feedbacks = 8088
    learning  = 8087
  }
}

# Dynamically create integrations for each service
resource "aws_apigatewayv2_integration" "service_integrations" {
  for_each          = local.services
  api_id            = aws_apigatewayv2_api.springboot_http_api.id
  integration_type  = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri   = "http://${data.aws_eip.g4_eip.public_ip}:${each.value}/${each.key}/{proxy}"
}

# Dynamically create routes for each service
resource "aws_apigatewayv2_route" "service_routes" {
  for_each    = local.services
  api_id      = aws_apigatewayv2_api.springboot_http_api.id
  route_key   = "ANY /${each.key}/{proxy+}"
  target      = "integrations/${aws_apigatewayv2_integration.service_integrations[each.key].id}"
}

# Deploy the HTTP API Gateway using the $default stage
resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.springboot_http_api.id
  name        = "$default" # Use the $default stage
  auto_deploy = true # Enable auto-deploy
}

# Output the HTTP API Gateway endpoint
output "http_api_gateway_endpoint" {
  value = "${aws_apigatewayv2_stage.default_stage.invoke_url}"
}

# Add an inbound rule to the RDS security group to allow traffic from the EC2 instance's private IP
resource "aws_security_group_rule" "allow_rds_from_ec2" {
  type              = "ingress"
  from_port         = 3306 # MySQL/Aurora port
  to_port           = 3306
  protocol          = "tcp"
  security_group_id = "sg-0385eb5a3aa6bea43" # Security group ID of the RDS (G4-SG)
  cidr_blocks       = ["${aws_instance.direct_instance.private_ip}/32"] # Private IP of the EC2 instance with /32
  description       = "Allow MySQL/Aurora traffic from EC2 instance"

  depends_on = [aws_instance.direct_instance] # Ensure the EC2 instance is created first
}

# Local-exec provisioner to update the .env file and bring up Docker Compose
resource "null_resource" "final_steps" {
  triggers = {
    public_ip = aws_eip_association.direct_instance_eip_assoc.public_ip
    api_gateway_endpoint = aws_apigatewayv2_stage.default_stage.invoke_url
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for the EC2 instance to complete user_data
      echo "Waiting for EC2 instance to complete user_data script..."
      sleep 180 # Initial wait time for bootup
      while ! ssh -i "${local_file.private_key.filename}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${aws_eip_association.direct_instance_eip_assoc.public_ip} "test -f /home/ubuntu/user_data_complete.marker"; do
        echo "user_data script not yet complete. Retrying in 30 seconds..."
        sleep 30
      done

      echo "user_data script completed. Proceeding to update .env file..."

      # Update the .env file with the new public IP
      ssh -i "${local_file.private_key.filename}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${aws_eip_association.direct_instance_eip_assoc.public_ip} "
        echo 'Updating .env file with the new public IP...'
        cd /home/ubuntu/Test
        sed -i 's/PUBLIC_IP=.*/PUBLIC_IP=${aws_eip_association.direct_instance_eip_assoc.public_ip}/' .env
      "

      # Update the .env file with the new API Gateway endpoint
      ssh -i "${local_file.private_key.filename}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${aws_eip_association.direct_instance_eip_assoc.public_ip} "
        echo 'Updating .env file with the new API Gateway endpoint...'
        cd /home/ubuntu/Test
        sed -i 's|REACT_APP_API_URL_ADMIN=.*|REACT_APP_API_URL_ADMIN=${aws_apigatewayv2_stage.default_stage.invoke_url}|' .env
        sed -i 's|REACT_APP_API_URL_COURSE=.*|REACT_APP_API_URL_COURSE=${aws_apigatewayv2_stage.default_stage.invoke_url}|' .env
        sed -i 's|REACT_APP_API_URL_FEEDBACK=.*|REACT_APP_API_URL_FEEDBACK=${aws_apigatewayv2_stage.default_stage.invoke_url}|' .env
        sed -i 's|REACT_APP_API_URL_REGISTER=.*|REACT_APP_API_URL_REGISTER=${aws_apigatewayv2_stage.default_stage.invoke_url}|' .env
      "

      # Bring up the Docker Compose environment
      ssh -i "${local_file.private_key.filename}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${aws_eip_association.direct_instance_eip_assoc.public_ip} "
        echo 'Bringing up Docker Compose environment...'
        cd /home/ubuntu/Test
        sudo docker-compose --env-file .env up --build
      "
    EOT
  }

  depends_on = [
    aws_instance.direct_instance,
    aws_security_group_rule.allow_rds_from_ec2 # Ensure the security group rule is updated first
  ]
}
