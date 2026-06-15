# The jenkins/ root wires its one module — our own jenkins-controller (no third-party modules). The
# instance-role policy (iam.tf) is authored HERE in the root (it needs the cross-stack ECR ARNs and
# the dev.tfvars Nova ids) and handed to the module as policy_json — mirroring how platform/irsa.tf
# authors policy docs in the root and passes them to modules/iam-irsa.

module "jenkins" {
  source = "../modules/jenkins-controller"

  name              = var.name
  vpc_id            = var.vpc_id
  subnet_id         = var.subnet_id
  availability_zone = var.availability_zone

  ami_id           = var.ami_id
  instance_type    = var.instance_type
  key_name         = var.key_name
  root_volume_size = var.root_volume_size
  aws_region       = var.aws_region

  jenkins_home_volume_size = var.jenkins_home_volume_size
  jenkins_home_device      = var.jenkins_home_device
  jenkins_home_mount       = var.jenkins_home_mount
  jenkins_plugins          = var.jenkins_plugins

  admin_cidr                 = var.admin_cidr
  webhook_ingress_cidrs      = var.webhook_ingress_cidrs
  webhook_ingress_ipv6_cidrs = var.webhook_ingress_ipv6_cidrs

  instance_role_policy_json = data.aws_iam_policy_document.jenkins_instance.json
}
