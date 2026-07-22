kubectl create secret generic bot-maison-secret \
  --from-literal=token="$DISCORD_TOKEN" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > kubernetes/apps/bot-maison/bot-maison-sealed.yaml