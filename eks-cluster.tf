# AWS Provider Ayarları
provider "aws" {
  region = "us-west-2"  # Bölgeyi ihtiyacınıza göre değiştirebilirsiniz
}

# VPC Oluşturma
resource "aws_vpc" "mern_vpc" {
  cidr_block = "172.15.0.0/24"
  enable_dns_hostnames = true
  enable_dns_support = true
  tags = {
    Name = "mern-example-vpc"
  }
}
resource "aws_route_table" "mern_route_table" {
  vpc_id = "${aws_vpc.mern_vpc.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.mern_igw.id}"
  }
  tags = {
    Name = "mern_route_table"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "subnet_app" {
  vpc_id = "${aws_vpc.mern_vpc.id}"
  cidr_block = "172.15.0.0/27"
  availability_zone = "us-west-2b"
  depends_on = [aws_internet_gateway.mern_igw]
  map_public_ip_on_launch = true
  tags = {
    Name = "mern_subnet_apps"
  }
}

resource "aws_subnet" "mern_subnet_cluster_1" {
  vpc_id = "${aws_vpc.mern_vpc.id}"
  cidr_block = "172.15.0.32/27"
  map_public_ip_on_launch = true
  availability_zone = "us-west-2a"
  tags = {
    Name = "subnet_1"
  }
}

resource "aws_subnet" "mern_subnet_cluster_2" {
  vpc_id = "${aws_vpc.mern_vpc.id}"
  cidr_block = "172.15.0.64/27"
  availability_zone = "us-west-2c"
  map_public_ip_on_launch = true
  tags = {
    Name = "subnet_2"
  }

}

resource "aws_internet_gateway" "mern_igw" {
  vpc_id = "${aws_vpc.mern_vpc.id}"
  tags = {
    Name = "mern-publicGateway"
  }
}


# EKS için IAM Rolü Oluşturma
resource "aws_iam_role" "mern_eks_role" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Effect   = "Allow"
        Sid      = ""
      }
    ]
  })
}

# IAM Rolüne Politika Bağlama
resource "aws_iam_role_policy_attachment" "eks_role_policy" {
  role       = aws_iam_role.mern_eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# EKS Cluster Oluşturma
resource "aws_eks_cluster" "mern_cluster" {
  name     = "mern-eks-cluster"
  role_arn = aws_iam_role.mern_eks_role.arn
  depends_on = [aws_iam_role_policy_attachment.AmazonEKSClusterPolicy]

  vpc_config {
    subnet_ids = [aws_subnet.mern_subnet_cluster_1.id, aws_subnet.mern_subnet_cluster_2.id]
    security_group_ids = []
  }
}

# Node Role (Worker Node) İçin IAM Rolü
resource "aws_iam_role" "mern_eks_node_role" {
  name = "eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Effect   = "Allow"
        Sid      = ""
      }
    ]
  })
}

# Node Role'a Politika Ekleme

resource "aws_iam_role_policy_attachment" "AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.mern_eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEKSServicePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.mern_eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.mern_eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.mern_eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.mern_eks_node_role.name
}


# EKS Node Group Oluşturma
resource "aws_eks_node_group" "mern_node_group" {
  cluster_name    = aws_eks_cluster.mern_cluster.name
  node_group_name = "mern-node-group"
  node_role_arn       = aws_iam_role.mern_eks_node_role.arn
  subnet_ids      = [aws_subnet.mern_subnet_cluster_1.id, aws_subnet.mern_subnet_cluster_2.id]
  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }
  instance_types = ["t3.medium"]
}

data "aws_instances" "mern_eks_cluster_instances" {
  filter {
    name   = "tag:eks:cluster-name"
    values = [aws_eks_cluster.mern_cluster.name]
  }
}

# Alarmlar buradan esinlenerek oluşturuldu. https://github.com/cds-snc/notification-terraform/blob/main/aws/eks/cloudwatch_alarms.tf

resource "aws_cloudwatch_metric_alarm" "kubernetes-failed-nodes" {
  alarm_name          = "kubernetes-failed-nodes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  alarm_description   = "Kubernetes failed node anomalies"
  treat_missing_data = "notBreaching"
  threshold          = 1

  metric_query {
    id          = "m1"
    return_data = "true"
    metric {
      metric_name = "cluster_failed_node_count"
      namespace   = "ContainerInsights"
      period      = 300
      stat        = "Average"
      dimensions = {
        Name = aws_eks_cluster.mern_cluster.name
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "admin-pods-high-cpu-warning" {
  alarm_name                = "admin-pods-high-cpu-warning"
  alarm_description         = "Average CPU of admin pods >=50% during 10 minutes"
  comparison_operator       = "GreaterThanOrEqualToThreshold"
  evaluation_periods        = "2"
  metric_name               = "pod_cpu_utilization"
  namespace                 = "ContainerInsights"
  period                    = 300
  statistic                 = "Average"
  threshold                 = 50
  treat_missing_data        = "missing"
  dimensions = {
    ClusterName = aws_eks_cluster.mern_cluster.name
  }
}
