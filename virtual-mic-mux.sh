#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/virtual-mic"
STATE_FILE="${STATE_DIR}/state.env"

APP_SINK_NAME="virtual_mic_sink"
APP_SINK_DESC="VirtualMic Sink"

MIX_SINK_NAME="virtual_mic_mix_sink"
MIX_SINK_DESC="VirtualMic Mix Sink"

SRC_NAME="virtual_mic_source"
SRC_DESC="VirtualMic Source"

# Delimiter preference (not strictly needed here, but kept consistent)
DELIM="§"

require_cmd() {
    local cmd="${1}"
    command -v "${cmd}" >/dev/null 2>&1 || {
        echo "ERROR: missing command: ${cmd}" >&2
        exit 1
    }
}

get_default_sink() {
    pactl get-default-sink 2>/dev/null || true
}

get_default_source() {
    pactl get-default-source 2>/dev/null || true
}

module_loaded() {
    local module_id="${1}"
    pactl list short modules | awk '{print $1}' | grep -Fxq "${module_id}"
}

sink_exists() {
    local sink_name="${1}"
    pactl list short sinks | awk '{print $2}' | grep -Fxq "${sink_name}"
}

source_exists() {
    pactl list short sources | awk '{print $2}' | grep -Fxq "${SRC_NAME}"
}

save_state() {
    local prior_sink="${1}"
    local prior_source="${2}"
    local mod_app_null_sink="${3}"
    local mod_mix_null_sink="${4}"
    local mod_remap_source="${5}"
    local mod_loopback_mic="${6}"
    local mod_loopback_app_to_mix="${7}"
    local mod_loopback_app_to_output="${8}"
    local monitor_local="${9}"

    mkdir -p "${STATE_DIR}"

    cat > "${STATE_FILE}" <<EOF
PRIOR_DEFAULT_SINK="${prior_sink}"
PRIOR_DEFAULT_SOURCE="${prior_source}"
MOD_APP_NULL_SINK="${mod_app_null_sink}"
MOD_MIX_NULL_SINK="${mod_mix_null_sink}"
MOD_REMAP_SOURCE="${mod_remap_source}"
MOD_LOOPBACK_MIC="${mod_loopback_mic}"
MOD_LOOPBACK_APP_TO_MIX="${mod_loopback_app_to_mix}"
MOD_LOOPBACK_APP_TO_OUTPUT="${mod_loopback_app_to_output}"
MONITOR_LOCAL="${monitor_local}"
EOF
}

load_state() {
    if [[ -f "${STATE_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
        return 0
    fi
    return 1
}

enable_virtual_mic() {
    local monitor_local="${1:-0}"
    require_cmd "pactl"

    if [[ -f "${STATE_FILE}" ]]; then
        echo "Already enabled (state file exists): ${STATE_FILE}"
        echo "Run: ${0} off"
        exit 0
    fi

    local prior_sink=""
    local prior_source=""
    prior_sink="$(get_default_sink)"
    prior_source="$(get_default_source)"

    if [[ -z "${prior_sink}" || -z "${prior_source}" ]]; then
        echo "ERROR: Could not determine current default sink/source." >&2
        echo "Check that pipewire-pulse is running and pactl works." >&2
        exit 1
    fi

    # 1) Create a null sink that apps/music can output to.
    local mod_app_null_sink=""
    mod_app_null_sink="$(pactl load-module module-null-sink \
        sink_name="${APP_SINK_NAME}" \
        sink_properties="device.description=${APP_SINK_DESC}")"

    # 2) Create a separate mix sink that combines app audio and mic audio.
    local mod_mix_null_sink=""
    mod_mix_null_sink="$(pactl load-module module-null-sink \
        sink_name="${MIX_SINK_NAME}" \
        sink_properties="device.description=${MIX_SINK_DESC}")"

    # 3) Create a virtual source from the mix sink's monitor.
    #    This becomes the "virtual mic" that conferencing apps should use
    local mod_remap_source=""
    mod_remap_source="$(pactl load-module module-remap-source \
        master="${MIX_SINK_NAME}.monitor" \
        source_name="${SRC_NAME}" \
        source_properties="device.description=${SRC_DESC}")"

    # 4) Feed app/music audio into the mix sink.
    local mod_loopback_app_to_mix=""
    mod_loopback_app_to_mix="$(pactl load-module module-loopback \
        source="${APP_SINK_NAME}.monitor" \
        sink="${MIX_SINK_NAME}" \
        latency_msec=10)"

    # 5) Loop your *current default mic* into the mix sink so mic + app audio are mixed.
    #    (If you want a specific mic instead of the default, edit "source=" below.)
    local mod_loopback_mic=""
    mod_loopback_mic="$(pactl load-module module-loopback \
        source="${prior_source}" \
        sink="${MIX_SINK_NAME}" \
        latency_msec=10)"

    local mod_loopback_app_to_output=""
    if [[ "${monitor_local}" == "1" ]]; then
        mod_loopback_app_to_output="$(pactl load-module module-loopback \
            source="${APP_SINK_NAME}.monitor" \
            sink="${prior_sink}" \
            latency_msec=10)"
    fi

    # Set defaults so apps that just use defaults can “see” the virtual mic immediately.
    # We do NOT force the default sink to the virtual sink; you can route specific apps to it.
    pactl set-default-source "${SRC_NAME}"

    save_state "${prior_sink}" "${prior_source}" "${mod_app_null_sink}" "${mod_mix_null_sink}" "${mod_remap_source}" "${mod_loopback_mic}" "${mod_loopback_app_to_mix}" "${mod_loopback_app_to_output}" "${monitor_local}"

    echo "Enabled."
    echo "Playback sink (route apps to this):   ${APP_SINK_DESC}  (${APP_SINK_NAME})"
    echo "Recording source (select as mic):     ${SRC_DESC}   (${SRC_NAME})"
    if [[ "${monitor_local}" == "1" ]]; then
        echo "Local monitor:                        app/music only -> ${prior_sink}"
    else
        echo "Local monitor:                        disabled"
    fi
    echo
    echo "To revert:"
    echo "    ${0} off"
}

disable_virtual_mic() {
    require_cmd "pactl"

    if ! load_state; then
        echo "Not enabled (no state file found). Nothing to do."
        exit 0
    fi

    # Restore defaults first (best-effort)
    if [[ -n "${PRIOR_DEFAULT_SOURCE:-}" ]]; then
        pactl set-default-source "${PRIOR_DEFAULT_SOURCE}" || true
    fi
    if [[ -n "${PRIOR_DEFAULT_SINK:-}" ]]; then
        pactl set-default-sink "${PRIOR_DEFAULT_SINK}" || true
    fi

    # Unload modules (best-effort, tolerate partial teardown)
    for mid in "${MOD_LOOPBACK_APP_TO_OUTPUT:-}" "${MOD_LOOPBACK_MIC:-}" "${MOD_LOOPBACK_APP_TO_MIX:-}" "${MOD_REMAP_SOURCE:-}" "${MOD_MIX_NULL_SINK:-}" "${MOD_APP_NULL_SINK:-}"; do
        if [[ -n "${mid}" ]]; then
            if pactl list short modules | awk '{print $1}' | grep -Fxq "${mid}"; then
                pactl unload-module "${mid}" || true
            fi
        fi
    done

    rm -f "${STATE_FILE}" || true

    echo "Disabled. Restored prior defaults."
}

status_virtual_mic() {
    require_cmd "pactl"

    if [[ -f "${STATE_FILE}" ]]; then
        echo "State: enabled (state file present)"
        load_state || true
        echo "    PRIOR_DEFAULT_SINK=${PRIOR_DEFAULT_SINK:-}"
        echo "    PRIOR_DEFAULT_SOURCE=${PRIOR_DEFAULT_SOURCE:-}"
        echo "    MOD_APP_NULL_SINK=${MOD_APP_NULL_SINK:-}"
        echo "    MOD_MIX_NULL_SINK=${MOD_MIX_NULL_SINK:-}"
        echo "    MOD_REMAP_SOURCE=${MOD_REMAP_SOURCE:-}"
        echo "    MOD_LOOPBACK_MIC=${MOD_LOOPBACK_MIC:-}"
        echo "    MOD_LOOPBACK_APP_TO_MIX=${MOD_LOOPBACK_APP_TO_MIX:-}"
        echo "    MOD_LOOPBACK_APP_TO_OUTPUT=${MOD_LOOPBACK_APP_TO_OUTPUT:-}"
        echo "    MONITOR_LOCAL=${MONITOR_LOCAL:-0}"
    else
        echo "State: disabled (no state file)"
    fi

    echo
    echo "Current objects:"
    if sink_exists "${APP_SINK_NAME}"; then
        echo "    App sink exists: ${APP_SINK_NAME}"
    else
        echo "    App sink missing: ${APP_SINK_NAME}"
    fi

    if sink_exists "${MIX_SINK_NAME}"; then
        echo "    Mix sink exists: ${MIX_SINK_NAME}"
    else
        echo "    Mix sink missing: ${MIX_SINK_NAME}"
    fi

    if source_exists; then
        echo "    Source exists: ${SRC_NAME}"
    else
        echo "    Source missing: ${SRC_NAME}"
    fi
}

usage() {
    cat <<EOF
Usage:
    ${0} on [--monitor-local]
    ${0} off
    ${0} status

What it does:
    - Creates an app playback sink: "${APP_SINK_DESC}"
    - Creates a separate mix sink used only internally
    - Creates a virtual source: "${SRC_DESC}" (from the mix sink monitor)
    - Loops app/music audio from the app sink into the mix sink
    - Loops your prior default mic into the mix sink
    - Optionally loops only app/music audio back to your prior default output
    - Sets default source to the virtual source
    - Stores prior defaults + module IDs so "off" restores cleanly
EOF
}

main() {
    local action="${1:-}"
    case "${action}" in
        on)
            shift || true
            case "${1:-}" in
                "" )
                    enable_virtual_mic 0
                    ;;
                --monitor-local)
                    enable_virtual_mic 1
                    ;;
                -h|--help)
                    usage
                    ;;
                *)
                    echo "ERROR: Unknown option for 'on': ${1}" >&2
                    usage
                    exit 1
                    ;;
            esac
            ;;
        off)
            disable_virtual_mic
            ;;
        status)
            status_virtual_mic
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
