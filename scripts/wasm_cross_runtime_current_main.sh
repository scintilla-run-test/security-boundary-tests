#!/usr/bin/env bash
set -euo pipefail

WASMX_DAEMON_REPO="wasm-xprs/wasmx-desktop-daemon"
WASMX_DAEMON_SHA="d8999b344ff5fdb703fb037a4dffeeda60baed36"
WASMX_CLI_REPO="wasm-xprs/wasmx-desktop-cli"
WASMX_CLI_SHA="5179e4db75ec9d4eaebd867860b73296979b88ff"
LL_DAEMON_REPO="lunatic-lorry/ll-desktop-daemon"
LL_DAEMON_SHA="49a883262728cef5429c570832af9b506ae9279d"
LL_CLI_REPO="lunatic-lorry/ll-desktop-cli"
LL_CLI_SHA="0b669a11477586123ccd2d4867739e101015623f"

ROOT="${RUNNER_TEMP:-/tmp}/ores-cross-runtime-${RANDOM}-${RANDOM}"
SRC="$ROOT/src"
TEST_HOME="$ROOT/home"
LOGS="$ROOT/logs"
FIXTURES="$ROOT/fixtures"
mkdir -p "$SRC" "$TEST_HOME" "$LOGS" "$FIXTURES"
chmod 700 "$TEST_HOME"

WASMX_DAEMON_DIR="$SRC/wasmx-daemon"
WASMX_CLI_DIR="$SRC/wasmx-cli"
LL_DAEMON_DIR="$SRC/ll-daemon"
LL_CLI_DIR="$SRC/ll-cli"
WASMX_PID=""
LL_PID=""

cleanup() {
  set +e
  if [[ -n "$WASMX_PID" ]]; then kill -INT "$WASMX_PID" 2>/dev/null || true; fi
  if [[ -n "$LL_PID" ]]; then kill -INT "$LL_PID" 2>/dev/null || true; fi
  if [[ -n "$WASMX_PID" ]]; then wait "$WASMX_PID" 2>/dev/null || true; fi
  if [[ -n "$LL_PID" ]]; then wait "$LL_PID" 2>/dev/null || true; fi
  if [[ "${KEEP_CROSS_RUNTIME_TMP:-0}" != "1" ]]; then rm -rf "$ROOT"; fi
}
trap cleanup EXIT INT TERM

clone_exact() {
  local repo="$1"
  local sha="$2"
  local dest="$3"
  git init -q "$dest"
  git -C "$dest" remote add origin "https://github.com/${repo}.git"
  git -C "$dest" fetch -q --depth=1 origin "$sha"
  git -C "$dest" checkout -q --detach FETCH_HEAD
  [[ "$(git -C "$dest" rev-parse HEAD)" == "$sha" ]]
  [[ -f "$dest/Cargo.lock" ]] || { echo "$repo@$sha is missing Cargo.lock" >&2; return 1; }
}

wait_http() {
  local url="$1"
  local log="$2"
  for _ in $(seq 1 120); do
    if curl --silent --show-error --fail --max-time 1 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "endpoint did not become ready: $url" >&2
  cat "$log" >&2 || true
  return 1
}

http_code() {
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$@"
}

require_code() {
  local expected="$1"
  shift
  local actual
  actual="$(http_code "$@")"
  if [[ "$actual" != "$expected" ]]; then
    echo "expected HTTP $expected, got $actual: curl $*" >&2
    return 1
  fi
}

require_non_2xx() {
  local actual
  actual="$(http_code "$@")"
  case "$actual" in
    2*) echo "expected request to fail closed, got HTTP $actual" >&2; return 1 ;;
  esac
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

b64_file() {
  base64 -w0 "$1"
}

start_daemons() {
  (cd "$WASMX_DAEMON_DIR" && exec env HOME="$TEST_HOME" ./target/release/wasmx-desktop-daemon >"$LOGS/wasmx-daemon.log" 2>&1) &
  WASMX_PID=$!
  (cd "$LL_DAEMON_DIR" && exec env HOME="$TEST_HOME" ./target/release/ll-desktop-daemon >"$LOGS/ll-daemon.log" 2>&1) &
  LL_PID=$!
  wait_http "http://127.0.0.1:8766/healthz" "$LOGS/wasmx-daemon.log"
  wait_http "http://127.0.0.1:8763/healthz" "$LOGS/ll-daemon.log"
}

stop_daemons() {
  kill -INT "$WASMX_PID" "$LL_PID"
  wait "$WASMX_PID"
  wait "$LL_PID"
  WASMX_PID=""
  LL_PID=""
}

make_modules() {
  # (module (memory (export "memory") 1)
  #         (func (export "wasmx_main") (result i32) i32.const 0))
  perl -e 'print pack("H*", shift)' \
    '0061736d010000000105016000017f030201000503010001071702066d656d6f727902000a7761736d785f6d61696e00000a0601040041000b' \
    > "$FIXTURES/wasmx.wasm"

  # (module (func (export "_start")))
  perl -e 'print pack("H*", shift)' \
    '0061736d0100000001040160000003020100070a01065f737461727400000a040102000b' \
    > "$FIXTURES/lunatic.wasm"
}

make_evidence() {
  local source_sha
  source_sha="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

  cat > "$FIXTURES/wasmx-adapter.json" <<JSON
{"schema_version":"ores.lambda.adapter/v1","generated_by":"ores-stack","provider":"wasm_xprs","runtime_repository":"wasm-xprs/wasmx-lambdas","runtime_contract":"wasm-xprs.lambda-runtime/v1","execution_boundary":"wasmtime_store_instance","isolation_model":"fresh_store_and_instance_per_invocation","artifact_kind":"wasm_module","module_cache_policy":"compiled_module_allowed","invocation_instance_reuse":"forbidden","ambient_import_policy":"explicit_wasmx_v1_only","durable_state":"external_only","source":"src/routes/echo/lambda.rs","source_sha256":"${source_sha}"}
JSON

  cat > "$FIXTURES/lunatic-adapter.json" <<JSON
{"schema_version":"ores.lambda.adapter/v1","generated_by":"ores-stack","provider":"lunatic_lorry","runtime_repository":"lunatic-lorry/ll-lambdas","runtime_contract":"lunatic-lorry.lambda-runtime/v1","execution_boundary":"lunatic_process","isolation_model":"fresh_wasm_actor_per_invocation","artifact_kind":"wasm_module","module_cache_policy":"module_bytes_or_compiled_module_allowed","invocation_instance_reuse":"forbidden","ambient_import_policy":"explicit_lunatic_capabilities_only","durable_state":"external_only","source":"src/routes/echo/lambda.rs","source_sha256":"${source_sha}"}
JSON

  local wasmx_module_sha wasmx_adapter_sha ll_module_sha ll_adapter_sha
  wasmx_module_sha="$(sha256_file "$FIXTURES/wasmx.wasm")"
  wasmx_adapter_sha="$(sha256_file "$FIXTURES/wasmx-adapter.json")"
  ll_module_sha="$(sha256_file "$FIXTURES/lunatic.wasm")"
  ll_adapter_sha="$(sha256_file "$FIXTURES/lunatic-adapter.json")"

  jq -cn \
    --arg artifact "$wasmx_module_sha" \
    --arg adapter "$wasmx_adapter_sha" \
    --arg source "$source_sha" \
    '{schema_version:"ores.lambda.wasm-artifact.receipt/v1",generated_by:"ores-stack",provider:"wasm_xprs",runtime_repository:"wasm-xprs/wasmx-lambdas",runtime_contract:"wasm-xprs.lambda-runtime/v1",adapter_contract:"ores.lambda.adapter/v1",artifact_path:"build/lambda/wasm_xprs/module.wasm",artifact_sha256:$artifact,deploy_mutation_performed:false,target_triple:"wasm32-unknown-unknown",adapter_path:"generated/lambda-adapters/wasm_xprs/adapter.json",adapter_sha256:$adapter,source_path:"src/routes/echo/lambda.rs",source_sha256:$source,cargo_manifest_path:"Cargo.toml",cargo_package:"fixture",cargo_target_name:"ores_wasm_lambda_unit",wrapper_sha256:("d"*64),unit_manifest_sha256:("e"*64)}' \
    > "$FIXTURES/wasmx-receipt.json"

  jq -cn \
    --arg artifact "$ll_module_sha" \
    --arg adapter "$ll_adapter_sha" \
    --arg source "$source_sha" \
    '{schema_version:"ores.lambda.wasm-artifact.receipt/v1",generated_by:"ores-stack",provider:"lunatic_lorry",runtime_repository:"lunatic-lorry/ll-lambdas",runtime_contract:"lunatic-lorry.lambda-runtime/v1",adapter_contract:"ores.lambda.adapter/v1",artifact_path:"build/lambda/lunatic_lorry/module.wasm",artifact_sha256:$artifact,deploy_mutation_performed:false,target_triple:"wasm32-wasip1",adapter_path:"generated/lambda-adapters/lunatic_lorry/adapter.json",adapter_sha256:$adapter,source_path:"src/routes/echo/lambda.rs",source_sha256:$source,cargo_manifest_path:"Cargo.toml",cargo_package:"fixture",cargo_target_name:"ores_wasm_lambda_unit",wrapper_sha256:("d"*64),unit_manifest_sha256:("e"*64)}' \
    > "$FIXTURES/lunatic-receipt.json"
}

make_raw_deploy_body() {
  local provider="$1"
  local deployment="$2"
  local module adapter receipt
  if [[ "$provider" == "wasmx" ]]; then
    module="$FIXTURES/wasmx.wasm"
    adapter="$FIXTURES/wasmx-adapter.json"
    receipt="$FIXTURES/wasmx-receipt.json"
  else
    module="$FIXTURES/lunatic.wasm"
    adapter="$FIXTURES/lunatic-adapter.json"
    receipt="$FIXTURES/lunatic-receipt.json"
  fi
  jq -cn \
    --arg tenant "cross-runtime" \
    --arg deployment "$deployment" \
    --arg wasm "$(b64_file "$module")" \
    --argjson adapter "$(cat "$adapter")" \
    --arg raw_adapter "$(b64_file "$adapter")" \
    --arg raw_receipt "$(b64_file "$receipt")" \
    '{tenant_id:$tenant,deployment_id:$deployment,wasm_base64:$wasm,ores_adapter:$adapter,ores_adapter_raw_base64:$raw_adapter,ores_receipt_raw_base64:$raw_receipt}'
}

echo "== clone exact current heads =="
clone_exact "$WASMX_DAEMON_REPO" "$WASMX_DAEMON_SHA" "$WASMX_DAEMON_DIR"
clone_exact "$WASMX_CLI_REPO" "$WASMX_CLI_SHA" "$WASMX_CLI_DIR"
clone_exact "$LL_DAEMON_REPO" "$LL_DAEMON_SHA" "$LL_DAEMON_DIR"
clone_exact "$LL_CLI_REPO" "$LL_CLI_SHA" "$LL_CLI_DIR"

echo "== build exact locked releases =="
cargo build --locked --release --manifest-path "$WASMX_DAEMON_DIR/Cargo.toml"
cargo build --locked --release --manifest-path "$WASMX_CLI_DIR/Cargo.toml"
cargo build --locked --release --manifest-path "$LL_DAEMON_DIR/Cargo.toml"
cargo build --locked --release --manifest-path "$LL_CLI_DIR/Cargo.toml"

make_modules
make_evidence

echo "== run both daemons concurrently on canonical ports =="
start_daemons
[[ -s "$TEST_HOME/.wasm-xprs/daemon/token" ]]
[[ -s "$TEST_HOME/.lunatic-lorry/daemon/token" ]]
[[ "$(stat -c '%a' "$TEST_HOME/.wasm-xprs/daemon/token")" == "600" ]]
[[ "$(stat -c '%a' "$TEST_HOME/.lunatic-lorry/daemon/token")" == "600" ]]
WASMX_TOKEN="$(tr -d '\r\n' < "$TEST_HOME/.wasm-xprs/daemon/token")"
LL_TOKEN="$(tr -d '\r\n' < "$TEST_HOME/.lunatic-lorry/daemon/token")"
[[ "$WASMX_TOKEN" != "$LL_TOKEN" ]]

echo "== prove auth and runtime identities are isolated =="
require_code 401 -H "Authorization: Bearer $WASMX_TOKEN" "http://127.0.0.1:8763/v1/status"
require_code 401 -H "Authorization: Bearer $LL_TOKEN" "http://127.0.0.1:8766/v1/status"
curl -fsS -H "Authorization: Bearer $WASMX_TOKEN" "http://127.0.0.1:8766/v1/status" \
  | jq -e '.runtime == "wasmtime" and .guest_abi == "wasmx-v1" and .target_triple == "wasm32-unknown-unknown" and .wasi_enabled == false and .store_per_invocation == true' >/dev/null
curl -fsS -H "Authorization: Bearer $LL_TOKEN" "http://127.0.0.1:8763/v1/status" \
  | jq -e '.runtime == "lunatic_wasm" and .actor_reusable == false and .worker_mode == "embedded_fresh_lunatic_actor" and .deployment_mode == "immutable_wasm_module"' >/dev/null

echo "== exercise current CLIs against current daemons =="
(cd "$WASMX_CLI_DIR" && HOME="$TEST_HOME" ./target/release/wasmx-desktop-cli doctor >/dev/null)
(cd "$LL_CLI_DIR" && HOME="$TEST_HOME" ./target/release/ll-desktop-cli status >/dev/null)

(cd "$WASMX_CLI_DIR" && HOME="$TEST_HOME" ./target/release/wasmx-desktop-cli deploy \
  --tenant cross-runtime --deployment wasmx-v1 \
  --module "$FIXTURES/wasmx.wasm" \
  --ores-adapter "$FIXTURES/wasmx-adapter.json" \
  --ores-receipt "$FIXTURES/wasmx-receipt.json") \
  | jq -e '.ores_adapter_verified == true and .ores_receipt_verified == true' >/dev/null

(cd "$LL_CLI_DIR" && HOME="$TEST_HOME" ./target/release/ll-desktop-cli deploy \
  --tenant cross-runtime --deployment lunatic-v1 \
  --module "$FIXTURES/lunatic.wasm" \
  --ores-adapter "$FIXTURES/lunatic-adapter.json" \
  --ores-receipt "$FIXTURES/lunatic-receipt.json") \
  | jq -e '.ores_adapter_verified == true and .ores_receipt_verified == true' >/dev/null

echo "== exact receipt-backed redeploy is idempotent =="
(cd "$WASMX_CLI_DIR" && HOME="$TEST_HOME" ./target/release/wasmx-desktop-cli deploy \
  --tenant cross-runtime --deployment wasmx-v1 \
  --module "$FIXTURES/wasmx.wasm" --ores-adapter "$FIXTURES/wasmx-adapter.json" --ores-receipt "$FIXTURES/wasmx-receipt.json" >/dev/null)
(cd "$LL_CLI_DIR" && HOME="$TEST_HOME" ./target/release/ll-desktop-cli deploy \
  --tenant cross-runtime --deployment lunatic-v1 \
  --module "$FIXTURES/lunatic.wasm" --ores-adapter "$FIXTURES/lunatic-adapter.json" --ores-receipt "$FIXTURES/lunatic-receipt.json" >/dev/null)

echo "== wrong-provider receipt replay fails at daemon authority =="
WASMX_WRONG="$(make_raw_deploy_body wasmx wrong-provider-wasmx | jq --arg receipt "$(b64_file "$FIXTURES/lunatic-receipt.json")" '.ores_receipt_raw_base64=$receipt')"
LL_WRONG="$(make_raw_deploy_body lunatic wrong-provider-lunatic | jq --arg receipt "$(b64_file "$FIXTURES/wasmx-receipt.json")" '.ores_receipt_raw_base64=$receipt')"
require_code 400 -H "Authorization: Bearer $WASMX_TOKEN" -H 'content-type: application/json' -d "$WASMX_WRONG" "http://127.0.0.1:8766/v1/deploy"
require_code 400 -H "Authorization: Bearer $LL_TOKEN" -H 'content-type: application/json' -d "$LL_WRONG" "http://127.0.0.1:8763/v1/deploy"

echo "== restart preserves tokens, immutable modules and receipt evidence =="
WASMX_TOKEN_BEFORE="$WASMX_TOKEN"
LL_TOKEN_BEFORE="$LL_TOKEN"
stop_daemons
start_daemons
WASMX_TOKEN="$(tr -d '\r\n' < "$TEST_HOME/.wasm-xprs/daemon/token")"
LL_TOKEN="$(tr -d '\r\n' < "$TEST_HOME/.lunatic-lorry/daemon/token")"
[[ "$WASMX_TOKEN" == "$WASMX_TOKEN_BEFORE" ]]
[[ "$LL_TOKEN" == "$LL_TOKEN_BEFORE" ]]

(cd "$WASMX_CLI_DIR" && HOME="$TEST_HOME" ./target/release/wasmx-desktop-cli inspect --tenant cross-runtime --deployment wasmx-v1) \
  | jq -e '.integrity_verified == true and .ores_adapter_verified == true and .ores_build_receipt_bound == true' >/dev/null
jq -e '.runtime_contract == "lunatic-lorry.lambda-runtime/v1" and .execution_boundary == "lunatic_process" and .isolation_model == "fresh_wasm_actor_per_invocation" and .ores_adapter_verified == true and .ores_build_evidence != null' \
  "$TEST_HOME/.lunatic-lorry/deployments/cross-runtime/lunatic-v1/manifest.json" >/dev/null

(cd "$WASMX_CLI_DIR" && HOME="$TEST_HOME" ./target/release/wasmx-desktop-cli deploy \
  --tenant cross-runtime --deployment wasmx-v1 --module "$FIXTURES/wasmx.wasm" --ores-adapter "$FIXTURES/wasmx-adapter.json" --ores-receipt "$FIXTURES/wasmx-receipt.json" >/dev/null)
(cd "$LL_CLI_DIR" && HOME="$TEST_HOME" ./target/release/ll-desktop-cli deploy \
  --tenant cross-runtime --deployment lunatic-v1 --module "$FIXTURES/lunatic.wasm" --ores-adapter "$FIXTURES/lunatic-adapter.json" --ores-receipt "$FIXTURES/lunatic-receipt.json" >/dev/null)

echo "== tamper persisted modules and prove restart/redeploy fails closed without repair =="
stop_daemons
printf '\001' >> "$TEST_HOME/.wasm-xprs/artifacts/cross-runtime/wasmx-v1/module.wasm"
printf '\001' >> "$TEST_HOME/.lunatic-lorry/deployments/cross-runtime/lunatic-v1/module.wasm"
WASMX_TAMPERED_SHA="$(sha256_file "$TEST_HOME/.wasm-xprs/artifacts/cross-runtime/wasmx-v1/module.wasm")"
LL_TAMPERED_SHA="$(sha256_file "$TEST_HOME/.lunatic-lorry/deployments/cross-runtime/lunatic-v1/module.wasm")"
start_daemons
WASMX_TOKEN="$(tr -d '\r\n' < "$TEST_HOME/.wasm-xprs/daemon/token")"
LL_TOKEN="$(tr -d '\r\n' < "$TEST_HOME/.lunatic-lorry/daemon/token")"

WASMX_BODY="$(make_raw_deploy_body wasmx wasmx-v1)"
LL_BODY="$(make_raw_deploy_body lunatic lunatic-v1)"
require_non_2xx -H "Authorization: Bearer $WASMX_TOKEN" -H 'content-type: application/json' -d "$WASMX_BODY" "http://127.0.0.1:8766/v1/deploy"
require_non_2xx -H "Authorization: Bearer $LL_TOKEN" -H 'content-type: application/json' -d "$LL_BODY" "http://127.0.0.1:8763/v1/deploy"
[[ "$(sha256_file "$TEST_HOME/.wasm-xprs/artifacts/cross-runtime/wasmx-v1/module.wasm")" == "$WASMX_TAMPERED_SHA" ]]
[[ "$(sha256_file "$TEST_HOME/.lunatic-lorry/deployments/cross-runtime/lunatic-v1/module.wasm")" == "$LL_TAMPERED_SHA" ]]

echo "cross-runtime current-main security proof: PASS"
