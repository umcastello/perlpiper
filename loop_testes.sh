#!/bin/bash
PLAYBOOKS=(
  "playbook.yml"
  "test_user.yml"
  "test-file.yml"
  "test-file2.yml"
  "test-cron.yml"
  "test-cron2.yml"
)

for pb in "${PLAYBOOKS[@]}"; do
  echo "=== RODANDO $pb ==="
  perl perlpiper.pl "$pb" && echo "OK: $pb"
  echo
done
