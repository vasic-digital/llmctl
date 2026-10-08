#!/usr/bin/env bash
# bad_decide.sh - fake `llmctl-decide` whose behaviour is chosen by BAD_DECIDE_MODE (hook error-path tests).
case "${BAD_DECIDE_MODE:-garbage}" in
  garbage) echo "this is not json"; exit 0 ;;
  noconf) echo '{"model":"m","answers":{"q":{"type":"choice","choice":"allow","probabilities":{"allow":0.9,"review":0.05,"block":0.05}}}}'; exit 0 ;;
  nochoice) echo '{"model":"m","answers":{}}'; exit 0 ;;
  hang) sleep 30 ;;
  crash) echo "boom" >&2; exit 139 ;;
  abstain) echo '{"model":"m","answers":{"q":{"type":"choice","choice":"allow","confidence":0.1}},"abstained":true}'; exit 10 ;;
  lowconf) echo '{"model":"m","answers":{"q":{"type":"choice","choice":"allow","confidence":0.1}}}'; exit 0 ;;
  surprise) echo '{"model":"m","answers":{"q":{"type":"choice","choice":"maybe","confidence":0.99}}}'; exit 0 ;;
esac
