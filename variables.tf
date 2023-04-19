variable "avx_gcp_account_name" {
  description = "GCP account as it appears in the controller."
  type        = string
}

variable "transit_gateway_name" {
  description = "Transit Gateway to connect this spoke to."
  type        = string
}

variable "network_domain" {
  description = "Network domain to associate this spoke with. Optional."
  type        = string
  default     = null
}

variable "name" {
  description = "Name of the Cloud Build spoke."
  type        = string
}

variable "region" {
  description = "Region to deploy Aviatrix Spoke and Cloud Build Private Pool."
  type        = string
}

variable "cidr" {
  description = "CIDR for the Spoke Gateway and worker range. Use /23."
  type        = string

  validation {
    condition     = split("/", var.cidr)[1] == "23"
    error_message = "This module needs a /23."
  }
}

variable "aviatrix_spoke_instance_size" {
  description = "Size of the Aviatrix Spoke Gateway."
  type        = string
  default     = "n1-standard-1"
}

variable "worker_pool_instance_size" {
  description = "Size of the GCP Cloud Build worker instance."
  type        = string
  default     = "e2-medium"
}

variable "use_aviatrix_firenet_egress" {
  description = "Apply the avx_snat_noip tag to nodes for Egress."
  type        = bool
  default     = true
}

locals {
  spoke_cidr = cidrsubnet(var.cidr, 1, 0)
  servicenetworking_cidr = cidrsubnet(var.cidr, 1, 1)
}