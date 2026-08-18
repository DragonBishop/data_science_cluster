resource "kubernetes_secret" "cluster_config" {
  metadata {
    name      = "cluster-config"
    namespace = "flux-system"
  }
  data = {
    GATEWAY_IP     = var.gateway_ip
    COREDNS_LAN_IP = var.coredns_lan_ip
    HOST_IP        = var.host_ip
    CILIUM_VERSION = var.cilium_version
  }
  type = "Opaque"
}
