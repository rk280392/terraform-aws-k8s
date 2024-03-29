provider "aws" {
  region  = var.aws-region
  profile = var.profile
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "KUBERNETES VPC"
  }
}

resource "aws_subnet" "master-subnet" {
  count             = length(var.master-subnet)
  vpc_id            = aws_vpc.main.id
  cidr_block        = element(var.master-subnet, count.index)
  availability_zone = element(var.azs, count.index)

  tags = {
    Name = "Master Subnet ${count.index + 1}"
  }
}

resource "aws_subnet" "node_subnets" {
  count             = length(var.node-subnet)
  vpc_id            = aws_vpc.main.id
  cidr_block        = element(var.node-subnet, count.index)
  availability_zone = element(var.azs, count.index)

  tags = {
    Name = "Node Subnet ${count.index + 1}"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "Project VPC IG"
  }
}

resource "aws_route_table" "second_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "2nd Route Table"
  }
}

resource "aws_route_table_association" "master_subnet_asso" {
  count          = length(var.master-subnet)
  subnet_id      = element(aws_subnet.master-subnet[*].id, count.index)
  route_table_id = aws_route_table.second_rt.id
}

resource "aws_route_table_association" "node_subnet_asso" {
  count          = length(var.node-subnet)
  subnet_id      = element(aws_subnet.node_subnets[*].id, count.index)
  route_table_id = aws_route_table.second_rt.id
}
resource "aws_security_group" "allow_master" {
  name        = "allow_master"
  description = "Allow inbound traffic for master"
  vpc_id      = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "ingress_rules_master" {
  count = length(var.sg_master_ingress_rules)

  type              = "ingress"
  from_port         = var.sg_master_ingress_rules[count.index].from_port
  to_port           = var.sg_master_ingress_rules[count.index].to_port
  protocol          = var.sg_master_ingress_rules[count.index].protocol
  cidr_blocks       = [var.sg_master_ingress_rules[count.index].cidr_block]
  description       = var.sg_master_ingress_rules[count.index].description
  security_group_id = aws_security_group.allow_master.id
}

resource "aws_security_group" "allow_node" {
  name        = "allow_node"
  description = "Allow inbound traffic for node"
  vpc_id      = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "ingress_rules_node" {
  count = length(var.sg_node_ingress_rules)

  type              = "ingress"
  from_port         = var.sg_node_ingress_rules[count.index].from_port
  to_port           = var.sg_node_ingress_rules[count.index].to_port
  protocol          = var.sg_node_ingress_rules[count.index].protocol
  cidr_blocks       = [var.sg_node_ingress_rules[count.index].cidr_block]
  description       = var.sg_node_ingress_rules[count.index].description
  security_group_id = aws_security_group.allow_node.id
}
resource "aws_eip" "master-eip" {
  vpc = true
}

#aws instance creation
resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_spot_instance_request.master.spot_instance_id
  allocation_id = aws_eip.master-eip.id
}

resource "aws_spot_instance_request" "master" {
  ami                         = var.master-ami
  spot_price                  = var.spot-price
  instance_type               = var.master-size
  spot_type                   = "one-time"
  wait_for_fulfillment        = "true"
  associate_public_ip_address = var.master-pubip-assoc
  private_ip                  = var.master-pvt-ip
  subnet_id                   = aws_subnet.master-subnet[0].id
  key_name                    = var.master-key-pair
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids      = [aws_security_group.allow_master.id]
  tags = {
    Name = "master-k8s-0"
  }

  provisioner "local-exec" {
    command = "/bin/bash ansible-provision.sh ${self.public_ip} ${self.private_ip} worker k8s-master ${aws_eip.master-eip.public_ip}"
  }
}

#aws instance creation
resource "aws_spot_instance_request" "worker" {
  depends_on                  = [aws_spot_instance_request.master]
  count                       = var.node-count
  ami                         = var.node-ami
  instance_type               = var.node-size
  spot_price                  = var.spot-price
  spot_type                   = "one-time"
  wait_for_fulfillment        = "true"
  associate_public_ip_address = var.node-pubip-assoc
  subnet_id                   = aws_subnet.node_subnets[0].id
  key_name                    = var.node-key-pair
  vpc_security_group_ids      = [aws_security_group.allow_node.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  tags = {
    Name = "worker-k8s-${count.index}"
  }

  provisioner "local-exec" {
    command = "/bin/bash ansible-provision.sh ${self.public_ip} ${self.private_ip} master k8s-worker-${count.index}"
  }
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_iam-profile"
  role = var.iam_role
}

resource "null_resource" "running-provisioner" {
  depends_on = [aws_spot_instance_request.master, aws_spot_instance_request.worker]
  triggers = {
    cluster_instance_ids = join(",", aws_spot_instance_request.master.*.id)
  }
  provisioner "local-exec" {
    command = "/bin/bash ansible-provision.sh banner ${aws_eip_association.eip_assoc.public_ip}"
  }
}


output "publicIpk8sMaster" {
  value = aws_eip_association.eip_assoc.public_ip
}

output "publicIpk8sWorker" {
  value = aws_spot_instance_request.worker[*].public_ip
}
