MAX_TRIES=2
for i in $(seq 1 ${MAX_TRIES}); do
  if /root/check.sh; then
    exit 0
  fi
  echo "Attempt ${i}: proxy broken, switching..."
  /root/switch.sh --next
  /root/trpoxy.sh
  sleep 3
done
echo "All ${MAX_TRIES} nodes failed — check subscription"
exit 1
