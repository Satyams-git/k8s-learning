#!/bin/bash

kubectl delete -f load-generator/load-generator.yml
kubectl delete -f load-generator/stress-load.yml

kubectl delete -f vpa/vpa.yml

kubectl delete -f notes-app/notes-service.yml
kubectl delete -f notes-app/notes-app.yml

kubectl delete ns notes-ns
kubectl delete ns load-ns
