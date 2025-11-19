# Install VPA Components

kubectl apply -f vpa/vpa-up.yaml

kubectl get pods -n kube-system | grep vpa
kubectl get crd | grep verticalpodautoscalers
