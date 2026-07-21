#!/bin/sh
sudo kubectl apply -f sealed-secrets-key-backup.yaml
sudo kubectl delete pod -n kube-system -l name=sealed-secrets-controller