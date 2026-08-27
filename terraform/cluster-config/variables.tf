variable "gateway_ip" {
  type        = string
  sensitive   = true
  description = "Shared Gateway/LoadBalancer IP pool start address (Cilium LB pool, Gateway, cert SAN, *.internal DNS target)"
}

variable "coredns_lan_ip" {
  type        = string
  sensitive   = true
  description = "LAN-facing LoadBalancer IP for the external CoreDNS Service"
}

variable "host_ip" {
  type        = string
  sensitive   = true
  description = "Node IP address for Vault egress to the host Transit Vault"
}

variable "cilium_version" {
  type        = string
  description = "Cilium HelmRelease chart version"
}
