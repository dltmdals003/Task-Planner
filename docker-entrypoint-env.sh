#!/bin/sh
set -eu
envsubst '${VITE_SUPABASE_URL} ${VITE_SUPABASE_PUBLISHABLE_KEY}' \
  < /usr/share/nginx/html/env.js.template \
  > /usr/share/nginx/html/env.js
