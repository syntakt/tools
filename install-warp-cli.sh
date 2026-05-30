#!/usr/bin/env bash

# By skrepysh.dll <3

set -Eeuo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

CLOUDFLARE_KEYRING="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
CLOUDFLARE_APT_LIST="/etc/apt/sources.list.d/cloudflare-client.list"
CLOUDFLARE_RPM_REPO="/etc/yum.repos.d/cloudflare-warp.repo"

LOGD() {
    printf "%b[DBG] %s%b\n" "$yellow" "$*" "$plain"
}

LOGE() {
    printf "%b[ERR] %s%b\n" "$red" "$*" "$plain" >&2
}

LOGI() {
    printf "%b[INF] %s%b\n" "$green" "$*" "$plain"
}

die() {
    LOGE "$*"
    exit 1
}

run() {
    local message=$1
    shift

    LOGI "$message"
    "$@"
}

load_os_release() {
    local os_release_file

    if [[ -f /etc/os-release ]]; then
        os_release_file=/etc/os-release
    elif [[ -f /usr/lib/os-release ]]; then
        os_release_file=/usr/lib/os-release
    else
        die "Failed to check the system OS."
    fi

    # shellcheck source=/dev/null
    source "$os_release_file"

    release=${ID:-}
    version_id=${VERSION_ID:-}
    version_codename=${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}

    if [[ -z "$version_codename" ]] && command -v lsb_release >/dev/null 2>&1; then
        version_codename=$(lsb_release -cs)
    fi

    [[ -n "$release" ]] || die "Failed to detect the operating system ID."
}

require_root() {
    [[ $EUID -eq 0 ]] || die "You must be root to run this script. Use sudo."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

warp_installed() {
    command -v warp-cli >/dev/null 2>&1
}

is_supported_codename() {
    local codename=$1
    shift
    local supported

    for supported in "$@"; do
        [[ "$codename" == "$supported" ]] && return 0
    done

    return 1
}

rpm_major_version() {
    printf "%s\n" "$version_id" | cut -d. -f1
}

incompatible_os() {
    printf "%bYour operating system is not supported by this script.%b\n\n" "$red" "$plain"
    echo "Supported Cloudflare WARP package targets:"
    echo "- Ubuntu: focal (20.04), jammy (22.04), noble (24.04)"
    echo "- Debian: bullseye (11), bookworm (12), trixie (13)"
    echo "- Red Hat Enterprise Linux / CentOS: 8"
    exit 1
}

ensure_apt_prerequisites() {
    run "Updating apt repositories" apt-get update
    run "Installing apt prerequisites" apt-get install -y ca-certificates curl gpg
}

add_apt_repo() {
    local codename=$1

    install -d -m 0755 /usr/share/keyrings
    run "Adding Cloudflare WARP GPG key" bash -c \
        "curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output '$CLOUDFLARE_KEYRING'"
    printf "deb [signed-by=%s] https://pkg.cloudflareclient.com/ %s main\n" "$CLOUDFLARE_KEYRING" "$codename" > "$CLOUDFLARE_APT_LIST"
}

install_apt_warp() {
    local distro_name=$1
    local codename=$2

    LOGI "Installing for $distro_name ($codename)"

    if warp_installed; then
        die "warp-cli is already installed. Installation aborted."
    fi

    ensure_apt_prerequisites
    add_apt_repo "$codename"
    run "Updating apt repositories with Cloudflare WARP repo" apt-get update
    run "Installing warp-cli" apt-get install -y cloudflare-warp netcat-openbsd
}

install_rpm_warp() {
    local major_version
    major_version=$(rpm_major_version)

    LOGI "Installing for $release $version_id"

    if warp_installed; then
        die "warp-cli is already installed. Installation aborted."
    fi

    [[ "$major_version" == "8" ]] || incompatible_os

    require_command curl
    require_command rpm
    require_command yum

    # Cloudflare documents re-importing the package key for repositories that
    # had the old key installed before the 2025 key rotation.
    rpm -e 'gpg-pubkey(4fa1c3ba-61abda35)' >/dev/null 2>&1 || true
    run "Importing Cloudflare WARP RPM GPG key" rpm --import https://pkg.cloudflareclient.com/pubkey.gpg
    run "Adding Cloudflare WARP yum repository" bash -c \
        "curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo > '$CLOUDFLARE_RPM_REPO'"
    run "Updating yum repositories" yum update -y
    run "Installing warp-cli" yum install -y cloudflare-warp
}

detect_os_and_install_warp() {
    case "$release" in
        ubuntu)
            is_supported_codename "$version_codename" focal jammy noble || incompatible_os
            install_apt_warp "Ubuntu" "$version_codename"
            ;;
        debian)
            is_supported_codename "$version_codename" bullseye bookworm trixie || incompatible_os
            install_apt_warp "Debian" "$version_codename"
            ;;
        centos | rhel)
            install_rpm_warp
            ;;
        *)
            incompatible_os
            ;;
    esac
}

port_is_available() {
    local port=$1

    if command -v ss >/dev/null 2>&1; then
        if ss -H -ltn "sport = :$port" | grep -q .; then
            return 1
        fi
        return 0
    elif command -v nc >/dev/null 2>&1; then
        if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
            return 1
        fi
        return 0
    else
        LOGD "Neither ss nor nc is available; skipping local port availability check."
        return 0
    fi
}

select_port() {
    local port

    while true; do
        read -r -p "Enter port for WARP local proxy (1024-65535): " port

        if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
            LOGE "Incorrect value. The port must be in the range from 1024 to 65535."
            continue
        fi

        if port_is_available "$port"; then
            WARP_PORT=$port
            export WARP_PORT
            LOGI "Port $WARP_PORT will be used."
            break
        fi

        LOGE "Port $port is unavailable. Try another port."
    done
}

warp_connected() {
    warp-cli --accept-tos status 2>/dev/null \
        | grep -Eqi 'Status update:[[:space:]]+Connected|^[[:space:]]*Status:[[:space:]]+Connected|^[[:space:]]*Connected[[:space:]]*$'
}

warp_registered() {
    warp-cli --accept-tos registration show >/dev/null 2>&1
}

register_warp_if_needed() {
    if warp_registered; then
        LOGI "WARP registration already exists."
        return
    fi

    run "Registering WARP client" warp-cli --accept-tos registration new
}

configure_license_if_requested() {
    local warp_key

    printf "%bEnter WARP+ key (leave blank if you do not have one): %b" "$yellow" "$plain"
    read -r warp_key

    if [[ -z "$warp_key" ]]; then
        LOGI "Skipping WARP+ license configuration."
        return
    fi

    run "Setting WARP+ license key" warp-cli --accept-tos registration license "$warp_key"
}

set_warp_proxy_mode() {
    if warp-cli --accept-tos mode proxy; then
        return
    fi

    LOGD "Falling back to legacy warp-cli set-mode syntax."
    warp-cli --accept-tos set-mode proxy
}

set_warp_proxy_port() {
    local port=$1

    if warp-cli --accept-tos proxy port "$port"; then
        return
    fi

    LOGD "Falling back to legacy warp-cli set-proxy-port syntax."
    warp-cli --accept-tos set-proxy-port "$port"
}

configure_warp() {
    warp_installed || die "warp-cli is not installed. Configuring aborted."

    LOGI "Configuring WARP"

    if warp_connected; then
        run "Disconnecting existing WARP connection" warp-cli --accept-tos disconnect
    fi

    register_warp_if_needed
    configure_license_if_requested
    select_port

    run "Setting local proxy mode" set_warp_proxy_mode
    run "Setting local proxy port to $WARP_PORT" set_warp_proxy_port "$WARP_PORT"
    run "Starting WARP" warp-cli --accept-tos connect

    LOGI "warp-cli has been configured successfully."
    LOGI "You can access the local proxy on 127.0.0.1:$WARP_PORT."
    LOGD "Check it with: curl -x socks5://127.0.0.1:$WARP_PORT https://www.cloudflare.com/cdn-cgi/trace"
    LOGD "The trace output should include: warp=on"
    LOGE "You do not need to open port $WARP_PORT on the firewall."
}

print_menu() {
    if warp_installed; then
        LOGD "warp-cli is already installed."
    fi

    LOGI "Functions:"
    echo "0. Exit"
    echo "1. Install and configure warp-cli"
    echo "2. Install warp-cli without configuring"
    echo "3. Configure warp-cli (only if it is already installed)"
}

manage_warp() {
    local choice

    while true; do
        print_menu
        read -r -p "Select action (0-3): " choice

        case "${choice:-}" in
            0)
                exit 0
                ;;
            1)
                detect_os_and_install_warp
                configure_warp
                return
                ;;
            2)
                detect_os_and_install_warp
                return
                ;;
            3)
                configure_warp
                return
                ;;
            *)
                LOGE "Incorrect choice. Try again."
                ;;
        esac
    done
}

main() {
    load_os_release
    require_root

    LOGI "The OS release is: $release ${version_id:-unknown} (${version_codename:-unknown})"
    manage_warp
}

main "$@"
