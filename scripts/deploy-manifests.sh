#!/bin/bash

# Deploy MetalLB and NGINX Ingress to k3s cluster
# Run this script on the master node (k3s-21) after the cluster is up

echo "Deploying MetalLB and NGINX Ingress Controller to k3s cluster..."

# Wait for k3s to be ready
echo "Waiting for k3s cluster to be ready..."
until kubectl get nodes | grep -q Ready; do
    echo "Waiting for cluster..."
    sleep 10
done

echo "Cluster is ready. Deploying services..."

# Deploy MetalLB
echo "Deploying MetalLB Load Balancer..."
kubectl apply -f /mnt/data/k3s-manifests/metallb-config.yaml

# Wait for MetalLB to be ready
echo "Waiting for MetalLB to be ready..."
kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=300s

# Deploy NGINX Ingress Controller
echo "Deploying NGINX Ingress Controller..."
kubectl apply -f /mnt/data/k3s-manifests/nginx-proxy.yaml

# Wait for NGINX Ingress to be ready
echo "Waiting for NGINX Ingress Controller to be ready..."
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/name=ingress-nginx --timeout=300s

echo "Deployment complete!"
echo ""
echo "Cluster Status:"
kubectl get nodes -o wide
echo ""
echo "Services:"
kubectl get svc --all-namespaces
echo ""
echo "LoadBalancer Services:"
kubectl get svc --all-namespaces | grep LoadBalancer

echo ""
echo "Your k3s cluster with MetalLB and NGINX Ingress is ready!"
echo "MetalLB will assign IPs from range: 192.168.1.100-192.168.1.199"
echo "Use 'nginx' as the ingress class in your Ingress resources"