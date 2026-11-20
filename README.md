# Kubernetes Learning: Hands-on Course

A step-by-step Kubernetes course, from "what is a Pod" to a self-built cluster on AWS. Every module has a README that explains the concept, walks through each YAML line by line, gives single-line commands with the **expected output**, and ends with troubleshooting, cleanup and an assignment.

## Modules

| # | Module | You will learn | Main files |
| --- | --- | --- | --- |
| 01 | [Architecture](01-architecture/) | Why Kubernetes, control plane and worker components, what happens when you create a Pod | Theory only |
| 02 | [Kind and kubectl setup](02-kind-setup/) | Install Docker, kubectl and Kind on EC2; create a 3-node cluster | `cluster.yml` |
| 03 | [Pods and Deployments](03-pods-deployments/) | Namespace, Pod, Deployment, scaling, rolling update, rollback, resources, probes | `01-namespace.yaml` ... `04-deployment-production.yaml` |
| 04 | [Services](04-services/) | ClusterIP, NodePort, LoadBalancer, DNS, port-forward; deploy the Notes app | `01-service-clusterip.yaml`, `02-notes-app.yaml` |
| 05 | [Ingress and Gateway API](05-ingress-gateway/) | Traefik controller, path routing, prefix stripping, HTTPRoute; ingress-nginx retirement | `01-apps.yaml` ... `04-httproute.yaml` |
| 06 | [ConfigMap and Secret](06-configmap-secret/) | Externalised config, MySQL with Secret + ConfigMap, env vs volume, data-loss demo | `01-namespace.yaml` ... `05-config-demo.yaml` |
| 07 | [Storage: PV, PVC, StorageClass](07-storage-pv-pvc/) | Static and dynamic provisioning, MySQL that survives Pod deletion | `01-pv.yaml` ... `04-dynamic-pvc.yaml` |
| 08 | [StatefulSet](08-statefulset/) | Stable names, headless Service DNS, one PVC per Pod, ordered start | `01-namespace-secret.yaml` ... `03-statefulset.yaml` |
| 09 | [DaemonSet](09-daemonset/) | One Pod per node, downward API, hostPath, tolerations, nodeSelector | `02-daemonset.yaml` + patches |
| 10 | [Scheduling](10-scheduling/) | nodeSelector, node/pod affinity, taints and tolerations, NoExecute, cordon/drain | `01-nodeselector-pod.yaml` ... `05-noexecute-pod.yaml` |
| 11 | [Autoscaling](11-autoscaling/) | Metrics Server, HPA under load, VPA modes and recommendations | `01-hpa.yaml`, `02-load-generator.yaml`, `03-vpa.yaml` |
| 12 | [Helm](12-helm/) | Helm 4, community charts (Nginx, Jenkins), your own chart, dev/prod values, rollback, tests, packaging | `notes-app/` chart |
| 13 | [kubeadm on AWS](13-kubeadm-aws/) | Real 3-node cluster with one script, Security Group design, Notes app via NodePort | `k8s-setup.sh` |

Capstone project that combines modules 1-13: [TaskBoard-Kanban-K8s](https://github.com/Satyams-git/TaskBoard-Kanban-K8s).

## How to use this repo

1. Do the modules **in order**. Later modules reuse earlier objects (e.g. Module 7 uses the Secret from Module 6; Module 11 uses the Notes app from Module 4).
2. Clone once on your lab machine and `cd` into each module folder:

   ```bash
   git clone https://github.com/Satyams-git/k8s-learning.git && cd k8s-learning
   ```

3. Read the README top to bottom. Run each command, compare with the **Expected** output, then read the explanation table.
4. Do the cleanup at the end of each module unless the README says to keep something for the next one.
5. Do the assignment without looking at the solution YAML.

## Prerequisites

| Item | Details |
| --- | --- |
| Machine | Ubuntu 22.04/24.04, 2 vCPU and 4 GB RAM minimum (EC2 `t2.medium` or larger; `t3.large` is comfortable for Modules 8, 11 and 12) |
| Ports (EC2 Security Group) | 22 (SSH), 30080-30081 (NodePort apps), 8080 (port-forward demos), from your IP |
| Tools | Docker, kubectl, Kind (Module 2), Helm (Module 5 or 12) |
| Knowledge | Linux command line, basic Docker (images, containers, ports) |

Modules 2-12 run on a **Kind** cluster named `demo-cluster` (nodes `demo-cluster-control-plane`, `demo-cluster-worker`, `demo-cluster-worker2`). Commands find worker names with a label selector, so they also work on other clusters. Module 13 builds a real cluster on 3 EC2 instances.

## Repo conventions

- File names are numbered in the order you apply them: `01-...yaml`, `02-...yaml`.
- Every object has an explicit `namespace` (except cluster-wide ones like PersistentVolume), so modules do not collide.
- Image tags are pinned (`nginx:1.27`, `mysql:8.4`, `busybox:1.36`); the Notes app uses `satyamsri/notes-app:latest`.
- Passwords in this repo (`Admin123`) are lab values. Never commit real Secrets.
- All YAML is validated with [kubeconform](https://github.com/yannh/kubeconform) against the Kubernetes schemas.

## Quick reference

```bash
kubectl get pods -A -o wide                 # everything, with nodes
kubectl describe pod <pod> -n <ns>          # events: why Pending / CrashLoopBackOff
kubectl logs <pod> -n <ns> --previous       # logs of the crashed container
kubectl get events -n <ns> --sort-by=.lastTimestamp
kubectl explain deployment.spec.strategy    # built-in field documentation
```
