output "node_ipv4" {
  value = hcloud_server.node1.ipv4_address
}

output "node7_ipv4" {
  value = hcloud_server.node7.ipv4_address
}

output "node6_ipv4" {
  value = hcloud_server.node6.ipv4_address
}

output "s3_endpoint" {
  value = "https://fsn1.your-objectstorage.com"
}
