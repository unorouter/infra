resource "hcloud_network" "cluster" {
  name     = "saas-cluster"
  ip_range = "10.100.0.0/16"
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.100.1.0/24"
}
