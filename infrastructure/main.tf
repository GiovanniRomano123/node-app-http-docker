provider "aws" {
  region = "eu-central-1"
}

# Use the aws_caller_identity data source to fetch details about the currently configured AWS identity.
data "aws_caller_identity" "current" {}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.10.0/24"
  availability_zone       = "eu-central-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.20.0/24"
  availability_zone = "eu-central-1a"
}

resource "aws_subnet" "private2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.30.0/24"
  availability_zone = "eu-central-1b"
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "rds" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "main"
  subnet_ids = [aws_subnet.private1.id, aws_subnet.private2.id]
}

resource "aws_db_instance" "postgres" {
  allocated_storage    = 20
  engine               = "postgres"
  engine_version       = "16.3"
  instance_class       = "db.t3.micro"
  db_name              = "mydatabase"
  username             = "postgres"
  password             = "mypassword"
  publicly_accessible  = false
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name = aws_db_subnet_group.main.name
  skip_final_snapshot  = true  # Skip final snapshot on deletion
}

resource "aws_security_group" "ec2" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["<INSERT YOUR IP>/32"]  
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # To be fixed: connect to the instance using EC2 Instance Connect Endpoint
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "ec2_instance_connect_role" {
  name = "ec2-instance-connect-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "ec2_instance_connect_policy" {
  name   = "ec2-instance-connect-policy"
  role   = aws_iam_role.ec2_instance_connect_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = "ec2-instance-connect:SendSSHPublicKey",
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = "ec2:DescribeInstances",
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "ecr_policy" {
  name   = "ecr-policy"
  role   = aws_iam_role.ec2_instance_connect_role.id

  policy = jsonencode({
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ],
        Resource: "*"
      }
    ]
  })
}

resource "aws_instance" "app" {
  ami                    = "ami-0c5823fd00977ca15" # Amazon Linux 2 AMI for eu-central-1
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_instance_connect_profile.name

  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              amazon-linux-extras install docker -y
              service docker start
              usermod -a -G docker ec2-user

              # Install AWS CLI
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              unzip awscliv2.zip
              sudo ./aws/install

              # Authenticate Docker to ECR
              aws ecr get-login-password --region eu-central-1 | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.eu-central-1.amazonaws.com

              # Pull the Docker image from ECR
              docker pull ${data.aws_caller_identity.current.account_id}.dkr.ecr.eu-central-1.amazonaws.com/sugarapprepo:latest

              # Install PostgreSQL client
              sudo amazon-linux-extras enable postgresql14
              sudo yum install postgresql-server -y

              # Wait for the RDS instance to be available
              sleep 30

              # Connect to the rds db
              PGPASSWORD="mypassword" psql -h ${aws_db_instance.postgres.address} -U postgres -d mydatabase
              
              # Run the Docker container in the background
              # --network host -> container's network stack isn't isolated from the Docker host, I used this settings for enabling the connection to the RDS 
              docker run -d --network host -p 8080:8080 \
                --name sugarapp \
                -e DB_HOST=${aws_db_instance.postgres.address} \
                -e DB_USER=postgres \
                -e DB_PASS=mypassword \
                ${data.aws_caller_identity.current.account_id}.dkr.ecr.eu-central-1.amazonaws.com/sugarapprepo:latest
              
              # Wait for the container to start
              sleep 30

              # Create a Node.js script to test PostgreSQL connection
              echo 'const { Client } = require("pg");

              const client = new Client({
                host: process.env.DB_HOST,
                user: process.env.DB_USER,
                password: process.env.DB_PASS,
                database: "mydatabase",
                ssl: {
                  rejectUnauthorized: false
                }
              });

              client.connect()
                .then(() => {
                  console.log("Connected to PostgreSQL");
                  return client.query("SELECT 1");
                })
                .then((res) => {
                  console.log("Test query result:", res.rows);
                  return client.end();
                })
                .catch((err) => {
                  console.error("Database connection error", err.stack);
                  process.exit(1);
                });' > test_db_connection.js

              # Copy the script to the Docker container
              docker cp test_db_connection.js sugarapp:/usr/src/app/test_db_connection.js

              # Install the pg module and run the Node.js script inside the Docker container
              docker exec sugarapp sh -c "cd /usr/src/app && npm install pg && node test_db_connection.js
              "
              EOF

  tags = {
    Name = "AppServer"
  }
}

resource "aws_iam_instance_profile" "ec2_instance_connect_profile" {
  name = "ec2-instance-connect-profile"
  role = aws_iam_role.ec2_instance_connect_role.name
}

output "ec2_instance_public_ip" {
  value = aws_instance.app.public_ip
}
