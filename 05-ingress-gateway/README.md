# Module 5: Ingress and Gateway API

**Goal:** send traffic from one entry point to different apps by path (`/` → frontend, `/api` → backend), first with Ingress, then with the newer Gateway API.
**Prerequisite:** Module 4. **Time:** 2 hours.

| File | What it creates |
| --- | --- |
| `01-apps.yaml` | `frontend` (http-echo) and `backend` (whoami) Deployments + ClusterIP Services in `nginx-ns` |
| `02-middleware.yaml` | Traefik Middleware that strips the `/api` prefix |
| `03-ingress.yaml` | Ingress: `/api` → backend-svc:81, `/` → frontend-svc:80 |
| `04-httproute.yaml` | The same routing as a Gateway API HTTPRoute |

---

## 1. Why Ingress

Imagine five apps, each on its own NodePort: `IP:30080`, `IP:30081`, `IP:30082`... Users cannot remember ports, and opening one port per app is bad for security and maintenance. Companies want **one domain, many paths**:

```text
shopworld.com          → frontend
shopworld.com/api      → backend
shopworld.com/login    → login service
```

**Ingress** does this: it looks at the host and path of each HTTP/HTTPS request and sends it to the right Service. It also gives one entry point, TLS (HTTPS) termination and load balancing.

Analogy: the building is the cluster, the main gate is the Ingress, and the security guard is the Ingress Controller. The guard asks "where are you going?" and sends `/api` visitors to the backend office and everyone else to the frontend office.

### Ingress vs Ingress Controller

| | Ingress | Ingress Controller |
| --- | --- | --- |
| What it is | A YAML resource: the routing **rules** | Software running as Pods that **applies** those rules |
| Analogy | The guard's written list | The guard |
| Who provides it | Kubernetes API (`networking.k8s.io/v1`) | You install one: Traefik, HAProxy, Kong, cloud controllers |

> Applying an Ingress YAML does nothing on its own. A controller must be running in the cluster to read it.

## 2. Important update: ingress-nginx is retired

Many older notes use the `ingress-nginx` controller with `ingressClassName: nginx`. Kubernetes announced its retirement in November 2025: after March 2026 it gets no releases, bug fixes or security patches ([kubernetes.io blog](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)). In January 2026 the Steering and Security Response Committees warned that clusters still on it are exposed, and that there is no drop-in replacement ([statement](https://www.kubernetes.io/blog/2026/01/29/ingress-nginx-statement/)).

| | Old notes | This course |
| --- | --- | --- |
| Controller | ingress-nginx (retired) | **Traefik** (maintained; supports Ingress and Gateway API) |
| `ingressClassName` | `nginx` | `traefik` |
| Path rewrite | `nginx.ingress.kubernetes.io/rewrite-target` | Traefik `Middleware` (stripPrefix), or Gateway API `URLRewrite` |
| New concept | | **Gateway API** (`Gateway` + `HTTPRoute`), the modern replacement for Ingress |

> The Ingress **API** (`kind: Ingress`) is not deprecated; only one controller (ingress-nginx) is retired. For new projects the Kubernetes project recommends Gateway API.

## 3. Routing at a glance

```text
                       +--> /api/...  --(strip /api)-->  backend-svc:81  --> whoami pods
Browser --> Traefik ---+
                       +--> /...      ------------------> frontend-svc:80 --> http-echo pods
```

Part A (Ingress) and Part B (Gateway API) produce the same picture; only the way you write the rules changes.

## 4. Install the controller

### Step 1: install Helm (only the binary; Helm is covered in Module 12)

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 && chmod 700 get_helm.sh && ./get_helm.sh && helm version
```

**Expected:** `version.BuildInfo{Version:"v4.x.x", ...}`.

### Step 2a: install the Gateway API CRDs

`Gateway` and `HTTPRoute` are not built into Kubernetes; their CRDs (Custom Resource Definitions) are installed separately:

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml && kubectl get crd | grep gateway.networking.k8s.io
```

**Expected:** `gatewayclasses`, `gateways`, `httproutes`, `referencegrants` and others.

### Step 2b: install Traefik

```bash
helm repo add traefik https://traefik.github.io/charts && helm repo update
```

```bash
helm install traefik traefik/traefik --namespace traefik --create-namespace --set providers.kubernetesGateway.enabled=true --set gateway.listeners.web.namespacePolicy.from=All
```

| Flag | Meaning |
| --- | --- |
| `helm install traefik traefik/traefik` | Release `traefik` from the `traefik` chart in the `traefik` repo |
| `--namespace traefik --create-namespace` | Controller in its own namespace |
| `providers.kubernetesGateway.enabled=true` | Turn on Gateway API support next to Ingress. The chart creates a `GatewayClass` (`traefik`) and a default `Gateway` (`traefik-gateway`) |
| `gateway.listeners.web.namespacePolicy.from=All` | Let the default Gateway accept HTTPRoutes from other namespaces (like `nginx-ns`) |

```bash
kubectl get pods,svc -n traefik && kubectl get ingressclass,gatewayclass && kubectl get gateway -n traefik
```

**Expected:** a `traefik-xxxx` Pod `Running`; IngressClass `traefik`; GatewayClass `traefik` `ACCEPTED True`; Gateway `traefik-gateway`. On Kind the `traefik` Service shows `EXTERNAL-IP <pending>` (Module 4), so we use port-forward.

### Step 2c: open a path to the controller (keep it running in its own terminal)

```bash
kubectl port-forward svc/traefik -n traefik 8080:80 --address=0.0.0.0
```

`http://<EC2-IP>:8080` is now the single entry point for all routes. With no rules yet you get `404 page not found`, which is correct.

## 5. Step 3: frontend and backend apps

Older labs used `nginx` for both Pods, so both URLs showed the same page and routing was invisible. This lab uses two different images:

- **frontend:** `hashicorp/http-echo` replies "Welcome to Frontend" to every request.
- **backend:** `traefik/whoami` replies with the request details, **including the path it received**. Perfect for seeing the rewrite.

| Line in `01-apps.yaml` | Meaning |
| --- | --- |
| `args: ["-text=Welcome to Frontend"]` | Argument passed to the program at start; http-echo returns this text |
| `containerPort: 5678` | http-echo listens on 5678 by default |
| `frontend-svc`: `port: 80` → `targetPort: 5678` | Service on 80, Pod on 5678 |
| `backend-svc`: `port: 81` → `targetPort: 80` | Service on 81, whoami Pod on 80 |

No `type` is set, so both Services are `ClusterIP`. Outside traffic arrives only through the Ingress Controller: the right design.

```bash
kubectl apply -f 01-apps.yaml && kubectl get deploy,svc -n nginx-ns
```

## 6. Step 4: Ingress with path rewrite

### 4a. Middleware: strip the `/api` prefix

The user asks for `/api/users`, but the backend only knows `/users`. The `/api` part must be removed on the way. In Traefik a **Middleware** does that.

| Line in `02-middleware.yaml` | Meaning |
| --- | --- |
| `apiVersion: traefik.io/v1alpha1` | Traefik's own CRD (installed by the chart), not a built-in Kubernetes type |
| `kind: Middleware` | A step that changes the request before it reaches the backend |
| `stripPrefix.prefixes: [/api]` | Remove `/api` from the start of the path: `/api/users` → `/users`, `/api` → `/` |

### 4b. Ingress

| Line in `03-ingress.yaml` | Meaning |
| --- | --- |
| `apiVersion: networking.k8s.io/v1` | Ingress API group |
| `annotations: ...router.middlewares` | Attach the `strip-api` Middleware. Format: `<namespace>-<middleware>@kubernetescrd` |
| `ingressClassName: traefik` | The Traefik controller reads these rules |
| `rules: - http:` | HTTP rules; no `host`, so they apply to any host |
| `path: /api`, `pathType: Prefix` | Everything starting with `/api` → `backend-svc:81` |
| `path: /`, `pathType: Prefix` | Everything else → `frontend-svc:80` |

```bash
kubectl apply -f 02-middleware.yaml -f 03-ingress.yaml && kubectl get ingress -n nginx-ns
```

### 4c. Test (the port-forward terminal must be running)

```bash
curl http://localhost:8080/ && curl http://localhost:8080/api/users
```

**Expected:**

```text
Welcome to Frontend

Hostname: backend-xxxxxxxxx-abcde
...
GET /users HTTP/1.1
...
X-Forwarded-Prefix: /api
```

The backend received `/users`, not `/api/users`: the Middleware removed the prefix. Try `http://<EC2-IP>:8080/` and `http://<EC2-IP>:8080/api/hello` in the browser too.

### Two mistakes in older notes

> **"If the rule order is wrong, `/api` never matches."** Not true. With `pathType: Prefix`, Kubernetes uses the **longest matching path**, whatever the order in the YAML. `/api` always beats `/` for `/api/users`. Putting specific paths first is still a good readability habit.

> **"`rewrite-target: /` turns `/api/users` into `/users`."** In ingress-nginx, `rewrite-target: /` turned every matching path into `/` (`/api/users` → `/`), and the annotation applied to the whole Ingress, frontend paths included. Removing only the prefix needed a regex capture group. Traefik's `stripPrefix` and Gateway API's `ReplacePrefixMatch` do it cleanly.

### Bonus: host-based routing

```yaml
  rules:
  - host: shop.local
    http:
      paths: [...]
```

Test with `curl -H "Host: shop.local" http://localhost:8080/`. For a real domain, point a DNS A record at the controller's IP.

## 7. Part B: Gateway API

### Theory

Ingress was simple, but every advanced feature (rewrite, timeout, headers) needed **controller-specific annotations**, so changing controllers meant rewriting them all. Gateway API solves this with standard fields, and splits the work by role:

| Resource | Created by | Defines | Analogy |
| --- | --- | --- | --- |
| `GatewayClass` | Platform / controller (the Traefik chart created `traefik`) | Which controller | The mall's maintenance company |
| `Gateway` | Cluster / platform team (the chart created `traefik-gateway`) | Which port/protocol to listen on (listener) | The mall's main gate |
| `HTTPRoute` | App team | Which path/host goes to which Service | Each shop's signboard |

See what the chart created:

```bash
kubectl get gateway traefik-gateway -n traefik -o yaml | sed -n '/^spec:/,$p'
```

You will see `gatewayClassName: traefik`, a listener named `web` on `port: 8000` with `protocol: HTTP`, and `allowedRoutes.namespaces.from: All`. Port 8000 is the "web" port inside the Traefik Pod; the `traefik` Service exposes it on port 80.

### Write the HTTPRoute

Remove the Ingress first so the two do not compete for the same paths:

```bash
kubectl delete -f 03-ingress.yaml -f 02-middleware.yaml
```

| Line in `04-httproute.yaml` | Meaning |
| --- | --- |
| `apiVersion: gateway.networking.k8s.io/v1` | Gateway API stable (GA) version |
| `kind: HTTPRoute` | Routing rules for HTTP traffic |
| `parentRefs:` | Attach this route to `traefik-gateway` in namespace `traefik` |
| `matches.path.type: PathPrefix`, `value: /api` | Paths starting with `/api` |
| `filters.type: URLRewrite` | Change the URL before sending it on. **A standard field, not an annotation** |
| `ReplacePrefixMatch: /` | Replace the matched prefix (`/api`) with `/`: `/api/users` → `/users` |
| `backendRefs: backend-svc:81` | Where the traffic goes |
| Second rule `/` → `frontend-svc:80` | Everything else to the frontend |

```bash
kubectl apply -f 04-httproute.yaml && kubectl get httproute -n nginx-ns && kubectl describe httproute app-route -n nginx-ns | grep -A4 Conditions
```

```bash
curl http://localhost:8080/ && curl http://localhost:8080/api/users
```

**Expected:** `Accepted: True` and `ResolvedRefs: True` in `describe`, and the same curl output as the Ingress version.

### Ingress vs Gateway API

| Point | Ingress | Gateway API |
| --- | --- | --- |
| Status | Stable but feature-frozen | Kubernetes' recommended future |
| Rewrite, headers, traffic split | Controller-specific annotations | Standard fields (`filters`, `weight`) |
| Roles | One object for everything | GatewayClass / Gateway / Route for different teams |
| Protocols | Mainly HTTP/HTTPS | HTTP, gRPC, TLS (TCP/UDP experimental) |
| Changing controller | Rewrite the annotations | Usually just change `gatewayClassName` |

## 8. Troubleshooting, cleanup and assignment

| Error | Cause | Fix |
| --- | --- | --- |
| `404 page not found` (Traefik) | No rule matched: wrong `ingressClassName`, or a `host` is set but the request has no matching Host header | `kubectl describe ingress app-ingress -n nginx-ns`; check `ingressClassName: traefik` |
| `Bad Gateway` (502) | The Service `targetPort` does not match the Pod port | frontend 5678, backend 80 |
| `Service Unavailable` (503) | The Service has no endpoints | `kubectl get endpointslices -n nginx-ns`; check labels |
| Backend gets the full `/api/...` path | Wrong Middleware annotation, or Middleware in another namespace | Format `<ns>-<name>@kubernetescrd` |
| HTTPRoute `Accepted: False`, `NotAllowedByListeners` | The Gateway does not allow routes from other namespaces | Was `namespacePolicy.from=All` set? Fix with `helm upgrade` |
| `connection refused` on :8080 | The port-forward stopped | Run Step 2c again |
| Need Traefik logs | | `kubectl logs -n traefik deploy/traefik` |

**Cleanup** (keep Traefik: Modules 14 and 16 use it):

```bash
kubectl delete -f 04-httproute.yaml -f 01-apps.yaml
```

To remove Traefik as well: `helm uninstall traefik -n traefik && kubectl delete ns traefik`.

**Assignment**

1. Add a third app: `hashicorp/http-echo:1.0` with text "Login Page", Service `login-svc` on port 82.
2. Route `/login` → `login-svc` with an Ingress. Test that `/`, `/api` and `/login` each go to the right place.
3. Build the same routing with an HTTPRoute.
4. Bonus: in an HTTPRoute, give `backendRefs` two Services with `weight: 80` and `weight: 20` (canary). Run `curl` 20 times and note the ratio.
5. One paragraph: after the ingress-nginx retirement, what options does a company have?

## Sources

- [Ingress NGINX Retirement: What You Need to Know](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/) (kubernetes.io, Nov 2025)
- [Ingress NGINX: Statement from the Kubernetes Steering and Security Response Committees](https://www.kubernetes.io/blog/2026/01/29/ingress-nginx-statement/) (kubernetes.io, Jan 2026)
- [Gateway API v1.5: Moving features to Stable](https://kubernetes.io/blog/2026/04/21/gateway-api-v1-5/) (kubernetes.io, Apr 2026)
- [Traefik & Kubernetes with Gateway API](https://doc.traefik.io/traefik/master/reference/install-configuration/providers/kubernetes/kubernetes-gateway/)
- [Installing Helm](https://helm.sh/docs/intro/install/)
