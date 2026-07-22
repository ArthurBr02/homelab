# Sur la machine en local
ssh -L 8080:localhost:8080 ubuntu@192.168.1.100

# Sur le control plane

sudo kubectl port-forward -n argocd svc/argocd-server 8080:443