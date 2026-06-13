terraform {
  required_version = ">= 1.4"
  required_providers {
    bigip = {
      source  = "F5Networks/bigip"
      version = "~> 1.24"
    }
  }
}

provider "bigip" {
  address                = var.bigip_mgmt
  username               = var.bigip_user
  password               = var.bigip_password
  api_retries            = 5
  validate_certs_disable = true
}

# Provision + AS3 RPM + partition + VXLAN profile (idempotent REST script)
resource "terraform_data" "prep" {
  triggers_replace = [
    filemd5("${path.module}/prep.sh"),
    var.provision_ltm, var.provision_asm, var.cis_partition,
    var.vxlan_profile_name, var.vxlan_port, filemd5(var.as3_rpm_local_path),
  ]
  provisioner "local-exec" {
    command = "bash ${path.module}/prep.sh"
    environment = {
      BIGIP_HOST    = var.bigip_mgmt
      BIGIP_USER    = var.bigip_user
      BIGIP_PASS    = var.bigip_password
      PROVISION_LTM = var.provision_ltm
      PROVISION_ASM = var.provision_asm
      AS3_RPM       = abspath(var.as3_rpm_local_path)
      PARTITION     = var.cis_partition
      VXLAN_PROFILE = var.vxlan_profile_name
      VXLAN_PORT    = tostring(var.vxlan_port)
    }
  }
}

# VXLAN tunnel + self-IP (native, idempotent)
resource "bigip_net_tunnel" "flannel" {
  depends_on    = [terraform_data.prep]
  name          = "/Common/${var.tunnel_name}"
  profile       = "/Common/${var.vxlan_profile_name}"
  key           = var.tunnel_key
  local_address = var.bigip_internal_selfip
}

resource "bigip_net_selfip" "flannel" {
  depends_on    = [bigip_net_tunnel.flannel]
  name          = "/Common/${var.flannel_self_name}"
  ip            = var.flannel_self_address
  vlan          = "/Common/${var.tunnel_name}"
  port_lockdown = ["all"]
}

# Save config, read VTEP MAC, render + (optionally) apply the bigip1 Node
resource "terraform_data" "node" {
  depends_on       = [bigip_net_selfip.flannel]
  triggers_replace = [bigip_net_tunnel.flannel.id]
  provisioner "local-exec" {
    command = "bash ${path.module}/mac-node.sh"
    environment = {
      BIGIP_HOST  = var.bigip_mgmt
      BIGIP_USER  = var.bigip_user
      BIGIP_PASS  = var.bigip_password
      TUNNEL      = var.tunnel_name
      NODE_NAME   = var.bigip_node_name
      PUBLIC_IP   = var.bigip_internal_selfip
      POD_CIDR    = var.node_pod_cidr
      CREATE_NODE = var.create_k8s_node ? "true" : "false"
      KUBECONFIG  = var.kubeconfig_path
      NODE_FILE   = "${path.module}/bigip-node.yaml"
    }
  }
}
