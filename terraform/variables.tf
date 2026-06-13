variable "bigip_mgmt" {
  description = "BIG-IP management IP/hostname"
  type        = string
}

variable "bigip_user" {
  type    = string
  default = "admin"
}

variable "bigip_password" {
  description = "BIG-IP password (set in terraform.tfvars or TF_VAR_bigip_password)"
  type        = string
  sensitive   = true
}

variable "provision_ltm" {
  type    = string
  default = "nominal"
}

variable "provision_asm" {
  type    = string
  default = "nominal"
}

variable "as3_rpm_local_path" {
  description = "Local path to the AS3 RPM (download first)"
  type        = string
  default     = "./f5-appsvcs-3.56.0-6.noarch.rpm"
}

variable "cis_partition" {
  type    = string
  default = "kubernetes"
}

variable "vxlan_profile_name" {
  type    = string
  default = "fl-vxlan"
}

variable "vxlan_port" {
  type    = number
  default = 8472
}

variable "tunnel_name" {
  type    = string
  default = "flannel_vxlan"
}

variable "tunnel_key" {
  type    = number
  default = 1
}

variable "bigip_internal_selfip" {
  description = "Existing BIG-IP internal self-IP (tunnel local-address, NOT mgmt)"
  type        = string
  default     = "10.1.20.10"
}

variable "flannel_self_name" {
  type    = string
  default = "flannel-self"
}

variable "flannel_self_address" {
  type    = string
  default = "10.244.255.254/16"
}

variable "create_k8s_node" {
  type    = bool
  default = true
}

variable "kubeconfig_path" {
  type    = string
  default = "/etc/kubernetes/admin.conf"
}

variable "bigip_node_name" {
  type    = string
  default = "bigip1"
}

variable "node_pod_cidr" {
  type    = string
  default = "10.244.255.0/24"
}
