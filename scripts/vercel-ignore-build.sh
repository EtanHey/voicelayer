#!/usr/bin/env bash

if [[ "${VERCEL_GIT_COMMIT_REF:-}" != "main" ]]; then
  exit 0
fi

if git diff --quiet "${VERCEL_GIT_PREVIOUS_SHA:-HEAD^}" HEAD -- .; then
  exit 0
fi

exit 1
