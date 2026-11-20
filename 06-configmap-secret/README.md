# Module 6: ConfigMap and Secret

**Goal:** keep configuration and passwords outside the container image, and inject them into Pods. Run MySQL using a Secret for the password and a ConfigMap for the database name, then see why it loses data without storage.
**Prerequisite:** Module 4. **Time:** 1.5 hours.

| File | What it creates |
| --- | --- |
| `01-namespace.yaml` | Namespace `mysql` |
| `02-secret.yaml` | Secret `mysql-secret` (root password) |
| `03-configmap.yaml` | ConfigMap `mysql-config` (database name) |
| `04-mysql-deployment.yaml` | Deployment `mysql-dep` + Service `mysql-svc` |
| `05-config-demo.yaml` | ConfigMap `app-config` + Pod `config-demo` (envFrom and volume file) |

---

## 1. Why ConfigMap and Secret

If a database URL or password is written inside the image, you must rebuild the image for every environment (dev, test, prod) and anyone who can pull the image can read the password. The rule (from the 12-factor app): **build once, configure per environment**.

| | ConfigMap | Secret |
| --- | --- | --- |
| Holds | Non-sensitive config: DB name, log level, feature flags, config files | Sensitive data: passwords, API tokens, TLS keys |
| Stored as | Plain text | base64-encoded (and can be encrypted at rest in etcd if the admin enables it) |
| Size limit | 1 MiB | 1 MiB |
| Used as | Env vars, files in a volume, command args | Same |

> **base64 is encoding, not encryption.** Anyone with `kubectl get secret -o yaml` can decode it. Protect Secrets with RBAC, encryption at rest, and tools like External Secrets Operator / Sealed Secrets / Vault in production.

## 2. Step 1: namespace

```bash
kubectl apply -f 01-namespace.yaml && kubectl get ns mysql
```

## 3. Step 2: Secret

Encode the password. **Use `echo -n`**: without `-n`, echo adds a newline, the newline is encoded too, and MySQL's password becomes `Admin123\n`. Login then fails with "Access denied" and it is very hard to spot.

```bash
echo -n 'Admin123' | base64
```

**Expected:** `QWRtaW4xMjM=` (without `-n` you would get `QWRtaW4xMjMK`, note the `K` at the end).

| Line in `02-secret.yaml` | Meaning |
| --- | --- |
| `kind: Secret` | Sensitive key-value store |
| `type: Opaque` | Generic user-defined secret (the most common type) |
| `data.password: QWRtaW4xMjM=` | Values under `data` must be base64. Use `stringData:` instead if you want to write plain text and let Kubernetes encode it |

```bash
kubectl apply -f 02-secret.yaml && kubectl get secret mysql-secret -n mysql
```

Decode it to prove it is not encrypted:

```bash
kubectl get secret mysql-secret -n mysql -o jsonpath='{.data.password}' | base64 -d; echo
```

**Expected:** `Admin123`.

Imperative alternative (Kubernetes encodes it for you): `kubectl create secret generic mysql-secret -n mysql --from-literal=password=Admin123`.

### Secret types

| Type | Used for |
| --- | --- |
| `Opaque` | Any user data (default) |
| `kubernetes.io/dockerconfigjson` | Private registry credentials (`imagePullSecrets`) |
| `kubernetes.io/tls` | TLS certificate + key (`tls.crt`, `tls.key`), used by Ingress / Gateway |
| `kubernetes.io/basic-auth` | `username` + `password` |
| `kubernetes.io/ssh-auth` | SSH private key |
| `kubernetes.io/service-account-token` | Legacy ServiceAccount token |

## 4. Step 3: ConfigMap

```bash
kubectl apply -f 03-configmap.yaml && kubectl describe configmap mysql-config -n mysql
```

**Expected:** `database: myDB` under `Data`.

## 5. Step 4: MySQL Deployment using both

| Line in `04-mysql-deployment.yaml` | Meaning |
| --- | --- |
| `image: mysql:8.4` | MySQL 8.4 LTS |
| `MYSQL_ROOT_PASSWORD` ← `secretKeyRef` | The image reads this env var to set the root password; the value comes from Secret `mysql-secret`, key `password` |
| `MYSQL_DATABASE` ← `configMapKeyRef` | The image creates this database on first start; the value comes from ConfigMap `mysql-config`, key `database` |
| `requests 250m/512Mi`, `limits 1/1Gi` | MySQL needs memory; with too low a limit it gets `OOMKilled` |
| `mysql-svc` port 3306 | ClusterIP Service so other Pods reach MySQL by name |

```bash
kubectl apply -f 04-mysql-deployment.yaml && kubectl get pods -n mysql -w
```

Wait for `1/1 Running` (MySQL takes 30-60 seconds to initialise), then press Ctrl+C.

Check the env vars inside the container:

```bash
kubectl exec -n mysql deploy/mysql-dep -- printenv MYSQL_DATABASE MYSQL_ROOT_PASSWORD
```

**Expected:** `myDB` and `Admin123`. (This also shows that anyone with `exec` access can read Secrets: RBAC matters.)

## 6. Step 5: create data

Open a MySQL shell (enter `Admin123` when asked):

```bash
kubectl exec -it -n mysql deploy/mysql-dep -- mysql -u root -p
```

Inside MySQL:

```sql
SHOW DATABASES;
USE myDB;
CREATE TABLE students (id INT PRIMARY KEY, name VARCHAR(50));
INSERT INTO students VALUES (1, 'Aman'), (2, 'Priya');
SELECT * FROM students;
exit
```

**Expected:** `myDB` is listed (created from the ConfigMap), and the select shows 2 rows.

## 7. Step 6: the data-loss demo

Delete the Pod. The Deployment creates a new one:

```bash
kubectl delete pod -n mysql -l app=mysql && kubectl get pods -n mysql -w
```

When the new Pod is `Running`, check the table:

```bash
kubectl exec -it -n mysql deploy/mysql-dep -- mysql -u root -pAdmin123 -e "SELECT * FROM myDB.students;"
```

**Expected:** `ERROR 1146 (42S02): Table 'myDB.students' doesn't exist`.

**Why:** the data lived in the container's writable layer (`/var/lib/mysql`). A new Pod = a new container = an empty disk. The database `myDB` exists again only because MySQL re-created it from the ConfigMap. **Module 7 fixes this with a PersistentVolume.**

## 8. Step 7: ConfigMap as env vars and as a file

| Part of `05-config-demo.yaml` | Meaning |
| --- | --- |
| `app.properties: \|` | A multi-line value: a whole config file stored in one key |
| `envFrom.configMapRef` | Every key in the ConfigMap becomes an env var (keys with dots, like `app.properties`, are skipped because they are not valid env var names) |
| `volumes.configMap.items` | Mount only the `app.properties` key as a file |
| `mountPath: /etc/config` | The file appears at `/etc/config/app.properties` |

```bash
kubectl apply -f 05-config-demo.yaml && kubectl wait --for=condition=Ready pod/config-demo -n mysql --timeout=60s
```

```bash
kubectl exec -n mysql config-demo -- sh -c 'echo "APP_ENV=$APP_ENV LOG_LEVEL=$LOG_LEVEL"; cat /etc/config/app.properties'
```

**Expected:**

```text
APP_ENV=production LOG_LEVEL=info
server.port=8080
feature.dark-mode=true
```

### What happens when you change a ConfigMap?

```bash
kubectl patch configmap app-config -n mysql --type merge -p '{"data":{"LOG_LEVEL":"debug","app.properties":"server.port=9090\n"}}'
```

Wait about a minute, then run the same `exec` again.

| Consumed as | Updates automatically? |
| --- | --- |
| Volume file | **Yes**, after the kubelet sync (up to ~1 min). Not with `subPath` mounts |
| Env var (`env` / `envFrom`) | **No.** Env vars are fixed at container start. Restart: `kubectl rollout restart deployment/<name>` |

**Expected:** the file shows `server.port=9090`, but `LOG_LEVEL` is still `info`.

## 9. Best practices

- Never commit real Secrets to Git. Commit a template, keep real values in a vault or a git-ignored file.
- Enable **encryption at rest** for Secrets in etcd (managed clusters often do this by default).
- Limit `get secret` and `exec` with RBAC.
- Mark ConfigMaps/Secrets `immutable: true` when they never change: safer, and less load on the API server.
- Use `stringData` when writing by hand to avoid base64 mistakes.
- In production, use External Secrets Operator, Sealed Secrets, or HashiCorp Vault.

## 10. Troubleshooting

| Error | Cause | Fix |
| --- | --- | --- |
| `CreateContainerConfigError` | Secret/ConfigMap or key not found (wrong name, wrong namespace) | `kubectl describe pod`; they must be in the **same namespace** as the Pod |
| `Access denied for user 'root'` | Newline in the password (`echo` without `-n`), or the data dir was initialised with an older password | Re-encode with `echo -n`; delete the Pod (no PV yet) |
| `OOMKilled` | Memory limit too low for MySQL | Keep at least `512Mi` request / `1Gi` limit |
| `illegal base64 data` on apply | Plain text put under `data:` | Encode it, or use `stringData:` |
| Env var did not change after editing ConfigMap | Env vars are read at start only | `kubectl rollout restart deployment/<name>` |

## 11. Cleanup and assignment

Keep the `mysql` namespace, Secret and ConfigMap for Module 7. Remove the demo and the Deployment:

```bash
kubectl delete -f 05-config-demo.yaml -f 04-mysql-deployment.yaml
```

**Assignment**

1. Create a Secret `api-secret` with `stringData` keys `API_KEY` and `API_URL`. Inject both with `envFrom.secretRef` into a busybox Pod and print them.
2. Create a `kubernetes.io/dockerconfigjson` Secret with `kubectl create secret docker-registry` and explain where `imagePullSecrets` is used.
3. Mount a ConfigMap containing an `nginx.conf` into an nginx Pod at `/etc/nginx/conf.d/` and change the listen port.
4. Explain in 3 lines why base64 is not security.
