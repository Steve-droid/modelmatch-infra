# Inputs for our own EKS module (no third-party/registry modules — Roey's hard rule).
# DEFAULTLESS by rule: every concrete value is supplied by the calling stack via dev.tfvars,
# never a `default` here — keeps applies predictable and makes the module interface explicit.

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used to derive the IAM role names and is the value behind the kubernetes.io/cluster/<name> subnet tag (passed to the VPC module from the platform stack)."
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes minor version for the control plane (e.g. \"1.36\"). MUST be a latest in-support (STANDARD_SUPPORT) version — extended-support versions ~multiply the control-plane charge. Pinned explicitly in dev.tfvars."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs the cluster ENIs and the managed node group launch into. We pass the PRIVATE subnets only (workers never get public IPs)."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Whether the cluster API server is reachable from the public internet (still IAM+auth gated, and narrowed by public_access_cidrs). True for laptop kubectl during the bootcamp."
  type        = bool
}

variable "endpoint_private_access" {
  description = "Whether the cluster API server is reachable from inside the VPC. True so worker nodes reach the API over the private endpoint regardless of the public-CIDR allowlist."
  type        = bool
}

variable "public_access_cidrs" {
  description = "Source CIDRs allowed to reach the public API endpoint (e.g. [\"<my-ip>/32\"]). Narrows the public surface to approved IPs. Ignored when endpoint_public_access is false."
  type        = list(string)
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group (we use [\"t3a.medium\"])."
  type        = list(string)
}

variable "node_desired_size" {
  description = "Desired worker node count at create (2)."
  type        = number
}

variable "node_min_size" {
  description = "Minimum worker node count."
  type        = number
}

variable "node_max_size" {
  description = "Maximum worker node count (3) — the cap for this portfolio's node sizing."
  type        = number
}

variable "node_max_pods" {
  description = "kubelet --max-pods per node. The default for t3a.medium is 17 (ENI/IP limited), which the monitoring + logging stacks exhaust. We enable VPC CNI prefix delegation (each ENI gets /28 prefixes = 16 IPs) and raise this ceiling so unused RAM can actually be scheduled. 110 is AWS's recommended cap for sub-30-vCPU instances; real packing is RAM-bound well below it. Set in dev.tfvars."
  type        = number
}
