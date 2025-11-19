# Install Metrics Server (Required for VPA)

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch for KIND/Minikube
kubectl apply -f metrics-server/metrics-server-patch.yml

# Verify
kubectl get pods -n kube-system | grep metrics-server
kubectl top nodes
kubectl top pods -A
