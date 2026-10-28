#!/usr/bin/env bash

if [[ "${VERCEL_GIT_COMMIT_REF:-}" != "main" ]]; then
  exit 0
fi

if [[ -z "${VERCEL_GIT_PREVIOUS_SHA:-}" ]]; then
  exit 1
fi

if git diff --quiet "$VERCEL_GIT_PREVIOUS_SHA" HEAD -- .; then
  exit 0
fi

exit 1
