#!/usr/bin/env bash
# ==============================================================================
# IPQuality | Dual-Stack (IPv4 + IPv6) Diagnostics
# ==============================================================================

set -uo pipefail
shopt -s extglob

export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=C
REPORT_TIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

STACK_MODE="dual"
CUSTOM_IP=""
MASK_IP=false
DIRECT_ONLY=false
OUTPUT_FILE=""

is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    local -a octets=($ip)
    local o
    for o in "${octets[@]}"; do
        ((10#$o >= 0 && 10#$o <= 255)) || return 1
    done
    return 0
}

is_valid_ipv6() {
    local ip="$1"
    [[ "$ip" == *":"* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]
}

detect_public_ip() {
    local mode="$1" url res=""
    local -a urls=()
    if [[ "$mode" == "-4" ]]; then
        urls=("https://ipv4.icanhazip.com" "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipinfo.io/ip")
    else
        urls=("https://ipv6.icanhazip.com" "https://api6.ipify.org" "https://ifconfig.me/ip")
    fi
    for url in "${urls[@]}"; do
        res=$(curl -s "$mode" --connect-timeout 2 -m 4 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$mode" == "-4" ]]; then
            is_valid_ipv4 "$res" && { printf '%s' "$res"; return 0; }
        else
            is_valid_ipv6 "$res" && { printf '%s' "$res"; return 0; }
        fi
    done
    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -4|--ipv4)   STACK_MODE="4"; shift ;;
        -6|--ipv6)   STACK_MODE="6"; shift ;;
        -i|--ip)
            if [[ -z "${2:-}" ]]; then
                echo "Error: -i/--ip requires a target IP address." >&2
                exit 1
            fi
            CUSTOM_IP="$2"
            shift 2
            ;;
        -m|--mask)   MASK_IP=true; shift ;;
        -d|--direct) DIRECT_ONLY=true; shift ;;
        -o|--output)
            if [[ -z "${2:-}" ]]; then
                echo "Error: -o/--output requires a file path." >&2
                exit 1
            fi
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: bash ipcheck.sh [-4|-6] [-i target_ip] [-m] [-d|--direct] [-o output.txt]"
            exit 0
            ;;
        *) shift ;;
    esac
done

if [[ -n "$CUSTOM_IP" ]] && ! is_valid_ipv4 "$CUSTOM_IP" && ! is_valid_ipv6 "$CUSTOM_IP"; then
    echo "Error: Invalid IP address format: $CUSTOM_IP" >&2
    exit 1
fi

# --- Modern 256-Color Palette ---
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[38;5;243m'
    readonly C_BORDER=$'\033[38;5;239m'
    readonly C_TRACK=$'\033[38;5;237m'
    readonly C_CYAN=$'\033[38;5;110m'
    readonly C_ACCENT=$'\033[1;38;5;117m'
    readonly C_WHITE=$'\033[1;38;5;255m'
    readonly C_BAR=$'\033[38;5;75m'
    readonly C_GREEN=$'\033[38;5;114m'
    readonly C_YELLOW=$'\033[38;5;221m'
    readonly C_RED=$'\033[38;5;203m'
    readonly C_BLUE=$'\033[38;5;75m'
    readonly C_PURPLE=$'\033[38;5;141m'
    readonly C_BADGE=$'\033[1;48;5;24;38;5;195m'

    # Soft dark-tinted pills (easy on the eyes)
    readonly BG_GREEN=$'\033[48;5;22;38;5;120m'
    readonly BG_YELLOW=$'\033[48;5;58;38;5;228m'
    readonly BG_RED=$'\033[48;5;52;38;5;210m'
    readonly BG_BLUE=$'\033[48;5;24;38;5;159m'
    readonly BG_GRAY=$'\033[48;5;236;38;5;246m'
else
    readonly C_RESET="" C_BOLD="" C_DIM="" C_BORDER="" C_TRACK=""
    readonly C_CYAN="" C_ACCENT="" C_WHITE="" C_BAR=""
    readonly C_GREEN="" C_YELLOW="" C_RED="" C_BLUE="" C_PURPLE="" C_BADGE=""
    readonly BG_GREEN="" BG_YELLOW="" BG_RED="" BG_BLUE="" BG_GRAY=""
fi

readonly CLEAR_LINE=$'\r\033[K'
readonly SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
readonly RAIL="│"
readonly UA_BROWSER="Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"

BASE_TMP=$(mktemp -d -t ipq.XXXXXX)
cleanup() {
    local pid
    for pid in $(jobs -pr 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
    rm -rf -- "$BASE_TMP"
}
trap cleanup EXIT INT TERM

FRAME_IDX=0

# --- Dependencies ---
check_deps() {
    local missing=()
    for cmd in curl jq awk sed tr head cut; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if ! command -v dig &>/dev/null && ! command -v host &>/dev/null; then
        missing+=("dnsutils")
    fi
    if ((${#missing[@]} > 0)); then
        if ((EUID == 0)); then
            if command -v apt-get &>/dev/null; then
                apt-get update -qq && apt-get install -y -qq "${missing[@]}" &>/dev/null
            elif command -v dnf &>/dev/null; then
                dnf install -y -q "${missing[@]}" bind-utils &>/dev/null
            elif command -v yum &>/dev/null; then
                yum install -y -q "${missing[@]}" bind-utils &>/dev/null
            elif command -v pacman &>/dev/null; then
                pacman -Sy --noconfirm "${missing[@]/dnsutils/bind}" &>/dev/null
            elif command -v apk &>/dev/null; then
                apk add --no-cache "${missing[@]}" bind-tools &>/dev/null
            fi
        else
            printf '%s[✗]%s Missing dependencies: %s. Run as root or install manually.\n' "$C_RED" "$C_RESET" "${missing[*]}" >&2
            exit 1
        fi
    fi
}

wait_with_spinner() {
    local label="$1"
    local total
    total=$(jobs -pr | wc -l)
    ((total == 0)) && return
    if [[ -t 2 ]]; then
        while true; do
            local running
            running=$(jobs -pr | wc -l)
            ((running == 0)) && break
            local frame="${SPINNER_FRAMES[FRAME_IDX % ${#SPINNER_FRAMES[@]}]}"
            FRAME_IDX=$((FRAME_IDX + 1))
            printf '%s %s%s%s  %s %s(%d/%d)%s' \
                "$CLEAR_LINE" "$C_CYAN" "$frame" "$C_RESET" "$label" \
                "$C_DIM" $((total - running)) "$total" "$C_RESET" >&2
            sleep 0.1
        done
        wait 2>/dev/null || true
        printf '%s' "$CLEAR_LINE" >&2
    else
        wait
    fi
}

print_section() {
    local title="$1"
    local pad_len=$((74 - ${#title}))
    ((pad_len < 4)) && pad_len=4
    local line=""
    local i
    for ((i = 0; i < pad_len; i++)); do line+="─"; done
    printf '\n %s╭─%s %s%s%s %s%s%s\n' "$C_BORDER" "$C_RESET" "$C_ACCENT" "$title" "$C_RESET" "$C_BORDER" "$line" "$C_RESET"
}

print_rail() {
    printf ' %s%s%s ' "$C_BORDER" "$RAIL" "$C_RESET"
}

print_section_end() {
    printf ' %s╰──────────────────────────────────────────────────────────────────────────────%s\n' "$C_BORDER" "$C_RESET"
}

jq_get() {
    local file="$1" query="$2"
    [[ ! -s "$file" ]] && { printf 'N/A'; return; }
    local res
    res=$(jq -r "(${query}) | if . == null or . == \"\" then \"N/A\" else tostring end" "$file" 2>/dev/null || true)
    [[ -z "$res" ]] && res="N/A"
    printf '%s' "$res"
}

asn_label() {
    case "$1" in
        1299)  printf 'Arelion (Tier-1)' ;;
        174)   printf 'Cogent (Tier-1)' ;;
        3356)  printf 'Lumen (Tier-1)' ;;
        2914)  printf 'NTT (Tier-1)' ;;
        3257)  printf 'GTT (Tier-1)' ;;
        6453)  printf 'Tata (Tier-1)' ;;
        6762)  printf 'Sparkle (Tier-1)' ;;
        6939)  printf 'Hurricane Electric' ;;
        9002)  printf 'RETN' ;;
        6461)  printf 'Zayo (Tier-1)' ;;
        3491)  printf 'PCCW Global' ;;
        7018)  printf 'AT&T (Tier-1)' ;;
        701)   printf 'Verizon' ;;
        3320)  printf 'Deutsche Telekom' ;;
        5511)  printf 'Orange (Tier-1)' ;;
        12956) printf 'Telxius' ;;
        4809)  printf 'China Telecom CN2' ;;
        4134)  printf 'ChinaNet (163)' ;;
        4837)  printf 'China Unicom' ;;
        9808|58453) printf 'China Mobile CMI' ;;
        12389) printf 'Rostelecom' ;;
        20485) printf 'TransTeleCom' ;;
        8359)  printf 'MTS' ;;
        31133) printf 'MegaFon' ;;
        3216)  printf 'VimpelCom' ;;
        49505) printf 'Selectel' ;;
        13335) printf 'Cloudflare' ;;
        16509) printf 'Amazon AWS' ;;
        15169) printf 'Google' ;;
        8075)  printf 'Microsoft' ;;
        24940) printf 'Hetzner' ;;
        16276) printf 'OVHcloud' ;;
        *)     printf '' ;;
    esac
}

# --- ISO Country Mapper ---
iata_to_country() {
    local iata="${1^^}"
    [[ -z "$iata" || ${#iata} -ne 3 ]] && return
    case "$iata" in
        AMS|EIN|RTM) printf 'NL' ;;
        FRA|MUC|BER|DUS|HAM|STR|CGN|NUE|LEJ|HAJ) printf 'DE' ;;
        ARN|GOT|MMX|BMA) printf 'SE' ;;
        HEL|TMP|OUL) printf 'FI' ;;
        OSL|BGO|SVG|TRD) printf 'NO' ;;
        CPH|BLL|AAL) printf 'DK' ;;
        LHR|LGW|MAN|STN|LTN|EDI|BHX|GLA|BRS) printf 'GB' ;;
        CDG|ORY|MRS|LYS|NCE|TLS|BOD) printf 'FR' ;;
        ZRH|GVA|BSL) printf 'CH' ;;
        VIE|SZG|GRZ) printf 'AT' ;;
        WAW|KRK|GDN|KTW|POZ|WRO) printf 'PL' ;;
        PRG|BRQ) printf 'CZ' ;;
        BUD) printf 'HU' ;;
        OTP|CLJ) printf 'RO' ;;
        SOF) printf 'BG' ;;
        BEG) printf 'RS' ;;
        ZAG) printf 'HR' ;;
        LJU) printf 'SI' ;;
        BTS) printf 'SK' ;;
        RIX) printf 'LV' ;;
        TLL) printf 'EE' ;;
        VNO|KUN) printf 'LT' ;;
        DUB|ORK) printf 'IE' ;;
        BRU|CRL) printf 'BE' ;;
        LUX) printf 'LU' ;;
        MAD|BCN|AGP|VLC|PMI|SVQ|BIO) printf 'ES' ;;
        LIS|OPO) printf 'PT' ;;
        MXP|LIN|FCO|BGY|VCE|BLQ|NAP|TRN|PMO) printf 'IT' ;;
        ATH|SKG) printf 'GR' ;;
        IST|SAW|ESB|AYT|ADB) printf 'TR' ;;
        KBP|IEV|LWO|ODS) printf 'UA' ;;
        SVO|DME|VKO|LED|KZN|SVX|OVB|AER|ROV) printf 'RU' ;;
        TLV|HFA) printf 'IL' ;;
        DXB|AUH|SHJ) printf 'AE' ;;
        JNB|CPT|DUR) printf 'ZA' ;;
        IAD|JFK|EWR|LAX|SFO|SJC|ORD|DFW|MIA|ATL|SEA|DEN|BOS|PHX|IAH|MSP|DTW|PHL|CLT|SLC|LAS|MCO|PDX|BNA|RDU|MCI|CMH|IND|PIT|STL|BUF) printf 'US' ;;
        YYZ|YVR|YUL|YYC|YOW|YEG|YWG|YHZ) printf 'CA' ;;
        GRU|GIG|VCP|BSB|CNF|POA|REC|FOR|SSA|CWB) printf 'BR' ;;
        EZE|AEP|COR) printf 'AR' ;;
        SCL) printf 'CL' ;;
        NRT|HND|KIX|ITM|NGO|FUK|CTS) printf 'JP' ;;
        ICN|GMP|PUS) printf 'KR' ;;
        SIN) printf 'SG' ;;
        HKG) printf 'HK' ;;
        TPE|KHH) printf 'TW' ;;
        BKK|DMK|HKT) printf 'TH' ;;
        KUL|JHB) printf 'MY' ;;
        BOM|DEL|BLR|MAA|HYD|CCU|AMD|PNQ) printf 'IN' ;;
        SYD|MEL|BNE|PER|ADL|CBR) printf 'AU' ;;
        AKL|WLG|CHC) printf 'NZ' ;;
        *) printf '' ;;
    esac
}

# --- UI Badges ---
format_type_badge() {
    local val="${1,,}"
    case "$val" in
        *hosting*|*datacenter*|*dch*|*transit*|*cloud*|*server*|*colocation*)
            printf "${BG_RED} %-8s ${C_RESET}" "Hosting" ;;
        *tor*)
            printf "${BG_RED} %-8s ${C_RESET}" "Tor" ;;
        *vpn*)
            printf "${BG_RED} %-8s ${C_RESET}" "VPN" ;;
        *proxy*|*socks*)
            printf "${BG_RED} %-8s ${C_RESET}" "Proxy" ;;
        *cdn*|*content*)
            printf "${BG_BLUE} %-8s ${C_RESET}" "CDN" ;;
        *spider*|*ses*|*crawler*|*bot*)
            printf "${BG_RED} %-8s ${C_RESET}" "Crawler" ;;
        *isp/mob*|*mob/isp*)
            printf "${BG_GREEN} %-8s ${C_RESET}" "ISP/Mob" ;;
        *mobile*|*mob*|*cellular*|*wireless*)
            printf "${BG_GREEN} %-8s ${C_RESET}" "Mobile" ;;
        *isp*|*residential*|*home*|*cable*|*dsl*|*dialup*|*broadband*|*fiber*)
            printf "${BG_GREEN} %-8s ${C_RESET}" "ISP" ;;
        *line*|*fixed*)
            printf "${BG_GREEN} %-8s ${C_RESET}" "Line" ;;
        *edu*|*university*|*college*|*school*|*library*|*lib*)
            printf "${BG_BLUE} %-8s ${C_RESET}" "Edu" ;;
        *gov*|*mil*)
            printf "${BG_YELLOW} %-8s ${C_RESET}" "Gov" ;;
        *business*|*com*|*commercial*|*corporate*|*org*|*bank*)
            printf "${BG_YELLOW} %-8s ${C_RESET}" "Business" ;;
        *sat*)
            printf "${BG_GREEN} %-8s ${C_RESET}" "Sat" ;;
        *)
            printf "${BG_GRAY} %-8s ${C_RESET}" "N/A" ;;
    esac
}

draw_score_bar() {
    local label="$1" score="$2" disp_val="$3" level_txt="$4"
    local total_cells=34
    local fill_len
    fill_len=$(awk -v s="$score" -v t="$total_cells" 'BEGIN { len=int((s / 100.0) * t + 0.5); if(s>0 && len<1) len=1; if(len<0) len=0; if(len>t) len=t; print len }')
    local empty_len=$((total_cells - fill_len))

    local fill_color="$C_GREEN" pill_bg="$BG_GREEN"
    case "$level_txt" in
        High|VeryHigh|DoS|Risky|HighRisk)
            fill_color="$C_RED"; pill_bg="$BG_RED" ;;
        Medium|Elevated|Suspicious)
            fill_color="$C_YELLOW"; pill_bg="$BG_YELLOW" ;;
        *)
            fill_color="$C_GREEN"; pill_bg="$BG_GREEN" ;;
    esac

    local fill_str="" empty_str="" i
    for ((i = 0; i < fill_len; i++)); do fill_str+="━"; done
    for ((i = 0; i < empty_len; i++)); do empty_str+="─"; done

    print_rail
    printf "${C_CYAN}%-15s${C_RESET} ${fill_color}%s${C_RESET}${C_TRACK}%s${C_RESET}  ${fill_color}${C_BOLD}%-9s${C_RESET} ${pill_bg} %-8s ${C_RESET}\n" \
        "$label" "$fill_str" "$empty_str" "$disp_val" "$level_txt"
}

fmt_bool() {
    case "$1" in
        true|Yes|yes|1) printf "${C_RED}${C_BOLD}● Yes   ${C_RESET}" ;;
        false|No|no|0)  printf "${C_GREEN}○ No    ${C_RESET}" ;;
        *)              printf "${C_DIM}· N/A   ${C_RESET}" ;;
    esac
}

fmt_reg() {
    if [[ -n "$1" && "$1" != "null" && "$1" != "N/A" && ${#1} -eq 2 ]]; then
        printf "${C_ACCENT}[%s]    ${C_RESET}" "$1"
    else
        printf "${C_DIM}· N/A   ${C_RESET}"
    fi
}

fmt_srv_status() {
    case "$1" in
        Yes)      printf "${BG_GREEN} ✔ Yes    ${C_RESET}" ;;
        NoPrem)   printf "${BG_RED} ✘ NoPrem ${C_RESET}" ;;
        OrigOnly) printf "${BG_YELLOW} OrigOnly ${C_RESET}" ;;
        NoIPv6)   printf "${BG_GRAY} NoIPv6   ${C_RESET}" ;;
        Clean*)   printf "${BG_GREEN} ✔ Clean  ${C_RESET}" ;;
        Captcha*) printf "${BG_YELLOW} Captcha  ${C_RESET}" ;;
        RangeBlk) printf "${BG_YELLOW} RangeBlk ${C_RESET}" ;;
        RateLim)  printf "${BG_YELLOW} RateLim  ${C_RESET}" ;;
        Block|*)  printf "${BG_RED} ✘ Block  ${C_RESET}" ;;
    esac
}

fmt_srv_type() {
    case "$1" in
        Native)       printf "${BG_GREEN} %-8s ${C_RESET}" "Native" ;;
        OrigOnly)     printf "${BG_YELLOW} %-8s ${C_RESET}" "OrigOnly" ;;
        APIOnly)      printf "${BG_YELLOW} %-8s ${C_RESET}" "APIOnly" ;;
        GoogleDB)     printf "${BG_YELLOW} %-8s ${C_RESET}" "GoogleDB" ;;
        ViaDNS|Proxy) printf "${BG_YELLOW} %-8s ${C_RESET}" "ViaDNS" ;;
        Editable)     printf "${BG_GREEN} %-8s ${C_RESET}" "Editable" ;;
        ReadOnly)     printf "${BG_YELLOW} %-8s ${C_RESET}" "ReadOnly" ;;
        200*)         printf "${BG_GREEN} %-8s ${C_RESET}" "200 OK" ;;
        403*)         printf "${BG_RED} %-8s ${C_RESET}" "HTTP 403" ;;
        429*)         printf "${BG_YELLOW} %-8s ${C_RESET}" "HTTP 429" ;;
        *)            printf "${BG_GRAY} %-8s ${C_RESET}" "${1:--}" ;;
    esac
}

extract_ip2location_demo() {
    local html_file="$1" out_json="$2"
    [[ ! -s "$html_file" ]] && return 1

    local raw_json
    raw_json=$(awk '
        /<pre id="code2"/ { flag=1; sub(/.*<code[^>]*>/, ""); print; next }
        flag && /<\/code>/ { sub(/<\/code>.*/, ""); print; flag=0; exit }
        flag { print }
    ' "$html_file" 2>/dev/null || true)

    if [[ -n "$raw_json" ]] && jq -e '.ip' <<<"$raw_json" &>/dev/null; then
        printf '%s\n' "$raw_json" > "$out_json"
        return 0
    fi

    if [[ -n "$raw_json" ]]; then
        raw_json=$(sed -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e "s/&#039;/'/g" <<<"$raw_json")
        if jq -e '.ip' <<<"$raw_json" &>/dev/null; then
            printf '%s\n' "$raw_json" > "$out_json"
            return 0
        fi
    fi

    # Fallback to HTML table extraction if code2 JSON is absent
    local ut="" aut="" pt="" fs=""
    ut=$(grep -A 1 'aria-label="usageType"' "$html_file" 2>/dev/null | grep -oE '\([A-Z0-9]+\)' | tr -d '()' | head -n1 || true)
    [[ -z "$ut" ]] && ut=$(grep -A 1 '<strong>Usage Type</strong>' "$html_file" 2>/dev/null | grep -oE '\([A-Z0-9]+\)' | tr -d '()' | head -n1 || true)
    aut=$(grep -A 1 'aria-label="asUsageType"' "$html_file" 2>/dev/null | grep -oE '\([A-Z0-9]+\)' | tr -d '()' | head -n1 || true)
    [[ -z "$aut" ]] && aut=$(grep -A 1 '<strong>AS Usage Type</strong>' "$html_file" 2>/dev/null | grep -oE '\([A-Z0-9]+\)' | tr -d '()' | head -n1 || true)
    pt=$(grep -A 1 'aria-label="px_usageType"' "$html_file" 2>/dev/null | grep -oE '\([A-Z0-9]+\)' | tr -d '()' | head -n1 || true)
    fs=$(grep -A 1 'aria-label="fraudScore"' "$html_file" 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)

    if [[ -n "$ut" || -n "$aut" || -n "$fs" ]]; then
        local is_dch="false" is_vpn="false" is_tor="false" is_proxy="false"
        [[ "${ut:-}" == "DCH" || "${aut:-}" == "DCH" || "${pt:-}" == "DCH" ]] && is_dch="true"
        [[ "${pt:-}" =~ (VPN|SES) ]] && is_vpn="true"
        [[ "${pt:-}" == "TOR" ]] && is_tor="true"
        [[ "$is_dch" == "true" || "$is_vpn" == "true" || "$is_tor" == "true" ]] && is_proxy="true"

        jq -n \
            --arg ut "${ut:-N/A}" \
            --arg aut "${aut:-N/A}" \
            --arg fs "${fs:-0}" \
            --argjson dch "$is_dch" \
            --argjson vpn "$is_vpn" \
            --argjson tor "$is_tor" \
            --argjson prx "$is_proxy" \
            '{
                usage_type: $ut,
                as_info: {as_usage_type: $aut},
                fraud_score: ($fs | tonumber),
                is_proxy: $prx,
                proxy: {
                    is_data_center: $dch,
                    is_vpn: $vpn,
                    is_tor: $tor,
                    is_public_proxy: false
                }
            }' > "$out_json" 2>/dev/null && return 0
    fi

    return 1
}

parse_scamalytics_html() {
    local html_file="$1" out_kv="$2"
    [[ ! -s "$html_file" ]] && return 1
    grep -qE '<th>Server</th>|Fraud Score:' "$html_file" 2>/dev/null || return 1

    local score="" blk_ext=""
    score=$(tr '\r\n' ' ' < "$html_file" | sed -n 's/.*"score":"\([0-9][0-9]*\)".*/\1/p' | head -n1 || true)
    [[ -z "$score" ]] && score=$(grep -i "Fraud Score:" "$html_file" 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)
    blk_ext=$(tr '\r\n' ' ' < "$html_file" | sed -n 's/.*"is_blacklisted_external":[ ]*\(true\|false\).*/\1/p' | head -n1 || true)

    {
        [[ -n "$score" ]] && printf 'score=%s\n' "$score"
        [[ -n "$blk_ext" ]] && printf 'blk_ext=%s\n' "$blk_ext"
        tr '\r\n\t' ' ' < "$html_file" | sed 's/<\/[tT][rR]>/\n/g' | awk '
        function trim(s) {
            gsub(/^[ ]+|[ ]+$/, "", s)
            gsub(/ +/, " ", s)
            return s
        }
        function strip_tags(s) {
            gsub(/<[^>]*>/, " ", s)
            return trim(s)
        }
        {
            low = tolower($0)
            p_th1 = index(low, "<th")
            p_th2 = index(low, "</th>")
            p_td1 = index(low, "<td")
            p_td2 = index(low, "</td>")
            if (p_th1 > 0 && p_th2 > p_th1 && p_td1 > p_th2 && p_td2 > p_td1) {
                th_seg = substr($0, p_th1, p_th2 - p_th1)
                gt = index(th_seg, ">")
                if (gt > 0) th_seg = substr(th_seg, gt + 1)
                th = tolower(strip_tags(th_seg))

                td_seg = substr($0, p_td1, p_td2 - p_td1)
                gt = index(td_seg, ">")
                if (gt > 0) td_seg = substr(td_seg, gt + 1)
                td = strip_tags(td_seg)
                td_low = tolower(td)

                if (th == "country code" && cc == "" && td ~ /^[A-Za-z][A-Za-z]$/) cc = toupper(td)
                else if (th == "connection type" && conn == "" && td_low != "" && td_low != "n/a" && td_low != "unknown" && td_low != "-") conn = td
                else if (th == "datacenter" && (td_low == "yes" || td_low == "no") && dc == "") dc = td_low
                else if (th == "server" && (td_low == "yes" || td_low == "no") && srv == "") srv = td_low
                else if (th == "anonymizing vpn" && (td_low == "yes" || td_low == "no") && vpn == "") vpn = td_low
                else if (th == "tor exit node" && (td_low == "yes" || td_low == "no") && tor == "") tor = td_low
                else if (th == "public proxy" && (td_low == "yes" || td_low == "no") && pub_p == "") pub_p = td_low
                else if (th == "web proxy" && (td_low == "yes" || td_low == "no") && web_p == "") web_p = td_low
                else if (th == "search engine robot" && (td_low == "yes" || td_low == "no") && bot == "") bot = td_low
                else if (th == "firehol" || th == "ip2proxylite" || th == "ipsum" || th == "spamhaus" || th == "x4bnet spambot") {
                    if (td_low == "yes") blk_list = "yes"
                    else if (td_low == "no" && blk_list == "") blk_list = "no"
                }
            }
        }
        END {
            if (cc != "") print "cc=" cc
            if (conn != "") print "conn=" conn
            if (dc != "") print "dc=" dc
            if (srv != "") print "srv=" srv
            if (vpn != "") print "vpn=" vpn
            if (tor != "") print "tor=" tor
            if (pub_p != "") print "pub_proxy=" pub_p
            if (web_p != "") print "web_proxy=" web_p
            if (bot != "") print "bot=" bot
            if (blk_list != "") print "blk_list=" blk_list
        }'
    } > "$out_kv"
}

ensure_maxmind_token() {
    [[ -s "$BASE_TMP/mm_token" ]] && return 0
    local mm_page csrf
    mm_page=$(curl -sL $DB_CURL_FLAG --connect-timeout 5 -m 8 -A "$UA_BROWSER" -c "$BASE_TMP/mm_cookies" "https://www.maxmind.com/en/geoip-web-services-demo" 2>/dev/null || true)
    if [[ "$mm_page" =~ value=\"([0-9a-f]+)\"\ name=\"csrf_token\" ]]; then
        csrf="${BASH_REMATCH[1]}"
        curl -sL $DB_CURL_FLAG --connect-timeout 5 -m 8 -A "$UA_BROWSER" -X POST -b "$BASE_TMP/mm_cookies" \
            -H "Referer: https://www.maxmind.com/en/geoip-web-services-demo" \
            -H "X-CSRF-Token: $csrf" \
            "https://www.maxmind.com/en/geoip2/demo/token" 2>/dev/null | jq -r '.token // empty' > "$BASE_TMP/mm_token" 2>/dev/null || true
    fi
}

# ==============================================================================
# MAIN ENGINE FOR A SINGLE STACK (-4 or -6)
# ==============================================================================
run_check_for_stack() {
    local IPV_MODE="$1"
    local IPV_LABEL="$2"
    local TARGET_IP="$3"
    local IS_LOCAL_IP="$4"

    local TMP_DIR="$BASE_TMP/${IPV_LABEL}"
    mkdir -p "$TMP_DIR"

    # --- 1. Fetch All 12+ IP Databases & BGP Telemetry in Parallel ---
    (
        ensure_maxmind_token || true
        if [[ -s "$BASE_TMP/mm_token" ]]; then
            local mmt
            mmt=$(<"$BASE_TMP/mm_token")
            curl -sL $DB_CURL_FLAG --connect-timeout 5 -m 9 -A "$UA_BROWSER" -H "Authorization: Bearer $mmt" \
                "https://geoip.maxmind.com/geoip/v2.1/city/${TARGET_IP}?demo=1" > "$TMP_DIR/maxmind_direct.json"
        fi
        curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 8 -A "$UA_BROWSER" "https://stat.ripe.net/data/prefix-overview/data.json?resource=${TARGET_IP}" > "$TMP_DIR/ripe_asn.json"
        curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 8 -A "$UA_BROWSER" "https://stat.ripe.net/data/rir-stats-country/data.json?resource=${TARGET_IP}" > "$TMP_DIR/ripe_reg.json"

        local r_asn r_pfx
        r_asn=$(jq -r '.data.asns[0].asn // empty' "$TMP_DIR/ripe_asn.json" 2>/dev/null || true)
        r_pfx=$(jq -r '.data.resource // empty' "$TMP_DIR/ripe_asn.json" 2>/dev/null || true)
        if [[ -n "$r_asn" && -n "$r_pfx" ]]; then
            curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 6 -A "$UA_BROWSER" "https://stat.ripe.net/data/rpki-validation/data.json?resource=AS${r_asn}&prefix=${r_pfx}" > "$TMP_DIR/ripe_rpki.json" &
            curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 6 -A "$UA_BROWSER" "https://stat.ripe.net/data/asn-neighbours/data.json?resource=AS${r_asn}" > "$TMP_DIR/ripe_peers.json" &
            wait
        fi
    ) &

    (
        if [[ -n "${IPINFO_TOKEN:-}" ]]; then
            curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 -A "$UA_BROWSER" -H "Authorization: Bearer ${IPINFO_TOKEN}" \
                "https://ipinfo.io/${TARGET_IP}/json" | jq '{data: .}' > "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true
            if ! jq -e '.data.asn.type' "$TMP_DIR/ipinfo_widget.json" &>/dev/null; then
                curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 -A "$UA_BROWSER" -H "Referer: https://ipinfo.io/" \
                    "https://ipinfo.io/widget/demo/${TARGET_IP}" > "$TMP_DIR/ipinfo_demo.json" 2>/dev/null || true
                if jq -e '.data.asn.type' "$TMP_DIR/ipinfo_demo.json" &>/dev/null; then
                    jq -s '(.[0] * {data: ((.[0].data // {}) * {asn: (.[1].data.asn // .[0].data.asn), company: (.[1].data.company // .[0].data.company), privacy: (.[1].data.privacy // .[0].data.privacy), is_hosting: (.[1].data.is_hosting // .[0].data.is_hosting), is_mobile: (.[1].data.is_mobile // .[0].data.is_mobile), is_anycast: (.[1].data.is_anycast // .[0].data.anycast)})})' \
                        "$TMP_DIR/ipinfo_widget.json" "$TMP_DIR/ipinfo_demo.json" > "$TMP_DIR/ipinfo_merged.json" 2>/dev/null \
                        && mv "$TMP_DIR/ipinfo_merged.json" "$TMP_DIR/ipinfo_widget.json"
                fi
            fi
        else
            curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 -A "$UA_BROWSER" -H "Referer: https://ipinfo.io/" \
                "https://ipinfo.io/widget/demo/${TARGET_IP}" > "$TMP_DIR/ipinfo_widget.json"
            if ! jq -e '.data.ip' "$TMP_DIR/ipinfo_widget.json" &>/dev/null; then
                curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 7 -A "$UA_BROWSER" \
                    "https://ipinfo.io/${TARGET_IP}/json" | jq 'select(.ip != null) | {data: .}' > "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true
            fi
        fi
    ) &

    (
        local reg_key="${IPREGISTRY_KEY:-sb69ksjcajfs4c}"
        curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 --compressed -A "$UA_BROWSER" \
            -H "Origin: https://ipregistry.co" -H "Referer: https://ipregistry.co/" \
            "https://api.ipregistry.co/${TARGET_IP}?hostname=true&key=${reg_key}" > "$TMP_DIR/ipregistry.json"
    ) &

    (
        local ipapi_url="https://api.ipapi.is/?q=${TARGET_IP}"
        [[ -n "${IPAPI_KEY:-}" ]] && ipapi_url="${ipapi_url}&key=${IPAPI_KEY}"
        curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 -A "$UA_BROWSER" "$ipapi_url" > "$TMP_DIR/ipapi_is.json"
    ) &

    curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 -A "$UA_BROWSER" "https://api.ipquery.io/${TARGET_IP}" > "$TMP_DIR/ipquery.json" &
    (
        local pck_url="https://proxycheck.io/v2/${TARGET_IP}?vpn=1&asn=1&risk=1"
        [[ -n "${PROXYCHECK_KEY:-}" ]] && pck_url="${pck_url}&key=${PROXYCHECK_KEY}"
        curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 -A "$UA_BROWSER" "$pck_url" > "$TMP_DIR/proxycheck.json"
    ) &
    (
        curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 -A "$UA_BROWSER" \
            -H "Origin: https://ip-api.com" -H "Referer: https://ip-api.com/" \
            "https://demo.ip-api.com/json/${TARGET_IP}?fields=66842623" > "$TMP_DIR/ip_api.json"
        if [[ "$(jq -r '.status // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true)" != "success" ]]; then
            curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 7 -A "$UA_BROWSER" \
                "http://ip-api.com/json/${TARGET_IP}?fields=66842623" > "$TMP_DIR/ip_api.json"
        fi
    ) &
    (
        curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 -A "$UA_BROWSER" \
            -H "Origin: https://ipwhois.io" -H "Referer: https://ipwhois.io/" \
            "https://ipwhois.io/demo?ip=${TARGET_IP}" > "$TMP_DIR/ipwhois.json"
        if ! jq -e '.security' "$TMP_DIR/ipwhois.json" &>/dev/null; then
            curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 7 -A "$UA_BROWSER" "https://ipwho.is/${TARGET_IP}" > "$TMP_DIR/ipwhois.json"
            if [[ -z "${IPAPI_KEY:-}" ]]; then
                curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 7 -A "$UA_BROWSER" "https://vpnapi.io/api/${TARGET_IP}" > "$TMP_DIR/vpnapi.json"
            fi
        fi
    ) &

    (
        curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 -A "$UA_BROWSER" "https://scamalytics.com/ip/${TARGET_IP}" > "$TMP_DIR/scamalytics.html"
        parse_scamalytics_html "$TMP_DIR/scamalytics.html" "$TMP_DIR/scam_parsed" || true
    ) &

    (
        if [[ -n "${IP2LOCATION_KEY:-}" ]]; then
            curl -sL $DB_CURL_FLAG --connect-timeout 5 -m 10 -A "$UA_BROWSER" "https://api.ip2location.io/?ip=${TARGET_IP}&key=${IP2LOCATION_KEY}" > "$TMP_DIR/ip2location.json"
        fi
        if ! jq -e '.usage_type' "$TMP_DIR/ip2location.json" &>/dev/null; then
            curl -sL $DB_CURL_FLAG --connect-timeout 5 -m 10 -A "$UA_BROWSER" -H "Referer: https://www.ip2location.com/demo" "https://www.ip2location.com/demo/${TARGET_IP}" > "$TMP_DIR/ip2loc_demo.html"
            extract_ip2location_demo "$TMP_DIR/ip2loc_demo.html" "$TMP_DIR/ip2location.json" || true
        fi
        curl -sL $DB_CURL_FLAG --connect-timeout 5 -m 8 -A "$UA_BROWSER" "https://api.ip2location.io/?ip=${TARGET_IP}" > "$TMP_DIR/ip2loc_direct.json" 2>/dev/null || true
        if [[ -s "$TMP_DIR/ip2loc_direct.json" ]]; then
            if [[ -s "$TMP_DIR/ip2location.json" ]]; then
                jq -s '(.[0] // {}) * (.[1] // {})' "$TMP_DIR/ip2loc_direct.json" "$TMP_DIR/ip2location.json" > "$TMP_DIR/ip2loc_merged.json" 2>/dev/null && mv "$TMP_DIR/ip2loc_merged.json" "$TMP_DIR/ip2location.json"
            else
                cp "$TMP_DIR/ip2loc_direct.json" "$TMP_DIR/ip2location.json" 2>/dev/null || true
            fi
        fi
    ) &

    (
        if [[ -n "${IPDATA_KEY:-}" ]]; then
            curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 -A "$UA_BROWSER" "https://api.ipdata.co/${TARGET_IP}?api-key=${IPDATA_KEY}" > "$TMP_DIR/ipdata.json"
        elif ((IS_LOCAL_IP == 1)); then
            curl -sL "$IPV_MODE" --connect-timeout 4 -m 9 -A "$UA_BROWSER" \
                -H "Accept: application/json" -H "Origin: https://ipdata.co" -H "Referer: https://ipdata.co/" \
                "https://ipdata.co/me" > "$TMP_DIR/ipdata_me.tmp"
            if jq -e --arg ip "$TARGET_IP" '.ip == $ip and .asn != null' "$TMP_DIR/ipdata_me.tmp" &>/dev/null; then
                mv "$TMP_DIR/ipdata_me.tmp" "$TMP_DIR/ipdata.json"
            else
                rm -f "$TMP_DIR/ipdata_me.tmp"
            fi
        fi
    ) &

    (
        if [[ -n "${ABUSEIPDB_KEY:-}" ]]; then
            curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 -A "$UA_BROWSER" -G "https://api.abuseipdb.com/api/v2/check" \
                --data-urlencode "ipAddress=${TARGET_IP}" -d maxAgeInDays=90 \
                -H "Key: ${ABUSEIPDB_KEY}" -H "Accept: application/json" > "$TMP_DIR/abuseipdb.json"
        fi
    ) &

    (
        if [[ -n "${IPQS_KEY:-}" ]]; then
            curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 9 -A "$UA_BROWSER" "https://www.ipqualityscore.com/api/json/ip/${IPQS_KEY}/${TARGET_IP}" > "$TMP_DIR/ipqs.json"
        fi
    ) &

    (
        if [[ -n "${DBIP_KEY:-}" ]]; then
            curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 8 -A "$UA_BROWSER" "https://api.db-ip.com/v2/${DBIP_KEY}/${TARGET_IP}" > "$TMP_DIR/dbip.json"
        fi
        if ! jq -e '.ipAddress' "$TMP_DIR/dbip.json" &>/dev/null; then
            curl -sL $DB_CURL_FLAG --connect-timeout 4 -m 7 -A "$UA_BROWSER" "https://api.db-ip.com/v2/free/${TARGET_IP}" > "$TMP_DIR/dbip.json"
        fi
    ) &

    (
        if command -v dig &>/dev/null; then
            dig +short -x "$TARGET_IP" 2>/dev/null | head -n1 | sed 's/\.$//' > "$TMP_DIR/ptr.txt"
        elif command -v host &>/dev/null; then
            host "$TARGET_IP" 2>/dev/null | awk '/domain name pointer/ {print $5}' | sed 's/\.$//' | head -n1 > "$TMP_DIR/ptr.txt"
        fi
    ) &

    # --- Services, AI, CDN & Email (When checking local host IP) ---
    if ((IS_LOCAL_IP == 1)); then
        # YouTube & Gemini
        (
            local yt_sw gl="" prem_res
            yt_sw=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" -H "Cookie: SOCS=CAI" "https://www.youtube.com/sw.js_data" 2>/dev/null || true)
            gl=$(jq -r '.[0][2][0][0][1] // empty' <<<"${yt_sw#")]}'"}" 2>/dev/null || true)
            prem_res=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" -H "Cookie: SOCS=CAI" "https://www.youtube.com/youtubei/v1/browse" \
                -H "Content-Type: application/json" \
                -d '{"context":{"client":{"clientName":"MWEB","clientVersion":"2.20261020.00.00","hl":"en","gl":"US"}},"browseId":"SPunlimited"}' 2>/dev/null || true)

            echo "${gl:-N/A}" > "$TMP_DIR/google_gl"
            if [[ -z "$yt_sw" && -z "$prem_res" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_youtube"
            elif [[ "$prem_res" == *"premiumPurchaseButtonRenderer"* ]]; then
                echo "Yes|${gl:-N/A}|Native" > "$TMP_DIR/srv_youtube"
            elif [[ "$prem_res" == *"responseContext"* ]]; then
                echo "NoPrem|${gl:-N/A}|GoogleDB" > "$TMP_DIR/srv_youtube"
            else
                echo "Block|${gl:-N/A}|Err" > "$TMP_DIR/srv_youtube"
            fi

            local g_res g_cc=""
            g_res=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" -H "Cookie: SOCS=CAI" "https://accounts.google.com/v3/signin/identifier?flowName=GlifSetupAndroid" 2>/dev/null || true)
            [[ "$g_res" =~ name=\"region\"\ value=\"([^\"]*)\" ]] && g_cc="${BASH_REMATCH[1]}"
            [[ -z "$g_cc" ]] && g_cc="$gl"
            if [[ -z "$g_res" && -z "$yt_sw" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/ai_gemini"
            elif [[ -n "$g_cc" && ! "$g_cc" =~ ^(RU|BY|CN|HK|IR|KP|CU|SY)$ ]]; then
                echo "Yes|${g_cc}|Native" > "$TMP_DIR/ai_gemini"
            else
                echo "Block|${g_cc:-N/A}|GoogleDB" > "$TMP_DIR/ai_gemini"
            fi
        ) &

        # TikTok
        (
            local tt_res tt_reg
            tt_res=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" "https://www.tiktok.com/api/v1/web-cookie-privacy/config?appId=1988" 2>/dev/null || true)
            tt_reg=$(jq -r '.body.appProps.region // empty' <<<"$tt_res" 2>/dev/null || true)
            if [[ -z "$tt_res" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_tiktok"
            elif [[ -n "$tt_reg" && ! "$tt_reg" =~ ^(RU|BY|CN|IR|KP|IN)$ ]]; then
                echo "Yes|${tt_reg}|Native" > "$TMP_DIR/srv_tiktok"
            else
                echo "Block|${tt_reg:-N/A}|N/A" > "$TMP_DIR/srv_tiktok"
            fi
        ) &

        # Netflix + Netflix OCA CDN
        (
            local nf_fast nf_reg nf_url node="" iata="" oca_cc=""
            nf_fast=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=1" 2>/dev/null || true)
            nf_reg=$(jq -r '.client.location.country // empty' <<<"$nf_fast" 2>/dev/null || true)
            oca_cc=$(jq -r '.targets[0].location.country // empty' <<<"$nf_fast" 2>/dev/null || true)
            nf_url=$(jq -r '.targets[0].url // empty' <<<"$nf_fast" 2>/dev/null || true)
            if [[ "$nf_url" =~ ^https://ipv[46]-([a-z0-9]+-([a-z]{3})[0-9]+[a-z0-9-]*)\. ]]; then
                node="${BASH_REMATCH[1]}"
                iata="${BASH_REMATCH[2]^^}"
            fi
            [[ -z "$oca_cc" && -n "$iata" ]] && oca_cc=$(iata_to_country "$iata")
            printf '%s|%s\n' "${oca_cc:--}" "${node:-${iata:--}}" > "$TMP_DIR/cdn_netflix"

            local nf_code1 nf_code2
            nf_code1=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://www.netflix.com/title/81280792" 2>/dev/null || true)
            nf_code2=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://www.netflix.com/title/70143836" 2>/dev/null || true)
            if [[ "$nf_code1" == "000" && "$nf_code2" == "000" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_netflix"
            elif [[ "$nf_code1" == "200" && "$nf_code2" == "200" ]]; then
                echo "Yes|${nf_reg:-OK}|Native" > "$TMP_DIR/srv_netflix"
            elif [[ "$nf_code1" == "200" ]]; then
                echo "OrigOnly|${nf_reg:-OK}|OrigOnly" > "$TMP_DIR/srv_netflix"
            elif [[ "$nf_code1" == "403" || "$nf_code2" == "403" ]]; then
                echo "Block|${nf_reg:-N/A}|403" > "$TMP_DIR/srv_netflix"
            else
                echo "Block|${nf_reg:-N/A}|Err" > "$TMP_DIR/srv_netflix"
            fi
        ) &

        # Disney+
        (
            local dp_res dp_reg dp_ok
            dp_res=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" \
                -H "Authorization: Bearer ZGlzbmV5JmFuZHJvaWQmMS4wLjA.bkeb0m230uUhv8qrAXuNu39tbE_mD5EEhM_NAcohjyA" \
                -H "Content-Type: application/json" \
                -d '{"query":"mutation registerDevice($registerDevice: RegisterDeviceInput!) { registerDevice(registerDevice: $registerDevice) { __typename } }","variables":{"registerDevice":{"applicationRuntime":"android","attributes":{"operatingSystem":"Android","operatingSystemVersion":"13"},"deviceFamily":"android","deviceLanguage":"en","deviceProfile":"phone","devicePlatformId":"android"}},"operationName":"registerDevice"}' 2>/dev/null || true)
            dp_reg=$(jq -r '.extensions.sdk.session.location.countryCode // empty' <<<"$dp_res" 2>/dev/null || true)
            dp_ok=$(jq -r '.extensions.sdk.session.inSupportedLocation // empty' <<<"$dp_res" 2>/dev/null || true)
            if [[ -z "$dp_res" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_disney"
            elif [[ "$dp_ok" == "true" ]]; then
                echo "Yes|${dp_reg}|Native" > "$TMP_DIR/srv_disney"
            else
                echo "Block|${dp_reg:-N/A}|N/A" > "$TMP_DIR/srv_disney"
            fi
        ) &

        # Spotify
        (
            local sp_res sp_reg sp_ok
            sp_res=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" -H "X-Client-Id: 9a8d2f0ce77a4e248bb71fefcb557637" \
                "https://spclient.wg.spotify.com/signup/public/v1/account/?validate=1&key=142b583129b2df829de3656f9eb484e6" 2>/dev/null || true)
            sp_reg=$(jq -r '.country // empty' <<<"$sp_res" 2>/dev/null || true)
            sp_ok=$(jq -r '.is_country_launched // empty' <<<"$sp_res" 2>/dev/null || true)
            if [[ -z "$sp_res" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_spotify"
            elif [[ "$sp_ok" == "true" ]]; then
                echo "Yes|${sp_reg}|Native" > "$TMP_DIR/srv_spotify"
            else
                echo "Block|${sp_reg:-N/A}|N/A" > "$TMP_DIR/srv_spotify"
            fi
        ) &

        # Twitch
        (
            local tw_res tw_reg
            tw_res=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" "https://gql.twitch.tv/gql" \
                -H "Client-Id: kimne78kx3ncx6brgo4mv6wki5h1ko" -H "Content-Type: application/json" \
                -d '[{"operationName":"VerifyEmail_CurrentUser","variables":{},"extensions":{"persistedQuery":{"version":1,"sha256Hash":"f9e7dcdf7e99c314c82d8f7f725fab5f99d1df3d7359b53c9ae122deec590198"}}}]' 2>/dev/null || true)
            tw_reg=$(jq -r '.[0].data.requestInfo.countryCode // empty' <<<"$tw_res" 2>/dev/null || true)
            if [[ -z "$tw_res" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/srv_twitch"
            elif [[ -n "$tw_reg" ]]; then
                echo "Yes|${tw_reg}|Native" > "$TMP_DIR/srv_twitch"
            else
                echo "Block|N/A|N/A" > "$TMP_DIR/srv_twitch"
            fi
        ) &

        # ChatGPT / OpenAI
        (
            local oa_trace oa_reg="" oa_web oa_api
            oa_trace=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 7 -A "$UA_BROWSER" "https://chatgpt.com/cdn-cgi/trace" 2>/dev/null || true)
            oa_reg=$(awk -F= '/^loc=/{print $2; exit}' <<<"$oa_trace" | tr -d '[:space:]')
            oa_web=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 7 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27" 2>/dev/null || true)
            oa_api=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 7 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://api.openai.com/v1/models" 2>/dev/null || true)
            if [[ "$oa_web" == "000" && "$oa_api" == "000" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/ai_chatgpt"
            elif [[ -n "$oa_reg" && "$oa_reg" =~ ^(RU|BY|CN|HK|KP|IR|SY|CU)$ ]]; then
                echo "Block|${oa_reg}|403" > "$TMP_DIR/ai_chatgpt"
            elif [[ "$oa_web" =~ ^(200|401)$ && "$oa_api" =~ ^(200|401)$ ]]; then
                echo "Yes|${oa_reg:-OK}|Native" > "$TMP_DIR/ai_chatgpt"
            elif [[ "$oa_api" =~ ^(200|401)$ ]]; then
                echo "Yes|${oa_reg:-OK}|APIOnly" > "$TMP_DIR/ai_chatgpt"
            else
                echo "Block|${oa_reg:-N/A}|${oa_web:-Err}" > "$TMP_DIR/ai_chatgpt"
            fi
        ) &

        # Claude
        (
            local cl_raw cl_boot cl_res cl_trace cl_api cl_reg=""
            cl_raw=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 7 -A "Claude com.anthropic.claude/1.261023.20 (Android 30) Claude/1.261023.20" \
                -H "Anthropic-Client-Platform: android" -w $'\nCODE:%{http_code}' "https://claude.ai/api/bootstrap" 2>/dev/null || true)
            cl_boot="${cl_raw##*$'\n'CODE:}"
            cl_res="${cl_raw%$'\n'CODE:*}"
            cl_reg=$(jq -r '.statsig.user.country // empty' <<<"$cl_res" 2>/dev/null || true)
            if [[ -z "$cl_reg" ]]; then
                cl_trace=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 6 -A "$UA_BROWSER" "https://claude.ai/cdn-cgi/trace" 2>/dev/null || true)
                cl_reg=$(awk -F= '/^loc=/{print $2; exit}' <<<"$cl_trace" | tr -d '[:space:]')
            fi
            cl_api=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 7 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://api.anthropic.com/v1/models" 2>/dev/null || true)
            if [[ "${cl_boot:-000}" == "000" && "${cl_api:-000}" == "000" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/ai_claude"
            elif [[ -n "$cl_reg" && "$cl_reg" =~ ^(RU|BY|CN|HK|KP|IR|SY|CU)$ ]]; then
                echo "Block|${cl_reg}|403" > "$TMP_DIR/ai_claude"
            elif [[ "$cl_boot" == "200" && "$cl_api" =~ ^(200|401)$ ]]; then
                echo "Yes|${cl_reg:-OK}|Native" > "$TMP_DIR/ai_claude"
            elif [[ "$cl_api" =~ ^(200|401)$ ]]; then
                if [[ "$cl_boot" == "403" ]]; then
                    echo "Yes|${cl_reg:-OK}|APIOnly" > "$TMP_DIR/ai_claude"
                else
                    echo "Yes|${cl_reg:-OK}|Native" > "$TMP_DIR/ai_claude"
                fi
            else
                echo "Block|${cl_reg:-N/A}|${cl_api:-Err}" > "$TMP_DIR/ai_claude"
            fi
        ) &

        # Grok (xAI)
        (
            local gk_trace gk_reg="" gk_web gk_code
            gk_trace=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 7 -A "$UA_BROWSER" "https://grok.com/cdn-cgi/trace" 2>/dev/null || true)
            gk_reg=$(awk -F= '/^loc=/{print $2; exit}' <<<"$gk_trace" | tr -d '[:space:]')
            gk_web=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 7 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://grok.com/" 2>/dev/null || true)
            gk_code=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 7 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://api.x.ai/v1/models" 2>/dev/null || true)
            if [[ "${gk_web:-000}" == "000" && "${gk_code:-000}" == "000" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|N/A" > "$TMP_DIR/ai_copilot"
            elif [[ -n "$gk_reg" && "$gk_reg" =~ ^(RU|BY|CN|HK|KP|IR|SY|CU)$ ]]; then
                echo "Block|${gk_reg}|403" > "$TMP_DIR/ai_copilot"
            elif [[ "$gk_code" =~ ^(200|401)$ ]]; then
                if [[ "$gk_web" == "200" ]]; then
                    echo "Yes|${gk_reg:-OK}|Native" > "$TMP_DIR/ai_copilot"
                elif [[ "$gk_web" == "403" ]]; then
                    echo "Yes|${gk_reg:-OK}|APIOnly" > "$TMP_DIR/ai_copilot"
                else
                    echo "Yes|${gk_reg:-OK}|Native" > "$TMP_DIR/ai_copilot"
                fi
            else
                echo "Block|${gk_reg:-N/A}|${gk_code:-Err}" > "$TMP_DIR/ai_copilot"
            fi
        ) &

        # Cloudflare CDN + Web
        (
            local cf_meta cf_cc cf_iata
            cf_meta=$(curl -sL "$IPV_MODE" --connect-timeout 5 -m 10 -A "$UA_BROWSER" -H "Referer: https://speed.cloudflare.com" "https://speed.cloudflare.com/meta" 2>/dev/null || true)
            cf_cc=$(jq -r '.colo.cca2 // empty' <<<"$cf_meta" 2>/dev/null || true)
            cf_iata=$(jq -r '.colo.iata // empty' <<<"$cf_meta" 2>/dev/null || true)
            printf '%s|%s\n' "${cf_cc:--}" "${cf_iata:--}" > "$TMP_DIR/cdn_cloudflare"
            if [[ -z "$cf_meta" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|-" > "$TMP_DIR/cdn_cf"
            elif [[ -n "$cf_iata" ]]; then
                echo "Clean|${cf_cc:-OK}|200 OK" > "$TMP_DIR/cdn_cf"
            else
                echo "Block|N/A|Err" > "$TMP_DIR/cdn_cf"
            fi
        ) &

        # YouTube GGC CDN + Fastly + CloudFront
        (
            local yt_map node="" iata="" cc=""
            yt_map=$(curl -sL "$IPV_MODE" --connect-timeout 5 -m 8 -A "$UA_BROWSER" "https://redirector.googlevideo.com/report_mapping?di=no" 2>/dev/null || true)
            [[ "$yt_map" =~ =\>\ ([^[:space:]]+) ]] && node="${BASH_REMATCH[1]}"
            node="${node%%.*}"
            if [[ "$node" =~ ^([a-z]{3})[0-9] || "$node" =~ ^[a-z]+-([a-z]{3})[0-9] || "$node" =~ ^[a-z]{2}([a-z]{3})[a-z]-[a-z0-9]+$ ]]; then
                iata="${BASH_REMATCH[1]^^}"
            fi
            [[ -n "$iata" ]] && cc=$(iata_to_country "$iata")
            printf '%s|%s\n' "${cc:--}" "${node:-${iata:--}}" > "$TMP_DIR/cdn_youtube"
        ) &
        (
            local fs_hdr pop="" iata="" cc=""
            fs_hdr=$(curl -sIL "$IPV_MODE" --connect-timeout 5 -m 8 -A "$UA_BROWSER" "https://www.fastly.com/robots.txt" 2>/dev/null | tr -d '\r' || true)
            if [[ "$fs_hdr" =~ [Xx]-[Ss]erved-[Bb]y:\ *([^[:space:],]+) ]]; then
                pop="${BASH_REMATCH[1]#cache-}"
                [[ "$pop" =~ -([A-Z]{3})$ ]] && iata="${BASH_REMATCH[1]}"
            fi
            [[ -n "$iata" ]] && cc=$(iata_to_country "$iata")
            printf '%s|%s\n' "${cc:--}" "${pop:--}" > "$TMP_DIR/cdn_fastly"
        ) &
        (
            local cf_hdr pop="" iata="" cc=""
            cf_hdr=$(curl -sIL "$IPV_MODE" --connect-timeout 5 -m 9 -A "$UA_BROWSER" "https://d1.awsstatic.com/robots.txt" 2>/dev/null | tr -d '\r' || true)
            if [[ "$cf_hdr" =~ [Xx]-[Aa]mz-[Cc]f-[Pp]op:\ *([A-Za-z0-9-]+) ]]; then
                pop="${BASH_REMATCH[1]}"
                iata="${pop:0:3}"
            fi
            [[ -n "$iata" ]] && cc=$(iata_to_country "$iata")
            printf '%s|%s\n' "${cc:--}" "${pop:--}" > "$TMP_DIR/cdn_cloudfront"
        ) &

        # Google Search
        (
            local gs_out
            gs_out=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" -H "Cookie: SOCS=CAI" -w "\nCODE:%{http_code}\nREDIR:%{redirect_url}" "https://www.google.com/search?q=cats" 2>/dev/null || true)
            if [[ "$gs_out" == *"CODE:000"* && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|-" > "$TMP_DIR/cdn_google"
            elif [[ "$gs_out" == *"/sorry/"* || "$gs_out" == *"CODE:429"* ]]; then
                echo "Captcha|N/A|429" > "$TMP_DIR/cdn_google"
            elif [[ "$gs_out" == *"CODE:200"* ]]; then
                echo "Clean|OK|200 OK" > "$TMP_DIR/cdn_google"
            else
                echo "Block|N/A|Err" > "$TMP_DIR/cdn_google"
            fi
        ) &

        # Extra Platforms & Proxy Cleanliness (Reddit, Wikipedia, Steam, Instagram, GitHub, Telegram)
        (
            local rd_out rd_code rd_body
            rd_out=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" -w $'\nCODE:%{http_code}' "https://www.reddit.com/" 2>/dev/null || true)
            rd_code="${rd_out##*$'\n'CODE:}"
            rd_body="${rd_out%$'\n'CODE:*}"
            if [[ "${rd_code:-000}" == "000" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|-" > "$TMP_DIR/ext_reddit"
            elif [[ "$rd_code" == "403" || "${rd_body,,}" == *"blocked by network security"* || "${rd_body,,}" == *"whoa there, pardner"* ]]; then
                echo "Block|VPN/DC|403" > "$TMP_DIR/ext_reddit"
            elif [[ "$rd_code" == "429" ]]; then
                echo "RateLim|N/A|429" > "$TMP_DIR/ext_reddit"
            elif [[ "$rd_code" == "200" ]]; then
                echo "Yes|OK|200 OK" > "$TMP_DIR/ext_reddit"
            else
                echo "Block|N/A|Err" > "$TMP_DIR/ext_reddit"
            fi
        ) &

        (
            local wk_res wk_blk
            wk_res=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 7 -A "$UA_BROWSER" "https://en.wikipedia.org/w/api.php?action=query&meta=userinfo&uiprop=blockinfo&format=json" 2>/dev/null || true)
            if [[ -z "$wk_res" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|-" > "$TMP_DIR/ext_wiki"
            elif jq -e '.query.userinfo' <<<"$wk_res" &>/dev/null; then
                wk_blk=$(jq -r '.query.userinfo.blockid // empty' <<<"$wk_res" 2>/dev/null || true)
                if [[ -z "$wk_blk" ]]; then
                    echo "Clean|OK|Editable" > "$TMP_DIR/ext_wiki"
                else
                    echo "RangeBlk|Proxy|ReadOnly" > "$TMP_DIR/ext_wiki"
                fi
            else
                echo "Block|N/A|Err" > "$TMP_DIR/ext_wiki"
            fi
        ) &

        (
            local st_hdr st_cc=""
            st_hdr=$(curl -sIL "$IPV_MODE" --connect-timeout 4 -m 7 -A "$UA_BROWSER" "https://store.steampowered.com/" 2>/dev/null | tr -d '\r' || true)
            if [[ -z "$st_hdr" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|-" > "$TMP_DIR/ext_steam"
            elif [[ "$st_hdr" =~ steamCountry=([A-Z]{2}) ]]; then
                st_cc="${BASH_REMATCH[1]}"
                echo "Yes|${st_cc}|Native" > "$TMP_DIR/ext_steam"
            elif [[ "$st_hdr" == *"200"* ]]; then
                echo "Yes|OK|200 OK" > "$TMP_DIR/ext_steam"
            else
                echo "Block|N/A|Err" > "$TMP_DIR/ext_steam"
            fi
        ) &

        (
            local ig_meta ig_code ig_eff
            ig_meta=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 8 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}|%{url_effective}" "https://www.instagram.com/" 2>/dev/null || true)
            IFS='|' read -r ig_code ig_eff <<<"$ig_meta"
            if [[ "${ig_code:-000}" == "000" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|-" > "$TMP_DIR/ext_insta"
            elif [[ "$ig_code" == "429" ]]; then
                echo "Captcha|N/A|429" > "$TMP_DIR/ext_insta"
            elif [[ "$ig_eff" == *"/accounts/login"* || "$ig_eff" == *"/challenge"* || "$ig_code" == "302" ]]; then
                echo "Captcha|Login|Login" > "$TMP_DIR/ext_insta"
            elif [[ "$ig_code" == "200" ]]; then
                echo "Yes|OK|200 OK" > "$TMP_DIR/ext_insta"
            else
                echo "Block|N/A|${ig_code:-Err}" > "$TMP_DIR/ext_insta"
            fi
        ) &

        (
            local gh_res gh_rem
            gh_res=$(curl -sL "$IPV_MODE" --connect-timeout 4 -m 7 -A "$UA_BROWSER" "https://api.github.com/rate_limit" 2>/dev/null || true)
            if [[ -z "$gh_res" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|-" > "$TMP_DIR/ext_github"
            elif [[ -n "$gh_res" ]]; then
                gh_rem=$(jq -r '.resources.core.remaining // empty' <<<"$gh_res" 2>/dev/null || true)
                if [[ -n "$gh_rem" && "$gh_rem" -gt 0 ]] 2>/dev/null; then
                    echo "Clean|${gh_rem}/60|200 OK" > "$TMP_DIR/ext_github"
                else
                    echo "RateLim|0/60|403" > "$TMP_DIR/ext_github"
                fi
            else
                echo "Block|N/A|Err" > "$TMP_DIR/ext_github"
            fi
        ) &

        (
            local tg_code
            tg_code=$(curl -s "$IPV_MODE" --connect-timeout 5 -m 9 -A "$UA_BROWSER" -o /dev/null -w "%{http_code}" "https://api.telegram.org" 2>/dev/null || true)
            if [[ "$tg_code" == "000" && "$IPV_MODE" == "-6" ]]; then
                echo "NoIPv6|N/A|-" > "$TMP_DIR/ext_telegram"
            elif [[ "$tg_code" =~ ^(200|301|302|404)$ ]]; then
                echo "Yes|OK|Native" > "$TMP_DIR/ext_telegram"
            else
                echo "Block|N/A|Err" > "$TMP_DIR/ext_telegram"
            fi
        ) &

        # Outbound DNS Resolver (EDNS Leak Check) & Anycast Latency
        (
            local rnd_sub edns_res
            rnd_sub=$(printf '%08x%08x%08x%08x' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM")
            edns_res=$(curl -sL $DB_CURL_FLAG --connect-timeout 5 -m 8 -A "$UA_BROWSER" "https://${rnd_sub}.edns.ip-api.com/json" 2>/dev/null || true)
            if [[ -n "$edns_res" ]]; then
                local d_ip d_geo
                d_ip=$(jq -r '.dns.ip // empty' <<<"$edns_res" 2>/dev/null || true)
                d_geo=$(jq -r '.dns.geo // empty' <<<"$edns_res" 2>/dev/null || true)
                [[ -n "$d_ip" ]] && printf '%s|%s\n' "$d_ip" "${d_geo:-Unknown}" > "$TMP_DIR/edns_info"
            fi
        ) &

        (
            local t_cf="1.1.1.1" t_gg="8.8.8.8" t_q9="9.9.9.9"
            if [[ "$IPV_MODE" == "-6" ]]; then
                t_cf="2606:4700:4700::1111"
                t_gg="2001:4860:4860::8888"
                t_q9="2620:fe::fe"
            fi
            for pair in "cf|${t_cf}|https://1.1.1.1" "gg|${t_gg}|https://dns.google" "q9|${t_q9}|https://dns.quad9.net"; do
                (
                    IFS='|' read -r k ip url <<<"$pair"
                    local rtt=""
                    if command -v ping &>/dev/null; then
                        rtt=$(ping "$IPV_MODE" -c 2 -i 0.2 -W 1 "$ip" 2>/dev/null | awk -F'/' '/rtt|round-trip/ {printf "%.1f ms", $5}' || true)
                    fi
                    if [[ -z "$rtt" ]]; then
                        local t_conn
                        t_conn=$(curl -s "$IPV_MODE" -m 2 -o /dev/null -w "%{time_connect}" "$url" 2>/dev/null || true)
                        if [[ -n "$t_conn" && "$t_conn" != "0.000000" ]]; then
                            rtt=$(awk -v t="$t_conn" 'BEGIN {printf "%.1f ms (TCP)", t * 1000}')
                        fi
                    fi
                    echo "${rtt:-Timeout}" > "$TMP_DIR/rtt_${k}"
                ) &
            done
            wait
        ) &

        # Port 25 & MX Reachability
        (
            local mx_addr
            if [[ "$IPV_MODE" == "-4" ]]; then
                mx_addr=$(dig +short A gmail-smtp-in.l.google.com 2>/dev/null | head -n1 || true)
            else
                mx_addr=$(dig +short AAAA gmail-smtp-in.l.google.com 2>/dev/null | head -n1 || true)
            fi
            if [[ -n "$mx_addr" ]] && timeout 3 bash -c "</dev/tcp/${mx_addr}/25" &>/dev/null; then
                echo "Open" > "$TMP_DIR/p25_local"
            else
                echo "Block" > "$TMP_DIR/p25_local"
            fi
        ) &

        for m_item in "Gmail|gmail-smtp-in.l.google.com" "Outlook|outlook-com.olc.protection.outlook.com" "Yahoo|mta5.am0.yahoodns.net" "Apple|mx01.mail.icloud.com" "Proton|mail.protonmail.ch" "Yandex|mx.yandex.ru" "Mail.ru|mxs.mail.ru" "Zoho|mx.zoho.com"; do
            (
                IFS='|' read -r m_name m_host <<<"$m_item"
                local target_addr=""
                if [[ "$IPV_MODE" == "-4" ]]; then
                    target_addr=$(dig +short A "$m_host" 2>/dev/null | head -n1 || true)
                else
                    target_addr=$(dig +short AAAA "$m_host" 2>/dev/null | head -n1 || true)
                fi
                if [[ -z "$target_addr" ]]; then
                    echo "NoIPv6" > "$TMP_DIR/mail_${m_name}"
                else
                    if timeout 3 bash -c "</dev/tcp/${target_addr}/25" &>/dev/null; then
                        echo "Yes" > "$TMP_DIR/mail_${m_name}"
                    else
                        echo "No" > "$TMP_DIR/mail_${m_name}"
                    fi
                fi
            ) &
        done
    fi

    # --- DNSBL Checks ---
    local REV_IP=""
    if [[ "$TARGET_IP" == *":"* ]]; then
        REV_IP=$(awk -F: '
        {
            n = split($0, a, ":")
            empty_idx = 0
            for (i = 1; i <= n; i++) {
                if (a[i] == "" && empty_idx == 0) empty_idx = i
            }
            out = ""
            if (empty_idx > 0) {
                missing = 8 - (n - 1)
                if (a[1] == "") missing++
                if (a[n] == "") missing++
                for (i = 1; i <= n; i++) {
                    if (i == empty_idx) {
                        for (j = 1; j <= missing; j++) out = out "0000"
                    } else if (a[i] != "") {
                        out = out sprintf("%04s", tolower(a[i]))
                    }
                }
            } else {
                for (i = 1; i <= n; i++) out = out sprintf("%04s", tolower(a[i]))
            }
            gsub(/ /, "0", out)
            rev = ""
            for (i = length(out); i >= 1; i--) {
                rev = rev substr(out, i, 1) (i > 1 ? "." : "")
            }
            print rev
        }' <<<"$TARGET_IP")
    else
        REV_IP=$(awk -F. '{print $4"."$3"."$2"."$1}' <<<"$TARGET_IP")
    fi

    local RBL_LIST="zen.spamhaus.org b.barracudacentral.org bl.spamcop.net dnsbl.sorbs.net dnsbl-1.uceprotect.net psbl.surriel.com db.wpbl.info ix.dnsbl.manitu.net 0spam.fusionzero.com rbl.interserver.net"
    local RBL_TOTAL=10
    mkdir -p "$TMP_DIR/rbl"

    if [[ -n "$REV_IP" ]]; then
        for rbl in $RBL_LIST; do
            (
                local res=""
                if command -v dig &>/dev/null; then
                    res=$(dig +short +time=2 +tries=1 "${REV_IP}.${rbl}" A 2>/dev/null | grep -E '^127\.0\.0\.[0-9]+$' || true)
                elif command -v host &>/dev/null; then
                    res=$(host -W 2 "${REV_IP}.${rbl}" 2>/dev/null | grep -oE '127\.0\.0\.[0-9]+' || true)
                fi
                [[ -n "$res" && "$res" != "127.0.0.255" ]] && echo "$rbl" > "$TMP_DIR/rbl/${rbl}"
            ) &
        done
    fi

    wait_with_spinner "Checking ${IPV_LABEL} quality (${TARGET_IP})"

    # ==========================================================================
    # PARSE DATA FOR REPORT
    # ==========================================================================
    local ASN="" ORG="" CITY="" POSTAL="" COUNTRY_CODE="" COUNTRY_NAME="" REG_COUNTRY="" TIMEZONE="" LAT_LON="" PTR_RECORD=""

    ASN=$(jq -r '.traits.autonomous_system_number // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$ASN" || "$ASN" == "null" ]] && ASN=$(jq -r '.data.asns[0].asn // empty' "$TMP_DIR/ripe_asn.json" 2>/dev/null || true)
    [[ -z "$ASN" || "$ASN" == "null" ]] && ASN=$(jq -r '.connection.asn // empty' "$TMP_DIR/ipregistry.json" 2>/dev/null || true)
    [[ -z "$ASN" || "$ASN" == "null" ]] && ASN=$(jq -r '.data.asn.asn // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)
    if [[ -z "$ASN" || "$ASN" == "null" ]]; then
        ASN=$(jq -r '.data.org // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null | awk '{print $1}' || true)
        [[ "$ASN" =~ ^AS[0-9]+$ ]] || ASN=""
    fi
    [[ -z "$ASN" || "$ASN" == "null" ]] && ASN=$(jq -r 'select(.status=="success") | .as // empty' "$TMP_DIR/ip_api.json" 2>/dev/null | awk '{print $1}' || true)
    [[ -z "$ASN" || "$ASN" == "null" ]] && ASN=$(jq -r '.asn // empty' "$TMP_DIR/ip2location.json" 2>/dev/null || true)
    [[ -z "$ASN" || "$ASN" == "null" ]] && ASN=$(jq -r '.isp.asn // empty' "$TMP_DIR/ipquery.json" 2>/dev/null || true)
    [[ -z "$ASN" || "$ASN" == "null" ]] && ASN=$(jq -r '.connection.asn // empty' "$TMP_DIR/ipwhois.json" 2>/dev/null || true)
    [[ "$ASN" =~ ^[0-9]+$ ]] && ASN="AS${ASN}"
    [[ -z "$ASN" || "$ASN" == "null" ]] && ASN="N/A"

    ORG=$(jq -r '.traits.autonomous_system_organization // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$ORG" || "$ORG" == "null" ]] && ORG=$(jq -r '.data.asns[0].holder // empty | sub("^\\S+ (- )?"; "")' "$TMP_DIR/ripe_asn.json" 2>/dev/null || true)
    [[ -z "$ORG" || "$ORG" == "null" ]] && ORG=$(jq -r '.data.asn.name // .data.company.name // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)
    [[ -z "$ORG" || "$ORG" == "null" ]] && ORG=$(jq -r '.connection.organization // .company.name // empty' "$TMP_DIR/ipregistry.json" 2>/dev/null || true)
    [[ -z "$ORG" || "$ORG" == "null" ]] && ORG=$(jq -r 'select(.status=="success") | .org // .isp // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true)
    [[ -z "$ORG" || "$ORG" == "null" ]] && ORG=$(jq -r '.as // .isp // empty' "$TMP_DIR/ip2location.json" 2>/dev/null || true)
    [[ -z "$ORG" || "$ORG" == "null" ]] && ORG=$(jq -r '.isp.org // .isp.isp // empty' "$TMP_DIR/ipquery.json" 2>/dev/null || true)
    [[ -z "$ORG" || "$ORG" == "null" ]] && ORG=$(jq -r '.connection.org // .connection.isp // empty' "$TMP_DIR/ipwhois.json" 2>/dev/null || true)
    [[ -z "$ORG" ]] && ORG="N/A"

    CITY=$(jq -r '.city.names.en // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$CITY" || "$CITY" == "null" ]] && CITY=$(jq -r '.data.city // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)
    [[ -z "$CITY" || "$CITY" == "null" ]] && CITY=$(jq -r '.location.city // empty' "$TMP_DIR/ipregistry.json" 2>/dev/null || true)
    [[ -z "$CITY" || "$CITY" == "null" ]] && CITY=$(jq -r '.city_name // empty' "$TMP_DIR/ip2location.json" 2>/dev/null || true)
    [[ -z "$CITY" || "$CITY" == "null" ]] && CITY=$(jq -r 'select(.status=="success") | .city // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true)
    [[ -z "$CITY" || "$CITY" == "null" ]] && CITY=$(jq -r '.location.city // empty' "$TMP_DIR/ipquery.json" 2>/dev/null || true)
    [[ -z "$CITY" || "$CITY" == "null" ]] && CITY=$(jq -r '.city // empty' "$TMP_DIR/ipwhois.json" 2>/dev/null || true)
    [[ -z "$CITY" ]] && CITY="N/A"

    POSTAL=$(jq -r '.postal.code // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$POSTAL" || "$POSTAL" == "null" ]] && POSTAL=$(jq -r '.data.postal // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)
    [[ -z "$POSTAL" || "$POSTAL" == "null" ]] && POSTAL=$(jq -r '.location.postal // empty' "$TMP_DIR/ipregistry.json" 2>/dev/null || true)
    [[ -z "$POSTAL" || "$POSTAL" == "null" ]] && POSTAL=$(jq -r '.zip_code // empty' "$TMP_DIR/ip2location.json" 2>/dev/null || true)
    [[ -z "$POSTAL" || "$POSTAL" == "null" ]] && POSTAL=$(jq -r 'select(.status=="success") | .zip // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true)
    [[ -z "$POSTAL" || "$POSTAL" == "null" ]] && POSTAL=$(jq -r '.postal // empty' "$TMP_DIR/ipwhois.json" 2>/dev/null || true)
    [[ "$POSTAL" == "null" ]] && POSTAL=""

    COUNTRY_CODE=$(jq -r '.country.iso_code // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_CODE" || "$COUNTRY_CODE" == "null" ]] && COUNTRY_CODE=$(jq -r '.data.country // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_CODE" || "$COUNTRY_CODE" == "null" ]] && COUNTRY_CODE=$(jq -r '.location.country.code // empty' "$TMP_DIR/ipregistry.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_CODE" || "$COUNTRY_CODE" == "null" ]] && COUNTRY_CODE=$(jq -r '.country_code // empty' "$TMP_DIR/ip2location.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_CODE" || "$COUNTRY_CODE" == "null" ]] && COUNTRY_CODE=$(jq -r 'select(.status=="success") | .countryCode // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_CODE" || "$COUNTRY_CODE" == "null" ]] && COUNTRY_CODE=$(jq -r '.location.country_code // empty' "$TMP_DIR/ipquery.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_CODE" || "$COUNTRY_CODE" == "null" ]] && COUNTRY_CODE=$(jq -r '.country_code // empty' "$TMP_DIR/ipwhois.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_CODE" ]] && COUNTRY_CODE="N/A"

    COUNTRY_NAME=$(jq -r '.country.names.en // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_NAME" || "$COUNTRY_NAME" == "null" ]] && COUNTRY_NAME=$(jq -r '.location.country.name // empty' "$TMP_DIR/ipregistry.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_NAME" || "$COUNTRY_NAME" == "null" ]] && COUNTRY_NAME=$(jq -r '.country_name // empty' "$TMP_DIR/ip2location.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_NAME" || "$COUNTRY_NAME" == "null" ]] && COUNTRY_NAME=$(jq -r 'select(.status=="success") | .country // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_NAME" || "$COUNTRY_NAME" == "null" ]] && COUNTRY_NAME=$(jq -r '.location.country // empty' "$TMP_DIR/ipquery.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_NAME" || "$COUNTRY_NAME" == "null" ]] && COUNTRY_NAME=$(jq -r '.country // empty' "$TMP_DIR/ipwhois.json" 2>/dev/null || true)
    [[ -z "$COUNTRY_NAME" ]] && COUNTRY_NAME="N/A"

    REG_COUNTRY=$(jq -r '.data.located_resources[0].location // empty' "$TMP_DIR/ripe_reg.json" 2>/dev/null || true)
    [[ -z "$REG_COUNTRY" || "$REG_COUNTRY" == "null" ]] && REG_COUNTRY=$(jq -r '.registered_country.iso_code // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$REG_COUNTRY" || "$REG_COUNTRY" == "null" ]] && REG_COUNTRY="$COUNTRY_CODE"

    TIMEZONE=$(jq -r '.location.time_zone // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ -z "$TIMEZONE" || "$TIMEZONE" == "null" ]] && TIMEZONE=$(jq -r '.data.timezone // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)
    [[ -z "$TIMEZONE" || "$TIMEZONE" == "null" ]] && TIMEZONE=$(jq -r '.time_zone.id // empty' "$TMP_DIR/ipregistry.json" 2>/dev/null || true)
    [[ -z "$TIMEZONE" || "$TIMEZONE" == "null" ]] && TIMEZONE=$(jq -r 'select(.status=="success") | .timezone // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true)
    [[ -z "$TIMEZONE" || "$TIMEZONE" == "null" ]] && TIMEZONE=$(jq -r '.location.timezone // empty' "$TMP_DIR/ipquery.json" 2>/dev/null || true)
    [[ -z "$TIMEZONE" || "$TIMEZONE" == "null" ]] && TIMEZONE=$(jq -r '.timezone.id // empty' "$TMP_DIR/ipwhois.json" 2>/dev/null || true)
    [[ -z "$TIMEZONE" ]] && TIMEZONE="N/A"

    LAT_LON=$(jq -r '.data.loc // empty' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)
    [[ "$LAT_LON" == *,* ]] && LAT_LON="${LAT_LON/,/, }"
    if [[ -z "$LAT_LON" || "$LAT_LON" == "null" ]]; then
        local lat="" lon=""
        lat=$(jq -r '.location.latitude // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
        lon=$(jq -r '.location.longitude // empty' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
        [[ -z "$lat" || -z "$lon" ]] && { lat=$(jq -r '.location.latitude // empty' "$TMP_DIR/ipregistry.json" 2>/dev/null || true); lon=$(jq -r '.location.longitude // empty' "$TMP_DIR/ipregistry.json" 2>/dev/null || true); }
        [[ -z "$lat" || -z "$lon" ]] && { lat=$(jq -r '.latitude // empty' "$TMP_DIR/ip2location.json" 2>/dev/null || true); lon=$(jq -r '.longitude // empty' "$TMP_DIR/ip2location.json" 2>/dev/null || true); }
        [[ -z "$lat" || -z "$lon" ]] && { lat=$(jq -r 'select(.status=="success") | .lat // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true); lon=$(jq -r 'select(.status=="success") | .lon // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true); }
        [[ -z "$lat" || -z "$lon" ]] && { lat=$(jq -r '.latitude // empty' "$TMP_DIR/ipwhois.json" 2>/dev/null || true); lon=$(jq -r '.longitude // empty' "$TMP_DIR/ipwhois.json" 2>/dev/null || true); }
        [[ -n "$lat" && -n "$lon" ]] && LAT_LON="${lat}, ${lon}"
    fi
    [[ -z "$LAT_LON" ]] && LAT_LON="N/A"

    PTR_RECORD=$(cat "$TMP_DIR/ptr.txt" 2>/dev/null || true)
    [[ -z "$PTR_RECORD" ]] && PTR_RECORD="No PTR (Missing rDNS)"

    # --- Parse BGP Prefix, RPKI ROA & Upstream Transit ---
    local BGP_PREFIX RPKI_STATUS ANYCAST_FLAG="" UPSTREAM_TXT=""
    BGP_PREFIX=$(jq -r '.data.resource // empty' "$TMP_DIR/ripe_asn.json" 2>/dev/null || true)
    RPKI_STATUS=$(jq -r '.data.status // empty' "$TMP_DIR/ripe_rpki.json" 2>/dev/null || true)
    ANYCAST_FLAG=$(jq -r '(.traits.is_anycast // empty)' "$TMP_DIR/maxmind_direct.json" 2>/dev/null || true)
    [[ "$ANYCAST_FLAG" != "true" ]] && ANYCAST_FLAG=$(jq -r '(.data.anycast // .data.is_anycast // empty)' "$TMP_DIR/ipinfo_widget.json" 2>/dev/null || true)
    [[ "$ANYCAST_FLAG" != "true" ]] && ANYCAST_FLAG=$(jq -r '(.connection.is_anycast // empty)' "$TMP_DIR/ipregistry.json" 2>/dev/null || true)

    if [[ -s "$TMP_DIR/ripe_peers.json" ]]; then
        local total_peers up_asns
        total_peers=$(jq -r '.data.neighbour_counts.left // 0' "$TMP_DIR/ripe_peers.json" 2>/dev/null || echo 0)
        up_asns=$(jq -r '[.data.neighbours[]? | select(.type=="left")] | sort_by(-.power) | .[0:4] | .[].asn' "$TMP_DIR/ripe_peers.json" 2>/dev/null || true)
        if [[ -n "$up_asns" ]]; then
            local asn_item lbl items=()
            for asn_item in $up_asns; do
                lbl=$(asn_label "$asn_item")
                if [[ -n "$lbl" ]]; then
                    items+=("AS${asn_item} (${lbl})")
                else
                    items+=("AS${asn_item}")
                fi
            done
            local idx
            for ((idx = 0; idx < ${#items[@]}; idx++)); do
                ((idx > 0)) && UPSTREAM_TXT+=", "
                UPSTREAM_TXT+="${items[idx]}"
            done
            ((total_peers > 4)) && UPSTREAM_TXT+=" (+$((total_peers - 4)) more)"
        fi
    fi

    # --- Parse Scamalytics HTML fields safely ---
    local scm_score="" scm_blk_ext="" scm_cc="" scm_conn="" scm_dc="" scm_srv="" scm_vpn="" scm_tor="" scm_pub_proxy="" scm_web_proxy="" scm_bot="" scm_blk_list=""
    if [[ -s "$TMP_DIR/scam_parsed" ]]; then
        local _sk _sv
        while IFS='=' read -r _sk _sv; do
            case "$_sk" in
                score) scm_score="$_sv" ;;
                blk_ext) scm_blk_ext="$_sv" ;;
                cc) scm_cc="$_sv" ;;
                conn) scm_conn="$_sv" ;;
                dc) scm_dc="$_sv" ;;
                srv) scm_srv="$_sv" ;;
                vpn) scm_vpn="$_sv" ;;
                tor) scm_tor="$_sv" ;;
                pub_proxy) scm_pub_proxy="$_sv" ;;
                web_proxy) scm_web_proxy="$_sv" ;;
                bot) scm_bot="$_sv" ;;
                blk_list) scm_blk_list="$_sv" ;;
            esac
        done < "$TMP_DIR/scam_parsed"
    fi

    # --- Parse 12 IP Types ---
    local T_INF_U=$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.asn.type')
    if [[ "$T_INF_U" == "N/A" ]]; then
        if [[ "$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.is_hosting // .data.privacy.hosting')" == "true" ]]; then
            T_INF_U="hosting"
        elif [[ "$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.is_mobile')" == "true" ]]; then
            T_INF_U="mobile"
        fi
    fi
    local T_INF_C=$(jq_get "$TMP_DIR/ipinfo_widget.json" '.data.company.type')
    local T_REG_U=$(jq_get "$TMP_DIR/ipregistry.json" '.connection.type')
    local T_REG_C=$(jq_get "$TMP_DIR/ipregistry.json" '.company.type')
    local T_API_U=$(jq_get "$TMP_DIR/ipapi_is.json" 'if (.asn | type) == "object" then .asn.type elif .is_datacenter == true then "hosting" elif .is_mobile == true then "mobile" else empty end')
    local T_API_C=$(jq_get "$TMP_DIR/ipapi_is.json" 'if (.company | type) == "object" then .company.type else empty end')
    local T_I2L_U=$(jq_get "$TMP_DIR/ip2location.json" '.usage_type')
    local T_I2L_C=$(jq_get "$TMP_DIR/ip2location.json" '.as_info.as_usage_type')
    [[ "$T_I2L_U" == "N/A" && "$(jq_get "$TMP_DIR/ip2location.json" '.is_proxy')" == "true" ]] && T_I2L_U="hosting"
    local T_IPD_U=$(jq_get "$TMP_DIR/ipdata.json" '.asn.type')
    local T_IPD_C=$(jq_get "$TMP_DIR/ipdata.json" '.company.type')
    [[ "$T_IPD_U" == "N/A" && "$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_datacenter')" == "true" ]] && T_IPD_U="hosting"

    local T_WHO_U=$(jq_get "$TMP_DIR/ipwhois.json" '.connection.type')
    local T_WHO_C="N/A"
    if [[ "$T_WHO_U" == "N/A" ]] && jq -e '.security | type == "object"' "$TMP_DIR/ipwhois.json" &>/dev/null; then
        if [[ "$(jq_get "$TMP_DIR/ipwhois.json" '.security.hosting')" == "true" ]]; then
            T_WHO_U="hosting"
        elif [[ "$(jq_get "$TMP_DIR/ipwhois.json" '.security.mobile')" == "true" ]]; then
            T_WHO_U="mobile"
        elif [[ "$(jq_get "$TMP_DIR/ipwhois.json" '.security.tor')" == "true" ]]; then
            T_WHO_U="tor"
        else
            T_WHO_U="isp"
        fi
    fi

    local T_MAX_U=$(jq_get "$TMP_DIR/maxmind_direct.json" '.traits.user_type // .traits.connection_type')
    local T_ABU_U=$(jq_get "$TMP_DIR/abuseipdb.json" '.data.usageType')
    local T_PCK_U=$(jq -r --arg ip "$TARGET_IP" 'select(.status=="ok" or .status=="warning") | (.[$ip] // ([to_entries[] | select(.value | type == "object")][0].value // empty)) | .type // "N/A"' "$TMP_DIR/proxycheck.json" 2>/dev/null || true)
    [[ -z "$T_PCK_U" ]] && T_PCK_U="N/A"
    local T_IPA_U="N/A"
    if [[ "$(jq_get "$TMP_DIR/ip_api.json" '.status')" == "success" ]]; then
        if [[ "$(jq_get "$TMP_DIR/ip_api.json" '.hosting')" == "true" ]]; then T_IPA_U="hosting"
        elif [[ "$(jq_get "$TMP_DIR/ip_api.json" '.mobile')" == "true" ]]; then T_IPA_U="mobile"
        else T_IPA_U="isp"; fi
    fi
    local T_IPQ_U="N/A"
    if [[ "$(jq_get "$TMP_DIR/ipquery.json" '.risk.is_datacenter')" == "true" ]]; then T_IPQ_U="hosting"
    elif [[ "$(jq_get "$TMP_DIR/ipquery.json" '.risk.is_mobile')" == "true" ]]; then T_IPQ_U="mobile"
    elif jq -e '.isp' "$TMP_DIR/ipquery.json" &>/dev/null; then T_IPQ_U="isp"; fi

    local T_SCM_U="N/A"
    if [[ "$scm_dc" == "yes" || "$scm_srv" == "yes" ]]; then
        T_SCM_U="hosting"
    elif [[ -n "$scm_conn" ]]; then
        T_SCM_U="$scm_conn"
    elif [[ "$scm_srv" == "no" || "$scm_dc" == "no" ]]; then
        T_SCM_U="isp"
    fi

    # --- Parse 10 Risk Scores ---
    local I2L_SCORE=$(jq -r '.fraud_score // empty' "$TMP_DIR/ip2location.json" 2>/dev/null || true)
    [[ "$I2L_SCORE" =~ ^[0-9]+$ ]] || I2L_SCORE=""

    local SCAM_SCORE="$scm_score"
    [[ "$SCAM_SCORE" =~ ^[0-9]+$ ]] || SCAM_SCORE=""

    local IPQ_SCORE=$(jq -r '.risk.risk_score // empty' "$TMP_DIR/ipquery.json" 2>/dev/null || true)
    [[ "$IPQ_SCORE" =~ ^[0-9]+$ ]] || IPQ_SCORE=""

    local IPAPI_RAW=$(jq -r '((if (.company | type) == "object" then .company.abuser_score else null end) // (if (.asn | type) == "object" then .asn.abuser_score else null end) // empty)' "$TMP_DIR/ipapi_is.json" 2>/dev/null || true)
    [[ "$IPAPI_RAW" == "null" ]] && IPAPI_RAW=""
    local IPAPI_PCT="" IPAPI_LVL=""
    if [[ -n "$IPAPI_RAW" ]]; then
        IPAPI_PCT=$(awk '{printf "%.2f", $1 * 100}' <<<"$IPAPI_RAW")
        IPAPI_LVL=$(grep -oE '\([A-Za-z ]+\)' <<<"$IPAPI_RAW" | tr -d '() ' || true)
    fi

    local ABUSE_SCORE=$(jq -r '.data.abuseConfidenceScore // empty' "$TMP_DIR/abuseipdb.json" 2>/dev/null || true)
    [[ "$ABUSE_SCORE" =~ ^[0-9]+$ ]] || ABUSE_SCORE=""

    local IPQS_SCORE=$(jq -r '.fraud_score // empty' "$TMP_DIR/ipqs.json" 2>/dev/null || true)
    [[ "$IPQS_SCORE" =~ ^[0-9]+$ ]] || IPQS_SCORE=""

    local PCHECK_SCORE=$(jq -r --arg ip "$TARGET_IP" 'select(.status=="ok" or .status=="warning") | (.[$ip] // ([to_entries[] | select(.value | type == "object")][0].value // empty)) | .risk // empty' "$TMP_DIR/proxycheck.json" 2>/dev/null || true)
    [[ "$PCHECK_SCORE" =~ ^[0-9]+$ ]] || PCHECK_SCORE=""

    local IPREG_SCORE=""
    if jq -e '.security | type == "object"' "$TMP_DIR/ipregistry.json" &>/dev/null; then
        IPREG_SCORE=$(jq -r '.security | ((if .is_tor or .is_tor_exit then 50 else 0 end)+(if .is_attacker then 50 else 0 end)+(if .is_abuser then 40 else 0 end)+(if .is_threat then 40 else 0 end)+(if .is_proxy then 30 else 0 end)+(if .is_vpn then 25 else 0 end)+(if .is_cloud_provider then 15 else 0 end)) | if . > 100 then 100 else . end' "$TMP_DIR/ipregistry.json" 2>/dev/null || true)
    fi

    local IPDATA_SCORE=""
    if jq -e '.threat | type == "object"' "$TMP_DIR/ipdata.json" &>/dev/null; then
        IPDATA_SCORE=$(jq -r '.threat | ([((if .is_tor then 50 else 0 end)+(if .is_known_attacker then 50 else 0 end)+(if .is_known_abuser then 40 else 0 end)+(if .is_threat then 40 else 0 end)+(if .is_proxy then 30 else 0 end)+(if .is_vpn then 25 else 0 end)+(if .is_datacenter then 15 else 0 end)), (.scores.threat_score // 0 | floor)] | max) | if . > 100 then 100 else . end' "$TMP_DIR/ipdata.json" 2>/dev/null || true)
    fi

    local DBIP_RAW=$(jq -r '.threatLevel // empty' "$TMP_DIR/dbip.json" 2>/dev/null || true)
    local DBIP_SCORE=""
    case "$DBIP_RAW" in low) DBIP_SCORE=0 ;; medium) DBIP_SCORE=50 ;; high) DBIP_SCORE=100 ;; esac

    # ==========================================================================
    # RENDER VERTICAL REPORT
    # ==========================================================================
    local DISP_IP="$TARGET_IP"
    if [[ "$MASK_IP" == true ]]; then
        if [[ "$DISP_IP" == *"."* ]]; then
            DISP_IP="${DISP_IP%.*.*}.*.*"
        else
            DISP_IP="${DISP_IP%%:*}:${DISP_IP#*:}"
            DISP_IP="${DISP_IP%%:*}::*"
        fi
    fi

    printf '\n'
    printf ' %s╭──────────────────────────────────────────────────────────────────────────────╮%s\n' "$C_BORDER" "$C_RESET"
    printf ' %s│%s  %s  %s%s Diagnostics · %s%s\n' \
        "$C_BORDER" "$C_RESET" "${C_BADGE}  IPQUALITY  ${C_RESET}" \
        "${C_WHITE}" "$IPV_LABEL" "$DISP_IP" "${C_RESET}"
    printf ' %s│%s  %sReport Time: %s   ·   Mode: %s Stack%s\n' \
        "$C_BORDER" "$C_RESET" "${C_DIM}" "$REPORT_TIME" "$IPV_LABEL" "${C_RESET}"
    printf ' %s╰──────────────────────────────────────────────────────────────────────────────╯%s\n' "$C_BORDER" "$C_RESET"

    # --- I. Basic Information & BGP Routing ---
    print_section "I. Basic Information & BGP Routing"
    print_rail; printf "${C_CYAN}%-18s${C_RESET}${C_WHITE}%s${C_RESET} ${C_DIM}(%s)${C_RESET}\n" "IP Address:" "$DISP_IP" "$IPV_LABEL"
    print_rail; printf "${C_CYAN}%-18s${C_RESET}${C_ACCENT}%s${C_RESET} ${C_DIM}·${C_RESET} %s\n" "ASN / Holder:" "${ASN:-N/A}" "${ORG:-N/A}"
    if [[ -n "$BGP_PREFIX" ]]; then
        local rpki_badge="${C_DIM}Unknown${C_RESET}"
        case "$RPKI_STATUS" in
            valid)   rpki_badge="${C_GREEN}✔ RPKI Valid${C_RESET}" ;;
            invalid) rpki_badge="${C_RED}✘ RPKI Invalid${C_RESET}" ;;
            unknown) rpki_badge="${C_YELLOW}○ RPKI NotFound${C_RESET}" ;;
        esac
        local anycast_txt=""
        [[ "$ANYCAST_FLAG" == "true" ]] && anycast_txt=" ${C_DIM}·${C_RESET} ${C_PURPLE}Anycast${C_RESET}"
        print_rail; printf "${C_CYAN}%-18s${C_RESET}%s ${C_DIM}·${C_RESET} %s%s\n" "BGP Prefix:" "$BGP_PREFIX" "$rpki_badge" "$anycast_txt"
    fi
    [[ -n "$UPSTREAM_TXT" ]] && { print_rail; printf "${C_CYAN}%-18s${C_RESET}%s\n" "Upstreams:" "$UPSTREAM_TXT"; }
    print_rail; printf "${C_CYAN}%-18s${C_RESET}%s\n" "Location:" "${CITY:-N/A}${POSTAL:+, $POSTAL}, ${COUNTRY_NAME:-N/A} [${COUNTRY_CODE:-N/A}]"
    print_rail; printf "${C_CYAN}%-18s${C_RESET}[%s] ${C_DIM}· Time Zone:${C_RESET} %s\n" "Registered In:" "${REG_COUNTRY:-N/A}" "${TIMEZONE:-N/A}"
    print_rail; printf "${C_CYAN}%-18s${C_RESET}%s\n" "Coordinates:" "${LAT_LON:-N/A}"
    if [[ "$PTR_RECORD" == "No PTR"* ]]; then
        print_rail; printf "${C_CYAN}%-18s${C_RESET}${C_YELLOW}%s${C_RESET}\n" "PTR (rDNS):" "$PTR_RECORD"
    else
        print_rail; printf "${C_CYAN}%-18s${C_RESET}${C_GREEN}%s${C_RESET}\n" "PTR (rDNS):" "$PTR_RECORD"
    fi
    print_section_end

    # --- II. IP Type (12 Databases, Full Labels) ---
    print_section "II. IP Type Classification (12 Databases)"
    print_rail; printf "${C_DIM}%-11s%-11s%-11s%-11s%-11s%-11s%-11s${C_RESET}\n" "Database" "IPinfo" "ipregistry" "ipapi.is" "IP2Loc" "ipdata.co" "ipwho.is"
    print_rail; printf "${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Usage:" \
        "$(format_type_badge "$T_INF_U")" "$(format_type_badge "$T_REG_U")" "$(format_type_badge "$T_API_U")" \
        "$(format_type_badge "$T_I2L_U")" "$(format_type_badge "$T_IPD_U")" "$(format_type_badge "$T_WHO_U")"
    print_rail; printf "${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Company:" \
        "$(format_type_badge "$T_INF_C")" "$(format_type_badge "$T_REG_C")" "$(format_type_badge "$T_API_C")" \
        "$(format_type_badge "$T_I2L_C")" "$(format_type_badge "$T_IPD_C")" "$(format_type_badge "$T_WHO_C")"
    print_rail; printf '\n'
    print_rail; printf "${C_DIM}%-11s%-11s%-11s%-11s%-11s%-11s%-11s${C_RESET}\n" "Database" "MaxMind" "AbuseIPDB" "ProxyCheck" "ip-api.com" "ipquery.io" "Scamalytics"
    print_rail; printf "${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Usage:" \
        "$(format_type_badge "$T_MAX_U")" "$(format_type_badge "$T_ABU_U")" "$(format_type_badge "$T_PCK_U")" \
        "$(format_type_badge "$T_IPA_U")" "$(format_type_badge "$T_IPQ_U")" "$(format_type_badge "$T_SCM_U")"
    print_section_end

    # --- III. Risk Score (10 Engines) ---
    print_section "III. Fraud & Abuse Risk Scores (10 Engines)"
    print_rail; printf "${C_DIM}%-16s${C_RESET}${BG_GREEN} ● Low (0-24) ${C_RESET}  ${BG_YELLOW} ● Medium (25-64) ${C_RESET}  ${BG_RED} ● High (65+) ${C_RESET}\n" "Scale Legend:"

    if [[ -n "$SCAM_SCORE" ]]; then
        local lvl="Low"; ((SCAM_SCORE >= 25)) && lvl="Medium"; ((SCAM_SCORE >= 60)) && lvl="High"
        draw_score_bar "Scamalytics" "$SCAM_SCORE" "${SCAM_SCORE}/100" "$lvl"
    fi
    if [[ -n "$IPQS_SCORE" ]]; then
        local lvl="Low"; ((IPQS_SCORE >= 50)) && lvl="Medium"; ((IPQS_SCORE >= 75)) && lvl="Risky"; ((IPQS_SCORE >= 85)) && lvl="High"
        draw_score_bar "IPQualityScore" "$IPQS_SCORE" "${IPQS_SCORE}/100" "$lvl"
    fi
    if [[ -n "$IPQ_SCORE" ]]; then
        local lvl="Low"; ((IPQ_SCORE >= 25)) && lvl="Medium"; ((IPQ_SCORE >= 65)) && lvl="High"
        draw_score_bar "ipquery.io" "$IPQ_SCORE" "${IPQ_SCORE}/100" "$lvl"
    fi
    if [[ -n "$I2L_SCORE" ]]; then
        local lvl="Low"; ((I2L_SCORE >= 25)) && lvl="Medium"; ((I2L_SCORE >= 65)) && lvl="High"
        draw_score_bar "IP2Location" "$I2L_SCORE" "${I2L_SCORE}/100" "$lvl"
    fi
    if [[ -n "$ABUSE_SCORE" ]]; then
        local lvl="Low"; ((ABUSE_SCORE >= 25)) && lvl="Medium"; ((ABUSE_SCORE >= 65)) && lvl="High"
        draw_score_bar "AbuseIPDB" "$ABUSE_SCORE" "${ABUSE_SCORE}/100" "$lvl"
    fi
    if [[ -n "$PCHECK_SCORE" ]]; then
        local lvl="Low"; ((PCHECK_SCORE >= 33)) && lvl="Medium"; ((PCHECK_SCORE >= 66)) && lvl="High"
        draw_score_bar "ProxyCheck.io" "$PCHECK_SCORE" "${PCHECK_SCORE}/100" "$lvl"
    fi
    if [[ -n "$IPAPI_PCT" ]]; then
        local bar_num
        bar_num=$(awk '{print int($1 * 15)}' <<<"$IPAPI_PCT")
        draw_score_bar "ipapi.is" "$bar_num" "${IPAPI_PCT}%" "${IPAPI_LVL:-Low}"
    fi
    if [[ -n "$IPREG_SCORE" ]]; then
        local lvl="Low"; ((IPREG_SCORE >= 25)) && lvl="Medium"; ((IPREG_SCORE >= 60)) && lvl="High"
        draw_score_bar "ipregistry.co" "$IPREG_SCORE" "${IPREG_SCORE}/100" "$lvl"
    fi
    if [[ -n "$IPDATA_SCORE" ]]; then
        local lvl="Low"; ((IPDATA_SCORE >= 25)) && lvl="Medium"; ((IPDATA_SCORE >= 60)) && lvl="High"
        draw_score_bar "ipdata.co" "$IPDATA_SCORE" "${IPDATA_SCORE}/100" "$lvl"
    fi
    if [[ -n "$DBIP_SCORE" ]]; then
        local lvl="Low"; ((DBIP_SCORE == 50)) && lvl="Medium"; ((DBIP_SCORE == 100)) && lvl="High"
        draw_score_bar "DB-IP" "$DBIP_SCORE" "${DBIP_SCORE}%" "$lvl"
    fi
    print_section_end

    # --- IV. Risk Factors Matrix (8 Sources) ---
    print_section "IV. Security & Risk Factors (8 Sources)"

    local col2_hdr="ipwho"
    local C_COL2="N/A" P_COL2="N/A" V_COL2="N/A" R_COL2="N/A" S_COL2="N/A" A_COL2="N/A" B_COL2="N/A"
    if jq -e 'has("is_proxy")' "$TMP_DIR/ipapi_is.json" &>/dev/null; then
        col2_hdr="ipapi"
        C_COL2=$(jq -r '.location.country_code // empty' "$TMP_DIR/ipapi_is.json" 2>/dev/null || true)
        P_COL2=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_proxy')
        V_COL2=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_vpn')
        R_COL2=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_tor')
        S_COL2=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_datacenter')
        A_COL2=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_abuser')
        B_COL2=$(jq_get "$TMP_DIR/ipapi_is.json" '.is_crawler')
    elif jq -e '.security | type == "object"' "$TMP_DIR/ipwhois.json" &>/dev/null; then
        col2_hdr="ipwho"
        C_COL2=$(jq -r '.country_code // empty' "$TMP_DIR/ipwhois.json" 2>/dev/null || true)
        P_COL2=$(jq_get "$TMP_DIR/ipwhois.json" '.security.proxy')
        V_COL2=$(jq_get "$TMP_DIR/ipwhois.json" '.security.vpn')
        R_COL2=$(jq_get "$TMP_DIR/ipwhois.json" '.security.tor')
        S_COL2=$(jq_get "$TMP_DIR/ipwhois.json" '.security.hosting')
    elif jq -e '.security | type == "object"' "$TMP_DIR/vpnapi.json" &>/dev/null; then
        col2_hdr="vpnapi"
        C_COL2=$(jq -r '.location.country_code // empty' "$TMP_DIR/vpnapi.json" 2>/dev/null || true)
        P_COL2=$(jq_get "$TMP_DIR/vpnapi.json" '.security.proxy')
        V_COL2=$(jq_get "$TMP_DIR/vpnapi.json" '.security.vpn')
        R_COL2=$(jq_get "$TMP_DIR/vpnapi.json" '.security.tor')
    fi

    print_rail; printf "${C_DIM}%-10s%-8s%-8s%-8s%-8s%-8s%-8s%-8s%-8s${C_RESET}\n" "Factor" "IP2Loc" "$col2_hdr" "ipreg" "ipquery" "Scamal" "ipdata" "PCheck" "ip-api"

    local C_I2L=$(jq -r '.country_code // empty' "$TMP_DIR/ip2location.json" 2>/dev/null || true)
    [[ -z "$C_I2L" || "$C_I2L" == "null" ]] && C_I2L=$(jq -r '.country_code // empty' "$TMP_DIR/ip2loc_direct.json" 2>/dev/null || true)
    local C_REG=$(jq -r '.location.country.code // empty' "$TMP_DIR/ipregistry.json" 2>/dev/null || true)
    local C_IPQ=$(jq -r '.location.country_code // empty' "$TMP_DIR/ipquery.json" 2>/dev/null || true)
    local C_SCM="$scm_cc"
    local C_IPD=$(jq -r '.country_code // empty' "$TMP_DIR/ipdata.json" 2>/dev/null || true)
    local C_PCK=$(jq -r --arg ip "$TARGET_IP" 'select(.status=="ok" or .status=="warning") | (.[$ip] // ([to_entries[] | select(.value | type == "object")][0].value // empty)) | .isocode // empty' "$TMP_DIR/proxycheck.json" 2>/dev/null || true)
    local C_IPA=$(jq -r 'select(.status=="success") | .countryCode // empty' "$TMP_DIR/ip_api.json" 2>/dev/null || true)

    print_rail; printf "${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "Country" \
        "$(fmt_reg "$C_I2L")" "$(fmt_reg "$C_COL2")" "$(fmt_reg "$C_REG")" "$(fmt_reg "$C_IPQ")" \
        "$(fmt_reg "$C_SCM")" "$(fmt_reg "$C_IPD")" "$(fmt_reg "$C_PCK")" "$(fmt_reg "$C_IPA")"

    local P_I2L=$(jq_get "$TMP_DIR/ip2location.json" '.is_proxy')
    [[ "$P_I2L" == "N/A" ]] && P_I2L=$(jq_get "$TMP_DIR/ip2loc_direct.json" '.is_proxy')
    local P_REG=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_proxy')
    local P_IPQ=$(jq_get "$TMP_DIR/ipquery.json" '.risk.is_proxy')
    local P_SCM="N/A"
    if [[ "$scm_pub_proxy" == "yes" || "$scm_web_proxy" == "yes" ]]; then
        P_SCM="Yes"
    elif [[ "$scm_pub_proxy" == "no" || "$scm_web_proxy" == "no" ]]; then
        P_SCM="No"
    fi
    local P_IPD=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_proxy')
    local P_PCK=$(jq -r --arg ip "$TARGET_IP" 'select(.status=="ok" or .status=="warning") | (.[$ip] // ([to_entries[] | select(.value | type == "object")][0].value // empty)) | .proxy // "N/A"' "$TMP_DIR/proxycheck.json" 2>/dev/null || true)
    [[ -z "$P_PCK" ]] && P_PCK="N/A"
    local P_IPA=$(jq_get "$TMP_DIR/ip_api.json" 'select(.status=="success") | .proxy')

    local pck_ok=0
    [[ "$P_PCK" != "N/A" || "$T_PCK_U" != "N/A" ]] && pck_ok=1

    print_rail; printf "${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "Proxy" \
        "$(fmt_bool "$P_I2L")" "$(fmt_bool "$P_COL2")" "$(fmt_bool "$P_REG")" "$(fmt_bool "$P_IPQ")" \
        "$(fmt_bool "$P_SCM")" "$(fmt_bool "$P_IPD")" "$(fmt_bool "$P_PCK")" "$(fmt_bool "$P_IPA")"

    local V_I2L=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_vpn')
    local V_REG=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_vpn')
    local V_IPQ=$(jq_get "$TMP_DIR/ipquery.json" '.risk.is_vpn')
    local V_SCM="${scm_vpn:-N/A}"
    local V_IPD=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_vpn')
    local V_PCK="N/A"
    if ((pck_ok == 1)); then
        [[ "${T_PCK_U^^}" == *VPN* ]] && V_PCK="Yes" || V_PCK="No"
    fi

    print_rail; printf "${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "VPN" \
        "$(fmt_bool "$V_I2L")" "$(fmt_bool "$V_COL2")" "$(fmt_bool "$V_REG")" "$(fmt_bool "$V_IPQ")" \
        "$(fmt_bool "$V_SCM")" "$(fmt_bool "$V_IPD")" "$(fmt_bool "$V_PCK")" "$(fmt_bool "N/A")"

    local R_I2L=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_tor')
    local R_REG=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_tor')
    local R_IPQ=$(jq_get "$TMP_DIR/ipquery.json" '.risk.is_tor')
    local R_SCM="${scm_tor:-N/A}"
    local R_IPD=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_tor')
    local R_PCK="N/A"
    if ((pck_ok == 1)); then
        [[ "${T_PCK_U^^}" == *TOR* ]] && R_PCK="Yes" || R_PCK="No"
    fi

    print_rail; printf "${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "Tor" \
        "$(fmt_bool "$R_I2L")" "$(fmt_bool "$R_COL2")" "$(fmt_bool "$R_REG")" "$(fmt_bool "$R_IPQ")" \
        "$(fmt_bool "$R_SCM")" "$(fmt_bool "$R_IPD")" "$(fmt_bool "$R_PCK")" "$(fmt_bool "N/A")"

    local S_I2L="N/A"
    if [[ "$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_data_center')" == "true" || "$T_I2L_U" =~ (DCH|hosting) ]]; then
        S_I2L="Yes"
    elif [[ "$T_I2L_U" != "N/A" ]]; then
        S_I2L="No"
    fi
    local S_REG=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_cloud_provider')
    local S_IPQ=$(jq_get "$TMP_DIR/ipquery.json" '.risk.is_datacenter')
    local S_SCM="N/A"
    if [[ "$scm_dc" == "yes" || "$scm_srv" == "yes" ]]; then
        S_SCM="Yes"
    elif [[ "$scm_srv" == "no" || "$scm_dc" == "no" ]]; then
        S_SCM="No"
    fi
    local S_IPD=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_datacenter')
    local S_PCK="N/A"
    if ((pck_ok == 1)); then
        [[ "${T_PCK_U^^}" =~ (HOSTING|DATACENTER) ]] && S_PCK="Yes" || S_PCK="No"
    fi
    local S_IPA=$(jq_get "$TMP_DIR/ip_api.json" 'select(.status=="success") | .hosting')

    print_rail; printf "${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "Server" \
        "$(fmt_bool "$S_I2L")" "$(fmt_bool "$S_COL2")" "$(fmt_bool "$S_REG")" "$(fmt_bool "$S_IPQ")" \
        "$(fmt_bool "$S_SCM")" "$(fmt_bool "$S_IPD")" "$(fmt_bool "$S_PCK")" "$(fmt_bool "$S_IPA")"

    local A_I2L=$(jq_get "$TMP_DIR/ip2location.json" '.proxy.is_spammer')
    local A_REG=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_abuser')
    local A_PQS=$(jq_get "$TMP_DIR/ipqs.json" '.recent_abuse')
    local A_SCM="N/A"
    if [[ "$scm_blk_ext" == "true" || "$scm_blk_list" == "yes" ]]; then
        A_SCM="Yes"
    elif [[ "$scm_blk_ext" == "false" || "$scm_blk_list" == "no" ]]; then
        A_SCM="No"
    fi
    local A_IPD=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_known_abuser')

    print_rail; printf "${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "Abuser" \
        "$(fmt_bool "$A_I2L")" "$(fmt_bool "$A_COL2")" "$(fmt_bool "$A_REG")" "$(fmt_bool "$A_PQS")" \
        "$(fmt_bool "$A_SCM")" "$(fmt_bool "$A_IPD")" "$(fmt_bool "N/A")" "$(fmt_bool "N/A")"

    local B_I2L=$(jq_get "$TMP_DIR/ip2location.json" 'if (.proxy | type) == "object" then ((.proxy.is_scanner // false) or (.proxy.is_web_crawler // false) or (.proxy.is_ai_crawler // false)) else empty end')
    local B_REG=$(jq_get "$TMP_DIR/ipregistry.json" '.security.is_attacker')
    local B_PQS=$(jq_get "$TMP_DIR/ipqs.json" '.bot_status')
    local B_SCM="${scm_bot:-N/A}"
    local B_IPD=$(jq_get "$TMP_DIR/ipdata.json" '.threat.is_threat')

    print_rail; printf "${C_CYAN}%-10s${C_RESET}%s%s%s%s%s%s%s%s\n" "Robot" \
        "$(fmt_bool "$B_I2L")" "$(fmt_bool "$B_COL2")" "$(fmt_bool "$B_REG")" "$(fmt_bool "$B_PQS")" \
        "$(fmt_bool "$B_SCM")" "$(fmt_bool "$B_IPD")" "$(fmt_bool "N/A")" "$(fmt_bool "N/A")"
    print_section_end

    # --- V. Streaming, AI & Web Accessibility ---
    if ((IS_LOCAL_IP == 1)); then
        print_section "V. Streaming, AI & Web Accessibility (${IPV_LABEL})"

        IFS='|' read -r s_tt r_tt t_tt <<<"$(cat "$TMP_DIR/srv_tiktok" 2>/dev/null || true)"
        IFS='|' read -r s_dp r_dp t_dp <<<"$(cat "$TMP_DIR/srv_disney" 2>/dev/null || true)"
        IFS='|' read -r s_nf r_nf t_nf <<<"$(cat "$TMP_DIR/srv_netflix" 2>/dev/null || true)"
        IFS='|' read -r s_yt r_yt t_yt <<<"$(cat "$TMP_DIR/srv_youtube" 2>/dev/null || true)"
        IFS='|' read -r s_sp r_sp t_sp <<<"$(cat "$TMP_DIR/srv_spotify" 2>/dev/null || true)"
        IFS='|' read -r s_tw r_tw t_tw <<<"$(cat "$TMP_DIR/srv_twitch" 2>/dev/null || true)"

        print_rail; printf "${C_CYAN}%-11s${C_RESET}%-11s%-11s%-11s%-11s%-11s%-11s\n" "Streaming:" "TikTok" "Disney+" "Netflix" "YouTube" "Spotify" "Twitch"
        print_rail; printf "${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Status:" \
            "$(fmt_srv_status "$s_tt")" "$(fmt_srv_status "$s_dp")" "$(fmt_srv_status "$s_nf")" \
            "$(fmt_srv_status "$s_yt")" "$(fmt_srv_status "$s_sp")" "$(fmt_srv_status "$s_tw")"
        print_rail; printf "${C_CYAN}%-11s${C_RESET} %-9s  %-9s  %-9s  %-9s  %-9s  %-9s\n" "Region:" \
            "[${r_tt:-N/A}]" "[${r_dp:-N/A}]" "[${r_nf:-N/A}]" "[${r_yt:-N/A}]" "[${r_sp:-N/A}]" "[${r_tw:-N/A}]"
        print_rail; printf "${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Type:" \
            "$(fmt_srv_type "$t_tt")" "$(fmt_srv_type "$t_dp")" "$(fmt_srv_type "$t_nf")" \
            "$(fmt_srv_type "$t_yt")" "$(fmt_srv_type "$t_sp")" "$(fmt_srv_type "$t_tw")"

        print_rail; printf '\n'
        IFS='|' read -r s_oa r_oa t_oa <<<"$(cat "$TMP_DIR/ai_chatgpt" 2>/dev/null || true)"
        IFS='|' read -r s_gm r_gm t_gm <<<"$(cat "$TMP_DIR/ai_gemini" 2>/dev/null || true)"
        IFS='|' read -r s_cl r_cl t_cl <<<"$(cat "$TMP_DIR/ai_claude" 2>/dev/null || true)"
        IFS='|' read -r s_cp r_cp t_cp <<<"$(cat "$TMP_DIR/ai_copilot" 2>/dev/null || true)"
        IFS='|' read -r s_cf r_cf t_cf <<<"$(cat "$TMP_DIR/cdn_cf" 2>/dev/null || true)"
        IFS='|' read -r s_gs r_gs t_gs <<<"$(cat "$TMP_DIR/cdn_google" 2>/dev/null || true)"

        print_rail; printf "${C_CYAN}%-11s${C_RESET}%-11s%-11s%-11s%-11s%-11s%-11s\n" "AI / Web:" "ChatGPT" "Gemini" "Claude" "xAI Grok" "Cloudflare" "Google"
        print_rail; printf "${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Status:" \
            "$(fmt_srv_status "$s_oa")" "$(fmt_srv_status "$s_gm")" "$(fmt_srv_status "$s_cl")" \
            "$(fmt_srv_status "$s_cp")" "$(fmt_srv_status "$s_cf")" "$(fmt_srv_status "$s_gs")"
        print_rail; printf "${C_CYAN}%-11s${C_RESET} %-9s  %-9s  %-9s  %-9s  %-9s  %-9s\n" "Region:" \
            "[${r_oa:-N/A}]" "[${r_gm:-N/A}]" "[${r_cl:-N/A}]" "[${r_cp:-N/A}]" "[${r_cf:-N/A}]" "[${r_gs:-N/A}]"
        print_rail; printf "${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Detail:" \
            "$(fmt_srv_type "$t_oa")" "$(fmt_srv_type "$t_gm")" "$(fmt_srv_type "$t_cl")" \
            "$(fmt_srv_type "$t_cp")" "$(fmt_srv_type "$t_cf")" "$(fmt_srv_type "$t_gs")"

        print_rail; printf '\n'
        IFS='|' read -r s_rd r_rd t_rd <<<"$(cat "$TMP_DIR/ext_reddit" 2>/dev/null || true)"
        IFS='|' read -r s_wk r_wk t_wk <<<"$(cat "$TMP_DIR/ext_wiki" 2>/dev/null || true)"
        IFS='|' read -r s_st r_st t_st <<<"$(cat "$TMP_DIR/ext_steam" 2>/dev/null || true)"
        IFS='|' read -r s_ig r_ig t_ig <<<"$(cat "$TMP_DIR/ext_insta" 2>/dev/null || true)"
        IFS='|' read -r s_gh r_gh t_gh <<<"$(cat "$TMP_DIR/ext_github" 2>/dev/null || true)"
        IFS='|' read -r s_tg r_tg t_tg <<<"$(cat "$TMP_DIR/ext_telegram" 2>/dev/null || true)"

        print_rail; printf "${C_CYAN}%-11s${C_RESET}%-11s%-11s%-11s%-11s%-11s%-11s\n" "Platforms:" "Reddit" "Wikipedia" "Steam" "Instagram" "GitHub" "Telegram"
        print_rail; printf "${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Status:" \
            "$(fmt_srv_status "$s_rd")" "$(fmt_srv_status "$s_wk")" "$(fmt_srv_status "$s_st")" \
            "$(fmt_srv_status "$s_ig")" "$(fmt_srv_status "$s_gh")" "$(fmt_srv_status "$s_tg")"
        print_rail; printf "${C_CYAN}%-11s${C_RESET} %-9s  %-9s  %-9s  %-9s  %-9s  %-9s\n" "Quota/Reg:" \
            "[${r_rd:-N/A}]" "[${r_wk:-N/A}]" "[${r_st:-N/A}]" "[${r_ig:-N/A}]" "[${r_gh:-N/A}]" "[${r_tg:-N/A}]"
        print_rail; printf "${C_CYAN}%-11s${C_RESET}%s %s %s %s %s %s\n" "Access:" \
            "$(fmt_srv_type "$t_rd")" "$(fmt_srv_type "$t_wk")" "$(fmt_srv_type "$t_st")" \
            "$(fmt_srv_type "$t_ig")" "$(fmt_srv_type "$t_gh")" "$(fmt_srv_type "$t_tg")"
        print_section_end

        # --- VI. CDN Anycast Edge Nodes ---
        print_section "VI. CDN Edge Nodes (${IPV_LABEL})"
        IFS='|' read -r cf_cc cf_node <<<"$(cat "$TMP_DIR/cdn_cloudflare" 2>/dev/null || echo "-|-")"
        IFS='|' read -r yt_cc yt_node <<<"$(cat "$TMP_DIR/cdn_youtube" 2>/dev/null || echo "-|-")"
        IFS='|' read -r nf_cc nf_node <<<"$(cat "$TMP_DIR/cdn_netflix" 2>/dev/null || echo "-|-")"
        IFS='|' read -r fs_cc fs_node <<<"$(cat "$TMP_DIR/cdn_fastly" 2>/dev/null || echo "-|-")"
        IFS='|' read -r aw_cc aw_node <<<"$(cat "$TMP_DIR/cdn_cloudfront" 2>/dev/null || echo "-|-")"

        print_rail; printf "${C_CYAN}%-18s${C_RESET}[%s] %s\n" "Cloudflare Edge:" "${cf_cc:--}" "${cf_node:--}"
        print_rail; printf "${C_CYAN}%-18s${C_RESET}[%s] %s\n" "YouTube (GGC):" "${yt_cc:--}" "${yt_node:--}"
        print_rail; printf "${C_CYAN}%-18s${C_RESET}[%s] %s\n" "Netflix (OCA):" "${nf_cc:--}" "${nf_node:--}"
        print_rail; printf "${C_CYAN}%-18s${C_RESET}[%s] %s\n" "Fastly POP:" "${fs_cc:--}" "${fs_node:--}"
        print_rail; printf "${C_CYAN}%-18s${C_RESET}[%s] %s\n" "CloudFront POP:" "${aw_cc:--}" "${aw_node:--}"
        print_section_end
    fi

    # --- VII. Email Connectivity & DNSBL ---
    print_section "VII. Email Connectivity & DNSBL (${IPV_LABEL})"
    if ((IS_LOCAL_IP == 1)); then
        local p25_st
        p25_st=$(cat "$TMP_DIR/p25_local" 2>/dev/null || true)
        if [[ "$p25_st" == "Open" ]]; then
            print_rail; printf "${C_CYAN}%-18s${C_RESET}${C_GREEN}${C_BOLD}Open (Outbound SMTP Allowed)${C_RESET}\n" "Local Port 25:"
        else
            print_rail; printf "${C_CYAN}%-18s${C_RESET}${C_RED}${C_BOLD}Blocked by ISP/Hosting${C_RESET}\n" "Local Port 25:"
        fi

        local m_line=""
        for m_name in Gmail Outlook Yahoo Apple Proton Yandex Mail.ru Zoho; do
            local mst
            mst=$(cat "$TMP_DIR/mail_${m_name}" 2>/dev/null || true)
            case "$mst" in
                Yes)    m_line+="${m_name}:${C_GREEN}✔${C_RESET}  " ;;
                NoIPv6) m_line+="${m_name}:${C_DIM}-${C_RESET}  " ;;
                *)      m_line+="${m_name}:${C_RED}✘${C_RESET}  " ;;
            esac
        done
        print_rail; printf "${C_CYAN}%-18s${C_RESET}%b\n" "MX Reachability:" "$m_line"
    fi

    local listed_files=("$TMP_DIR/rbl/"*)
    local listed_count=0
    local listed_names=()
    if [[ -e "${listed_files[0]}" ]]; then
        listed_count=${#listed_files[@]}
        for f in "${listed_files[@]}"; do
            listed_names+=("$(<"$f")")
        done
    fi
    local clean_count=$((RBL_TOTAL - listed_count))

    if ((listed_count == 0)); then
        print_rail; printf "${C_CYAN}%-18s${C_RESET}${C_GREEN}${C_BOLD}Clean (${clean_count}/${RBL_TOTAL}) · Blacklisted: 0${C_RESET}\n" "DNSBL Status:"
    else
        print_rail; printf "${C_CYAN}%-18s${C_RESET}${C_RED}${C_BOLD}Listed in ${listed_count}/${RBL_TOTAL}: ${listed_names[*]}${C_RESET}\n" "DNSBL Status:"
    fi
    print_section_end

    # --- VIII. Server Network & Routing Telemetry ---
    if ((IS_LOCAL_IP == 1)); then
        print_section "VIII. Server Network & Routing Telemetry (${IPV_LABEL})"
        local nat_txt="${C_YELLOW}Behind NAT / Masqueraded${C_RESET}"
        if command -v ip &>/dev/null && ip addr show 2>/dev/null | grep -Fq "$TARGET_IP"; then
            nat_txt="${C_GREEN}Direct / Routed Public IP${C_RESET}"
        fi
        print_rail; printf "${C_CYAN}%-18s${C_RESET}%b\n" "Interface & NAT:" "$nat_txt"

        local virt_type="Bare Metal"
        if command -v systemd-detect-virt &>/dev/null; then
            virt_type=$(systemd-detect-virt 2>/dev/null || true)
        fi
        [[ -z "$virt_type" || "$virt_type" == "none" ]] && virt_type="Bare Metal"
        local kern_ver tcp_cc tcp_qd tcp_badge
        kern_ver=$(uname -r 2>/dev/null | cut -d'-' -f1-2)
        tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "unknown")
        tcp_qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "pfifo")
        if [[ "$tcp_cc" == *bbr* ]]; then
            tcp_badge="${C_GREEN}✔ ${tcp_cc} + ${tcp_qd}${C_RESET}"
        else
            tcp_badge="${C_YELLOW}○ ${tcp_cc} + ${tcp_qd} (Tip: enable BBR)${C_RESET}"
        fi
        print_rail; printf "${C_CYAN}%-18s${C_RESET}${C_WHITE}%s${C_RESET} ${C_DIM}· Kernel %s · TCP:${C_RESET} %b\n" "Host Stack:" "${virt_type^^}" "$kern_ver" "$tcp_badge"

        if [[ -s "$TMP_DIR/edns_info" ]]; then
            IFS='|' read -r edns_ip edns_geo <<<"$(<"$TMP_DIR/edns_info")"
            local disp_edns="$edns_ip"
            [[ "$MASK_IP" == true && "$disp_edns" == *"."* ]] && disp_edns="${disp_edns%.*.*}.*.*"
            print_rail; printf "${C_CYAN}%-18s${C_RESET}%s ${C_DIM}(%s)${C_RESET}\n" "Outbound DNS:" "$disp_edns" "$edns_geo"
        fi

        local rtt_cf rtt_gg rtt_q9
        rtt_cf=$(cat "$TMP_DIR/rtt_cf" 2>/dev/null || echo "N/A")
        rtt_gg=$(cat "$TMP_DIR/rtt_gg" 2>/dev/null || echo "N/A")
        rtt_q9=$(cat "$TMP_DIR/rtt_q9" 2>/dev/null || echo "N/A")
        print_rail; printf "${C_CYAN}%-18s${C_RESET}Cloudflare: ${C_WHITE}%s${C_RESET}  ${C_DIM}·${C_RESET}  Google: ${C_WHITE}%s${C_RESET}  ${C_DIM}·${C_RESET}  Quad9: ${C_WHITE}%s${C_RESET}\n" "Anycast RTT:" "$rtt_cf" "$rtt_gg" "$rtt_q9"
        print_section_end
    fi

    # --- Overall IP Quality Verdict Card ---
    local score_sum=0 score_cnt=0 s_val
    for s_val in "$SCAM_SCORE" "$IPQS_SCORE" "$IPQ_SCORE" "$I2L_SCORE" "$ABUSE_SCORE" "$PCHECK_SCORE" "$IPREG_SCORE" "$IPDATA_SCORE"; do
        if [[ "$s_val" =~ ^[0-9]+$ ]]; then
            score_sum=$((score_sum + s_val))
            score_cnt=$((score_cnt + 1))
        fi
    done

    if ((score_cnt == 0)); then
        printf '\n'
        printf ' %s╭──────────────────────────────────────────────────────────────────────────────╮%s\n' "$C_BORDER" "$C_RESET"
        printf ' %s│%s  %s  %sTrust Score: N/A%s  %s·  No risk engines responded%s\n' \
            "$C_BORDER" "$C_RESET" "${BG_GRAY}  GRADE N/A  ${C_RESET}" \
            "$C_WHITE" "$C_RESET" "$C_DIM" "$C_RESET"
        printf ' %s│%s  %sVerdict:%s Unable to compute verdict (database queries timed out or failed)\n' "$C_BORDER" "$C_RESET" "$C_CYAN" "$C_RESET"
        printf ' %s╰──────────────────────────────────────────────────────────────────────────────╯%s\n' "$C_BORDER" "$C_RESET"
        return
    fi

    local avg_risk=$((score_sum / score_cnt))
    local trust_score=$((100 - avg_risk - listed_count * 6))
    ((trust_score < 0)) && trust_score=0
    ((trust_score > 100)) && trust_score=100

    local grade="A+" grade_pill="$BG_GREEN" verdict_summary="Pristine IP reputation · Ideal for VPN, AI, Streaming & Production"
    if ((trust_score < 35)); then
        grade="F"; grade_pill="$BG_RED"; verdict_summary="High abuse/fraud flags · Expect frequent CAPTCHAs & blocks"
    elif ((trust_score < 55)); then
        grade="D"; grade_pill="$BG_RED"; verdict_summary="Elevated fraud score · May face restrictions on strict platforms"
    elif ((trust_score < 72)); then
        grade="C"; grade_pill="$BG_YELLOW"; verdict_summary="Moderate reputation (Typical shared datacenter/hosting subnet)"
    elif ((trust_score < 85)); then
        grade="B"; grade_pill="$BG_BLUE"; verdict_summary="Good reputation · Suitable for general proxy, web & API workloads"
    elif ((trust_score < 94)); then
        grade="A"; grade_pill="$BG_GREEN"; verdict_summary="Clean IP reputation · Great for daily browsing, AI & services"
    fi

    printf '\n'
    printf ' %s╭──────────────────────────────────────────────────────────────────────────────╮%s\n' "$C_BORDER" "$C_RESET"
    printf ' %s│%s  %s  %sTrust Score: %3d/100%s  %s·  Avg Fraud Risk: %2d%%%s\n' \
        "$C_BORDER" "$C_RESET" "${grade_pill}  GRADE ${grade}  ${C_RESET}" \
        "$C_WHITE" "$trust_score" "$C_RESET" "$C_DIM" "$avg_risk" "$C_RESET"
    printf ' %s│%s  %sVerdict:%s %s\n' "$C_BORDER" "$C_RESET" "$C_CYAN" "$C_RESET" "$verdict_summary"
    printf ' %s╰──────────────────────────────────────────────────────────────────────────────╯%s\n' "$C_BORDER" "$C_RESET"
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================
check_deps

DB_CURL_FLAG=""
IPV4_ADDR=""
IPV6_ADDR=""

# Probe IPv4 reachability & public IPs + pre-fetch MaxMind Demo Token cleanly
(
    if [[ -z "$CUSTOM_IP" ]]; then
        if [[ "$STACK_MODE" == "dual" || "$STACK_MODE" == "4" ]]; then
            detect_public_ip -4 > "$BASE_TMP/ipv4_addr" 2>/dev/null || true
        fi
        if [[ "$STACK_MODE" == "dual" || "$STACK_MODE" == "6" ]]; then
            detect_public_ip -6 > "$BASE_TMP/ipv6_addr" 2>/dev/null || true
        fi
    fi

    probe4_flag=""
    if curl -s4 --connect-timeout 3 -m 5 -o /dev/null "https://stat.ripe.net/data/prefix-overview/data.json?resource=1.1.1.1" 2>/dev/null; then
        probe4_flag="-4"
        echo "-4" > "$BASE_TMP/db_curl_flag"
        DB_CURL_FLAG="-4"
    fi

    ensure_maxmind_token || true
) &
wait_with_spinner "Initializing session"

[[ -s "$BASE_TMP/db_curl_flag" ]] && DB_CURL_FLAG=$(<"$BASE_TMP/db_curl_flag")
[[ -s "$BASE_TMP/ipv4_addr" ]] && IPV4_ADDR=$(<"$BASE_TMP/ipv4_addr")
[[ -s "$BASE_TMP/ipv6_addr" ]] && IPV6_ADDR=$(<"$BASE_TMP/ipv6_addr")

run_all_checks() {
    if [[ -n "$CUSTOM_IP" ]]; then
        if [[ "$CUSTOM_IP" == *":"* ]]; then
            run_check_for_stack "-6" "IPv6" "$CUSTOM_IP" 0
        else
            run_check_for_stack "-4" "IPv4" "$CUSTOM_IP" 0
        fi
    else
        if [[ -z "$IPV4_ADDR" && -z "$IPV6_ADDR" ]]; then
            printf '%s[✗]%s Could not detect public IPv4 or IPv6 address.\n' "$C_RED" "$C_RESET" >&2
            exit 1
        fi

        [[ -n "$IPV4_ADDR" ]] && run_check_for_stack "-4" "IPv4" "$IPV4_ADDR" 1
        [[ -n "$IPV6_ADDR" ]] && run_check_for_stack "-6" "IPv6" "$IPV6_ADDR" 1
    fi
    printf '\n'
}

if [[ -n "$OUTPUT_FILE" ]]; then
    exec 3>&1
    run_all_checks | (tee /dev/fd/3 | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g' > "$OUTPUT_FILE")
    exec 3>&-
else
    run_all_checks
fi
