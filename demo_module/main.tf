#provider "aws" {
 # region                   = "us-east-2"
 # access_key = ""
 # secret_key = ""
#}

#provider "null"{}

# Creating VPC

resource "aws_vpc" "terra_vpc" {
  cidr_block       = var.vpc_cidr
  tags = {
    Name = "TerraVPC"
  }
}

#Creating Internet Gateway 

resource "aws_internet_gateway" "terra_igw" {
  vpc_id = aws_vpc.terra_vpc.id
  tags = {
    Name = "main"
  }
  depends_on = [
    aws_vpc.terra_vpc
  ]
}




#Creating route table and attach IGW

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.terra_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.terra_igw.id
  }
  tags = {
    Name = "publicRouteTable"
  }
  depends_on = [
    aws_internet_gateway.terra_igw
  ]
}

# Creating public subnet

resource "aws_subnet" "public" {
  count = length(var.subnets_cidr)
  vpc_id = aws_vpc.terra_vpc.id
  cidr_block = element(var.subnets_cidr,count.index)
  availability_zone = element(var.azs,count.index)
  map_public_ip_on_launch = true
  tags = {
    Name = "Subnet-${count.index+1}"
  }
  depends_on = [
    aws_route_table.public_rt
  ]
}

# Route table assosiation with public subnet

resource "aws_route_table_association" "a" {
  count = length(var.subnets_cidr)
  subnet_id      = element(aws_subnet.public.*.id,count.index)
  route_table_id = aws_route_table.public_rt.id

  depends_on = [
    aws_subnet.public
  ]
}

# Creating security group for ECS and ALB

resource "aws_security_group" "ecs_sg" {
  name        = "ecs_sg"
  description = "Allow ECS inbound traffic"
  vpc_id      = aws_vpc.terra_vpc.id

dynamic "ingress" {
   for_each = [80,8080,443]
    iterator = port
    content {
      description = "TLS from VPC"
      from_port   = port.value
      to_port     = port.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
   # ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_ecr_repository" "trial" {
  name                 = "terraform_ecs_repo"
  image_tag_mutability = "MUTABLE"


  image_scanning_configuration {
    scan_on_push = true
  }
}

 resource "null_resource" "ecr_repo" {
  triggers = {
    arn = aws_ecr_repository.trial.arn
   #     depends_on = [aws_ecr_repository.trial]
  }
  depends_on = [aws_ecr_repository.trial]
  provisioner "local-exec" {
    command = <<EOF
           aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin 169385419601.dkr.ecr.us-east-2.amazonaws.com
          # cd ${path.module}/lambdas/git_client
           docker build -t terraform_ecs_repo /mnt/lambda_container/simple_ecs
           docker tag terraform_ecs_repo:latest 169385419601.dkr.ecr.us-east-2.amazonaws.com/terraform_ecs_repo:latest
           docker push 169385419601.dkr.ecr.us-east-2.amazonaws.com/terraform_ecs_repo:latest
       EOF
  }
}

data "aws_ecr_image" "service_image" {
  depends_on      = [null_resource.ecr_repo]
  repository_name = aws_ecr_repository.trial.name
  image_tag       = "latest"
}

resource "aws_ecs_cluster" "my_cluster" {
  name = "terraform_ecs_cluster" 
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  depends_on = [
    data.aws_ecr_image.service_image
  ]
}
  # depends_on = [
  #   data.aws_ecr_image.service_image
  # ]

resource "aws_ecs_task_definition" "my_first_task" {
  family                   = "my_terraform_task" # Naming our first task
  container_definitions    = <<DEFINITION
  [
    {
      "name": "my_terraform_task",
      "image": "${aws_ecr_repository.trial.repository_url}",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8080,
          "hostPort": 8080
        }
      ],
      "memory": 512,
      "cpu": 256
    }
  ]
  DEFINITION
  requires_compatibilities = ["FARGATE"] # Stating that we are using ECS Fargate
  network_mode             = "awsvpc"    # Using awsvpc as our network mode as this is required for Fargate
  memory                   = 512         # Specifying the memory our container requires
  cpu                      = 256         # Specifying the CPU our container requires
  execution_role_arn       = "${aws_iam_role.ecsTaskExecutionRole.arn}"
  depends_on = [
    aws_ecs_cluster.my_cluster
  ]
}

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = "${aws_iam_role.ecsTaskExecutionRole.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_service" "my_first_service" {
  name            = "my-first-service"                             # Naming our first service
  cluster         = "${aws_ecs_cluster.my_cluster.id}"             # Referencing our created Cluster
  task_definition = "${aws_ecs_task_definition.my_first_task.arn}" # Referencing the task our service will spin up
  launch_type     = "FARGATE"
  desired_count   = 3 # Setting the number of containers we want deployed to 3

  load_balancer {
    target_group_arn = "${aws_lb_target_group.target_group.arn}" # Referencing our target group
    container_name   = "${aws_ecs_task_definition.my_first_task.family}"
    container_port   = 8080 # Specifying the container port
    #depends_on = [aws_lb_target_group.target_group]
  }

  network_configuration {
   # subnets          = ["${aws_default_subnet.default_subnet_a.id}", "${aws_default_subnet.default_subnet_b.id}", "${aws_default_subnet.default_subnet_c.id}"]
    subnets = ["${aws_subnet.public[0].id}","${aws_subnet.public[1].id}"]
    assign_public_ip = true # Providing our containers with public IPs
    security_groups = ["${aws_security_group.ecs_sg.id}"]
  }
 depends_on = [
    aws_ecs_task_definition.my_first_task
  ]

}

resource "aws_alb" "application_load_balancer" {
  name               = "test-lb-tf" # Naming our load balancer
  load_balancer_type = "application"
  subnets = [ # Referencing the default subnets
    # 
    "${aws_subnet.public[0].id}",
    "${aws_subnet.public[1].id}"
  ]
  # Referencing the security group
  security_groups = ["${aws_security_group.ecs_sg.id}"]
}

resource "aws_lb_target_group" "target_group" {
  name        = "target-group"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = "${aws_vpc.terra_vpc.id}" # Referencing the default VPC
  health_check {
    matcher = "200,301,302"
    path = "/tmp/apache-tomcat-9.0.70/webapps/gameoflife.war"
    healthy_threshold   = 3
    unhealthy_threshold = 2
    timeout             = 3
    interval            = 60
    protocol            = "HTTP"
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = "${aws_alb.application_load_balancer.arn}" # Referencing our load balancer
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.target_group.arn}" # Referencing our tagrte group
  }
  depends_on = [
    aws_lb_target_group.target_group
  ]
}
















