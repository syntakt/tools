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
WARP_UPDATE_SCRIPT="/usr/local/sbin/update-cloudflare-warp.sh"
WARP_UPDATE_SERVICE="/etc/systemd/system/cloudflare-warp-update.service"
WARP_UPDATE_TIMER="/etc/systemd/system/cloudflare-warp-update.timer"
WARP_PROXY_HOST="127.0.0.1"

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

rpm_package_manager() {
    if command -v dnf >/dev/null 2>&1; then
        printf "dnf\n"
    elif command -v yum >/dev/null 2>&1; then
        printf "yum\n"
    else
        return 1
    fi
}

rpm_major_version() {
    printf "%s\n" "$version_id" | cut -d. -f1
}

incompatible_os() {
    printf "%bYour operating system is not supported by this script.%b\n\n" "$red" "$plain"
    echo "Supported operating systems:"
    echo "- Ubuntu: focal (20.04), jammy (22.04), noble (24.04), resolute (26.04)"
    echo "- Debian: bullseye (11), bookworm (12), trixie (13)"
    echo "- Red Hat Enterprise Linux / CentOS: 8"
    echo
    echo "Cloudflare WARP apt package targets:"
    echo "- Ubuntu: focal, jammy, noble (Ubuntu 26.04 uses noble until Cloudflare publishes resolute packages)"
    echo "- Debian: bullseye, bookworm, trixie"
    exit 1
}

cloudflare_apt_target_codename() {
    local distro=$1
    local codename=$2
    local version=$3

    case "$distro" in
        ubuntu)
            case "$codename" in
                focal | jammy | noble)
                    printf "%s\n" "$codename"
                    return 0
                    ;;
                resolute)
                    printf "noble\n"
                    return 0
                    ;;
            esac

            case "$version" in
                20.04)
                    printf "focal\n"
                    ;;
                22.04)
                    printf "jammy\n"
                    ;;
                24.04 | 26.04)
                    printf "noble\n"
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        debian)
            case "$codename" in
                bullseye | bookworm | trixie)
                    printf "%s\n" "$codename"
                    return 0
                    ;;
            esac

            case "$version" in
                11)
                    printf "bullseye\n"
                    ;;
                12)
                    printf "bookworm\n"
                    ;;
                13)
                    printf "trixie\n"
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_apt_prerequisites() {
    run "Updating apt repositories" apt-get update
    run "Installing apt prerequisites" apt-get install -y ca-certificates curl gpg iproute2
}

download_cloudflare_apt_key() {
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor --output "$CLOUDFLARE_KEYRING"
}

add_apt_repo() {
    local codename=$1

    install -d -m 0755 /usr/share/keyrings
    run "Adding Cloudflare WARP GPG key" download_cloudflare_apt_key
    printf "deb [signed-by=%s] https://pkg.cloudflareclient.com/ %s main\n" "$CLOUDFLARE_KEYRING" "$codename" > "$CLOUDFLARE_APT_LIST"
}

ensure_apt_warp_repository() {
    local distro_name=$1
    local os_codename=$2
    local package_codename=$3

    LOGI "Preparing Cloudflare WARP repository for $distro_name ($os_codename)"
    if [[ "$os_codename" != "$package_codename" ]]; then
        LOGI "Using Cloudflare WARP package target: $package_codename"
    fi
    ensure_apt_prerequisites
    add_apt_repo "$package_codename"
    run "Updating apt repositories with Cloudflare WARP repo" apt-get update
}

ensure_rpm_prerequisites() {
    local pkg_manager=$1

    run "Installing RPM prerequisites" "$pkg_manager" install -y ca-certificates curl iproute
}

download_cloudflare_rpm_repo() {
    curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo > "$CLOUDFLARE_RPM_REPO"
}

ensure_rpm_warp_repository() {
    local major_version
    local pkg_manager

    major_version=$(rpm_major_version)
    [[ "$major_version" == "8" ]] || incompatible_os

    require_command rpm
    pkg_manager=$(rpm_package_manager) || die "Required command is missing: dnf or yum"

    LOGI "Preparing Cloudflare WARP repository for $release $version_id"
    ensure_rpm_prerequisites "$pkg_manager"

    # Cloudflare documents re-importing the package key for repositories that
    # had the old key installed before the 2025 key rotation.
    rpm -e 'gpg-pubkey(4fa1c3ba-61abda35)' >/dev/null 2>&1 || true
    run "Importing Cloudflare WARP RPM GPG key" rpm --import https://pkg.cloudflareclient.com/pubkey.gpg
    run "Adding Cloudflare WARP yum repository" download_cloudflare_rpm_repo
    run "Refreshing RPM package metadata" "$pkg_manager" makecache -y
}

ensure_warp_repository() {
    local package_codename

    case "$release" in
        ubuntu)
            package_codename=$(cloudflare_apt_target_codename "$release" "$version_codename" "$version_id") || incompatible_os
            ensure_apt_warp_repository "Ubuntu" "$version_codename" "$package_codename"
            ;;
        debian)
            package_codename=$(cloudflare_apt_target_codename "$release" "$version_codename" "$version_id") || incompatible_os
            ensure_apt_warp_repository "Debian" "$version_codename" "$package_codename"
            ;;
        centos | rhel)
            ensure_rpm_warp_repository
            ;;
        *)
            incompatible_os
            ;;
    esac
}

install_latest_warp() {
    if warp_installed; then
        die "warp-cli is already installed. Installation aborted."
    fi

    ensure_warp_repository

    case "$release" in
        ubuntu | debian)
            run "Installing latest warp-cli" apt-get install -y cloudflare-warp netcat-openbsd
            ;;
        centos | rhel)
            local pkg_manager
            pkg_manager=$(rpm_package_manager) || die "Required command is missing: dnf or yum"
            run "Installing latest warp-cli" "$pkg_manager" install -y cloudflare-warp
            ;;
        *)
            incompatible_os
            ;;
    esac

    enable_monthly_warp_update
}

validate_warp_version() {
    local version=$1

    [[ -n "$version" ]] || die "Version cannot be empty."
    [[ "$version" =~ ^[A-Za-z0-9.:_+~%-]+$ ]] || die "Version contains unsupported characters: $version"
}

prompt_warp_version() {
    local version

    list_available_warp_versions
    read -r -p "Enter exact cloudflare-warp package version: " version
    validate_warp_version "$version"
    WARP_VERSION=$version
}

installed_warp_package_version() {
    if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Version}\n' cloudflare-warp >/dev/null 2>&1; then
        dpkg-query -W -f='${Version}\n' cloudflare-warp
    elif command -v rpm >/dev/null 2>&1 && rpm -q cloudflare-warp >/dev/null 2>&1; then
        rpm -q --qf '%{VERSION}-%{RELEASE}\n' cloudflare-warp
    else
        return 1
    fi
}

log_installed_warp_package_version() {
    local installed_version

    installed_version=$(installed_warp_package_version || true)
    LOGI "Installed cloudflare-warp package version: ${installed_version:-unknown}"
}

list_available_warp_versions() {
    ensure_warp_repository

    LOGI "Available cloudflare-warp versions:"
    case "$release" in
        ubuntu | debian)
            apt-cache madison cloudflare-warp || apt-cache policy cloudflare-warp
            ;;
        centos | rhel)
            local pkg_manager
            pkg_manager=$(rpm_package_manager) || die "Required command is missing: dnf or yum"
            "$pkg_manager" --showduplicates list cloudflare-warp
            ;;
        *)
            incompatible_os
            ;;
    esac
}

disable_monthly_warp_update() {
    if ! command -v systemctl >/dev/null 2>&1; then
        LOGE "systemctl is not available. Monthly auto-update cannot be disabled from this script."
        return 0
    fi

    if [[ ! -f "$WARP_UPDATE_TIMER" ]]; then
        LOGI "Monthly WARP auto-update timer is not installed."
        return 0
    fi

    run "Disabling monthly WARP auto-update timer" systemctl disable --now "$(basename "$WARP_UPDATE_TIMER")"
    run "Reloading systemd units" systemctl daemon-reload
    LOGI "Monthly WARP auto-update is disabled."
}

offer_disable_auto_update_for_fixed_version() {
    local answer

    if ! command -v systemctl >/dev/null 2>&1; then
        return
    fi

    if ! systemctl is-enabled --quiet "$(basename "$WARP_UPDATE_TIMER")" 2>/dev/null; then
        return
    fi

    printf "%bMonthly WARP auto-update is enabled and can replace this fixed version with latest. Disable it? [Y/n]: %b" "$yellow" "$plain"
    read -r answer

    case "${answer:-Y}" in
        [Yy] | [Yy][Ee][Ss])
            disable_monthly_warp_update
            ;;
        *)
            LOGD "Monthly auto-update remains enabled."
            ;;
    esac
}

install_warp_version() {
    local version=$1

    validate_warp_version "$version"

    if warp_installed; then
        die "warp-cli is already installed. Use rollback/update to switch versions."
    fi

    ensure_warp_repository

    case "$release" in
        ubuntu | debian)
            run "Installing warp-cli version $version" apt-get install -y --allow-downgrades "cloudflare-warp=$version" netcat-openbsd
            ;;
        centos | rhel)
            local pkg_manager
            pkg_manager=$(rpm_package_manager) || die "Required command is missing: dnf or yum"
            run "Installing warp-cli version $version" "$pkg_manager" install -y "cloudflare-warp-$version"
            ;;
        *)
            incompatible_os
            ;;
    esac

    offer_disable_auto_update_for_fixed_version
    log_installed_warp_package_version
}

switch_rpm_warp_version() {
    local pkg_manager=$1
    local version=$2

    if "$pkg_manager" downgrade -y "cloudflare-warp-$version"; then
        return 0
    fi

    LOGD "RPM downgrade did not apply; trying exact-version install."
    "$pkg_manager" install -y "cloudflare-warp-$version"
}

switch_warp_version() {
    local version=$1

    validate_warp_version "$version"
    warp_installed || die "warp-cli is not installed. Rollback/update aborted."

    ensure_warp_repository

    case "$release" in
        ubuntu | debian)
            run "Installing requested warp-cli version $version" apt-get install -y --allow-downgrades "cloudflare-warp=$version"
            ;;
        centos | rhel)
            local pkg_manager
            pkg_manager=$(rpm_package_manager) || die "Required command is missing: dnf or yum"
            run "Rolling back/updating warp-cli to version $version" switch_rpm_warp_version "$pkg_manager" "$version"
            ;;
        *)
            incompatible_os
            ;;
    esac

    offer_disable_auto_update_for_fixed_version
    log_installed_warp_package_version
}

detect_os_and_install_warp() {
    install_latest_warp
}

enable_monthly_warp_update() {
    local required=${1:-false}

    if ! warp_installed; then
        if [[ "$required" == "true" ]]; then
            die "warp-cli is not installed. Monthly auto-update setup aborted."
        fi
        LOGE "warp-cli is not installed. Monthly auto-update was not configured."
        return 0
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        if [[ "$required" == "true" ]]; then
            die "systemctl is not available. Monthly auto-update setup aborted."
        fi
        LOGE "systemctl is not available. Monthly auto-update was not configured."
        return 0
    fi

    install -d -m 0755 /usr/local/sbin /etc/systemd/system

    cat > "$WARP_UPDATE_SCRIPT" <<'UPDATE_SCRIPT'
#!/usr/bin/env bash

set -Eeuo pipefail

if ! command -v warp-cli >/dev/null 2>&1; then
    echo "warp-cli is not installed; nothing to update."
    exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --only-upgrade cloudflare-warp
elif command -v dnf >/dev/null 2>&1; then
    dnf update -y cloudflare-warp
elif command -v yum >/dev/null 2>&1; then
    yum update -y cloudflare-warp
else
    echo "No supported package manager found for Cloudflare WARP updates." >&2
    exit 1
fi
UPDATE_SCRIPT
    chmod 0755 "$WARP_UPDATE_SCRIPT"

    cat > "$WARP_UPDATE_SERVICE" <<EOF
[Unit]
Description=Update Cloudflare WARP package
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$WARP_UPDATE_SCRIPT
EOF

    cat > "$WARP_UPDATE_TIMER" <<EOF
[Unit]
Description=Run monthly Cloudflare WARP package update

[Timer]
OnCalendar=monthly
Persistent=true
RandomizedDelaySec=1h
Unit=$(basename "$WARP_UPDATE_SERVICE")

[Install]
WantedBy=timers.target
EOF

    run "Reloading systemd units" systemctl daemon-reload
    run "Enabling monthly WARP auto-update timer" systemctl enable --now "$(basename "$WARP_UPDATE_TIMER")"
    LOGI "Monthly WARP auto-update is enabled via $(basename "$WARP_UPDATE_TIMER")."
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

local_proxy_listeners() {
    local port=$1

    require_command ss
    ss -H -ltn "sport = :$port"
}

verify_local_proxy_listener() {
    local port=$1
    local listeners
    local line
    local local_address
    local non_local_listeners=()
    local found_ipv4_loopback=false

    for _ in {1..10}; do
        listeners=$(local_proxy_listeners "$port" || true)
        [[ -n "$listeners" ]] && break
        sleep 1
    done

    if [[ -z "$listeners" ]]; then
        die "WARP local proxy did not start listening on ${WARP_PROXY_HOST}:$port."
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        local_address=$(awk '{print $4}' <<< "$line")

        case "$local_address" in
            "${WARP_PROXY_HOST}:$port")
                found_ipv4_loopback=true
                ;;
            "[::1]:$port" | "::1:$port")
                ;;
            *)
                non_local_listeners+=("$local_address")
                ;;
        esac
    done <<< "$listeners"

    if ((${#non_local_listeners[@]} > 0)); then
        LOGE "WARP proxy must be local-only, but these listeners were found:"
        printf "%s\n" "${non_local_listeners[@]}" >&2
        die "Refusing to continue because WARP proxy is not limited to ${WARP_PROXY_HOST}:$port."
    fi

    if [[ "$found_ipv4_loopback" != "true" ]]; then
        die "WARP proxy is not listening on required local address ${WARP_PROXY_HOST}:$port."
    fi

    LOGI "Verified WARP local proxy is bound to ${WARP_PROXY_HOST}:$port only."
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
    local registration_output

    if ! registration_output=$(warp-cli --accept-tos registration show 2>&1); then
        return 1
    fi

    ! printf "%s\n" "$registration_output" | grep -Eqi 'missing registration|registration missing|no registration'
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

set_masque_tunnel_protocol() {
    if warp-cli --accept-tos tunnel protocol set MASQUE; then
        return
    fi

    LOGD "Could not set MASQUE tunnel protocol; continuing with current tunnel protocol."
}

configure_warp() {
    warp_installed || die "warp-cli is not installed. Configuring aborted."
    require_command ss

    LOGI "Configuring WARP"

    if warp_connected; then
        run "Disconnecting existing WARP connection" warp-cli --accept-tos disconnect
    fi

    register_warp_if_needed
    configure_license_if_requested
    select_port

    run "Setting MASQUE tunnel protocol for local proxy mode" set_masque_tunnel_protocol
    run "Setting local proxy mode" set_warp_proxy_mode
    run "Setting local proxy port to $WARP_PORT" set_warp_proxy_port "$WARP_PORT"
    run "Starting WARP" warp-cli --accept-tos connect

    verify_local_proxy_listener "$WARP_PORT"

    LOGI "warp-cli has been configured successfully."
    LOGI "You can access the local proxy on ${WARP_PROXY_HOST}:$WARP_PORT."
    LOGD "Check it with: curl -x socks5://${WARP_PROXY_HOST}:$WARP_PORT https://www.cloudflare.com/cdn-cgi/trace"
    LOGD "The trace output should include: warp=on"
    LOGI "Do not open port $WARP_PORT on the firewall."
}

print_menu() {
    if warp_installed; then
        LOGD "warp-cli is already installed."
    fi

    LOGI "Functions:"
    echo "0. Exit"
    echo "1. Install latest warp-cli and configure"
    echo "2. Install latest warp-cli without configuring"
    echo "3. Install specific warp-cli version and configure"
    echo "4. Install specific warp-cli version without configuring"
    echo "5. Configure warp-cli (only if it is already installed)"
    echo "6. Roll back/update warp-cli to a specific version"
    echo "7. List available warp-cli package versions"
    echo "8. Enable monthly warp-cli auto-update"
    echo "9. Disable monthly warp-cli auto-update"
}

manage_warp() {
    local choice

    while true; do
        print_menu
        read -r -p "Select action (0-9): " choice

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
                prompt_warp_version
                install_warp_version "$WARP_VERSION"
                configure_warp
                return
                ;;
            4)
                prompt_warp_version
                install_warp_version "$WARP_VERSION"
                return
                ;;
            5)
                configure_warp
                return
                ;;
            6)
                prompt_warp_version
                switch_warp_version "$WARP_VERSION"
                return
                ;;
            7)
                list_available_warp_versions
                return
                ;;
            8)
                enable_monthly_warp_update true
                return
                ;;
            9)
                disable_monthly_warp_update
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
