# Module 12: Helm (Package Manager for Kubernetes)

**Goal:** install ready-made apps with Helm, then turn the Notes app into your own chart: basic first, then professional (helpers, labels, NOTES, tests), with dev/prod values, upgrades, rollbacks and packaging.
**Prerequisite:** Modules 3, 4 and 6. Kind cluster from Module 2. **Time:** 4 hours (theory + 6 labs).

| Path | What it is |
| --- | --- |
| `my-nginx.yaml` | Values override for the Bitnami nginx chart (Lab 2) |
| `my-jenkins.yaml` | Values override for the Jenkins chart (Lab 2) |
| `charts-basic/notes-app/` | Lab 3: a minimal chart (chart version 0.1.0), with a deliberate label bug |
| `notes-app/` | Labs 4-6: the professional chart (version 0.3.0) |
| `values-dev.yaml`, `values-prod.yaml` | Lab 5: per-environment values |

---

# Part A: Theory

## 1. What Helm is and why you need it

The Notes app needed 3 YAML files. A real app (frontend, backend, database, cache, Ingress, ConfigMaps, Secrets, HPA) needs 20-50, and you need them for dev, test and prod with small differences (replicas, image tag, resources). Copy-pasting YAML per environment leads to drift and mistakes.

**Helm is the package manager for Kubernetes**, like `apt` for Ubuntu or `npm` for Node:

| Problem without Helm | With Helm |
| --- | --- |
| Many YAML files applied one by one | One command installs everything: `helm install` |
| Copy YAML per environment | One chart (templates) + one values file per environment |
| "What version is running? What changed?" | Every install/upgrade is a numbered **revision**: `helm history` |
| Rollback = find old YAML and re-apply | `helm rollback <release> <revision>` |
| Writing Jenkins/Prometheus YAML yourself | Install a community chart in one line |

**When not to use Helm:** a single small YAML, or when a team already standardised on Kustomize. Helm adds a template language; it is worth it when you have many objects or many environments.

## 2. Key terms

| Term | Meaning | Analogy |
| --- | --- | --- |
| **Chart** | A package: templates + default values + metadata | A recipe |
| **Values** | Settings that fill the templates (`values.yaml`, `-f`, `--set`) | Quantities in the recipe |
| **Release** | One installed copy of a chart, with a name, in a namespace | A dish cooked from the recipe |
| **Revision** | Version number of a release; +1 on every install/upgrade/rollback | Pages in a diary |
| **Repository** | A server hosting charts (`helm repo add`) | A recipe book shop |
| **OCI registry** | Charts stored in a container registry (Docker Hub, ECR, GHCR) | Same shop as your images |
| **Artifact Hub** | artifacthub.io: search engine for public charts | Google for charts |

> **Chart version vs app version** (`Chart.yaml`): `version` is the chart's own version (bump it whenever the chart changes); `appVersion` is the version of the app inside (informational). They change independently.

## 3. How Helm works

```text
Chart templates  +  values (defaults ← -f file ← --set)
        │
        ▼  helm renders on your machine (Go templates)
  Plain Kubernetes YAML
        │
        ▼  sent to the API server
  Objects in the cluster  +  a release record (a Secret: sh.helm.release.v1.<name>.v<rev>)
```

There is no server-side component (Helm 2's Tiller was removed long ago). Helm uses your kubeconfig like kubectl. The release history is stored as Secrets in the release namespace:

```bash
kubectl get secrets -n <ns> -l owner=helm
```

## 4. Chart structure

```text
notes-app/
├── Chart.yaml            # name, chart version, appVersion, dependencies
├── values.yaml           # default settings
├── charts/               # downloaded subcharts (dependencies)
└── templates/
    ├── deployment.yaml   # templates rendered into YAML
    ├── service.yaml
    ├── _helpers.tpl      # reusable snippets (files starting with _ are not rendered as objects)
    ├── NOTES.txt         # message printed after install/upgrade
    └── tests/
        └── test-connection.yaml   # Pod run by `helm test`
```

## 5. Values: where settings come from

Priority, lowest to highest: chart `values.yaml` → `-f my-values.yaml` (later files win) → `--set key=value`.

- **Maps merge**, key by key: overriding `service.type` keeps `service.port` from the defaults.
- **Lists replace**: an `env:` list in your file replaces the whole default list.
- `--set` syntax: `--set image.tag=1.2`, `--set replicaCount=3`, list item: `--set env[0].name=APP_ENV`.
- **Production rule:** keep values in files in Git and pass them with `-f`. `--set` is for quick tests.
- **Upgrade trap:** `helm upgrade` does not remember earlier `--set` values. Each upgrade = chart defaults + what you pass now. (`--reuse-values` exists but also ignores new chart defaults; avoid it.)

## 6. Template language essentials

| Syntax | Example | Meaning |
| --- | --- | --- |
| Built-in objects | `{{ .Release.Name }}`, `{{ .Release.Namespace }}`, `{{ .Chart.Version }}`, `{{ .Values.x }}` | Values from the command, the chart, the values |
| Pipeline | `{{ .Values.tag \| default "latest" \| quote }}` | Pass a value through functions |
| `toYaml` + `nindent` | `{{- toYaml .Values.resources \| nindent 10 }}` | Turn a values block into YAML, on a new line, indented 10 spaces. The most used pair |
| Whitespace control | `{{-` / `-}}` | Remove spaces/newlines before/after the tag |
| `if` | `{{- if eq .Values.service.type "NodePort" }} ... {{- end }}` | Conditional block |
| `with` | `{{- with .Values.env }} env: {{- toYaml . \| nindent 10 }} {{- end }}` | Skip the block if empty; `.` becomes that value |
| `range` | `{{- range .Values.hosts }} - {{ . }} {{- end }}` | Loop |
| `define` / `include` | `{{- include "notes-app.labels" . \| nindent 4 }}` | Reusable snippets from `_helpers.tpl` |
| Comment | `{{/* not in output */}}` | Template comment |

## 7. Release lifecycle and important flags

| Command | Does |
| --- | --- |
| `helm install <rel> <chart> -n <ns>` | Revision 1 |
| `helm upgrade <rel> <chart> -n <ns> -f values.yaml` | New revision |
| `helm upgrade --install ...` | Install if missing, else upgrade (CI/CD standard) |
| `helm rollback <rel> <rev> -n <ns>` | Re-apply an old revision **as a new revision** |
| `helm history / status / get values / get manifest` | Inspect |
| `helm uninstall <rel> -n <ns>` | Delete the objects (PVCs created by StatefulSets usually remain) |

| Flag | Why |
| --- | --- |
| `--wait --timeout 5m` | Wait until Pods are Ready before reporting success |
| `--rollback-on-failure` | If the upgrade fails, roll back automatically (called `--atomic` in Helm 3) |
| `--dry-run=server` | Render and validate against the API server without creating anything |
| `--create-namespace` | Create the `-n` namespace if missing |
| `--version` | Pin the chart version (always do this in production) |

> **Rollback limit:** Helm restores what it wrote (Deployment, Service, settings), not data inside Pods. Data needs PVCs and backups.

## 8. Helm 4 vs Helm 3

Most online tutorials are Helm 3. Helm 4 (current) keeps the same charts and almost the same commands:

| Helm 3 | Helm 4 |
| --- | --- |
| `--atomic` | `--rollback-on-failure` (old name still works with a warning) |
| `--force` | `--force-replace` |
| Client-side merge | **Server-side apply** for new installs |
| `helm registry login https://registry...` | Domain only: `helm registry login registry-1.docker.io` |
| Install script `get-helm-3` | `get-helm-4` |

---

# Part B: Hands-on

## Lab 1: Install Helm

```bash
kubectl get nodes
```

**Expected:** all nodes `Ready`.

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 && chmod 700 get_helm.sh && ./get_helm.sh
```

**Expected:** `helm installed into /usr/local/bin/helm`.

```bash
helm version && helm list -A
```

**Expected:** `version.BuildInfo{Version:"v4.x.x"...}` and an empty release table (or Traefik if you did Module 5). An empty table with no error means Helm can reach the cluster.

Optional tab completion: `echo 'source <(helm completion bash)' >> ~/.bashrc && source ~/.bashrc`.

## Lab 2: Install ready-made charts (Nginx and Jenkins)

In real jobs you will install other people's charts (Nginx, Jenkins, Prometheus, Grafana) far more often than you write your own.

### Opening apps in the browser

The Kind cluster from Module 2 maps NodePorts **30080** and **30081** to the host, so `http://<EC2-IP>:30081` works once the EC2 security group allows those ports. If your cluster was created without `extraPortMappings`, NodePorts open only inside the Kind node containers; use port-forward instead:

```bash
kubectl port-forward svc/<service> -n <namespace> <host-port>:<service-port> --address=0.0.0.0
```

### Nginx from an OCI registry (no `helm repo add` needed)

On Artifact Hub, search "nginx" and open the Bitnami chart. The INSTALL button shows `helm repo add` + `helm install`, or an `oci://` address. Read the chart first:

```bash
helm show chart oci://registry-1.docker.io/bitnamicharts/nginx && helm show values oci://registry-1.docker.io/bitnamicharts/nginx > nginx-default-values.yaml && grep -nE '^replicaCount|^  type:' nginx-default-values.yaml
```

**Expected:** default `service.type: LoadBalancer` (stays `<pending>` on Kind) and `replicaCount: 1`. Our `my-nginx.yaml` overrides only what differs:

| Key | Meaning |
| --- | --- |
| `replicaCount: 2` | 2 Pods |
| `service.type: NodePort` | Instead of LoadBalancer |
| `service.nodePorts.http: 30081` | Bitnami's key for the NodePort number. **Every chart names its keys differently**: always read `helm show values` |

```bash
helm install my-nginx oci://registry-1.docker.io/bitnamicharts/nginx -n web --create-namespace -f my-nginx.yaml --wait --timeout 5m
```

```bash
helm list -n web && kubectl get pods,svc -n web
```

**Expected:** `STATUS: deployed`, `REVISION: 1`; 2 Pods `Running`; Service `NodePort 80:30081/TCP`. Open `http://<EC2-IP>:30081`: "Welcome to nginx!".

> **`ImagePullBackOff`?** Since August 2025 Bitnami's free catalogue offers only `latest` tags of its hardened images. If the chart's default image cannot be pulled, override it:
> `helm upgrade my-nginx oci://registry-1.docker.io/bitnamicharts/nginx -n web -f my-nginx.yaml --set image.repository=bitnamisecure/nginx --set image.tag=latest --set global.security.allowInsecureImages=true --wait`
> Lesson: the chart being free does not mean every image it references is.

Upgrade, inspect, roll back:

```bash
helm upgrade my-nginx oci://registry-1.docker.io/bitnamicharts/nginx -n web -f my-nginx.yaml --set replicaCount=3 --wait && helm get values my-nginx -n web
```

```bash
helm rollback my-nginx 1 -n web && helm history my-nginx -n web && kubectl get pods -n web
```

**Expected:** revision 2 had 3 Pods; after rollback there is revision 3 (`Rollback to 1`) with 2 Pods. History never deletes entries.

```bash
helm uninstall my-nginx -n web
```

### Jenkins from a Helm repository

```bash
helm repo add jenkins https://charts.jenkins.io && helm repo update && helm show values jenkins/jenkins > jenkins-default-values.yaml && grep -nE 'serviceType|servicePort' jenkins-default-values.yaml | head
```

Nginx used `service.type`; Jenkins uses `controller.serviceType`. No standard: read the values. Our `my-jenkins.yaml` sets `controller.serviceType: NodePort` and `controller.nodePort: 30080`.

```bash
helm install jenkins-demo jenkins/jenkins -n jenkins-ns --create-namespace -f my-jenkins.yaml && kubectl get pods -n jenkins-ns -w
```

**Expected:** `jenkins-demo-0` goes `Init` → `1/2` → `2/2 Running` in 2-5 minutes. Ctrl+C. Three lines of values created all of this:

```bash
kubectl get statefulset,svc,pvc,secret,configmap -n jenkins-ns
```

Get the admin password and log in at `http://<EC2-IP>:30080` as `admin`:

```bash
kubectl exec -n jenkins-ns -it svc/jenkins-demo -c jenkins -- /bin/cat /run/secrets/additional/chart-admin-password && echo
```

```bash
helm upgrade jenkins-demo jenkins/jenkins -n jenkins-ns -f my-jenkins.yaml --set controller.numExecutors=2 && helm history jenkins-demo -n jenkins-ns
```

Cleanup (the Jenkins PVC is not removed by uninstall, so delete the namespace):

```bash
helm uninstall jenkins-demo -n jenkins-ns && kubectl delete namespace jenkins-ns web
```

## Lab 3: A basic chart for the Notes app

`helm create notes-app` generates a large sample chart. We use a minimal chart instead: `charts-basic/notes-app/`.

First remove the kubectl-managed Notes app from Modules 4 and 11. It uses the same `notes-ns` namespace, the same `app: notes-app` label and NodePort 30080, and would mix with the Helm releases:

```bash
kubectl delete -f ../04-services/02-notes-app.yaml --ignore-not-found
```

| Template line | Value from | Rendered |
| --- | --- | --- |
| `name: {{ .Release.Name }}` | The install command | `notes-release` |
| `replicas: {{ .Values.replicaCount }}` | `values.yaml` | `1` |
| `image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"` | `values.yaml` | `satyamsri/notes-app:latest` |
| `port: {{ .Values.service.port }}` | `values.yaml` | `82` |
| No `namespace:` field | | Helm puts objects in the `-n` namespace, so the chart works anywhere |

```bash
cd charts-basic && helm lint ./notes-app && helm template notes-release ./notes-app -n notes-ns
```

**Expected:** `1 chart(s) linted, 0 chart(s) failed` (`icon is recommended` is only INFO), and plain YAML with no `{{ }}` left.

```bash
helm install notes-release ./notes-app -n notes-ns --create-namespace && helm list -n notes-ns && kubectl get deploy,svc,pods -n notes-ns
```

**Expected:** release `notes-release`, `CHART notes-app-0.1.0`, Deployment `1/1`, Service `notes-release ClusterIP 82/TCP`.

```bash
kubectl port-forward svc/notes-release -n notes-ns 8082:82 --address=0.0.0.0
```

Open `http://<EC2-IP>:8082`, then Ctrl+C.

**Find the bug:** install a second release of the same chart in the same namespace:

```bash
helm install notes-two ./notes-app -n notes-ns && kubectl get endpointslices -n notes-ns
```

**Expected:** each Service has **two** endpoints. Both releases label their Pods `app: notes-app`, so each Service selects the other release's Pods too. Lab 4 fixes this.

```bash
helm uninstall notes-two -n notes-ns && cd ..
```

## Lab 4: The professional chart

`notes-app/` (version 0.3.0) fixes three weaknesses of the basic chart: fixed labels (releases collide), hard-coded resources, ClusterIP-only Service.

### `values.yaml`: every setting lives here

| Key | Used for |
| --- | --- |
| `service.type`, `service.nodePort` | ClusterIP or NodePort, chosen by values |
| `resources` | Whole block, rendered with `toYaml` |
| `env` | List of env vars, rendered with `with` + `toYaml` |
| `persistence.mountPath` | Configurable mount path |

### `templates/_helpers.tpl`: two label sets

| Snippet | Labels | Where |
| --- | --- | --- |
| `notes-app.labels` | `app.kubernetes.io/name`, `instance`, `version`, `managed-by`, `helm.sh/chart` | `metadata.labels` of every object |
| `notes-app.selectorLabels` | `app.kubernetes.io/name`, `app.kubernetes.io/instance` | Deployment `selector` + Pod labels + Service `selector` |

`instance: {{ .Release.Name }}` makes each release's labels unique. Selector labels contain nothing that changes between upgrades (no version), because a Deployment's selector is **immutable**.

### Templates, line by line

| Template code | Meaning |
| --- | --- |
| `{{- include "notes-app.labels" . \| nindent 4 }}` | Insert the label block, indented 4 |
| `{{- with .Values.env }} env: {{- toYaml . \| nindent 10 }} {{- end }}` | Add `env:` only when the list is not empty |
| `{{- toYaml .Values.resources \| nindent 10 }}` | Resources from values |
| `{{- if eq .Values.service.type "NodePort" }} nodePort: ... {{- end }}` | `nodePort` only for NodePort Services |
| `NOTES.txt` | Prints how to open the app; branches on the Service type |

```bash
helm lint ./notes-app && helm template notes-release ./notes-app -n notes-ns --set service.type=NodePort | grep -A4 'ports:'
```

**Expected:** standard labels in the output, and `nodePort: 30080` in the NodePort render.

Upgrade the Lab 3 release to the new chart:

```bash
helm upgrade notes-release ./notes-app -n notes-ns
```

**Expected:** an error containing `spec.selector` and `field is immutable`. Lab 3's selector was `app: notes-app`; the new one is `app.kubernetes.io/...`. A Deployment's selector cannot change after creation: **get selector labels right from the start**. Reinstall:

```bash
helm uninstall notes-release -n notes-ns && helm install notes-release ./notes-app -n notes-ns
```

Check the Lab 3 bug is gone:

```bash
helm install notes-two ./notes-app -n notes-ns && kubectl get endpointslices -n notes-ns && kubectl get pods -n notes-ns --show-labels
```

**Expected:** each Service has exactly **one** endpoint; Pods carry `app.kubernetes.io/instance=notes-release` or `=notes-two`.

```bash
helm uninstall notes-two -n notes-ns && helm uninstall notes-release -n notes-ns
```

## Lab 5: One chart, dev and prod

| File | Differs from chart defaults | Rest comes from |
| --- | --- | --- |
| `values-dev.yaml` | 1 replica, `APP_ENV=dev` | `notes-app/values.yaml` |
| `values-prod.yaml` | 3 replicas, NodePort, bigger resources, `APP_ENV=prod` | `notes-app/values.yaml` (image, port, nodePort 30080) |

```bash
helm upgrade --install notes-dev ./notes-app -n dev --create-namespace -f values-dev.yaml && helm upgrade --install notes-prod ./notes-app -n prod --create-namespace -f values-prod.yaml --wait --timeout 3m && helm list -A
```

**Expected:**

```text
NAME        NAMESPACE  REVISION  STATUS    CHART            APP VERSION
notes-dev   dev        1         deployed  notes-app-0.3.0  1.0
notes-prod  prod       1         deployed  notes-app-0.3.0  1.0
```

```bash
kubectl get pods,svc -n dev && kubectl get pods,svc -n prod && helm get values notes-prod -n prod
```

**Expected:** dev: 1 Pod, ClusterIP. prod: 3 Pods, NodePort `82:30080` (open `http://<EC2-IP>:30080`). `helm get values` shows only what you supplied; add `--all` for the merged result.

**Lists replace, they do not merge:**

```bash
kubectl get deploy notes-prod -n prod -o jsonpath='{.spec.template.spec.containers[0].env}'; echo
```

**Expected:** only `APP_ENV=prod`; the prod list replaced the default list entirely.

**Bad upgrade with automatic rollback** (an image tag that does not exist):

```bash
helm upgrade notes-prod ./notes-app -n prod -f values-prod.yaml --set image.tag=does-not-exist --wait --timeout 2m --rollback-on-failure
```

```bash
helm history notes-prod -n prod && kubectl get pods -n prod
```

**Expected** after ~2 minutes:

```text
REVISION  STATUS      DESCRIPTION
1         superseded  Install complete
2         failed      Upgrade "notes-prod" failed: ...
3         deployed    Rollback to 1
```

Pods are back on `latest` and `Running`. This is why CI/CD pipelines use `--wait --rollback-on-failure`.

**Good upgrade, then manual rollback:**

```bash
helm upgrade notes-prod ./notes-app -n prod -f values-prod.yaml --set replicaCount=5 --wait && kubectl get pods -n prod && helm rollback notes-prod 3 -n prod && helm history notes-prod -n prod
```

**Expected:** 5 Pods, then back to 3; history shows revision 4 (upgrade) and 5 (`Rollback to 3`).

## Lab 6: helm test and packaging

`templates/tests/test-connection.yaml`:

| Line | Meaning |
| --- | --- |
| `kind: Pod`, `restartPolicy: Never` | A one-shot test Pod |
| `"helm.sh/hook": test` | Not created on install; only on `helm test` |
| `"helm.sh/hook-delete-policy": before-hook-creation` | Delete the previous test Pod before the next run (so you can read its logs meanwhile) |
| `wget ... http://{{ .Release.Name }}:{{ .Values.service.port }}` | Call this release's Service; a response = exit 0 = pass |

```bash
helm test notes-dev -n dev && kubectl logs notes-dev-test -n dev | head -5
```

**Expected:** `TEST SUITE: notes-dev-test`, `Phase: Succeeded`, and the Notes app's HTML in the logs.

Make it fail:

```bash
kubectl scale deploy notes-dev -n dev --replicas=0 && helm test notes-dev -n dev; kubectl scale deploy notes-dev -n dev --replicas=1
```

**Expected:** `Phase: Failed`. Note: Helm did not notice the `kubectl scale`; its record still says 1 replica and the next `helm upgrade` will reset it. **Do not change Helm-managed objects with kubectl.**

Package and install from the file:

```bash
helm package ./notes-app && tar -tzf notes-app-0.3.0.tgz && helm install notes-pkg ./notes-app-0.3.0.tgz -n pkg --create-namespace --wait && helm test notes-pkg -n pkg
```

**Expected:** `Successfully packaged chart and saved it to: .../notes-app-0.3.0.tgz`, and a successful test.

Optional, push to Docker Hub as an OCI artifact:

```bash
helm registry login registry-1.docker.io -u <dockerhub-username> && helm push notes-app-0.3.0.tgz oci://registry-1.docker.io/<dockerhub-username>
```

Anyone can now install it with `helm install notes oci://registry-1.docker.io/<dockerhub-username>/notes-app --version 0.3.0`.

---

# Part C: Troubleshooting and cleanup

### Debug order

```bash
helm lint ./notes-app
```

```bash
helm template notes-release ./notes-app -f values-prod.yaml
```

```bash
helm install notes-release ./notes-app -n notes-ns --dry-run=server
```

```bash
helm status <release> -n <ns> && helm get manifest <release> -n <ns>
```

Then the usual `kubectl get pods` / `kubectl describe pod`.

| Error | Cause | Fix |
| --- | --- | --- |
| `cannot re-use a name that is still in use` | Release exists | `helm upgrade`, or `helm upgrade --install` |
| `release: not found` | Forgot `-n` | Add `-n <ns>` to every command |
| `YAML parse error on notes-app/templates/x.yaml` | Bad indentation or tabs | Run `helm template`; check the `nindent` numbers |
| `field is immutable` (`spec.selector`) | Selector labels changed | Uninstall and reinstall; keep selector labels stable |
| `... exists and cannot be imported into the current release` | An object with that name already exists (created by kubectl or another release) | Delete it, or include `{{ .Release.Name }}` in names |
| `nil pointer evaluating interface {}.enabled` | Leftover `helm create` templates referencing values you deleted | `rm -rf notes-app/templates/*` and add your own files |
| `provided port is already allocated` | NodePort 30080 used by another Service | Use ClusterIP or another `nodePort` for the second release |
| A value changed but nothing changed | The template never uses that key | Check with `helm template` |
| `--set` value lost after upgrade | Upgrade does not remember `--set` | Use values files with `-f` |

### Cleanup

```bash
helm uninstall notes-dev -n dev; helm uninstall notes-prod -n prod; helm uninstall notes-pkg -n pkg; kubectl delete ns dev prod pkg notes-ns --ignore-not-found && rm -f notes-app-*.tgz
```

### Assignment

1. Add an optional HPA template to `notes-app` (`templates/hpa.yaml`) wrapped in `{{- if .Values.autoscaling.enabled }}`, with `minReplicas`, `maxReplicas` and `targetCPUUtilizationPercentage` in values. Bump the chart version.
2. Add a `range` over `.Values.extraLabels` (a map) to the Pod labels.
3. Create `values-staging.yaml` (2 replicas, `APP_ENV=staging`) and install it next to dev and prod.
4. Explain the difference between `version` and `appVersion` and when each changes.
5. Install `prometheus-community/kube-prometheus-stack` using only `helm show values` to find the right keys to expose Grafana.

## Sources

- [Helm documentation](https://helm.sh/docs/) and [Installing Helm](https://helm.sh/docs/intro/install/)
- [Helm 4 overview](https://helm.sh/docs/overview)
- [Chart template guide](https://helm.sh/docs/chart_template_guide/)
- [Artifact Hub](https://artifacthub.io/)
