#!/usr/bin/env bash
# Measure credential issuance and immediate usability for 12 hours by default.
#
# Each sample performs exactly one Vault creds read, immediately calls the same
# Temporal namespace frontend RPC used by plugin 0.3.0's propagation probe, and
# then revokes the lease. API keys are never written to the results file.

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_cmd jq
require_cmd temporal

DURATION_SECONDS="${DURATION_SECONDS:-43200}"       # 12 hours
INTERVAL_SECONDS="${INTERVAL_SECONDS:-60}"          # one sample per minute
VALIDATION_TIMEOUT="${VALIDATION_TIMEOUT:-20s}"
PROBE_INTERVAL="${PROBE_INTERVAL:-50ms}"
PROBE_CONSECUTIVE_SUCCESSES="${PROBE_CONSECUTIVE_SUCCESSES:-10}"
ADAPT_PROBE_ON_FAILURE="${ADAPT_PROBE_ON_FAILURE:-true}"
MAX_PROBE_CONSECUTIVE_SUCCESSES=20
PERF_ROLE="${PERF_ROLE:-vault-propagation-performance-test}"
RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/performance-results}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_FILE="${OUTPUT_FILE:-$RESULTS_DIR/plugin-${PLUGIN_VERSION}-${RUN_ID}.jsonl}"
SUMMARY_FILE="${SUMMARY_FILE:-${OUTPUT_FILE%.jsonl}.summary.json}"
LOCK_DIR="$REPO_ROOT/.performance-test.lock"
CURRENT_LEASE=""
ITERATION=0
START_EPOCH=0
END_EPOCH=0

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

[[ "$DURATION_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "DURATION_SECONDS must be a positive integer"
[[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || fail "INTERVAL_SECONDS must be a non-negative integer"
[[ "$PROBE_CONSECUTIVE_SUCCESSES" =~ ^([1-9]|1[0-9]|20)$ ]] ||
    fail "PROBE_CONSECUTIVE_SUCCESSES must be between 1 and 20"
[[ "$ADAPT_PROBE_ON_FAILURE" == true || "$ADAPT_PROBE_ON_FAILURE" == false ]] ||
    fail "ADAPT_PROBE_ON_FAILURE must be true or false"
[[ -n "${EPOCHREALTIME:-}" ]] || fail "Bash 5 or newer is required for high-resolution timing"

mkdir -p "$RESULTS_DIR" "$(dirname "$OUTPUT_FILE")" "$(dirname "$SUMMARY_FILE")"
mkdir "$LOCK_DIR" 2>/dev/null || fail "another performance test appears to be running ($LOCK_DIR exists)"

# EPOCHREALTIME is seconds.microseconds. Removing the decimal point yields an
# integer microsecond timestamp without spawning a process inside timed paths.
now_us() {
    printf '%s\n' "${EPOCHREALTIME/./}"
}

one_line() {
    tr '\n\r\t' '   ' | cut -c1-500
}

write_summary() {
    [[ -s "$OUTPUT_FILE" ]] || return 0
    jq -s \
        --arg run_id "$RUN_ID" \
        --arg plugin_version "$PLUGIN_VERSION" \
        --arg results_file "$OUTPUT_FILE" '
        def values_for(name): map(select(.vault_ok == true) | .[name]);
        def stats(name):
          (values_for(name)) as $v |
          if ($v | length) == 0 then null else {
            min_ms: ($v | min),
            max_ms: ($v | max),
            mean_ms: (($v | add) / ($v | length))
          } end;
        {
          run_id: $run_id,
          plugin_version: $plugin_version,
          results_file: $results_file,
          samples: length,
          adaptive_probe: .[0].adaptive_probe,
          initial_probe_consecutive_successes: .[0].probe_consecutive_successes,
          vault_successes: (map(select(.vault_ok == true)) | length),
          vault_failures: (map(select(.vault_ok == false)) | length),
          immediately_valid: (map(select(.valid == true)) | length),
          immediately_invalid: (map(select(.vault_ok == true and .valid == false)) | length),
          probe_adjustments: (map(select(.probe_adjusted_to != null)) |
            map({iteration, from: .probe_consecutive_successes, to: .probe_adjusted_to})),
          final_probe_consecutive_successes: (map(.probe_adjusted_to // .probe_consecutive_successes) | last),
          validity_rate_percent: (
            (map(select(.vault_ok == true)) | length) as $issued |
            if $issued == 0 then null
            else ((map(select(.valid == true)) | length) * 100 / $issued)
            end
          ),
          vault_return: stats("vault_return_ms"),
          immediate_validation: stats("validation_ms")
        }' "$OUTPUT_FILE" >"$SUMMARY_FILE"
}

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM

    if [[ -n "$CURRENT_LEASE" ]]; then
        vault lease revoke "$CURRENT_LEASE" >/dev/null 2>&1 || true
        CURRENT_LEASE=""
    fi

    # Prefix revocation catches a lease left between issuance and assignment if
    # the process was interrupted at exactly that point.
    if vault status >/dev/null 2>&1; then
        vault lease revoke -prefix "$MOUNT/creds/$PERF_ROLE" >/dev/null 2>&1 || true
        vault delete "$MOUNT/service-accounts/$PERF_ROLE" >/dev/null 2>&1 || true
    fi

    write_summary || true
    rmdir "$LOCK_DIR" 2>/dev/null || true

    printf '\nResults: %s\n' "$OUTPUT_FILE"
    [[ -f "$SUMMARY_FILE" ]] && printf 'Summary: %s\n' "$SUMMARY_FILE"
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

require_vault_running

# Make the target self-contained on a fresh `make up`. The mount and bootstrap
# config stay in the disposable dev Vault; only the dedicated performance-test
# service account is removed during cleanup.
if ! vault secrets list -format=json 2>/dev/null | jq -e --arg path "$MOUNT/" 'has($path)' >/dev/null; then
    plugin_sha="$(cat "$REPO_ROOT/.plugin-cache/binary.sha256")"
    vault plugin register -sha256="$plugin_sha" secret "$PLUGIN_NAME" >/dev/null ||
        fail "could not register $PLUGIN_NAME"
    vault secrets enable -path="$MOUNT" "$PLUGIN_NAME" >/dev/null ||
        fail "could not mount $PLUGIN_NAME at $MOUNT"
fi

if ! vault read "$MOUNT/config" >/dev/null 2>&1; then
    vault write "$MOUNT/config" \
        api_key="$TEMPORAL_API_KEY" \
        admin_service_account_id="$TEMPORAL_ADMIN_SA_ID" >/dev/null ||
        fail "could not configure $MOUNT with the bootstrap credential"
fi

# Pin the demo's mount-wide policy explicitly so every result file uses the
# same probe settings even if this mount was configured by another demo.
vault write "$MOUNT/config/probe" \
    interval="$PROBE_INTERVAL" \
    consecutive_successes="$PROBE_CONSECUTIVE_SUCCESSES" >/dev/null ||
    fail "could not configure mount-wide propagation probes"

vault write "$MOUNT/service-accounts/$PERF_ROLE" \
    account_role=read \
    namespace_access="$TEMPORAL_NAMESPACE=read" \
    verify_propagation=true \
    ttl=5m max_ttl=1h \
    description='12-hour Vault API key propagation performance test' >/dev/null ||
    fail "could not create performance-test role $PERF_ROLE"

NAMESPACE_ADDRESS="${TEMPORAL_NAMESPACE}.tmprl.cloud:7233"
START_EPOCH="$(date +%s)"
END_EPOCH=$((START_EPOCH + DURATION_SECONDS))

printf 'Plugin version:      %s\n' "$PLUGIN_VERSION"
printf 'Duration:            %s seconds\n' "$DURATION_SECONDS"
printf 'Sample interval:     %s seconds\n' "$INTERVAL_SECONDS"
printf 'Propagation probe:  %s successes at %s intervals\n' \
    "$PROBE_CONSECUTIVE_SUCCESSES" "$PROBE_INTERVAL"
printf 'Adaptive probe:     %s\n' "$ADAPT_PROBE_ON_FAILURE"
printf 'Namespace frontend: %s\n' "$NAMESPACE_ADDRESS"
printf 'Results:             %s\n\n' "$OUTPUT_FILE"
printf 'A valid sample means DescribeNamespace succeeded on the first attempt immediately after Vault returned.\n\n'

while (( $(date +%s) < END_EPOCH )); do
    ITERATION=$((ITERATION + 1))
    sample_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    vault_ok=false
    valid=false
    lease_id=""
    api_key=""
    api_key_id=""
    plugin_warnings_json='[]'
    probe_successes_used="$PROBE_CONSECUTIVE_SUCCESSES"
    probe_adjusted_to=null
    error=""
    validation_error=""
    vault_return_ms=0
    validation_ms=0
    revoke_ms=0

    vault_start_us="$(now_us)"
    if vault_output="$(vault read -format=json "$MOUNT/creds/$PERF_ROLE" 2>&1)"; then
        vault_end_us="$(now_us)"
        vault_return_ms=$(((vault_end_us - vault_start_us) / 1000))
        lease_id="$(jq -r '.lease_id // empty' <<<"$vault_output")"
        api_key="$(jq -r '.data.api_key // empty' <<<"$vault_output")"
        api_key_id="$(jq -r '.data.api_key_id // empty' <<<"$vault_output")"
        plugin_warnings_json="$(jq -c '.warnings // []' <<<"$vault_output")"

        if [[ -n "$lease_id" && -n "$api_key" ]]; then
            vault_ok=true
            CURRENT_LEASE="$lease_id"

            validation_start_us="$(now_us)"
            if validation_output="$(temporal operator namespace describe \
                --address "$NAMESPACE_ADDRESS" \
                --namespace "$TEMPORAL_NAMESPACE" \
                --api-key "$api_key" \
                --command-timeout "$VALIDATION_TIMEOUT" \
                --output none 2>&1)"; then
                valid=true
            else
                validation_error="$(printf '%s' "$validation_output" | one_line)"
            fi
            validation_end_us="$(now_us)"
            validation_ms=$(((validation_end_us - validation_start_us) / 1000))

            revoke_start_us="$(now_us)"
            if ! revoke_output="$(vault lease revoke "$CURRENT_LEASE" 2>&1)"; then
                error="lease revoke failed: $(printf '%s' "$revoke_output" | one_line)"
            else
                CURRENT_LEASE=""
            fi
            revoke_end_us="$(now_us)"
            revoke_ms=$(((revoke_end_us - revoke_start_us) / 1000))

            # In adaptive mode, treat independent post-return validation as
            # feedback for the next credential. The plugin caps this at 20.
            if [[ "$valid" == false && "$ADAPT_PROBE_ON_FAILURE" == true ]]; then
                if (( PROBE_CONSECUTIVE_SUCCESSES < MAX_PROBE_CONSECUTIVE_SUCCESSES )); then
                    next_probe_successes=$((PROBE_CONSECUTIVE_SUCCESSES + 1))
                    if vault write "$MOUNT/config/probe" \
                        consecutive_successes="$next_probe_successes" >/dev/null 2>&1; then
                        PROBE_CONSECUTIVE_SUCCESSES="$next_probe_successes"
                        probe_adjusted_to="$next_probe_successes"
                    else
                        error="${error:+$error; }could not increase consecutive_successes to $next_probe_successes"
                    fi
                else
                    error="${error:+$error; }valid=false but consecutive_successes is already at the plugin maximum of $MAX_PROBE_CONSECUTIVE_SUCCESSES"
                fi
            fi
        else
            error="Vault returned JSON without lease_id or api_key"
        fi
    else
        vault_end_us="$(now_us)"
        vault_return_ms=$(((vault_end_us - vault_start_us) / 1000))
        error="$(printf '%s' "$vault_output" | one_line)"
    fi

    jq -nc \
        --argjson iteration "$ITERATION" \
        --arg timestamp "$sample_time" \
        --argjson vault_ok "$vault_ok" \
        --argjson valid "$valid" \
        --arg api_key_id "$api_key_id" \
        --argjson plugin_warnings "$plugin_warnings_json" \
        --argjson probe_consecutive_successes "$probe_successes_used" \
        --argjson probe_adjusted_to "$probe_adjusted_to" \
        --arg probe_interval "$PROBE_INTERVAL" \
        --argjson adaptive_probe "$ADAPT_PROBE_ON_FAILURE" \
        --argjson vault_return_ms "$vault_return_ms" \
        --argjson validation_ms "$validation_ms" \
        --argjson revoke_ms "$revoke_ms" \
        --arg error "$error" \
        --arg validation_error "$validation_error" \
        '{iteration: $iteration, timestamp: $timestamp, vault_ok: $vault_ok,
          valid: $valid, api_key_id: $api_key_id,
          plugin_warnings: $plugin_warnings,
          probe_consecutive_successes: $probe_consecutive_successes,
          probe_interval: $probe_interval,
          adaptive_probe: $adaptive_probe,
          probe_adjusted_to: $probe_adjusted_to,
          vault_return_ms: $vault_return_ms, validation_ms: $validation_ms,
          revoke_ms: $revoke_ms, error: $error,
          validation_error: $validation_error}' >>"$OUTPUT_FILE"

    printf '[%s] sample=%d vault=%sms valid=%s validation=%sms probe=%s' \
        "$sample_time" "$ITERATION" "$vault_return_ms" "$valid" \
        "$validation_ms" "$probe_successes_used"
    if [[ "$probe_adjusted_to" != null ]]; then
        printf ' adjusted_to=%s' "$probe_adjusted_to"
    fi
    printf '\n'

    now_epoch="$(date +%s)"
    if (( now_epoch >= END_EPOCH )); then
        break
    fi
    sleep_seconds="$INTERVAL_SECONDS"
    remaining_seconds=$((END_EPOCH - now_epoch))
    if (( sleep_seconds > remaining_seconds )); then
        sleep_seconds="$remaining_seconds"
    fi
    if (( sleep_seconds > 0 )); then
        sleep "$sleep_seconds"
    fi
done
