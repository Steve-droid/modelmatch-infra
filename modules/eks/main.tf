# Our own EKS module (no third-party/registry modules — Roey's hard rule). It wires, by hand, the
# pieces a registry module would hide so the AWS↔k8s plumbing is gradeable:
#   - two IAM roles (the CLUSTER role the control plane assumes; the NODE role the workers assume)
#   - the EKS cluster itself, pinned to a latest in-support version, with workers in PRIVATE subnets
#   - a managed node group (t3a.medium, desired 2 / max 3)
#   - the OIDC provider registered against the cluster issuer  → IRSA (P7's app roles trust this)
#   - the EBS CSI driver addon + its dedicated IRSA role (the only IRSA role in P4; it's tightly
#     coupled to the addon — the in-cluster Postgres PVC in gitops P13/P14 needs this driver)
#
# Core addons (vpc-cni, coredns, kube-proxy) install automatically with the cluster, so they are
# NOT declared here. The app IRSA roles (backend→Bedrock/S3, ESO→Secrets Manager) are P7, not here.

data "aws_partition" "current" {}

# ---- Cluster IAM role: the control plane assumes this ------------------------
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---- Node IAM role: the worker EC2 instances assume this ---------------------
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# The three AWS-managed policies every EKS worker needs: join the cluster, run the CNI, pull images.
resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ---- The EKS cluster ---------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.k8s_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access
    public_access_cidrs     = var.public_access_cidrs
  }

  # The role must hold AmazonEKSClusterPolicy before the control plane is created, or it can't
  # manage cluster ENIs / security groups. Make the ordering explicit.
  depends_on = [aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy]
}

# ---- Managed node group (t3a.medium, private subnets) ------------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # Nodes can't register until their role has the worker/CNI/ECR policies attached.
  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
  ]
}

# ---- OIDC provider: the foundation for all IRSA (P7) -------------------------
# Register the cluster's OIDC issuer as an IAM identity provider so Kubernetes ServiceAccounts can
# assume IAM roles with no static keys. The thumbprint is the issuer's TLS cert SHA1 fingerprint.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

# ---- EBS CSI driver: addon + its dedicated IRSA role ------------------------
# The driver's controller runs as the kube-system/ebs-csi-controller-sa ServiceAccount; that SA
# assumes this role (scoped via the OIDC sub/aud conditions) to call the EC2 EBS APIs. This is the
# only IRSA role in P4 — it ships with the addon. App IRSA roles (A/B) are P7.
locals {
  # The OIDC condition keys use the issuer host without the https:// scheme.
  oidc_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.this.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  # Controller pods need schedulable nodes AND the role must already carry AmazonEBSCSIDriverPolicy
  # before the addon's SA assumes it — otherwise the driver comes up without EBS permissions.
  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}
