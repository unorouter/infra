output "node_ipv4" {
  value = hcloud_server.node1.ipv4_address
}

output "node9_ipv4" {
  value = hcloud_server.node9.ipv4_address
}

output "node8_ipv4" {
  value = hcloud_server.node8.ipv4_address
}

output "s3_endpoint" {
  value = "https://fsn1.your-objectstorage.com"
}
