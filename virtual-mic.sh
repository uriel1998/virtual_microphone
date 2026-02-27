#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage:
    ${0} off
    ${0} status
    ${0} -n <count> [-l <label>]...
    ${0} -h | --help

Description:
    Creates virtual audio pipeline pairs.
    For each label, the script creates:
    - "<label> input sink" (null sink)
    - "<label> virtual audio output" (remap source from the sink monitor)

Label selection:
    - Uses provided -l labels first, in order.
    - If fewer than -n labels are provided, fills the rest as v1, v2, v3...

Example:
    ${0} -n 4 -l wombat -l wombat2
    -> labels: wombat, wombat2, v1, v2
EOF
}

require_cmd() {
    local cmd="${1}"
    command -v "${cmd}" >/dev/null 2>&1 || {
        echo "ERROR: missing command: ${cmd}" >&2
        exit 1
    }
}

sanitize_id() {
    local value="${1}"
    # PulseAudio/PipeWire object names are safest with [A-Za-z0-9_]
    value="${value//[^[:alnum:]_]/_}"
    value="${value#_}"
    value="${value%_}"
    if [[ -z "${value}" ]]; then
        value="v"
    fi
    printf '%s\n' "${value}"
}

sink_exists() {
    local sink_name="${1}"
    pactl list short sinks | awk '{print $2}' | grep -Fxq "${sink_name}"
}

source_exists() {
    local source_name="${1}"
    pactl list short sources | awk '{print $2}' | grep -Fxq "${source_name}"
}

disable_virtual_devices() {
    require_cmd "pactl"

    local -a remap_ids=()
    local -a sink_ids=()

    while IFS=$'\t' read -r module_id module_name module_args _; do
        if [[ "${module_name}" == "module-remap-source" && "${module_args}" == *"virt_"* ]]; then
            remap_ids+=("${module_id}")
        fi
        if [[ "${module_name}" == "module-null-sink" && "${module_args}" == *"virt_"* ]]; then
            sink_ids+=("${module_id}")
        fi
    done < <(pactl list short modules)

    if (( ${#remap_ids[@]} == 0 && ${#sink_ids[@]} == 0 )); then
        echo "No virtual devices found to remove."
        return 0
    fi

    # Remove sources first because they depend on sink monitors.
    for module_id in "${remap_ids[@]}"; do
        pactl unload-module "${module_id}" || true
    done
    for module_id in "${sink_ids[@]}"; do
        pactl unload-module "${module_id}" || true
    done

    echo "Removed virtual devices with names starting with 'virt_'."
}

status_virtual_devices() {
    require_cmd "pactl"

    local -a sink_rows=()
    local -a source_rows=()
    local -a module_rows=()

    while IFS=$'\t' read -r id name driver spec state; do
        if [[ "${name}" == virt_* ]]; then
            sink_rows+=("${id}|${name}|${driver}|${spec}|${state}")
        fi
    done < <(pactl list short sinks)

    while IFS=$'\t' read -r id name driver spec state; do
        if [[ "${name}" == virt_* ]]; then
            source_rows+=("${id}|${name}|${driver}|${spec}|${state}")
        fi
    done < <(pactl list short sources)

    while IFS=$'\t' read -r id module args _; do
        if [[ "${args}" == *virt_* ]]; then
            module_rows+=("${id}|${module}|${args}")
        fi
    done < <(pactl list short modules)

    echo "Virtual device status (prefix: virt_)"
    echo

    if (( ${#sink_rows[@]} == 0 )); then
        echo "Sinks: none"
    else
        echo "Sinks:"
        for row in "${sink_rows[@]}"; do
            IFS='|' read -r id name driver spec state <<< "${row}"
            echo "  - id=${id} name=${name} state=${state} spec=${spec} driver=${driver}"
        done
    fi

    echo
    if (( ${#source_rows[@]} == 0 )); then
        echo "Sources: none"
    else
        echo "Sources:"
        for row in "${source_rows[@]}"; do
            IFS='|' read -r id name driver spec state <<< "${row}"
            echo "  - id=${id} name=${name} state=${state} spec=${spec} driver=${driver}"
        done
    fi

    echo
    if (( ${#module_rows[@]} == 0 )); then
        echo "Modules: none referencing virt_"
    else
        echo "Modules:"
        for row in "${module_rows[@]}"; do
            IFS='|' read -r id module args <<< "${row}"
            echo "  - id=${id} module=${module} args=${args}"
        done
    fi
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            return 0
        fi
    done

    if [[ "${1:-}" == "off" ]]; then
        disable_virtual_devices
        return 0
    fi
    if [[ "${1:-}" == "status" ]]; then
        status_virtual_devices
        return 0
    fi

    require_cmd "pactl"

    local count=""
    local -a labels=()

    while getopts ":n:l:h" opt; do
        case "${opt}" in
            n)
                count="${OPTARG}"
                ;;
            l)
                labels+=("${OPTARG}")
                ;;
            h)
                usage
                exit 0
                ;;
            :)
                echo "ERROR: Option -${OPTARG} requires an argument." >&2
                usage
                exit 1
                ;;
            \?)
                echo "ERROR: Unknown option: -${OPTARG}" >&2
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "${count}" ]]; then
        echo "ERROR: -n is required." >&2
        usage
        exit 1
    fi

    if ! [[ "${count}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: -n must be a positive integer." >&2
        exit 1
    fi

    local -a final_labels=()
    local i=0
    local auto_idx=1
    while (( i < count )); do
        if (( i < ${#labels[@]} )); then
            final_labels+=("${labels[${i}]}")
        else
            final_labels+=("v${auto_idx}")
            ((auto_idx += 1))
        fi
        ((i += 1))
    done

    echo "Creating ${count} virtual audio pipeline pair(s)..."

    for label in "${final_labels[@]}"; do
        local safe_label
        safe_label="$(sanitize_id "${label}")"

        local sink_name="virt_${safe_label}_input_sink"
        local source_name="virt_${safe_label}_output"
        local sink_desc="${label} input sink"
        local source_desc="${label} virtual audio output"

        if sink_exists "${sink_name}"; then
            echo "Sink already exists for '${label}': ${sink_name}"
        else
            pactl load-module module-null-sink \
                sink_name="${sink_name}" >/dev/null
            echo "Created sink for '${label}': ${sink_desc} (${sink_name})"
        fi

        if source_exists "${source_name}"; then
            echo "Source already exists for '${label}': ${source_name}"
        else
            pactl load-module module-remap-source \
                master="${sink_name}.monitor" \
                source_name="${source_name}" >/dev/null
            echo "Created output for '${label}': ${source_desc} (${source_name})"
        fi
    done
}

main "$@"
