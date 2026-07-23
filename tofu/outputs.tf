output "node_ipv4" {
  value = hcloud_server.node1.ipv4_address
}

output "node2_ipv4" {
  value = hcloud_server.node2.ipv4_address
}

output "node3_ipv4" {
  value = hcloud_server.node3.ipv4_address
}

output "s3_endpoint" {
  value = "https://fsn1.your-objectstorage.com"
}

output "kubeconfig_hint" {
  value = "ssh root@${hcloud_server.node1.ipv4_address} cat /etc/rancher/k3s/k3s.yaml > ../kubeconfig && sed -i 's/127.0.0.1/${hcloud_server.node1.ipv4_address}/' ../kubeconfig"
}
