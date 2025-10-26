#!/bin/sh

#
# Dev: garett09
# version: 8.0 (FINAL - Added Historical Label)
# - Added a clear header for the historical ConnMon section.
#

# --- Database Paths ---
LIVE_DB_FILE="/jffs/.sys/TrafficAnalyzer/TrafficAnalyzer.db"
ARCHIVE_DB_FILE="/jffs/scripts/user_archive.db"
CONMON_DB="/jffs/addons/connmon.d/connstats.db"
ALERT_LOG="/jffs/connmon_alerts.log" # Log file created by the separate alert script

# --- Helper Functions ---

# Function to format uptime
format_uptime() {
    # Read the total uptime in seconds from /proc/uptime
    local total_seconds=$(cat /proc/uptime | awk '{print $1}' | cut -d. -f1)
    
    local days=$(($total_seconds / 86400))
    local hours=$((($total_seconds % 86400) / 3600))
    local minutes=$((($total_seconds % 3600) / 60))
    local seconds=$(($total_seconds % 60))
    
    local output=""
    
    if [ "$days" -gt 0 ]; then
        output="${days}d ${hours}h ${minutes}m ${seconds}s"
    elif [ "$hours" -gt 0 ]; then
        output="${hours}h ${minutes}m ${seconds}s"
    elif [ "$minutes" -gt 0 ]; then
        output="${minutes}m ${seconds}s"
    else
        output="${seconds}s"
    fi
    
    echo "$output"
}

# Function to convert vnstat usage
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

# Function to convert BYTES to human-readable format
bytes_to_human() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ]; then
        echo "0.00 KB"
        return
    fi
    awk -v b="$bytes" '
        BEGIN {
            if (b > 1125899906842624) { printf "%.2f PB", b/1125899906842624 }
            else if (b > 1099511627776) { printf "%.2f TB", b/1099511627776 }
            else if (b > 1073741824) { printf "%.2f GB", b/1073741824 }
            else if (b > 1048576) { printf "%.2f MB", b/1048576 }
            else { printf "%.2f KB", b/1024 }
        }'
}

# Function to extract a clean MAC from a string
extract_mac() {
    local raw_data=$1
    echo "$raw_data" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -n 1
}

# Function to get client name (Sanitized for HTML)
get_client_name() {
    local raw_data=$1
    local clean_mac=$2
    local name=""
    local final_name=""

    local clientlist_entry=$(nvram get custom_clientlist | tr '>' '\n' | grep -i "<${clean_mac}")
    if [ -n "$clientlist_entry" ]; then
        name=$(echo "$clientlist_entry" | awk -F'<' '{print $1}')
        name=$(echo "$name" | sed 's/^[ \t]*//;s/[ \t]*$//')
        if [ -n "$name" ]; then final_name="$name"; fi
    fi
    if [ -z "$final_name" ]; then
        name=$(nvram get dhcp_staticlist | tr '>' '\n' | grep -i "$clean_mac" | awk -F'<' '{print $3}' | head -n 1)
        if [ -n "$name" ] && [ "$name" != "*" ]; then final_name=$(echo "$name" | sed 's/^[ \t]*//;s/[ \t]*$//'); fi
    fi
     if [ -z "$final_name" ]; then
        name=$(grep -i "$clean_mac" /var/lib/misc/dnsmasq.leases | awk '{print $4}' | head -n 1)
         if [ -n "$name" ] && [ "$name" != "*" ]; then final_name=$(echo "$name" | sed 's/^[ \t]*//;s/[ \t]*$//'); fi
    fi
     if [ -z "$final_name" ]; then
        if echo "$raw_data" | grep -q '>'; then
            parsed_name=$(echo "$raw_data" | awk -F'>' '{print $1}')
            if [ -n "$parsed_name" ] && [ "$parsed_name" != "$clean_mac" ]; then final_name=$(echo "$parsed_name" | sed 's/^[ \t]*//;s/[ \t]*$//'); fi
        fi
    fi
    if [ -z "$final_name" ]; then
        final_name="$clean_mac"
    fi

    echo "$final_name" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g'
}

# Function to create/ensure archive DB and tables exist
init_archive_db() {
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        echo "Creating new user archive database..."
    fi
    # Always ensure tables exist for immediate use
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS daily_usage (mac TEXT, name TEXT, date TEXT, total_bytes INTEGER, PRIMARY KEY(mac, date));"
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS connmon_history (date TEXT PRIMARY KEY, avg_ping REAL, avg_jitter REAL, avg_quality REAL);"
}

# Function to save daily data to archive
archive_daily_data() {
    local today_date=$(date +%Y-%m-%d)
    local midnight_today=$(date -d "00:00:00" +%s)

    # 1. Traffic Analyzer Archiving
    sqlite3 -separator ',' "$LIVE_DB_FILE" \
        "SELECT mac, SUM(rx) + SUM(tx) AS total
         FROM traffic
         WHERE timestamp >= $midnight_today
         GROUP BY mac" | \
    while IFS=',' read -r db_entry total_bytes; do
        clean_mac=$(extract_mac "$db_entry")
        if [ -z "$clean_mac" ]; then continue; fi
        client_name=$(get_client_name "$db_entry" "$clean_mac")
        safe_client_name=$(echo "$client_name" | sed "s/'/''/g") # Safe for SQL insert

        sqlite3 "$ARCHIVE_DB_FILE" "INSERT OR REPLACE INTO daily_usage (mac, name, date, total_bytes)
                                     VALUES ('$clean_mac', '$safe_client_name', '$today_date', $total_bytes);"
    done

    # 2. ConnMon History Archiving (Saves the day's average)
    local CONMON_TODAY_AVG=$(sqlite3 -separator ',' "$CONMON_DB" \
        "SELECT AVG(Ping), AVG(Jitter), AVG(LineQuality)
         FROM connstats
         WHERE Timestamp >= $midnight_today")

    if [ -n "$CONMON_TODAY_AVG" ] && [ "$CONMON_TODAY_AVG" != ",," ]; then
        local ping_avg=$(echo "$CONMON_TODAY_AVG" | cut -d, -f1)
        local jitter_avg=$(echo "$CONMON_TODAY_AVG" | cut -d, -f2)
        local quality_avg=$(echo "$CONMON_TODAY_AVG" | cut -d, -f3)

        # Check if ping_avg is a valid number before inserting
        if echo "$ping_avg" | grep -q '^[0-9.]*$'; then
             if [ -z "$ping_avg" ]; then ping_avg=0; fi
             if [ -z "$jitter_avg" ]; then jitter_avg=0; fi
             if [ -z "$quality_avg" ]; then quality_avg=0; fi

            sqlite3 "$ARCHIVE_DB_FILE" "INSERT OR REPLACE INTO connmon_history (date, avg_ping, avg_jitter, avg_quality)
                                         VALUES ('$today_date', $ping_avg, $jitter_avg, $quality_avg);"
        fi
    fi
}

# Function to build Top 5 Users list from Live DB
build_top_users_from_live_db() {
    local title="$1"
    local where_clause="$2"
    local __result_var=$3
    local list_output="<b>$title</b>"

    query_result=$(sqlite3 -separator ',' "$LIVE_DB_FILE" \
        "SELECT mac, SUM(rx) + SUM(tx) AS total
         FROM traffic $where_clause
         GROUP BY mac ORDER BY total DESC LIMIT 5")

    if [ -z "$query_result" ]; then
        list_output=$(printf "%s\n<i>No data for this period.</i>" "$list_output")
    else
        while IFS=',' read -r db_entry total_bytes; do
            clean_mac=$(extract_mac "$db_entry")
            client_name=$(get_client_name "$db_entry" "$clean_mac")
            total_human=$(bytes_to_human $total_bytes)
            list_output=$(printf "%s\n- %s: %s" "$list_output" "$client_name" "$total_human")
        done <<EOF
$query_result
EOF
        # Total line removed as requested
    fi
    eval $__result_var="'$list_output'"
}

# Function to build Top 5 Users list from Archive DB
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
            safe_client_name=$(echo "$client_name" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
            total_human=$(bytes_to_human $total_bytes)
            list_output=$(printf "%s\n- %s: %s" "$list_output" "$safe_client_name" "$total_human")
        done <<EOF
$query_result
EOF
        # Total line removed as requested
    fi
    eval $__result_var="'$list_output'"
}

# Function to get ConnMon Hourly Average
get_conmon_hourly_stats() {
    local db_file=$1
    if [ ! -f "$db_file" ]; then echo "N/A,N/A,N/A,N/A"; return; fi
    local end_of_last_hour_str=$(sqlite3 <<EOF
SELECT strftime('%Y-%m-%d %H:00:00', 'now', 'localtime');
EOF
)
    local start_of_last_hour_str=$(sqlite3 <<EOF
SELECT strftime('%Y-%m-%d %H:00:00', 'now', 'localtime', '-1 hour');
EOF
)
    local start_ts=$(date -d "$start_of_last_hour_str" +%s 2>/dev/null)
    local end_ts=$(date -d "$end_of_last_hour_str" +%s 2>/dev/null)
    if [ -z "$start_ts" ] || [ -z "$end_ts" ]; then echo "N/A,N/A,N/A,N/A"; return; fi
    local metrics_raw=$(sqlite3 -separator ',' "$db_file" \
        "SELECT AVG(Ping), AVG(Jitter), AVG(LineQuality)
         FROM connstats
         WHERE Timestamp >= $start_ts AND Timestamp < $end_ts")
    if [ -z "$metrics_raw" ] || [ "$metrics_raw" = ",," ]; then echo "N/A,N/A,N/A,N/A"; return; fi
    local report_time_start=$(date -d "@$start_ts" +"%H:%M")
    local report_time_end=$(date -d "@$end_ts" +"%H:%M")
    local report_time="${report_time_start} - ${report_time_end}"
    local ping_avg=$(echo "$metrics_raw" | cut -d, -f1)
    local jitter_avg=$(echo "$metrics_raw" | cut -d, -f2)
    local quality_avg=$(echo "$metrics_raw" | cut -d, -f3)
    printf "%s,%.2f,%.2f,%.2f" "$report_time" "$ping_avg" "$jitter_avg" "$quality_avg"
}

# Function to get ConnMon Historical Averages
get_connmon_history() {
    local period_sql="$1"
    local __result_var=$2
    local result_output="N/A ms | N/A ms | N/A %"

    local start_date=$(sqlite3 <<EOF
SELECT strftime('%Y-%m-%d', 'now', 'localtime', '$period_sql');
EOF
)

    local query_result=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT AVG(avg_ping), AVG(avg_jitter), AVG(avg_quality)
         FROM connmon_history
         WHERE date >= '$start_date'")

    # Check for empty result
    if [ -z "$query_result" ] || [ "$query_result" = ",," ]; then
        eval $__result_var="'$result_output'"
        return
    fi

    local avg_ping=$(echo "$query_result" | cut -d, -f1)
    local avg_jitter=$(echo "$query_result" | cut -d, -f2)
    local avg_quality=$(echo "$query_result" | cut -d, -f3)

    if [ -z "$avg_ping" ] && [ -z "$avg_jitter" ] && [ -z "$avg_quality" ]; then
        eval $__result_var="'$result_output'"
        return
    fi

    # Replace empty/null averages with 0 for formatting
    if [ -z "$avg_ping" ]; then avg_ping=0; fi
    if [ -z "$avg_jitter" ]; then avg_jitter=0; fi
    if [ -z "$avg_quality" ]; then avg_quality=0; fi

    avg_ping=$(printf "%.2f" "$avg_ping")
    avg_jitter=$(printf "%.2f" "$avg_jitter")
    avg_quality=$(printf "%.2f" "$avg_quality")

    result_output="${avg_ping} ms | ${avg_jitter} ms | ${avg_quality}%"

    eval $__result_var="'$result_output'"
}

# Function to get Recent Alerts Summary (Filters for Today)
get_recent_alerts_summary() {
    local log_file="$ALERT_LOG"
    local output=""
    
    # Set defaults
    ALERT_COUNT_TODAY=0
    
    local today_date_filter=$(date +"%Y-%m-%d")

    if [ ! -f "$log_file" ]; then
        output="No recent alert log found."
    else
        local todays_alerts=$(grep "^\[${today_date_filter}" "$log_file")
        local total_alerts=0 # Default to 0

        # --- FIX ---
        # Only count lines if the grep result is not empty
        if [ -n "$todays_alerts" ]; then
            total_alerts=$(echo "$todays_alerts" | wc -l)
        fi
        # --- END FIX ---

        if [ "$total_alerts" -eq 0 ]; then
            output="No ConnMon alerts were triggered today."
        else
            # Process today's alert lines
            local summary_list=$(echo "$todays_alerts" | awk -F'|' '{
                gsub(/\[|\]/,"", $1); 
                split($1, time_parts, " ");
                gsub(/ /,"", $2); 
                gsub(/^[ \t]+|[ \t]+$/, "", $3);
                gsub(/; /, ", ", $3); 
                printf " - %s (%s issues): %s\n", time_parts[2], $2, $3; 
            }' | sort -r | uniq)
            
            local unique_events=$(echo "$summary_list" | grep -c 'issues)') 

            if [ "$unique_events" -eq 0 ]; then
                 output="No valid alerts found for today (or log format issue)."
            else
                 output=$(printf "🚨 %d alert events triggered today:\n%s" "$unique_events" "$summary_list")
                 ALERT_COUNT_TODAY=$unique_events # Set global alert count
            fi
        fi
    fi
    # Set the global variable
    ALERT_SUMMARY_TEXT=$(echo "$output" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
}


# --- Main Logic Starts Here ---

# Initialize DB first
init_archive_db

# Sanitize text variables
IP_WAN0_RAW=$(nvram get wan0_ipaddr)
IP_LAN_RAW=$(nvram get lan_ipaddr)
FIRMWARE_VERSION_RAW=$(nvram get firmver).$(nvram get buildno)_$(nvram get extendno)
MODEL_NAME_RAW=$(nvram get wps_device_name)
SSID_5GHZ_RAW=$(nvram get wl1_ssid)
SSID_24GHZ_RAW=$(nvram get wl0_ssid)
SSID_5_1GHZ_RAW=$(nvram get wl2_ssid)
IP_WAN0=$(echo "$IP_WAN0_RAW" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
IP_LAN=$(echo "$IP_LAN_RAW" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
FIRMWARE_VERSION=$(echo "$FIRMWARE_VERSION_RAW" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
MODEL_NAME=$(echo "$MODEL_NAME_RAW" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
SSID_5GHZ=$(echo "$SSID_5GHZ_RAW" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
SSID_24GHZ=$(echo "$SSID_24GHZ_RAW" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
SSID_5_1GHZ=$(echo "$SSID_5_1GHZ_RAW" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
SIGN_DATE=$(nvram get bwdpi_sig_ver | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
FORMATTED_UPTIME=$(format_uptime | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')

# Numeric/safe values
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
LOAD_AVG=$(cat /proc/loadavg | awk '{printf "1 min: %.2f%% 5 mins: %.2f%% 15 mins: %.2f%%", $1, $2, $3}')
AVERAGE_PING=$(ping -c 10 1.1.1.1 | tail -n 1 | awk -F'/' '{print $5}')

# Get vnStat data usage
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

# Define Date Titles
TODAY_TITLE_DATE=$(date +"%b %d, %Y")
MONTH_TITLE_DATE=$(date +"%B %Y")
YEAR_TITLE_DATE=$(date +"%Y")

# ConnMon Data Extraction
CONMON_DATA=$(get_conmon_hourly_stats "$CONMON_DB")
CONMON_TIME=$(echo "$CONMON_DATA" | cut -d, -f1)
CONMON_PING=$(echo "$CONMON_DATA" | cut -d, -f2)
CONMON_JITTER=$(echo "$CONMON_DATA" | cut -d, -f3)
CONMON_QUALITY=$(echo "$CONMON_DATA" | cut -d, -f4)

# ConnMon Historical Data Retrieval
get_connmon_history '-7 day' CONMON_WEEK_AVG
get_connmon_history 'start of month' CONMON_MONTH_AVG
get_connmon_history 'start of year' CONMON_YEAR_AVG
get_connmon_history '1970-01-01' CONMON_LIFETIME_AVG

# Alert Summary Retrieval (Sets $ALERT_SUMMARY_TEXT and $ALERT_COUNT_TODAY)
get_recent_alerts_summary


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
    # Save today's data to archives
    archive_daily_data

    # Define Time Periods
    MIDNIGHT_TODAY=$(date -d "00:00:00" +%s)
    MIDNIGHT_MONTH=$(date -d "$(date +%Y-%m-01) 00:00:00" +%s)
    YEAR_START_DATE=$(date +%Y-01-01)

    # Run queries
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

# --- START: FINAL sendMessage FUNCTION (Clean) ---
function sendMessage()
{
    # --- DYNAMIC BANNER LOGIC (v1.2 - Clean Summary) ---
    local headline=""
    
    # $ALERT_COUNT_TODAY is a global variable set by get_recent_alerts_summary
    if [ "$ALERT_COUNT_TODAY" -gt 0 ]; then
        # Priority 1: Alerts were found.
        headline=$(printf "🚨 Status: ALERT (%d events)" "$ALERT_COUNT_TODAY")
        
    elif [ "$TEMP_CPU" -gt "$LIMIT_TEMP_CPU" ]; then
        # Priority 2: High CPU Temp
        headline=$(printf "🔥 Status: HIGH CPU (%sº)" "$TEMP_CPU")
    else
        # Priority 3: All Clear
        headline="❄️ Status: ALL CLEAR"
    fi
    
    # Assemble the final banner with key datapoints
    BANNER=$(printf "<b>%s</b>\nCPU: <code>%sº</code> | Ping: <code>%s ms</code> | Daily: <code>%s</code>" \
        "$headline" \
        "${TEMP_CPU:-N/A}" \
        "${CONMON_PING:-N/A}" \
        "${DAILY_USAGE_DECIMAL:-N/A}"
    )
    # --- END DYNAMIC BANNER LOGIC ---

    TEXT=$(cat <<EOF
$BANNER

$TOP_USERS_TODAY_LIST

<b>⚠️ Recent Alerts</b>
$ALERT_SUMMARY_TEXT

<b>📊 Status</b>
🌡️ WLAN 2.4 Temp: $TEMP_WIFI24º
🌡️ WLAN 5-1 Temp: $TEMP_WIFI5º
🌡️ WLAN 5-2 Temp: $TEMP_WIFI5_1GHZº
⏱️ Uptime: $FORMATTED_UPTIME
💻 Load Average: $LOAD_AVG
🧠 RAM Used: $RAM_USED_PERCENTAGE% / Free: $RAM_FREE_PERCENTAGE%
💾 Swap Used: $SWAP_USED%

<b>📈 ConnMon Stats (Avg. for $CONMON_TIME)</b>
Avg. Ping/Latency: $CONMON_PING ms
Avg. Jitter: $CONMON_JITTER ms
Avg. Quality: $CONMON_QUALITY %

<b>📊 Historical ConnMon Averages</b>
 ┣ Last 7 Days Avg.: $CONMON_WEEK_AVG
 ┣ This Month Avg.: $CONMON_MONTH_AVG
 ┣ This Year Avg.: $CONMON_YEAR_AVG
 ┗ Lifetime Avg.: $CONMON_LIFETIME_AVG

<b>📅 Total Data Usage (vnStat)</b>
Daily Data Usage ($TODAY_TITLE_DATE): $DAILY_USAGE_DECIMAL
Monthly Data Usage ($MONTH_TITLE_DATE): $MONTHLY_USAGE_DECIMAL
Yearly Data Usage ($YEAR_TITLE_DATE): $YEARLY_USAGE_DECIMAL
Lifetime Data Usage: $LIFETIME_USAGE_DECIMAL

<b>👤 Historical Device Usage</b>
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
📡 SSID 5.1Ghz: $SSID_5_1GHZ
🌐 WAN IP: $IP_WAN0
🏠 LAN IP: $IP_LAN
🕒 Trend Micro sign: $SIGN_DATE

🕒 Time of report: $DATE
EOF
)

    # Send the message silently
    curl -s -X POST $API_TELEGRAM \
        -d chat_id=$CHATID \
        -d text="$TEXT" > /dev/null 2>&1
}
# --- END: FINAL sendMessage FUNCTION ---

# --- Final Execution ---
sendMessage
