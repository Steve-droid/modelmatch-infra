# Our own EKS module (no third-party/registry modules — Roey's hard rule). It wires, by hand, the
# pieces a registry module would hide so the AWS↔k8s plumbing is gradeable:
#   - two IAM roles (the CLUSTER role the control plane assumes; the NODE role the workers assume)
#   - the EKS cluster itself, pinned to a latest in-support version, with workers in PRIVATE subnets
#   - a managed node group (t3a.medium, desired 2 / max 3)
#   - the OIDC provider registered against the cluster issuer  → IRSA (P7's app roles trust this)
#   - the EBS CSI driver addon + its dedicated IRSA role (the only IRSA role in P4; it's tightly
#     coupled to the addon — the in-cluster Postgres PVC in gitops P13/P14 needs this driver)
#
# Core addons (coredns, kube-proxy) install automatically with the cluster, so they are NOT declared
# here. vpc-cni IS declared (below) — we manage it explicitly to enable PREFIX DELEGATION. The app
# IRSA roles (backend→Bedrock/S3, ESO→Secrets Manager) are P7, not here.

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

# ---- VPC CNI addon: managed, with PREFIX DELEGATION --------------------------
# vpc-cni auto-installs with the cluster, but we adopt it as a managed addon (OVERWRITE the
# self-installed copy) so we can set ENABLE_PREFIX_DELEGATION. Default IP-per-pod allocation caps a
# t3a.medium at 17 pods (ENI/IP limited); the monitoring + logging stacks exhaust that. Prefix
# delegation hands each ENI a /28 prefix (16 IPs) instead of single IPs, lifting the pod ceiling far
# above 17 on the SAME instance type + AMI. WARM_PREFIX_TARGET=1 keeps one spare prefix warm so pod
# scheduling doesn't stall on a cold IP allocation. (Pairs with the raised --max-pods in the launch
# template below; both are required — the CNI gives the IPs, the kubelet flag lets pods use them.)
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"

  # Adopt the cluster-installed CNI and apply our config over it (create + drift updates).
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })
}

# ---- Launch template: raise kubelet --max-pods (AL2023 nodeadm) --------------
# Prefix delegation supplies the IPs; the kubelet's --max-pods must also be raised or it still admits
# only 17 pods. NO image_id is set, so EKS keeps managing the AL2023 EKS-optimized AMI for the cluster
# version (no pinned/stale AMI). We inject ONLY a NodeConfig that sets maxPods; EKS merges it with its
# own generated bootstrap (cluster name, endpoint, CA) via the AL2023 MIME/nodeadm mechanism.
resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-ng-"

  user_data = base64encode(<<-EOT
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: application/node.eks.aws

apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  kubelet:
    config:
      maxPods: ${var.node_max_pods}
--//--
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-ng" }
  }
}

# ---- Managed node group (t3a.medium, private subnets) ------------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.node_instance_types # stays on the node group (the LT sets no instance type)

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # Use the launch template (for the raised --max-pods). Tracking latest_version means a user_data
  # change rolls the node group to new nodes automatically.
  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  # Nodes can't register until their role has the worker/CNI/ECR policies attached. They must also
  # join AFTER the CNI is configured for prefix delegation, so fresh nodes get prefixes from the start.
  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_eks_addon.vpc_cni,
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
