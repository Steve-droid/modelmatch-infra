# The Jenkins CI controller, wired by hand (our own module — no third-party). Pieces:
#   - a security group: SSH + UI from the admin /32, 8080 also from GitHub's webhook ranges
#   - an IAM instance profile (the box's ONLY AWS identity — no static keys); the caller supplies
#     the least-privilege policy_json (Bedrock Nova + ECR push + modelmatch-jenkins-* secrets read)
#   - the EC2 instance, bootstrapped by user_data (Docker/AWS-CLI/Jenkins + mount the EBS home)
#   - a dedicated, PERSISTENT EBS volume holding JENKINS_HOME (prevent_destroy — the live source of
#     truth; survives instance replacement; S3 = backup/DR only, never a live sync)
#   - a static EIP so the webhook target is stable across stop/start

# ---- Security group ----------------------------------------------------------
# 8080 carries BOTH the Jenkins UI (admin only) and the GitHub webhook endpoint (/github-webhook/),
# so the rule opens 8080 to the admin /32 PLUS GitHub's published hook ranges. HMAC on the webhook
# protects authenticity even though the hop is plain HTTP (the payload is push metadata, not secrets).
resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "ModelMatch Jenkins controller: SSH + UI (admin), 8080 webhook (GitHub hook ranges)"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from admin CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description      = "Jenkins UI (admin) + GitHub webhook delivery (hook ranges)"
    from_port        = 8080
    to_port          = 8080
    protocol         = "tcp"
    cidr_blocks      = concat([var.admin_cidr], var.webhook_ingress_cidrs)
    ipv6_cidr_blocks = var.webhook_ingress_ipv6_cidrs
  }

  egress {
    description      = "All egress (apt, Docker pulls, ECR/Bedrock/Secrets-Manager APIs, GitHub)"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "${var.name}-sg" }
}

# ---- IAM instance profile (the box's ONLY AWS identity) ----------------------
# EC2 assumes this role; the AWS SDK/CLI default chain picks it up via IMDS — so ECR push and the
# e2e-live Bedrock call need NO static keys. The GitOps deploy SSH key is a SEPARATE identity (in
# Secrets Manager, a Git write) — this role cannot write GitHub; the deploy key cannot call AWS.
resource "aws_iam_role" "this" {
  name = "${var.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.name}-role" }
}

# Inline (not managed) policy: lives and dies with the role, purpose-built for this box. The caller
# scopes it to exact ARNs via policy_json (least-privilege Bedrock + ECR + Secrets Manager).
resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-policy"
  role   = aws_iam_role.this.id
  policy = var.instance_role_policy_json
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-instance-profile"
  role = aws_iam_role.this.name
}

# ---- The persistent JENKINS_HOME volume --------------------------------------
# The live source of truth for Jenkins state. prevent_destroy so a stray `terraform destroy` of this
# persistent stack can't wipe job history/config (the stack is "destroyed only intentionally" — drop
# the guard deliberately to tear down). Encrypted (the root box volume in the smoke was not).
resource "aws_ebs_volume" "jenkins_home" {
  availability_zone = var.availability_zone
  size              = var.jenkins_home_volume_size
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${var.name}-home" }

  lifecycle {
    prevent_destroy = true
  }
}

# ---- The controller instance -------------------------------------------------
resource "aws_instance" "this" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = true

  # IMDSv2 required — the instance-profile creds flow over IMDS; hop limit 1 keeps them off any
  # container that might run on the box.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  # user_data runs ONCE at first boot. It references the persistent volume's id (to find the stable
  # by-id symlink) so the instance depends on the volume; the volume_attachment links them (no cycle).
  # Changing user_data later does NOT re-run on the existing box (first-boot only) and does NOT
  # replace the instance (user_data_replace_on_change stays false) — the box is configured once.
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    jenkins_home_mount     = var.jenkins_home_mount
    jenkins_home_volume_id = aws_ebs_volume.jenkins_home.id
    aws_region             = var.aws_region
    jenkins_plugins        = var.jenkins_plugins
  })

  tags = { Name = var.name }
}

# Attach the persistent volume. stop_instance_before_detaching guards data on any future detach.
resource "aws_volume_attachment" "jenkins_home" {
  device_name                    = var.jenkins_home_device
  volume_id                      = aws_ebs_volume.jenkins_home.id
  instance_id                    = aws_instance.this.id
  stop_instance_before_detaching = true
}

# ---- Static EIP (stable webhook target) --------------------------------------
resource "aws_eip" "this" {
  domain = "vpc"
  tags   = { Name = "${var.name}-eip" }
}

resource "aws_eip_association" "this" {
  instance_id   = aws_instance.this.id
  allocation_id = aws_eip.this.id
}
