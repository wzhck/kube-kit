#!/usr/bin/env bash
# vim: nu:noai:ts=4
# shellcheck shell=bash disable=SC1090,SC2034,SC2206,SC2207

# note: this function returns an array's defination.
# e.g. ret_str="$(util::parse_ini /path/to/ini/file)"
# ret_str's content (including the single quotes) is
# '([10.10.10.11]="r00tnode1" [10.10.10.22]="r00tnode2" [10.10.10.33]="r00tnode3" )'
# you can use "${ret_str}" to re-declare your new array via the "eval" command:
# eval "declare -A new_array=${ret_str}"
# now, you can use the new_array as normal :)
function util::parse_ini() {
    local ini_file="${1}"

    if [[ ! -f "${ini_file}" ]]; then
        LOG error "The ini file '${ini_file}' doesn't exist!"
        return 1
    fi

    local -a ips
    for line in $(grep -vE '(^#|^;|^$)' "${ini_file}" | grep '^\[.*\]'); do
        group_ips=($(ipv4::ip_string_to_ip_array "${line:1:-1}"))
        for ip in "${group_ips[@]}"; do
            if util::element_in_array "${ip}" "${ips[@]}"; then
                LOG error "The ip address '${ip}' is duplicated!"
                return 2
            elif ! util::can_ping "${ip}"; then
                LOG error "Can't ping this ip address: '${ip}'!"
                return 3
            fi
            ips+=(${ip})
        done
    done

    local -A ret
    while read -r line; do
        # exclude lines that are blank or comments.
        if [[ "${line}" =~ (^#|^;|^$) ]]; then
            continue
        elif [[ "${line}" =~ ^\[.*\]$ ]]; then
            group_ips=($(ipv4::ip_string_to_ip_array "${line:1:-1}"))
        else
            for ip in "${group_ips[@]}"; do
                if [[ "${ret[${ip}]}" =~ ${line} ]]; then
                    LOG error "The value '${line}' for '${ip}' is duplicated!" \
                              "tips: if a value is the prefix of other values" \
                              "(e.g. two values '/dev/sdb' and '/dev/sdb1')," \
                              "you should put the shortest one (i.e. /dev/sdb)" \
                              "before the others which use it as prefix."
                    return 4
                fi
                ret[${ip}]+="${line} "
            done
        fi
    done < "${ini_file}"

    for ip in "${ips[@]}"; do
        if [[ -z "${ret[${ip}]}" ]]; then
            LOG error "The value for '${ip}' in '${ini_file}' is empty!"
            return 5
        fi
        # remove the tailing blank.
        ret[${ip}]="${ret[${ip}]% }"
    done

    # echo -n "${ret_str#*=}"
    declare -p ret | sed -r 's/[^=]+=(.*)/\1/'
}


# util::calling_stacks prints the calling stacks with function's name,
# filename and the line number of the last caller.
function util::calling_stacks() {
    local start="${1:-1}"
    local stack=""
    local stack_size="${#FUNCNAME[@]}"

    # NOTE: stack #0 is the util::calling_stacks itself, we should
    # start with at least 1 to skip the calling_stack function itself.
    for ((stack_idx = start; stack_idx < stack_size; stack_idx++)); do
        local func="${FUNCNAME[${stack_idx}]}"
        local script="${BASH_SOURCE[${stack_idx}]}"
        local lineno="${BASH_LINENO[$((stack_idx-1))]}"

        # this means this function is executed on a remote host.
        if [[ -z "${script}" ]]; then
            local lines=0
            for srcfile in "${SCRIPTS[@]}"; do
                line="${SCRIPTS_LINES[${srcfile}]}"
                ((lines += line))
                ((lines <= lineno)) && continue
                remote_host="$(util::current_host_ip)"
                script="${srcfile} (executed on ${remote_host})"
                lineno=$((lineno + line - lines))
                break
            done
        elif [[ "${script}" =~ ^\. ]]; then
            src_dir=$(cd "$(dirname ${script})" && pwd)
            src_filename="${script##*/}"
            script="${src_dir}/${src_filename}"
        fi

        stack+="    at: ${func} ${script} +${lineno}\n"
    done

    echo -e "${stack}"
}


# util::get_global_envs returns the definitions of some environmet variables or
# array which are defined by kube-kit (actually defined in etc/*.sh or parser/*.sh)
# whose name start with any prefix configurated in etc/env.prefix
function util::get_global_envs() {
    env_prefix_file="${__KUBE_KIT_DIR__}/etc/env.prefix"
    env_prefix_regex=$(grep -oP '^[A-Z]+' "${env_prefix_file}" | paste -sd '|')
    declare_env_prefix="^declare [-aAi]+ (${env_prefix_regex})[A-Z_]*="
    declare -p | grep -P "${declare_env_prefix}" | tee "${KUBE_KIT_ENV_FILE}"
}


function util::element_in_array() {
    for ele in "${@:2}"; do
        if [[ "${ele}" == "$1" ]]; then
            return 0
        fi
    done

    return 1
}


function util::last_idx_in_array() {
    local ele="${1}"
    local arr=(${@:2})
    local ans=-1

    for idx in "${!arr[@]}"; do
        [[ "${arr[idx]}" == "${ele}" ]] && ans="${idx}"
    done

    echo -n "${ans}"
}


function util::sort_uniq_array() {
    local -a old_array=(${@})
    local -a new_array
    local -a sort_options
    local ele_all_ips=true

    for ele in "${old_array[@]}"; do
        [[ "${ele}" =~ ^${IPV4_REGEX}$ ]] || ele_all_ips=false
    done

    if [[ "${ele_all_ips}" == true ]]; then
        # if all elements in an array are ipv4 addresses, then sort
        # them according to each dot-seperated part of ip address.
        # 1,1n equals 1.1,1.0n (using all chars in the first field)
        sort_options=("-t" "." "-k" "1,1n" "-k" "2,2n" "-k" "3,3n" "-k" "4,4n")
    fi

    new_array=($(tr " " "\n" <<< "${old_array[@]}" | sort -u "${sort_options[@]}"))
    echo -n "${new_array[@]}"
}


function util::random_string() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "${1:-16}" | head -n "${2:-1}"
}


function util::file_ends_with_newline() {
    [[ $(tail -c 1 "${1}" | wc -l) -gt 0 ]]
}


function util::timeout() {
    timeout --foreground -s SIGKILL -k 10s "${1}" "${@:2}"
}


function util::can_ping() {
    ping -c 4 -W 1 -i 0.05 "${1}" &>/dev/null
}


function util::can_ssh() {
    local host="${1}"
    util::timeout 10s \
        sshpass -p "${KUBE_CIPHERS_ARRAY[${host}]}" \
        ssh "root@${host}" "${OPENSSH_OPTIONS[@]}" -p "${SSHD_PORT}" \
        ls &>/dev/null
}


function util::show_time() {
    local timer_show=""
    local total_ns="${1}"
    local delta_us="$((total_ns / 1000))"
    local us="$((delta_us % 1000))"
    local ms="$((delta_us / 1000 % 1000))"
    local s="$((delta_us / 1000000 % 60))"
    local m="$((delta_us / 60000000 % 60))"
    local h="$((delta_us / 3600000000))"

    # Goal: always show around 3 digits of time.
    if ((h > 0)); then
        timer_show="${h}h${m}m${s}s"
    elif ((m > 0)); then
        timer_show="${m}m${s}s"
    elif ((s >= 10)); then
        timer_show="${s}.$((ms / 100))s"
    elif ((s > 0)); then
        timer_show="${s}.$(printf %03d ${ms})s"
    elif ((ms >= 100)); then
        timer_show="${ms}ms"
    elif ((ms > 0)); then
        timer_show="${ms}.$((us / 100))ms"
    else
        timer_show="${us}us"
    fi

    echo -n "${timer_show}"
}


# this function returns the ip address which is in the kubernetes cluster.
function util::current_host_ip() {
    for ip in $(hostname -I); do
        if [[ "${KUBE_MASTER_IPS_ARRAY_LEN}" -gt 1 && \
              "${ip}" == "${KUBE_MASTER_VIP}" ]]; then
            continue
        elif ipv4::two_ips_in_same_subnet "${ip}" "${KUBE_KIT_HOST_IP}" \
                                          "${KUBE_KIT_HOST_CIDR}"; then
            echo -n "${ip}"
            return 0
        fi
    done

    LOG error "failed to get ipaddr of current host in the kubernetes cluster!"
    return 1
}


function util::start_and_enable() {
    local service="${1%.service}.service"

    if ! systemctl list-unit-files | grep -q "${service}"; then
        LOG warn "The service ${service} doesn't exist, can't start it, do nothing!"
        return 0
    fi

    systemctl daemon-reload
    if ! systemctl is-enabled "${service}" &>/dev/null; then
        systemctl enable "${service}" &>/dev/null
    fi

    if systemctl is-active "${service}" &>/dev/null; then
        systemctl stop "${service}" &>/dev/null && sleep 2s
    fi

    for _ in $(seq 3); do
        systemctl start "${service}"
        systemctl is-active "${service}" &>/dev/null && return 0
    done

    LOG error "Failed to (re)start ${service}, please check it yourself!"
    return 1
}


function util::stop_and_disable() {
    local service="${1%.service}.service"

    if ! systemctl list-unit-files | grep -q "${service}"; then
        LOG warn "The service ${service} doesn't exist, can't stop it, do nothing!"
        return 0
    fi

    if systemctl is-enabled "${service}" &>/dev/null; then
        systemctl disable "${service}" &>/dev/null
    fi

    if systemctl is-active "${service}" &>/dev/null; then
        systemctl kill -s SIGKILL -f "${service}" || true
    fi
}
