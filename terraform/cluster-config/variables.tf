variable "gateway_ip" {
  type      = string
  sensitive = true
}

variable "coredns_lan_ip" {
  type      = string
  sensitive = true
}

variable "host_ip" {
  type      = string
  sensitive = true
}

variable "cilium_version" {
  type = string
}
