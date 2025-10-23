#!/bin/sh

#
# Dev: garett09
# version: 3.7 (Self-Archiving, Integrated Totals)
# (with "Top Users" archive logic by Gemini)
# Patched for 64-bit overflow, formatting, and TB/PB by Gemini
#

# --- Database Paths ---
LIVE_DB_FILE="/jffs/.sys/TrafficAnalyzer/TrafficAnalyzer.db"
ARCHIVE_DB_FILE="/jffs/scripts/user_archive.db" # Our new, permanent database

# --- Helper Functions ---

# Function to format uptime
format_uptime() {
    uptime | sed 's/.*up \([^,]*\), .*/\1/'
}

# Function to convert vnstat usage (from your script)
convert_usage() {
    local value=$1
    local unit=$2
    case $unit in
        GiB) echo "$(awk "BEGIN {printf \"%.2f\", $value * 1.07374}") GB" ;;
        MiB) echo "$(awk "BEGIN {printf \"%.2f\", $value * 1.04858}") MB" ;;
        TiB) echo "$(awk "BEGIN {printf \"%.2f\", $value * 1.09951}") TB" ;;
        PiB) echo "$(awk "BEGIN {printf \"%.2f\", $value * 1.12590}") PB" ;;
        *) echo "$value $unit" ;;
    esac
}

# --- START FIXED FUNCTION (64-bit safe + TB/PB) ---
# Function to convert BYTES to human-readable format
bytes_to_human() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then
        echo "0.00 KB"
        return
    fi
    # Use awk for 64-bit number handling
    awk -v b="$bytes" '
        BEGIN {
            if (b > 1125899906842624) { printf "%.2f PB", b/1125899906842624 } # 2^50
            else if (b > 1099511627776) { printf "%.2f TB", b/1099511627776 }  # 2^40
            else if (b > 1073741824) { printf "%.2f GB", b/1073741824 } # 2^30
            else if (b > 1048576) { printf "%.2f MB", b/1048576 }   # 2^20
            else { printf "%.2f KB", b/1024 }                 # 2^10
        }'
}
# --- END FIXED FUNCTION ---

# Function to extract a clean MAC from a string
extract_mac() {
    local raw_data=$1
    echo "$raw_data" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -n 1
}

# Function to get client name (Accepts lease names as best effort)
get_client_name() {
    local raw_data=$1
    local clean_mac=$2
    local name=""
    local found_in_custom=0 # Flag

    # 1. Try nvram custom_clientlist first (Often fails parsing)
    local clientlist_entry=$(nvram get custom_clientlist | tr '>' '\n' | grep -i "<${clean_mac}")
    if [ -n "$clientlist_entry" ]; then
        name=$(echo "$clientlist_entry" | awk -F'<' '{print $1}')
        # Minimal trim
        name=$(echo "$name" | sed 's/^[ \t]*//;s/[ \t]*$//')
        if [ -n "$name" ]; then
            found_in_custom=1
            echo "$name" # Return name if found and not empty
            return
        fi
    fi

    # --- Fallbacks ---

    # 2. Try Static DHCP list
    if [ "$found_in_custom" -eq 0 ]; then
        name=$(nvram get dhcp_staticlist | tr '>' '\n' | grep -i "$clean_mac" | awk -F'<' '{print $3}' | head -n 1)
        if [ -n "$name" ] && [ "$name" != "*" ]; then
             name=$(echo "$name" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim
             echo "$name"
             return
        else
            name="" # Reset name
        fi
    fi

    # 3. Try Active DHCP lease list (This is where names are being found)
     if [ -z "$name" ] || [ "$name" == "*" ]; then
        name=$(grep -i "$clean_mac" /var/lib/misc/dnsmasq.leases | awk '{print $4}' | head -n 1)
         if [ -n "$name" ] && [ "$name" != "*" ]; then
             name=$(echo "$name" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim
             echo "$name"
             return
        else
            name="" # Reset name
        fi
    fi

    # 4. Try parsing the raw DB entry (Less reliable fallback)
     if [ -z "$name" ] || [ "$name" == "*" ]; then
        if echo "$raw_data" | grep -q '>'; then
             parsed_name=$(echo "$raw_data" | awk -F'>' '{print $1}')
             if [ -n "$parsed_name" ] && [ "$parsed_name" != "$clean_mac" ]; then
                 name="$parsed_name"
                 name=$(echo "$name" | sed 's/^[ \t]*//;s/[ \t]*$//') # Trim
                 echo "$name"
                 return
             fi
        fi
    fi

    # 5. If all else fails, use the clean MAC
    echo "$clean_mac"
}


# --- Function to create our archive DB if it doesn't exist ---
init_archive_db() {
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        echo "Creating new user archive database..."
        sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS daily_usage (mac TEXT, name TEXT, date TEXT, total_bytes INTEGER, PRIMARY KEY(mac, date));"
    fi
}

# --- START FIXED FUNCTION (64-bit safe) ---
# --- Function to save today's data into our archive ---
archive_daily_data() {
    local today_date=$(date +%Y-%m-%d)
    local midnight_today=$(date -d "00:00:00" +%s)

    # Let SQL do the 64-bit math
    sqlite3 -separator ',' "$LIVE_DB_FILE" \
        "SELECT mac, SUM(rx) + SUM(tx) AS total
         FROM traffic
         WHERE timestamp >= $midnight_today
         GROUP BY mac" | \
    while IFS=',' read -r db_entry total_bytes; do
        clean_mac=$(extract_mac "$db_entry")
        if [ -z "$clean_mac" ]; then
            continue
        fi
        client_name=$(get_client_name "$db_entry" "$clean_mac")
        # total_bytes=$((rx_bytes + tx_bytes)) # <-- BUGGY LINE REMOVED
        # Ensure name doesn't contain single quotes which break SQL
        safe_client_name=$(echo "$client_name" | sed "s/'/''/g")

        sqlite3 "$ARCHIVE_DB_FILE" "INSERT OR REPLACE INTO daily_usage (mac, name, date, total_bytes)
                                    VALUES ('$clean_mac', '$safe_client_name', '$today_date', $total_bytes);"
    done
}
# --- END FIXED FUNCTION ---

# --- START FIXED FUNCTION (64-bit safe) ---
# --- Function to calculate TOTAL usage from databases ---
calculate_total_usage() {
    local db_path="$1"
    local table_name="$2" # 'traffic' for live, 'daily_usage' for archive
    local bytes_col_rx="$3" # 'rx' or 'total_bytes'
    local bytes_col_tx="$4" # 'tx' or empty string
    local where_clause="$6"
    local total_bytes=0

    # Construct the SELECT part based on columns provided
    local select_cols="SUM($bytes_col_rx)"
    if [ -n "$bytes_col_tx" ]; then
        select_cols="$select_cols + SUM($bytes_col_tx)"
    fi

    # Run the query
    query_result=$(sqlite3 "$db_path" \
        "SELECT $select_cols
         FROM $table_name
         $where_clause")

    # 64-bit safe check
    if [ -z "$query_result" ]; then
         total_bytes=0
    else
         total_bytes=$query_result
    fi

    bytes_to_human $total_bytes
}
# --- END FIXED FUNCTION ---


# --- START FIXED FUNCTION (64-bit safe + formatting) ---
# --- *** UPDATED: Function to build lists & add TOTALS (Live DB) *** ---
build_top_users_from_live_db() {
    local title="$1"
    local where_clause="$2"
    local __result_var=$3
    local list_output="<b>$title</b>"

    # Let SQL do the 64-bit math
    query_result=$(sqlite3 -separator ',' "$LIVE_DB_FILE" \
        "SELECT mac, SUM(rx) + SUM(tx) AS total
         FROM traffic
         $where_clause
         GROUP BY mac
         ORDER BY total DESC
         LIMIT 5")

    if [ -z "$query_result" ]; then
        list_output=$(printf "%s\n<i>No data for this period.</i>" "$list_output")
    else
        while IFS=',' read -r db_entry total_bytes; do
            clean_mac=$(extract_mac "$db_entry")
            client_name=$(get_client_name "$db_entry" "$clean_mac")
            # total_bytes=$((rx_bytes + tx_bytes)) # <-- BUGGY LINE REMOVED
            total_human=$(bytes_to_human $total_bytes)
            # Use printf for correct newlines
            list_output=$(printf "%s\n- %s: %s" "$list_output" "$client_name" "$total_human")
        done <<EOF
$query_result
EOF
        # *** ADD TOTAL ***
        local total_for_period=$(calculate_total_usage "$LIVE_DB_FILE" "traffic" "rx" "tx" "$where_clause")
        # Use printf for correct newlines
        list_output=$(printf "%s\n<b>Total: %s</b>" "$list_output" "$total_for_period")
    fi
    eval $__result_var="'$list_output'"
}
# --- END FIXED FUNCTION ---

# --- START FIXED FUNCTION (Formatting) ---
# --- *** UPDATED: Function to build lists & add TOTALS (Archive DB) *** ---
build_top_users_from_archive_db() {
    local title="$1"
    local where_clause="$2"
    local __result_var=$3
    local list_output="<b>$title</b>"

    query_result=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT name, SUM(total_bytes)
         FROM daily_usage
         $where_clause
         GROUP BY mac, name
         ORDER BY SUM(total_bytes) DESC
         LIMIT 5")

    if [ -z "$query_result" ]; then
        list_output=$(printf "%s\n<i>No archived data yet.</i>" "$list_output")
    else
        while IFS=',' read -r client_name total_bytes; do
             # Ensure name doesn't contain single quotes before printing
            safe_client_name=$(echo "$client_name" | sed "s/'/''/g")
            total_human=$(bytes_to_human $total_bytes)
            # Use printf for correct newlines
            list_output=$(printf "%s\n- %s: %s" "$list_output" "$safe_client_name" "$total_human")
        done <<EOF
$query_result
EOF
        # *** ADD TOTAL ***
        local total_for_period=$(calculate_total_usage "$ARCHIVE_DB_FILE" "daily_usage" "total_bytes" "" "$where_clause")
        # Use printf for correct newlines
        list_output=$(printf "%s\n<b>Total: %s</b>" "$list_output" "$total_for_period")
    fi
    eval $__result_var="'$list_output'"
}
# --- END FIXED FUNCTION ---

# --- Main Variable Setup ---
# (Removed unset list for brevity - assumed handled)

IP_WAN0=$(nvram get wan0_ipaddr)
IP_LAN=$(nvram get lan_ipaddr)
FIRMWARE_VERSION=$(nvram get firmver).$(nvram get buildno)_$(nvram get extendno)
MODEL_NAME=$(nvram get wps_device_name)
SSID_5GHZ=$(nvram get wl1_ssid)
SSID_24GHZ=$(nvram get wl0_ssid)
SSID_5_1GHZ=$(nvram get wl2_ssid)
TEMP_CPU=$(cat /sys/class/thermal/thermal_zone0/temp | awk '{printf("%.0f\n", $1 / 1000) }')
IF_WIFI24=$(nvram get wl0_ifname)
IF_WIFI5=$(nvram get wl1_ifname)
IF_WIFI5_1=$(nvram get wl2_ifname)
TEMP_WIFI24=$(wl -i $IF_WIFI24 phy_tempsense | awk '{print $1 / 2 + 20}')
TEMP_WIFI5=$(wl -i $IF_WIFI5 phy_tempsense | awk '{print $1 / 2 + 20}')
TEMP_WIFI5_1GHZ=$(wl -i $IF_WIFI5_1 phy_tempsense | awk '{print $1 / 2 + 20}')
RAM_USED_PERCENTAGE=$(free | grep Mem | awk '{ printf("%.2f", $3/$2 * 100.0) }')
RAM_FREE_PERCENTAGE=$(free | grep Mem | awk '{ printf("%.2f", $4/$2 * 100.0) }')
SWAP_USED=$(free | grep Swap | awk '{ if ($2 > 0) { printf("%.2f", $3/$2 * 100.0) } else { print "0.00" } }')
FORMATTED_UPTIME=$(format_uptime)
LOAD_AVG=$(cat /proc/loadavg | awk '{printf "1 min: %.2f%% 5 mins: %.2f%% 15 mins: %.2f%%", $1, $2, $3}')

# Get data usage from vnStat
DAILY_USAGE=$(vnstat -i ppp0 -d --dbdir /opt/var/lib/vnstat | grep "$(date +'%Y-%m-%d')" | awk '{print $8, $9}')
MONTHLY_USAGE=$(vnstat -i ppp0 -m --dbdir /opt/var/lib/vnstat | grep "$(date +'%Y-%m')" | awk '{print $8, $9}')
YEARLY_USAGE=$(vnstat -i ppp0 -y --dbdir /opt/var/lib/vnstat | grep "$(date +'%Y')" | awk '{print $8, $9}')
LIFETIME_USAGE=$(vnstat -i ppp0 --dbdir /opt/var/lib/vnstat | grep "total:" | awk '{print $8, $9}')
DAILY_VALUE=$(echo $DAILY_USAGE | awk '{print $1}')
DAILY_UNIT=$(echo $DAILY_USAGE | awk '{print $2}')
MONTHLY_VALUE=$(echo $MONTHLY_USAGE | awk '{print $1}')
MONTHLY_UNIT=$(echo $MONTHLY_USAGE | awk '{print $2}')
YEARLY_VALUE=$(echo $YEARLY_USAGE | awk '{print $1}')
YEARLY_UNIT=$(echo $YEARLY_USAGE | awk '{print $2}')
LIFETIME_VALUE=$(echo $LIFETIME_USAGE | awk '{print $1}')
LIFETIME_UNIT=$(echo $LIFETIME_USAGE | awk '{print $2}')
DAILY_USAGE_DECIMAL=$(convert_usage $DAILY_VALUE $DAILY_UNIT)
MONTHLY_USAGE_DECIMAL=$(convert_usage $MONTHLY_VALUE $MONTHLY_UNIT)
YEARLY_USAGE_DECIMAL=$(convert_usage $YEARLY_VALUE $YEARLY_UNIT)
LIFETIME_USAGE_DECIMAL=$(convert_usage $LIFETIME_VALUE $LIFETIME_UNIT)

AVERAGE_PING=$(ping -c 10 1.1.1.1 | tail -n 1 | awk -F'/' '{print $5}')
SIGN_DATE=$(nvram get bwdpi_sig_ver)

# --- Generate Top Users Lists ---

if [ ! -f "$LIVE_DB_FILE" ]; then
    TOP_USERS_TODAY_LIST="<b>🏆 Top 5 Users (Today)</b>
<i>Traffic DB not found.</i>"
    TOP_USERS_MONTH_LIST="<b>📅 Top 5 Users (This Month)</b>
<i>Traffic DB not found.</i>"
    TOP_USERS_YEAR_LIST="<b>🗓️ Top 5 Users (This Year)</b>
<i>Traffic DB not found.</i>"
    TOP_USERS_LIFE_LIST="<b>🌍 Top 5 Users (Lifetime)</b>
<i>Traffic DB not found.</i>"
else
    # 1. Create/Check our archive DB
    init_archive_db

    # 2. Save today's latest data to our archive
    archive_daily_data

    # 3. Define Time Periods and Titles
    MIDNIGHT_TODAY=$(date -d "00:00:00" +%s)
    MIDNIGHT_MONTH=$(date -d "$(date +%Y-%m-01) 00:00:00" +%s)
    YEAR_START_DATE=$(date +%Y-01-01)

    TODAY_TITLE_DATE=$(date +"%b %d, %Y")
    MONTH_TITLE_DATE=$(date +"%B %Y")
    YEAR_TITLE_DATE=$(date +"%Y")

    # 4. Run queries (Functions now include totals)
    build_top_users_from_live_db "🏆 Top 5 Users ($TODAY_TITLE_DATE)" "WHERE timestamp >= $MIDNIGHT_TODAY" TOP_USERS_TODAY_LIST
    build_top_users_from_live_db "📅 Top 5 Users ($MONTH_TITLE_DATE)" "WHERE timestamp >= $MIDNIGHT_MONTH" TOP_USERS_MONTH_LIST
    build_top_users_from_archive_db "🗓️ Top 5 Users ($YEAR_TITLE_DATE)" "WHERE date >= '$YEAR_START_DATE'" TOP_USERS_YEAR_LIST
    build_top_users_from_archive_db "🌍 Top 5 Users (Lifetime)" "" TOP_USERS_LIFE_LIST
fi

## Telegram
TELEGRAM_AUTH="/jffs/telegram.env"
TOKEN=$(cat $TELEGRAM_AUTH | grep "TOKEN" | awk -F "=" '{print $2}')
CHATID=$(cat $TELEGRAM_AUTH | grep "CHAT_ID" | awk -F "=" '{print $2}')
API_TELEGRAM="https://api.telegram.org/bot$TOKEN/sendMessage?parse_mode=HTML"

DATE=$(date +"%I:%M %p, %B %d, %Y")
LIMIT_TEMP_CPU=73
unset BANNER

function sendMessage()
{
    TEXT=$(cat <<EOF
<b>$BANNER</b>

<b>📊 Status</b>
🌡️ WLAN 2.4 Temp: $TEMP_WIFI24º
🌡️ WLAN 5-1 Temp: $TEMP_WIFI5º
🌡️ WLAN 5-2 Temp: $TEMP_WIFI5_1GHZº
⏱️ Uptime: $FORMATTED_UPTIME
💻 Load Average: $LOAD_AVG
🧠 RAM Used: $RAM_USED_PERCENTAGE% / Free: $RAM_FREE_PERCENTAGE%
💾 Swap Used: $SWAP_USED%

<b>📅 Total Data Usage (vnStat)</b>
Daily Data Usage: $DAILY_USAGE_DECIMAL
Monthly Data Usage: $MONTHLY_USAGE_DECIMAL
Yearly Data Usage: $YEARLY_USAGE_DECIMAL
Lifetime Data Usage: $LIFETIME_USAGE_DECIMAL

<b>👤 Per-Device Usage (TrafficAnalyzer Archive)</b>
$TOP_USERS_TODAY_LIST

$TOP_USERS_MONTH_LIST

$TOP_USERS_YEAR_LIST

$TOP_USERS_LIFE_LIST

<b>📶 Ping</b>
Average Ping: $AVERAGE_PING

<b>📃 Info</b>
📶 Model: $MODEL_NAME
🛠️ Firmware: $FIRMWARE_VERSION
📡 SSID 2.4Ghz: $SSID_24GHZ
📡 SSID 5Ghz: $SSID_5GHZ
🕒 Trend Micro sign: $SIGN_DATE

🕒 Time of report: $DATE
EOF
)

    curl -s -X POST $API_TELEGRAM \
        -d chat_id=$CHATID \
        -d text="$TEXT" > /dev/null 2>&1
}

if [ "$TEMP_CPU" -gt "$LIMIT_TEMP_CPU" ]
then
    BANNER="🔥 $MODEL_NAME | CPU: $TEMP_CPUº 🔥"
    sendMessage
else
    BANNER="❄️ $MODEL_NAME | CPU: $TEMP_CPUº ❄️"
    sendMessage
fi
