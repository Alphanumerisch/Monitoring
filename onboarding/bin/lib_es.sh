#!/usr/bin/env bash
set -euo pipefail


: "${ES_HOST:?set ES_HOST}"; : "${ES_USER:?set ES_USER}"; : "${ES_PASS:?set ES_PASS}"
: "${ES_CA:=}"


# bin/lib_es.sh
_curl() {
  local method="$1" path="$2"; shift 2
  local url="${ES_HOST%/}${path}" ; local ca=()
  [[ -n "$ES_CA" ]] && ca=(--cacert "$ES_CA")
  curl -sS --fail \
    --connect-timeout 5 --max-time 15 \
    -u "$ES_USER:$ES_PASS" -X "$method" "$url" \
    -H 'Content-Type: application/json' "${ca[@]}" "$@"
}


es_get() { _curl GET "$1"; }
es_put() { _curl PUT "$1" -d "$2"; }
es_post() { _curl POST "$1" -d "$2"; }
es_head() { _curl HEAD "$1"; }


es_ok() { es_get "/_cluster/health" | jq -e '.status!=null' >/dev/null; }


alias_exists(){ es_get "/_alias/$1?filter_path=*" >/dev/null 2>&1; }
index_exists(){ es_get "/$1?filter_path=*"        >/dev/null 2>&1; }
ct_exists(){    es_get "/_component_template/$1?filter_path=*" >/dev/null 2>&1; }
it_exists(){    es_get "/_index_template/$1?filter_path=*"     >/dev/null 2>&1; }
ilm_exists(){   es_get "/_ilm/policy/$1?filter_path=*" >/dev/null 2>&1; }

