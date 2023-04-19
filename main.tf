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
  cidr                             = local.spoke_cidr
  account                          = var.avx_gcp_account_name
  transit_gw                       = var.transit_gateway_name
  included_advertised_spoke_routes = var.cidr
}

# Enable service networking and cloud build apis.
resource "google_project_service" "servicenetworking" {
  project = data.aviatrix_account.this.gcloud_project_id

  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloud_build" {
  project = data.aviatrix_account.this.gcloud_project_id

  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

# Set up service networking.
resource "google_compute_global_address" "worker_range" {
  project = data.aviatrix_account.this.gcloud_project_id

  name          = "worker-pool-range"
  purpose       = "VPC_PEERING"
  address       = split("/", local.servicenetworking_cidr)[0]
  address_type  = "INTERNAL"
  prefix_length = split("/", local.servicenetworking_cidr)[1]
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

# Private pool creation
resource "google_cloudbuild_worker_pool" "pool" {
  project = data.aviatrix_account.this.gcloud_project_id

  name     = "${var.name}-worker-pool"
  location = var.region
  worker_config {
    disk_size_gb   = 100
    machine_type   = var.worker_pool_instance_size
    no_external_ip = var.use_aviatrix_firenet_egress
  }
  network_config {
    peered_network          = "projects/${data.google_project.this.number}/global/networks/${google_service_networking_connection.worker_pool_conn.network}"
    peered_network_ip_range = "/29"
  }
}

# Add firewall rule for Service Networking CIDR
resource "google_compute_firewall" "default" {
  name    = "cloudbuild-to-avx"
  network = module.cloud_build_spoke.vpc.id

  allow {
    protocol = "all"
  }

  source_ranges = [local.servicenetworking_cidr]

  target_tags = [module.cloud_build_spoke.spoke_gateway.gw_name, module.cloud_build_spoke.spoke_gateway.ha_gw_name]
}

# Needed for egress because the avx-snat-noip route will not pass across the peering.
resource "google_compute_route" "primary_spoke" {
  count = var.use_aviatrix_firenet_egress ? 1 : 0

  name                   = "avx-firenet-egress-primary"
  dest_range             = "0.0.0.0/0"
  network                = module.cloud_build_spoke.vpc.id
  next_hop_instance      = module.cloud_build_spoke.spoke_gateway.gw_name
  next_hop_instance_zone = module.cloud_build_spoke.spoke_gateway.vpc_reg
  priority               = 1200
}

resource "google_compute_route" "ha_spoke" {
  count = var.use_aviatrix_firenet_egress ? 1 : 0

  name                   = "avx-firenet-egress-ha"
  dest_range             = "0.0.0.0/0"
  network                = module.cloud_build_spoke.vpc.id
  next_hop_instance      = module.cloud_build_spoke.spoke_gateway.ha_gw_name
  next_hop_instance_zone = module.cloud_build_spoke.spoke_gateway.ha_zone
  priority               = 1200
}

# Set IAM for Cloud build.
resource "google_project_service_identity" "sa" {
  provider = google-beta

  project = data.aviatrix_account.this.gcloud_project_id
  service = "cloudbuild.googleapis.com"
}

resource "google_project_iam_member" "compute" {
  project = data.aviatrix_account.this.gcloud_project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_project_service_identity.sa.email}"
}

resource "google_project_iam_member" "gke" {
  project = data.aviatrix_account.this.gcloud_project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_project_service_identity.sa.email}"
}

resource "google_project_iam_member" "worker_pool" {
  project = data.aviatrix_account.this.gcloud_project_id
  role    = "roles/cloudbuild.workerPoolUser"
  member  = "serviceAccount:${google_project_service_identity.sa.email}"
}