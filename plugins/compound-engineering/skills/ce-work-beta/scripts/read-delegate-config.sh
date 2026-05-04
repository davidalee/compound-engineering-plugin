#!/bin/sh
top=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$top" ]; then
  cat "$top/.compound-engineering/config.local.yaml" 2>/dev/null || echo '__NO_CONFIG__'
else
  echo '__NO_CONFIG__'
fi
