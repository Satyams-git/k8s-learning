

# README

## MySQL Deployment on Kubernetes (Steps and Commands Only)

---

# 1. Namespace

```
kubectl apply -f namespace.yml
kubectl get ns
```

---

# 2. Secret

Base64 encode password:

```
echo -n 'Admin123' | base64
```

Apply Secret:

```
kubectl apply -f secret.yml
kubectl get secret -n mysql
```

---

# 3. ConfigMap

```
kubectl apply -f configmap.yml
kubectl get configmap -n mysql
```

---

# 4. Deployment

```
kubectl apply -f deployment.yml
kubectl get deploy -n mysql
kubectl get pods -n mysql -o wide
kubectl describe pod <pod-name> -n mysql
```

---

# 5. Service

```
kubectl apply -f service.yml
kubectl get svc -n mysql
```

---

# 6. Pod and Logs

```
kubectl get pods -n mysql
kubectl describe pod <pod-name> -n mysql
kubectl logs <pod-name> -n mysql
kubectl logs -f <pod-name> -n mysql
```

---

# 7. Connect to MySQL

Get pod:

```
kubectl get pods -n mysql
```

Open MySQL shell:

```
kubectl exec -it -n mysql <pod-name> -- mysql -u root -p
```

Password:

```
Admin123
```

Inside MySQL:

```
SHOW DATABASES;
USE myDB;
CREATE TABLE employees (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(50),
  role VARCHAR(50),
  salary INT
);
INSERT INTO employees (name, role, salary) VALUES ('Satyam','DevOps Trainer',90000);
SELECT * FROM employees;
EXIT;
```

---

# 8. Verify Environment Variables

```
kubectl exec -it -n mysql $(kubectl get pod -n mysql -o name) -- env | grep MYSQL
```

---

# 9. Apply All Files

One by one:

```
kubectl apply -f namespace.yml
kubectl apply -f secret.yml
kubectl apply -f configmap.yml
kubectl apply -f deployment.yml
kubectl apply -f service.yml
```

Or all at once:

```
kubectl apply -f .
```

---

# 10. Cleanup

```
kubectl delete ns mysql
```

---

