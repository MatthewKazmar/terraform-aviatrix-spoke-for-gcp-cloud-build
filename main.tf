data "aviatrix_account" "this" {
  account_name = var.avx_gcp_account_name
}

module "cloud_build_spoke" {
  source                           = "terraform-aviatrix-modules/mc-spoke/aviatrix"
  version                          = "1.5.0"
  cloud                            = "GCP"
  region                           = var.region
  name                             = "${var.name}-spoke-vpc"
  gw_name                          = "${var.name}-spoke-gateway"
  instance_size                    = var.aviatrix_spoke_instance_size
  cidr                             = cidrsubnet(var.cidr, 1, 0)
  account                          = var.avx_gcp_account_name
  transit_gw                       = var.transit_gateway_name
  included_advertised_spoke_routes = var.cidr
}

# Private pool creation
resource "google_project_service" "servicenetworking" {
  project = data.aviatrix_account.this.gcloud_project_id

  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_global_address" "worker_range" {
  project = data.aviatrix_account.this.gcloud_project_id

  name          = "worker-pool-range"
  purpose       = "VPC_PEERING"
  address       = split("/", cidrsubnet(var.cidr, 1, 1))[0]
  address_type  = "INTERNAL"
  prefix_length = split("/", cidrsubnet(var.cidr, 1, 1))[1]
  network       = module.cloud_build_spoke.vpc.vpc_id
}

resource "google_service_networking_connection" "worker_pool_conn" {
  project = data.aviatrix_account.this.gcloud_project_id

  network                 = module.cloud_build_spoke.vpc.vpc_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.worker_range.name]
  depends_on              = [google_project_service.servicenetworking]
}

resource "google_cloudbuild_worker_pool" "pool" {
  project = data.aviatrix_account.this.gcloud_project_id

  name     = "${name}-worker-pool"
  location = var.region
  worker_config {
    disk_size_gb   = 30
    machine_type   = var.worker_pool_instance_size
    no_external_ip = var.worker_pool_use_external_ip
  }
  network_config {
    peered_network          = google_service_networking_connection.worker_pool_conn.network
    peered_network_ip_range = "/29"
  }
}