data "aviatrix_account" "this" {
  account_name = var.avx_gcp_account_name
}

data "google_project" "this" {
  project_id = data.aviatrix_account.this.gcloud_project_id
}

module "cloud_build_spoke" {
  source                           = "terraform-aviatrix-modules/mc-spoke/aviatrix"
  version                          = "1.5.0"
  cloud                            = "GCP"
  region                           = var.region
  name                             = "${var.name}-spoke"
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
  network       = module.cloud_build_spoke.vpc.id
}

resource "google_service_networking_connection" "worker_pool_conn" {
  network                 = module.cloud_build_spoke.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.worker_range.name]
  depends_on              = [google_project_service.servicenetworking]
}

resource "google_compute_network_peering_routes_config" "peering_routes" {
  peering = google_service_networking_connection.worker_pool_conn.peering
  network = google_service_networking_connection.worker_pool_conn.network

  import_custom_routes = true
  export_custom_routes = true
}

resource "google_cloudbuild_worker_pool" "pool" {
  project = data.aviatrix_account.this.gcloud_project_id

  name     = "${var.name}-worker-pool"
  location = var.region
  worker_config {
    disk_size_gb   = 100
    machine_type   = var.worker_pool_instance_size
    no_external_ip = var.worker_pool_use_external_ip
  }
  network_config {
    peered_network          = "projects/${data.google_project.this.number}/global/networks/${google_service_networking_connection.worker_pool_conn.network}"
    peered_network_ip_range = "/29"
  }
}