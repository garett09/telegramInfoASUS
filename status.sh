#!/bin/sh
export PATH="/bin:/usr/bin:/sbin:/usr/sbin:/opt/bin:/opt/sbin"

#
# Dev: garett09
# version: 8.6 (FINAL - Removed old Ping)
# - Integrated Wicens DB archiving for reboots.
# - Moved Wicens sections for clarity.
# - Removed redundant Ping section (covered by ConnMon)
#
# --- Service Timing Information ---
# TrafficAnalyzer: Saves to DB every hour at :00 (cron: 0 * * * *)
#   - All traffic data is saved at the top of each hour
#   - Queries should use last completed hour's data for current metrics
#
# vnstat: UI updates every 5 minutes, but all data is logged in logfiles
#   - Historical data is always available regardless of UI update frequency
#
# ConnMon: Ping runs every minute to capture data
#   - Data is continuously logged to connstats.db
#   - Hourly averages are calculated from minute-by-minute data
#

# --- Database Paths ---
LIVE_DB_FILE="/jffs/.sys/TrafficAnalyzer/TrafficAnalyzer.db"
ARCHIVE_DB_FILE="/jffs/scripts/user_archive.db"
CONMON_DB="/jffs/addons/connmon.d/connstats.db"
ALERT_LOG="/jffs/connmon_alerts.log"
WICENS_LOG="/jffs/addons/wicens/wicens.log"
WICENS_HISTORY="/jffs/addons/wicens/wicens_wan_history.wic"

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

# Helper function just for Wicens duration
wicens_format_duration() {
    local total_seconds=$1
    
    if [ -z "$total_seconds" ] || [ "$total_seconds" -eq 0 ]; then
        echo "N/A"
        return
    fi
    
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
    # --- NEW: Check archive database for previously stored name (for offline devices) ---
    if [ -z "$final_name" ] && [ -f "$ARCHIVE_DB_FILE" ]; then
        name=$(sqlite3 "$ARCHIVE_DB_FILE" "SELECT name FROM daily_usage WHERE mac = '$clean_mac' AND name != '$clean_mac' ORDER BY date DESC LIMIT 1" 2>/dev/null)
        if [ -n "$name" ] && [ "$name" != "$clean_mac" ]; then
            final_name=$(echo "$name" | sed 's/^[ \t]*//;s/[ \t]*$//')
        fi
    fi
    # --- END NEW ---
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
    # --- NEW: Added Wicens table init ---
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS wicens_reboot_history (date TEXT PRIMARY KEY, reboot_count INTEGER);"
    # --- NEW: Device connection details table ---
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS device_connections (mac TEXT, ip TEXT, last_seen_timestamp INTEGER, connection_method TEXT, connection_duration_seconds INTEGER, date TEXT, PRIMARY KEY(mac, date));"
    # --- NEW: Hourly usage patterns table ---
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS hourly_usage_patterns (date TEXT, hour INTEGER, total_bytes INTEGER, device_count INTEGER, PRIMARY KEY(date, hour));"
    # --- NEW: Device session statistics table ---
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS device_session_stats (mac TEXT, date TEXT, avg_session_duration INTEGER, reconnection_count INTEGER, total_connection_time INTEGER, PRIMARY KEY(mac, date));"
    # --- NEW: ConnMon quality patterns table ---
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS connmon_quality_patterns (date TEXT, hour INTEGER, avg_quality REAL, avg_ping REAL, avg_jitter REAL, PRIMARY KEY(date, hour));"
}

# --- NEW: Function to archive today's reboot count ---
archive_todays_reboots() {
    local today_date=$(date +%Y-%m-%d)
    local today_filter_grep=$(date +"%b %d %Y")
    
    # FIX: Removed ^ anchor to find date anywhere on line
    local today_reboot_count=$(grep "$today_filter_grep" "$WICENS_LOG" | grep -c "reboot detected")
    
    # Save this number to the persistent database
    sqlite3 "$ARCHIVE_DB_FILE" "INSERT OR REPLACE INTO wicens_reboot_history (date, reboot_count) VALUES ('$today_date', $today_reboot_count);"
}

# --- NEW: Function to archive device connection details ---
archive_device_connections() {
    local today_date=$(date +%Y-%m-%d)
    local midnight_today=$(date -d "00:00:00" +%s)
    
    if [ ! -f "$LIVE_DB_FILE" ]; then
        return
    fi
    
    # Get all unique devices seen today
    local device_list=$(sqlite3 "$LIVE_DB_FILE" \
        "SELECT DISTINCT mac FROM traffic WHERE timestamp >= $midnight_today" 2>/dev/null)
    
    if [ -z "$device_list" ]; then
        return
    fi
    
    # Get wireless association lists for each band
    # Format: Get MAC addresses and convert to both colon-separated and no-colon formats for matching
    local wl0_assoc=$(wl -i $(nvram get wl0_ifname) assoclist 2>/dev/null | awk '{print $1}' | tr '\n' '|')
    local wl1_assoc=$(wl -i $(nvram get wl1_ifname) assoclist 2>/dev/null | awk '{print $1}' | tr '\n' '|')
    local wl2_assoc=$(wl -i $(nvram get wl2_ifname) assoclist 2>/dev/null | awk '{print $1}' | tr '\n' '|')
    
    echo "$device_list" | while read -r clean_mac; do
        if [ -z "$clean_mac" ]; then continue; fi
        
        # Get IP from dnsmasq.leases
        local device_ip=$(grep -i "$clean_mac" /var/lib/misc/dnsmasq.leases 2>/dev/null | awk '{print $3}' | head -n 1)
        if [ -z "$device_ip" ]; then device_ip="N/A"; fi
        
        # Get last seen timestamp from TrafficAnalyzer
        local last_seen=$(sqlite3 "$LIVE_DB_FILE" \
            "SELECT MAX(timestamp) FROM traffic WHERE mac = '$clean_mac' AND timestamp >= $midnight_today" 2>/dev/null)
        if [ -z "$last_seen" ]; then continue; fi
        
        # Determine connection method
        # Check wireless associations first, then check dnsmasq leases for wireless clients
        local connection_method="Wired"
        local mac_upper=$(echo "$clean_mac" | tr '[:lower:]' '[:upper:]')
        local mac_colon=$(echo "$clean_mac" | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')
        local mac_colon_upper=$(echo "$mac_colon" | tr '[:lower:]' '[:upper:]')
        
        # Check wireless associations (try both formats)
        if echo "$wl0_assoc" | grep -qiE "($mac_upper|$mac_colon_upper)"; then
            connection_method="2.4G"
        elif echo "$wl1_assoc" | grep -qiE "($mac_upper|$mac_colon_upper)"; then
            connection_method="5G"
        elif echo "$wl2_assoc" | grep -qiE "($mac_upper|$mac_colon_upper)"; then
            connection_method="5.1G"
        else
            # Check dnsmasq leases - if device has a lease but not in wireless assoc, it might be wired
            # But also check if it's in wireless by checking all possible MAC formats in leases
            local lease_check=$(grep -iE "($mac_upper|$mac_colon|$mac_colon_upper)" /var/lib/misc/dnsmasq.leases 2>/dev/null | head -n 1)
            if [ -z "$lease_check" ]; then
                connection_method="Unknown"
            fi
        fi
        
        # Calculate connection duration (first to last activity today)
        # IMPORTANT: TrafficAnalyzer saves data hourly at :00, so timestamps are hourly boundaries
        # If a device only has data in one hour, MIN and MAX timestamps will be the same or 1 second apart
        # This results in 1-second durations, which is why we see 1s - it's a limitation of hourly aggregated data
        # We need to count distinct hours instead of using timestamp differences
        local first_seen=$(sqlite3 "$LIVE_DB_FILE" \
            "SELECT MIN(timestamp) FROM traffic WHERE mac = '$clean_mac' AND timestamp >= $midnight_today" 2>/dev/null)
        local connection_duration=0
        if [ -n "$first_seen" ] && [ -n "$last_seen" ]; then
            # Count how many distinct hours the device was active (more accurate than timestamp diff)
            local active_hours=$(sqlite3 "$LIVE_DB_FILE" \
                "SELECT COUNT(DISTINCT strftime('%H', datetime(timestamp, 'unixepoch', 'localtime'))) 
                 FROM traffic WHERE mac = '$clean_mac' AND timestamp >= $midnight_today" 2>/dev/null)
            
            # If device was active in multiple hours, calculate duration from hour count
            # Otherwise, if only one hour, we can't determine actual duration from hourly aggregated data
            if [ -n "$active_hours" ] && [ "$active_hours" != "0" ] && [ "$active_hours" != "" ]; then
                if [ "$active_hours" -ge 2 ]; then
                    # Device active across multiple hours - estimate duration
                    # Use the actual timestamp difference, but this will be at least 1 hour (3600 seconds)
                    local raw_duration=$(($last_seen - $first_seen))
                    if [ $raw_duration -ge 3600 ]; then
                        connection_duration=$raw_duration
                    fi
                fi
                # If active_hours = 1, we can't determine actual duration from hourly data, so leave as 0 (will show N/A)
            fi
        fi
        
        # Store in archive
        sqlite3 "$ARCHIVE_DB_FILE" \
            "INSERT OR REPLACE INTO device_connections (mac, ip, last_seen_timestamp, connection_method, connection_duration_seconds, date) 
             VALUES ('$clean_mac', '$device_ip', $last_seen, '$connection_method', $connection_duration, '$today_date');" 2>/dev/null
    done
}

# --- NEW: Function to archive hourly usage patterns ---
# Note: TrafficAnalyzer saves to DB every hour at :00, so we query hourly boundaries
archive_hourly_usage() {
    local today_date=$(date +%Y-%m-%d)
    local midnight_today=$(date -d "00:00:00" +%s)
    
    if [ ! -f "$LIVE_DB_FILE" ]; then
        return
    fi
    
    # Archive data for each hour (0-23)
    local hour=0
    while [ $hour -lt 24 ]; do
        local hour_start=$(($midnight_today + ($hour * 3600)))
        local hour_end=$(($hour_start + 3600))
        
        # Get total bytes and device count for this hour
        local hour_data=$(sqlite3 -separator ',' "$LIVE_DB_FILE" \
            "SELECT COALESCE(SUM(rx + tx), 0), COUNT(DISTINCT mac) 
             FROM traffic 
             WHERE timestamp >= $hour_start AND timestamp < $hour_end" 2>/dev/null)
        
        if [ -n "$hour_data" ] && [ "$hour_data" != "," ]; then
            local total_bytes=$(echo "$hour_data" | cut -d, -f1)
            local device_count=$(echo "$hour_data" | cut -d, -f2)
            
            if [ -z "$total_bytes" ]; then total_bytes=0; fi
            if [ -z "$device_count" ]; then device_count=0; fi
            
            # Store in archive
            sqlite3 "$ARCHIVE_DB_FILE" \
                "INSERT OR REPLACE INTO hourly_usage_patterns (date, hour, total_bytes, device_count) 
                 VALUES ('$today_date', $hour, $total_bytes, $device_count);" 2>/dev/null
        fi
        
        hour=$(($hour + 1))
    done
}

# --- NEW: Function to archive ConnMon quality patterns (hourly) ---
# Note: ConnMon captures data every minute, so we calculate hourly averages from minute-by-minute records
archive_connmon_quality_patterns() {
    local today_date=$(date +%Y-%m-%d)
    local midnight_today=$(date -d "00:00:00" +%s)
    
    if [ ! -f "$CONMON_DB" ]; then
        return
    fi
    
    # Archive data for each hour (0-23)
    local hour=0
    while [ $hour -lt 24 ]; do
        local hour_start=$(($midnight_today + ($hour * 3600)))
        local hour_end=$(($hour_start + 3600))
        
        # Get average quality, ping, and jitter for this hour
        local hour_data=$(sqlite3 -separator ',' "$CONMON_DB" \
            "SELECT AVG(LineQuality), AVG(Ping), AVG(Jitter) 
             FROM connstats 
             WHERE Timestamp >= $hour_start AND Timestamp < $hour_end" 2>/dev/null)
        
        if [ -n "$hour_data" ] && [ "$hour_data" != ",," ]; then
            local avg_quality=$(echo "$hour_data" | cut -d, -f1)
            local avg_ping=$(echo "$hour_data" | cut -d, -f2)
            local avg_jitter=$(echo "$hour_data" | cut -d, -f3)
            
            # Only store if we have valid data
            if [ -n "$avg_quality" ] && [ "$avg_quality" != "" ] && [ "$avg_quality" != "NULL" ]; then
                if [ -z "$avg_ping" ] || [ "$avg_ping" = "" ] || [ "$avg_ping" = "NULL" ]; then avg_ping=0; fi
                if [ -z "$avg_jitter" ] || [ "$avg_jitter" = "" ] || [ "$avg_jitter" = "NULL" ]; then avg_jitter=0; fi
                if [ -z "$avg_quality" ] || [ "$avg_quality" = "" ] || [ "$avg_quality" = "NULL" ]; then avg_quality=0; fi
                
                # Store in archive
                sqlite3 "$ARCHIVE_DB_FILE" \
                    "INSERT OR REPLACE INTO connmon_quality_patterns (date, hour, avg_quality, avg_ping, avg_jitter) 
                     VALUES ('$today_date', $hour, $avg_quality, $avg_ping, $avg_jitter);" 2>/dev/null
            fi
        fi
        
        hour=$(($hour + 1))
    done
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
    # Note: ConnMon captures data every minute, so we calculate daily averages from all minute-by-minute records
    local CONMON_TODAY_AVG=$(sqlite3 -separator ',' "$CONMON_DB" \
        "SELECT AVG(Ping), AVG(Jitter), AVG(LineQuality)
          FROM connstats
          WHERE Timestamp >= $midnight_today")

    if [ -n "$CONMON_TODAY_AVG" ] && [ "$CONMON_TODAY_AVG" != ",," ]; then
        local ping_avg=$(echo "$CONMON_TODAY_AVG" | cut -d, -f1)
        local jitter_avg=$(echo "$CONMON_TODAY_AVG" | cut -d, -f2)
        local quality_avg=$(echo "$CONMON_TODAY_AVG" | cut -d, -f3)

        if echo "$ping_avg" | grep -q '^[0-9.]*$'; then
             if [ -z "$ping_avg" ]; then ping_avg=0; fi
             if [ -z "$jitter_avg" ]; then jitter_avg=0; fi
             if [ -z "$quality_avg" ]; then quality_avg=0; fi

             sqlite3 "$ARCHIVE_DB_FILE" "INSERT OR REPLACE INTO connmon_history (date, avg_ping, avg_jitter, avg_quality)
                                               VALUES ('$today_date', $ping_avg, $jitter_avg, $quality_avg);"
        fi
    fi
    
    # --- NEW: Archive today's wicens reboot count ---
    archive_todays_reboots
    
    # --- NEW: Archive device connection details ---
    archive_device_connections
    
    # --- NEW: Archive hourly usage patterns ---
    archive_hourly_usage
    
    # --- NEW: Archive ConnMon quality patterns (hourly) ---
    archive_connmon_quality_patterns
    
    # --- NEW: Calculate and archive device session statistics ---
    calculate_device_session_stats
}

# --- NEW: Function to calculate and archive device session statistics ---
calculate_device_session_stats() {
    local today_date=$(date +%Y-%m-%d)
    local midnight_today=$(date -d "00:00:00" +%s)
    
    if [ ! -f "$LIVE_DB_FILE" ]; then
        return
    fi
    
    # Get all unique devices seen today
    local device_list=$(sqlite3 "$LIVE_DB_FILE" \
        "SELECT DISTINCT mac FROM traffic WHERE timestamp >= $midnight_today" 2>/dev/null)
    
    if [ -z "$device_list" ]; then
        return
    fi
    
    echo "$device_list" | while read -r clean_mac; do
        if [ -z "$clean_mac" ]; then continue; fi
        
        # Get all timestamps for this device today, ordered
        local timestamps=$(sqlite3 "$LIVE_DB_FILE" \
            "SELECT DISTINCT timestamp FROM traffic WHERE mac = '$clean_mac' AND timestamp >= $midnight_today ORDER BY timestamp" 2>/dev/null)
        
        if [ -z "$timestamps" ]; then continue; fi
        
        # Calculate session stats
        local first_timestamp=$(echo "$timestamps" | head -n 1)
        local last_timestamp=$(echo "$timestamps" | tail -n 1)
        local total_connection_time=$(($last_timestamp - $first_timestamp))
        
        # Count reconnections - Best practice: Use adaptive threshold based on typical patterns
        # Gap > 5 minutes (300s) indicates disconnection, but also check for significant gaps
        # Consider gaps > 10% of total session time as reconnections (handles long sessions)
        local reconnection_count=0
        local prev_ts=""
        local total_gap_time=0
        
        # First pass: calculate adaptive threshold based on total connection time
        local adaptive_threshold=300
        if [ $total_connection_time -gt 3600 ]; then
            adaptive_threshold=$(awk -v t="$total_connection_time" 'BEGIN {printf "%.0f", t * 0.1}')
            if [ $adaptive_threshold -lt 300 ]; then adaptive_threshold=300; fi
        fi
        
        # Second pass: count reconnections using adaptive threshold
        for current_ts in $timestamps; do
            if [ -n "$prev_ts" ]; then
                local gap=$(($current_ts - $prev_ts))
                # Standard threshold: 5 minutes (300 seconds) or adaptive for long sessions
                if [ $gap -gt $adaptive_threshold ]; then
                    reconnection_count=$(($reconnection_count + 1))
                    total_gap_time=$(($total_gap_time + $gap))
                fi
            fi
            prev_ts="$current_ts"
        done
        
        # Calculate average session duration
        # If we have reconnections, divide total time by (reconnections + 1)
        # Only calculate if total connection time is meaningful (at least 60 seconds)
        local session_count=$(($reconnection_count + 1))
        local avg_session_duration=0
        if [ $total_connection_time -ge 60 ]; then
            if [ $session_count -gt 0 ]; then
                avg_session_duration=$(($total_connection_time / $session_count))
            else
                avg_session_duration=$total_connection_time
            fi
        fi
        # If avg_session_duration is still 0 or very small, set to 0 (will show as N/A in display)
        
        # Store in archive
        sqlite3 "$ARCHIVE_DB_FILE" \
            "INSERT OR REPLACE INTO device_session_stats (mac, date, avg_session_duration, reconnection_count, total_connection_time) 
             VALUES ('$clean_mac', '$today_date', $avg_session_duration, $reconnection_count, $total_connection_time);" 2>/dev/null
    done
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
    fi
    eval $__result_var="'$list_output'"
}

# --- NEW: Function to build Top 10 Users list from Archive DB ---
build_top_10_users_from_archive_db() {
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
          LIMIT 10") # Changed to LIMIT 10

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
    
    ALERT_COUNT_TODAY=0
    local today_date_filter=$(date +"%Y-%m-%d")

    if [ ! -f "$log_file" ]; then
        output="No recent alert log found."
    else
        # Only grab lines for today
        local todays_alerts=$(grep "^\[${today_date_filter}" "$log_file")
        local total_alerts=0
        if [ -n "$todays_alerts" ]; then
            total_alerts=$(echo "$todays_alerts" | wc -l)
        fi

        if [ "$total_alerts" -eq 0 ]; then
            output="No ConnMon alerts were triggered today."
        else
            # --- CORRECTED AWK COMMAND to use field 4 for ALERT messages ---
            local summary_list=$(echo "$todays_alerts" | awk -F'|' '{
                gsub(/\[|\]/,"", $1); 
                split($1, time_parts, " ");
                gsub(/ /,"", $2); 
                
                # RECOVERY LOGIC (Uses field $4 for resolved message)
                if ($2 == "RECOVERY") {
                    # Take the full message from field 4
                    detail_msg = $4;
                    gsub(/^[ \t]+|[ \t]+$/, "", detail_msg);
                    printf " - %s (%s): %s\n", time_parts[2], $2, detail_msg; 
                } 
                # ALERT LOGIC (Uses field $4 for detail message and field $3 for count)
                else if ($2 == "ALERT") {
                    # Take the alert count from field 3, and message detail from field 4
                    count = $3;
                    gsub(/^[ \t]+|[ \t]+$/, "", count);
                    detail_msg = $4;
                    gsub(/^[ \t]+|[ \t]+$/, "", detail_msg);
                    # ALERT messages should use the word "issue(s)"
                    printf " - %s (%s %s): %s\n", time_parts[2], $2, (count == "1" ? count " issue" : count " issues"), detail_msg; 
                }
            }' | sort -r | uniq)
            # --- END CORRECTED AWK COMMAND ---
            
            local unique_events=$(echo "$summary_list" | grep -c 'issues\|RECOVERY)') 

            if [ "$unique_events" -eq 0 ]; then
                output="No valid alerts found for today (or log format issue)."
            else
                output=$(printf "🚨 %d alert events triggered today:\n%s" "$unique_events" "$summary_list")
                # Count the number of unique ALERT lines for the banner headline
                ALERT_COUNT_TODAY=$(echo "$todays_alerts" | grep "ALERT" | awk '{print $1"|"$2"|"$3}' | sort | uniq | wc -l)
                if [ "$ALERT_COUNT_TODAY" -eq 0 ]; then
                    # Fallback for the banner if only recovery events exist
                    ALERT_COUNT_TODAY=$(echo "$todays_alerts" | grep "RECOVERY" | wc -l)
                fi
            fi
        fi
    fi
    ALERT_SUMMARY_TEXT=$(echo "$output" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
}

# --- NEW: Function to get all Wicens data (v8.5) ---
get_wicens_all_stats() {
    # Set defaults
    WAN_CONNECTION_DETAILS="<b>🌐 WAN Connection Details (Wicens)</b>
<i>Wicens log files not found.</i>"
    WAN_DISCONNECT_STATS="<b>🔄 WAN Disconnect Stats (Wicens)</b>
<i>Wicens log files not found.</i>"

    if [ ! -f "$WICENS_LOG" ] || [ ! -f "$WICENS_HISTORY" ]; then
        return # Exit function if files are missing
    fi

    # --- 1. Get Connection Details ---
    WIC_CURRENT_IP="$IP_WAN0_RAW" # Reuse already fetched IP (make global)
    WIC_CURRENT_UPTIME="N/A"
    WIC_CURRENT_CONN_STR="N/A"
    
    # --- FIX 1: Filter out 'cron' to find the real connection event ---
    local LATEST_INTERNET_UP_LINE=$(grep "appears up" "$WICENS_LOG" | grep -v "cron" | tail -n 1 | strings)

    if [ -n "$LATEST_INTERNET_UP_LINE" ]; then
        WIC_CURRENT_CONN_STR=$(echo "$LATEST_INTERNET_UP_LINE" | awk '
            BEGIN {
              m="Jan 1 Feb 2 Mar 3 Apr 4 May 5 Jun 6 Jul 7 Aug 8 Sep 9 Oct 10 Nov 11 Dec 12";
              split(m, a, " ");
              for (i=1; i<=24; i+=2) M[a[i]] = a[i+1];
            }
            {
              printf "%s-%02d-%02d %s", $3, M[$1], $2, $4
            }
        ')
        
        local UP_TS=$(date -d "$WIC_CURRENT_CONN_STR" +%s 2>/dev/null)
        if [ -n "$UP_TS" ]; then
            local NOW_TS=$(date +%s)
            local DURATION_SEC=$(($NOW_TS - $UP_TS))
            WIC_CURRENT_UPTIME=$(wicens_format_duration $DURATION_SEC)
        fi
    fi

    # --- 2. Get Previous IP Details ---
    local LAST_IP_ENTRY=$(tail -n 1 "$WICENS_HISTORY" | strings)
    WIC_OLD_IP_ADDR="N/A"
    WIC_OLD_IP_TIME_ACQUIRED="N/A"
    WIC_OLD_IP_LEASE_DURATION="N/A"

    if [ -n "$LAST_IP_ENTRY" ]; then
        WIC_OLD_IP_ADDR=$(echo "$LAST_IP_ENTRY" | awk '{print $5}')
        WIC_OLD_IP_TIME_ACQUIRED=$(echo "$LAST_IP_ENTRY" | awk '
            BEGIN {
              m="Jan 1 Feb 2 Mar 3 Apr 4 May 5 Jun 6 Jul 7 Aug 8 Sep 9 Oct 10 Nov 11 Dec 12";
              split(m, a, " ");
              for (i=1; i<=24; i+=2) M[a[i]] = a[i+1];
            }
            {
              printf "%s-%02d-%02d %s", $3, M[$1], $2, $4
            }
        ')
        WIC_OLD_IP_LEASE_DURATION=$(echo "$LAST_IP_ENTRY" | awk '{printf "%s %s %s %s", $6, $7, $8, $9}')
    fi
    
    # --- 3. Format Connection Details Output ---
    WAN_CONNECTION_DETAILS=$(cat <<EOF_DETAILS
<b>🌐 WAN Connection Details (Wicens)</b>
 ┣ Current IP: $WIC_CURRENT_IP
 ┣ Uptime: $WIC_CURRENT_UPTIME
 ┣ Connected Since: $WIC_CURRENT_CONN_STR
 ┣ Previous IP: $WIC_OLD_IP_ADDR
 ┣ Previous IP Since: $WIC_OLD_IP_TIME_ACQUIRED
 ┗ Previous Lease: $WIC_OLD_IP_LEASE_DURATION
EOF_DETAILS
)

    # --- 4. Get Disconnect Stats ---
    local WIC_TODAY_FILTER_GREP=$(date +"%b %d %Y")
    local WIC_MONTH_FILTER_AWK=$(date +"%b")
    local WIC_YEAR_FILTER_AWK=$(date +"%Y")
    local WIC_LABEL_TODAY=$(date +"%b %d")
    local WIC_LABEL_MONTH=$(date +"%B")
    local WIC_LABEL_YEAR=$(date +"%Y")

    # --- Get ALL Reboot stats from Archive DB ---
    local TODAY_DATE_SQL=$(date +%Y-%m-%d)
    local MONTH_START_SQL=$(date +%Y-%m-01)
    local YEAR_START_SQL=$(date +%Y-01-01)

    WIC_REBOOTS_TODAY=$(sqlite3 "$ARCHIVE_DB_FILE" "SELECT reboot_count FROM wicens_reboot_history WHERE date = '$TODAY_DATE_SQL'")
    WIC_REBOOTS_MONTH=$(sqlite3 "$ARCHIVE_DB_FILE" "SELECT SUM(reboot_count) FROM wicens_reboot_history WHERE date >= '$MONTH_START_SQL'")
    WIC_REBOOTS_YEAR=$(sqlite3 "$ARCHIVE_DB_FILE" "SELECT SUM(reboot_count) FROM wicens_reboot_history WHERE date >= '$YEAR_START_SQL'")
    WIC_REBOOTS_LIFETIME=$(sqlite3 "$ARCHIVE_DB_FILE" "SELECT SUM(reboot_count) FROM wicens_reboot_history")

    # Handle NULL/empty results from sqlite
    if [ -z "$WIC_REBOOTS_TODAY" ]; then WIC_REBOOTS_TODAY=0; fi
    if [ -z "$WIC_REBOOTS_MONTH" ]; then WIC_REBOOTS_MONTH=0; fi
    if [ -z "$WIC_REBOOTS_YEAR" ]; then WIC_REBOOTS_YEAR=0; fi
    if [ -z "$WIC_REBOOTS_LIFETIME" ]; then WIC_REBOOTS_LIFETIME=0; fi

    # --- IP Changes (from persistent log file) ---
    # --- FIX 2 & 3: Read all IP changes from the live log for consistency ---
    WIC_IP_CHANGES_TODAY=$(grep "$WIC_TODAY_FILTER_GREP" "$WICENS_LOG" | grep -c "WAN IP has changed")
    WIC_IP_CHANGES_MONTH=$(awk -v month="$WIC_MONTH_FILTER_AWK" -v year="$WIC_YEAR_FILTER_AWK" '$1 == month && $3 == year' "$WICENS_LOG" | grep -c "WAN IP has changed")
    WIC_IP_CHANGES_YEAR=$(awk -v year="$WIC_YEAR_FILTER_AWK" '$3 == year' "$WICENS_LOG" | grep -c "WAN IP has changed")
    WIC_IP_CHANGES_LIFETIME=$(grep -c "WAN IP has changed" "$WICENS_LOG")

    # --- 5. Format Disconnect Stats Output (Clean List Format) ---
    WAN_DISCONNECT_STATS=$(cat <<TABLE_EOF
<b>🔄 WAN Disconnect Stats (Wicens)</b>
 ┣ Reboots Today ($WIC_LABEL_TODAY): $WIC_REBOOTS_TODAY
 ┣ Reboots Month ($WIC_LABEL_MONTH): $WIC_REBOOTS_MONTH
 ┣ Reboots Year ($WIC_LABEL_YEAR): $WIC_REBOOTS_YEAR
 ┣ Reboots Lifetime: $WIC_REBOOTS_LIFETIME
 ┣ IP Changes Today ($WIC_LABEL_TODAY): $WIC_IP_CHANGES_TODAY
 ┣ IP Changes Month ($WIC_LABEL_MONTH): $WIC_IP_CHANGES_MONTH
 ┣ IP Changes Year ($WIC_LABEL_YEAR): $WIC_IP_CHANGES_YEAR
 ┗ IP Changes Lifetime: $WIC_IP_CHANGES_LIFETIME
TABLE_EOF
)
}
# --- END NEW FUNCTION ---

# --- NEW: Function to calculate percentage change ---
calculate_percentage_change() {
    local current=$1
    local previous=$2
    local __result_var=$3
    
    if [ -z "$current" ] || [ -z "$previous" ] || [ "$current" = "N/A" ] || [ "$previous" = "N/A" ]; then
        eval $__result_var="'N/A'"
        return
    fi
    
    # Extract numeric values (handle units like "GB", "ms", "%")
    local current_num=$(echo "$current" | sed 's/[^0-9.]//g')
    local previous_num=$(echo "$previous" | sed 's/[^0-9.]//g')
    
    if [ -z "$current_num" ] || [ -z "$previous_num" ] || [ "$previous_num" = "0" ] || [ "$previous_num" = "0.00" ]; then
        eval $__result_var="'N/A'"
        return
    fi
    
    # Calculate percentage change using awk for floating point
    local pct_change=$(awk -v c="$current_num" -v p="$previous_num" 'BEGIN {
        if (p == 0) print "N/A"
        else {
            change = ((c - p) / p) * 100
            printf "%.1f", change
        }
    }')
    
    eval $__result_var="'$pct_change'"
}

# --- NEW: Function to get yesterday's data usage from archive DB ---
get_yesterday_data_usage() {
    local __result_var=$1
    local yesterday_date=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null)
    
    if [ -z "$yesterday_date" ]; then
        eval $__result_var="'N/A'"
        return
    fi
    
    local total_bytes=$(sqlite3 "$ARCHIVE_DB_FILE" "SELECT SUM(total_bytes) FROM daily_usage WHERE date = '$yesterday_date'" 2>/dev/null)
    
    if [ -z "$total_bytes" ] || [ "$total_bytes" = "" ]; then
        eval $__result_var="'N/A'"
        return
    fi
    
    local human_readable=$(bytes_to_human $total_bytes)
    eval $__result_var="'$human_readable'"
}

# --- NEW: Function to get previous month's data usage from vnStat ---
# Note: vnstat data is always available from logfiles regardless of UI update frequency (5 min)
get_previous_month_data_usage() {
    local __result_var=$1
    local prev_month=$(date -d "last month" +%Y-%m 2>/dev/null || date -v-1m +%Y-%m 2>/dev/null)
    
    if [ -z "$prev_month" ]; then
        eval $__result_var="'N/A'"
        return
    fi
    
    local usage=$(vnstat -i ppp0 -m --dbdir /opt/var/lib/vnstat | grep "$prev_month" | awk '{print $8, $9}' 2>/dev/null)
    
    if [ -z "$usage" ]; then
        eval $__result_var="'N/A'"
        return
    fi
    
    local value=$(echo $usage | awk '{print $1}')
    local unit=$(echo $usage | awk '{print $2}')
    local converted=$(convert_usage $value $unit)
    
    eval $__result_var="'$converted'"
}

# --- NEW: Function to format trend indicator ---
format_trend_indicator() {
    local pct_change=$1
    local is_reverse=$2  # For metrics where lower is better (ping, jitter)
    
    if [ -z "$pct_change" ] || [ "$pct_change" = "N/A" ]; then
        echo ""
        return
    fi
    
    # Extract numeric value
    local num=$(echo "$pct_change" | sed 's/[^0-9.-]//g')
    
    if [ -z "$num" ]; then
        echo ""
        return
    fi
    
    # Determine if change is positive or negative
    local is_positive=$(awk -v n="$num" 'BEGIN {if (n > 0) print "1"; else print "0"}')
    
    if [ "$is_reverse" = "true" ]; then
        # For reverse metrics (lower is better), flip the logic
        if [ "$is_positive" = "1" ]; then
            echo "🔴 +${pct_change}%"
        else
            echo "🟢 ${pct_change}%"
        fi
    else
        # For normal metrics (higher is better)
        if [ "$is_positive" = "1" ]; then
            echo "🟢 +${pct_change}%"
        else
            echo "🔴 ${pct_change}%"
        fi
    fi
}

# --- NEW: Function to get current bandwidth speeds ---
# IMPORTANT: TrafficAnalyzer saves to DB every hour at :00 (cron: 0 * * * *)
# Therefore, we query the last completed hour's data for accurate metrics
# Example: At 11:44, we query data from 10:00-11:00 (saved at 11:00)
get_current_bandwidth_speeds() {
    local __result_var=$1
    local __result_var_up=$2
    
    if [ ! -f "$LIVE_DB_FILE" ]; then
        eval $__result_var="'N/A'"
        eval $__result_var_up="'N/A'"
        return
    fi
    
    # Calculate the last completed hour boundary
    # If it's 11:44, last completed hour is 10:00-11:00 (saved at 11:00)
    local current_minute=$(date +%M)
    local current_second=$(date +%S)
    
    # Get current timestamp
    local now_ts=$(date +%s)
    
    # Calculate seconds into current hour
    local seconds_into_hour=$(($current_minute * 60 + $current_second))
    
    # Last completed hour end = current time - seconds into current hour
    # This gives us the timestamp of the last :00 (when TrafficAnalyzer last saved)
    local last_hour_end=$(($now_ts - $seconds_into_hour))
    
    # Last completed hour start = last hour end - 3600 seconds
    local last_hour_start=$(($last_hour_end - 3600))
    
    # Get total download (rx) and upload (tx) in bytes from last completed hour
    # Use <= to include data at the exact hour boundary (when TrafficAnalyzer saves)
    local traffic_data=$(sqlite3 -separator ',' "$LIVE_DB_FILE" \
        "SELECT COALESCE(SUM(rx), 0), COALESCE(SUM(tx), 0) FROM traffic WHERE timestamp >= $last_hour_start AND timestamp <= $last_hour_end" 2>/dev/null)
    
    if [ -z "$traffic_data" ] || [ "$traffic_data" = "," ]; then
        eval $__result_var="'N/A'"
        eval $__result_var_up="'N/A'"
        return
    fi
    
    local rx_bytes=$(echo "$traffic_data" | cut -d, -f1)
    local tx_bytes=$(echo "$traffic_data" | cut -d, -f2)
    
    # Check if we have valid data (at least one should be > 0)
    local rx_check=$(awk -v r="$rx_bytes" 'BEGIN {if (r != "" && r != "NULL" && r > 0) print "1"; else print "0"}')
    local tx_check=$(awk -v t="$tx_bytes" 'BEGIN {if (t != "" && t != "NULL" && t > 0) print "1"; else print "0"}')
    if [ "$rx_check" != "1" ] && [ "$tx_check" != "1" ]; then
        eval $__result_var="'N/A'"
        eval $__result_var_up="'N/A'"
        return
    fi
    
    if [ -z "$rx_bytes" ] || [ "$rx_bytes" = "" ] || [ "$rx_bytes" = "NULL" ]; then rx_bytes=0; fi
    if [ -z "$tx_bytes" ] || [ "$tx_bytes" = "" ] || [ "$tx_bytes" = "NULL" ]; then tx_bytes=0; fi
    
    # Calculate average bytes per second over the hour (3600 seconds)
    local rx_bps=$(awk -v b="$rx_bytes" 'BEGIN {printf "%.0f", b/3600}')
    local tx_bps=$(awk -v b="$tx_bytes" 'BEGIN {printf "%.0f", b/3600}')
    
    # Convert to Mbps (1 byte = 8 bits, 1 Mbps = 1,000,000 bits)
    local rx_mbps=$(awk -v b="$rx_bps" 'BEGIN {printf "%.2f", (b * 8) / 1000000}')
    local tx_mbps=$(awk -v b="$tx_bps" 'BEGIN {printf "%.2f", (b * 8) / 1000000}')
    
    # Show 0.00 instead of very small numbers (use awk for comparison)
    local rx_check=$(awk -v r="$rx_mbps" 'BEGIN {if (r < 0.01) print "1"; else print "0"}')
    local tx_check=$(awk -v t="$tx_mbps" 'BEGIN {if (t < 0.01) print "1"; else print "0"}')
    if [ "$rx_check" = "1" ]; then
        rx_mbps="0.00"
    fi
    if [ "$tx_check" = "1" ]; then
        tx_mbps="0.00"
    fi
    
    eval $__result_var="'${rx_mbps} Mbps'"
    eval $__result_var_up="'${tx_mbps} Mbps'"
}

# --- NEW: Function to get device statistics ---
# IMPORTANT: TrafficAnalyzer saves to DB every hour at :00
# Active devices are counted from the last completed hour's data
get_device_statistics() {
    local __result_var_total=$1
    local __result_var_active=$2
    local __result_var_new=$3
    
    local total_devices=0
    local active_devices=0
    local new_devices=0
    
    if [ ! -f "$LIVE_DB_FILE" ]; then
        eval $__result_var_total="'N/A'"
        eval $__result_var_active="'N/A'"
        eval $__result_var_new="'N/A'"
        return
    fi
    
    local today_date=$(date +%Y-%m-%d)
    local yesterday_date=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null)
    local midnight_today=$(date -d "00:00:00" +%s)
    
    # Calculate the last completed hour boundary (TrafficAnalyzer saves at :00)
    local current_minute=$(date +%M)
    local current_second=$(date +%S)
    local now_ts=$(date +%s)
    local seconds_into_hour=$(($current_minute * 60 + $current_second))
    local last_hour_end=$(($now_ts - $seconds_into_hour))
    local last_hour_start=$(($last_hour_end - 3600))
    
    # Total unique devices seen today
    total_devices=$(sqlite3 "$LIVE_DB_FILE" \
        "SELECT COUNT(DISTINCT mac) FROM traffic WHERE timestamp >= $midnight_today" 2>/dev/null)
    
    # Active devices - use last completed hour's data, but only count devices seen today
    # Use <= to include data at the exact hour boundary (when TrafficAnalyzer saves)
    # Also ensure we only count devices that have been active today (not from previous day)
    active_devices=$(sqlite3 "$LIVE_DB_FILE" \
        "SELECT COUNT(DISTINCT mac) FROM traffic WHERE timestamp >= $last_hour_start AND timestamp <= $last_hour_end AND timestamp >= $midnight_today" 2>/dev/null)
    
    # New devices (devices seen today but not yesterday)
    if [ -n "$yesterday_date" ] && [ -f "$ARCHIVE_DB_FILE" ]; then
        local today_macs=$(sqlite3 "$LIVE_DB_FILE" \
            "SELECT DISTINCT mac FROM traffic WHERE timestamp >= $midnight_today" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        
        if [ -n "$today_macs" ]; then
            # Count devices in today's list that are NOT in yesterday's archive
            local yesterday_macs=$(sqlite3 "$ARCHIVE_DB_FILE" \
                "SELECT DISTINCT mac FROM daily_usage WHERE date = '$yesterday_date'" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
            
            # Simple comparison: if device not in yesterday's list, it's new
            new_devices=$(sqlite3 "$LIVE_DB_FILE" \
                "SELECT COUNT(DISTINCT mac) FROM traffic WHERE timestamp >= $midnight_today AND mac NOT IN (SELECT DISTINCT mac FROM daily_usage WHERE date = '$yesterday_date')" 2>/dev/null)
        fi
    fi
    
    if [ -z "$total_devices" ] || [ "$total_devices" = "" ]; then total_devices=0; fi
    if [ -z "$active_devices" ] || [ "$active_devices" = "" ]; then active_devices=0; fi
    if [ -z "$new_devices" ] || [ "$new_devices" = "" ]; then new_devices=0; fi
    
    eval $__result_var_total="'$total_devices'"
    eval $__result_var_active="'$active_devices'"
    eval $__result_var_new="'$new_devices'"
}

# --- NEW: Function to get peak usage times ---
get_peak_usage_times() {
    local __result_var_hour=$1
    local __result_var_data=$2
    
    if [ ! -f "$LIVE_DB_FILE" ]; then
        eval $__result_var_hour="'N/A'"
        eval $__result_var_data="'N/A'"
        return
    fi
    
    local midnight_today=$(date -d "00:00:00" +%s)
    
    # Get hourly breakdown
    local peak_data=$(sqlite3 -separator ',' "$LIVE_DB_FILE" \
        "SELECT strftime('%H', datetime(timestamp, 'unixepoch', 'localtime')) as hour, 
                SUM(rx + tx) as total
         FROM traffic 
         WHERE timestamp >= $midnight_today 
         GROUP BY hour 
         ORDER BY total DESC 
         LIMIT 1" 2>/dev/null)
    
    if [ -z "$peak_data" ] || [ "$peak_data" = "," ]; then
        eval $__result_var_hour="'N/A'"
        eval $__result_var_data="'N/A'"
        return
    fi
    
    local peak_hour=$(echo "$peak_data" | cut -d, -f1)
    local peak_bytes=$(echo "$peak_data" | cut -d, -f2)
    
    if [ -z "$peak_hour" ] || [ -z "$peak_bytes" ]; then
        eval $__result_var_hour="'N/A'"
        eval $__result_var_data="'N/A'"
        return
    fi
    
    local peak_human=$(bytes_to_human $peak_bytes)
    
    # Format peak hour display: if hour is 00, show as 23:00-00:00 (last hour of previous day)
    # If hour is 23, show as 23:00-00:00 (spans to next day)
    # Otherwise show as HH:00-HH+1:00
    local peak_time=""
    if [ "$peak_hour" = "00" ] || [ "$peak_hour" = "23" ]; then
        peak_time="23:00-00:00"
    else
        local next_hour=$(printf "%02d" $((${peak_hour#0} + 1)))
        peak_time="${peak_hour}:00-${next_hour}:00"
    fi
    
    eval $__result_var_hour="'$peak_time'"
    eval $__result_var_data="'$peak_human'"
}

# --- NEW: Function to calculate network health score ---
calculate_network_health_score() {
    local __result_var=$1
    
    local score=100
    local deductions=0
    
    # Ping score (0-25 points): Lower is better, ideal < 20ms
    if [ -n "$CONMON_PING" ] && [ "$CONMON_PING" != "N/A" ]; then
        local ping_num=$(echo "$CONMON_PING" | sed 's/[^0-9.]//g')
        if [ -n "$ping_num" ]; then
            local ping_deduction=$(awk -v p="$ping_num" 'BEGIN {
                if (p <= 20) print 0
                else if (p <= 50) print (p - 20) * 0.5
                else if (p <= 100) print 15 + (p - 50) * 0.3
                else print 30
            }')
            deductions=$(awk -v d="$deductions" -v p="$ping_deduction" 'BEGIN {printf "%.1f", d + p}')
        fi
    fi
    
    # Jitter score (0-15 points): Lower is better, ideal < 2ms
    if [ -n "$CONMON_JITTER" ] && [ "$CONMON_JITTER" != "N/A" ]; then
        local jitter_num=$(echo "$CONMON_JITTER" | sed 's/[^0-9.]//g')
        if [ -n "$jitter_num" ]; then
            local jitter_deduction=$(awk -v j="$jitter_num" 'BEGIN {
                if (j <= 2) print 0
                else if (j <= 5) print (j - 2) * 2
                else if (j <= 10) print 6 + (j - 5) * 1.2
                else print 12
            }')
            deductions=$(awk -v d="$deductions" -v j="$jitter_deduction" 'BEGIN {printf "%.1f", d + j}')
        fi
    fi
    
    # Quality score (0-20 points): Higher is better, ideal > 95%
    if [ -n "$CONMON_QUALITY" ] && [ "$CONMON_QUALITY" != "N/A" ]; then
        local quality_num=$(echo "$CONMON_QUALITY" | sed 's/[^0-9.]//g')
        if [ -n "$quality_num" ]; then
            local quality_deduction=$(awk -v q="$quality_num" 'BEGIN {
                if (q >= 95) print 0
                else if (q >= 85) print (95 - q) * 1
                else if (q >= 70) print 10 + (85 - q) * 0.67
                else print 20
            }')
            deductions=$(awk -v d="$deductions" -v q="$quality_deduction" 'BEGIN {printf "%.1f", d + q}')
        fi
    fi
    
    # CPU Temperature score (0-15 points): Lower is better, ideal < 60C
    if [ -n "$TEMP_CPU" ] && [ "$TEMP_CPU" != "N/A" ]; then
        local cpu_num=$(echo "$TEMP_CPU" | sed 's/[^0-9.]//g')
        if [ -n "$cpu_num" ]; then
            local cpu_deduction=$(awk -v c="$cpu_num" 'BEGIN {
                if (c <= 60) print 0
                else if (c <= 70) print (c - 60) * 0.5
                else if (c <= 80) print 5 + (c - 70) * 0.5
                else print 10
            }')
            deductions=$(awk -v d="$deductions" -v c="$cpu_deduction" 'BEGIN {printf "%.1f", d + c}')
        fi
    fi
    
    # RAM Usage score (0-15 points): Lower is better, ideal < 70%
    # Use actual memory pressure (excluding cache) since cache is reclaimable
    if [ -n "$RAM_ACTUAL_USED_PERCENTAGE" ] && [ "$RAM_ACTUAL_USED_PERCENTAGE" != "N/A" ]; then
        local ram_num=$(echo "$RAM_ACTUAL_USED_PERCENTAGE" | sed 's/[^0-9.]//g')
        if [ -n "$ram_num" ]; then
            local ram_deduction=$(awk -v r="$ram_num" 'BEGIN {
                if (r <= 70) print 0
                else if (r <= 85) print (r - 70) * 0.5
                else if (r <= 95) print 7.5 + (r - 85) * 0.75
                else print 15
            }')
            deductions=$(awk -v d="$deductions" -v r="$ram_deduction" 'BEGIN {printf "%.1f", d + r}')
        fi
    fi
    
    # Calculate final score
    local final_score=$(awk -v s="$score" -v d="$deductions" 'BEGIN {
        result = s - d
        if (result < 0) result = 0
        if (result > 100) result = 100
        printf "%.0f", result
    }')
    
    eval $__result_var="'$final_score'"
}

# --- NEW: Function to get device connection info from archive ---
# Uses user_archive.db for all historical device connection data
get_device_connection_info() {
    local __result_var=$1
    local today_date=$(date +%Y-%m-%d)
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        eval $__result_var="'<b>📱 Recent Device Connections</b>\n<i>No archived data yet.</i>'"
        return
    fi
    
    local list_output="<b>📱 Recent Device Connections</b>"
    
    # Get top 5 most recently active devices (by last_seen_timestamp)
    local query_result=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT dc.mac, dc.ip, dc.last_seen_timestamp, dc.connection_method, dc.connection_duration_seconds, du.name
         FROM device_connections dc
         LEFT JOIN daily_usage du ON dc.mac = du.mac AND dc.date = du.date
         WHERE dc.date = '$today_date'
         ORDER BY dc.last_seen_timestamp DESC
         LIMIT 5" 2>/dev/null)
    
    if [ -z "$query_result" ]; then
        list_output=$(printf "%s\n<i>No device connection data for today.</i>" "$list_output")
    else
        local count=0
        local total=$(echo "$query_result" | wc -l)
        while IFS=',' read -r mac ip last_seen method duration name; do
            if [ -z "$name" ] || [ "$name" = "" ]; then name="$mac"; fi
            safe_name=$(echo "$name" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
            
            # Format last seen time
            local last_seen_formatted="N/A"
            if [ -n "$last_seen" ] && [ "$last_seen" != "" ] && [ "$last_seen" != "NULL" ]; then
                last_seen_formatted=$(date -d "@$last_seen" +"%H:%M" 2>/dev/null || date -r "$last_seen" +"%H:%M" 2>/dev/null)
            fi
            
            # Format connection duration
            # Show N/A if duration is less than 60 seconds (too short to be meaningful)
            local duration_formatted="N/A"
            if [ -n "$duration" ] && [ "$duration" != "" ] && [ "$duration" != "NULL" ] && [ "$duration" != "0" ] && [ "$duration" -ge 60 ]; then
                duration_formatted=$(wicens_format_duration $duration)
            fi
            
            count=$(($count + 1))
            local connector="┣"
            if [ $count -eq $total ]; then connector="┗"; fi
            
            list_output=$(printf "%s\n $connector %s: <code>%s</code> | <code>%s</code> | Last: <code>%s</code> | Duration: <code>%s</code>" \
                "$list_output" "$safe_name" "$ip" "$method" "$last_seen_formatted" "$duration_formatted")
        done <<EOF
$query_result
EOF
    fi
    
    eval $__result_var="'$list_output'"
}

# --- NEW: Function to get usage patterns from archive ---
# Uses user_archive.db for all historical usage pattern analysis
get_usage_patterns() {
    local __result_var_quiet=$1
    local __result_var_busy=$2
    local __result_var_daynight=$3
    local today_date=$(date +%Y-%m-%d)
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        eval $__result_var_quiet="'N/A'"
        eval $__result_var_busy="'N/A'"
        eval $__result_var_daynight="'N/A'"
        return
    fi
    
    # Get quiet hours - Best practice: Filter out hours with zero/insignificant data
    # Only consider hours with meaningful activity (at least 1KB to avoid noise)
    local quiet_hours=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT hour, total_bytes FROM hourly_usage_patterns 
         WHERE date = '$today_date' AND total_bytes >= 1024
         ORDER BY total_bytes ASC 
         LIMIT 3" 2>/dev/null)
    
    local quiet_output="N/A"
    if [ -n "$quiet_hours" ]; then
        quiet_output=$(echo "$quiet_hours" | awk -F',' '{
            if (NR == 1) printf "%02d:00", $1
            else printf ", %02d:00", $1
        }')
    fi
    
    # Get top 3 busiest hours - Filter out hours with zero/insignificant data (same as quiet hours)
    local busy_hours=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT hour, total_bytes FROM hourly_usage_patterns 
         WHERE date = '$today_date' AND total_bytes >= 1024
         ORDER BY total_bytes DESC 
         LIMIT 3" 2>/dev/null)
    
    local busy_output="N/A"
    if [ -n "$busy_hours" ]; then
        busy_output=$(echo "$busy_hours" | awk -F',' '{
            bytes_human = $2
            if (bytes_human > 1073741824) bytes_human = sprintf("%.2f GB", bytes_human/1073741824)
            else if (bytes_human > 1048576) bytes_human = sprintf("%.2f MB", bytes_human/1048576)
            else if (bytes_human > 1024) bytes_human = sprintf("%.2f KB", bytes_human/1024)
            else bytes_human = sprintf("%.2f B", bytes_human)
            
            if (NR == 1) printf "%02d:00 (<code>%s</code>)", $1, bytes_human
            else printf ", %02d:00 (<code>%s</code>)", $1, bytes_human
        }')
    fi
    
    # Day vs Night comparison - Best practice: Include percentage breakdown for better insights
    # Day: 6 AM - 6 PM (12 hours), Night: 6 PM - 6 AM (12 hours)
    local day_night_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT 
         SUM(CASE WHEN hour >= 6 AND hour < 18 THEN total_bytes ELSE 0 END) as day_bytes,
         SUM(CASE WHEN hour < 6 OR hour >= 18 THEN total_bytes ELSE 0 END) as night_bytes
         FROM hourly_usage_patterns 
         WHERE date = '$today_date'" 2>/dev/null)
    
    local daynight_output="N/A"
    if [ -n "$day_night_data" ] && [ "$day_night_data" != "," ]; then
        local day_bytes=$(echo "$day_night_data" | cut -d, -f1)
        local night_bytes=$(echo "$day_night_data" | cut -d, -f2)
        if [ -z "$day_bytes" ]; then day_bytes=0; fi
        if [ -z "$night_bytes" ]; then night_bytes=0; fi
        
        local total_bytes=$(awk -v d="$day_bytes" -v n="$night_bytes" 'BEGIN {printf "%.0f", d + n}')
        local day_pct=0
        local night_pct=0
        if [ "$total_bytes" != "0" ] && [ -n "$total_bytes" ]; then
            day_pct=$(awk -v d="$day_bytes" -v t="$total_bytes" 'BEGIN {if (t > 0) printf "%.0f", (d/t)*100; else print 0}')
            night_pct=$(awk -v n="$night_bytes" -v t="$total_bytes" 'BEGIN {if (t > 0) printf "%.0f", (n/t)*100; else print 0}')
        fi
        
        local day_human=$(bytes_to_human $day_bytes)
        local night_human=$(bytes_to_human $night_bytes)
        daynight_output="Day: <code>$day_human</code> (<code>${day_pct}%</code>) | Night: <code>$night_human</code> (<code>${night_pct}%</code>)"
    fi
    
    eval $__result_var_quiet="'$quiet_output'"
    eval $__result_var_busy="'$busy_output'"
    eval $__result_var_daynight="'$daynight_output'"
}

# --- NEW: Function to get most active device from archive ---
# Uses user_archive.db for historical device activity analysis
get_most_active_device() {
    local __result_var=$1
    local today_date=$(date +%Y-%m-%d)
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        eval $__result_var="'N/A'"
        return
    fi
    
    local device_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT dc.mac, dc.connection_duration_seconds, du.name
         FROM device_connections dc
         LEFT JOIN daily_usage du ON dc.mac = du.mac AND dc.date = du.date
         WHERE dc.date = '$today_date'
         ORDER BY dc.connection_duration_seconds DESC
         LIMIT 1" 2>/dev/null)
    
    if [ -z "$device_data" ] || [ "$device_data" = "," ]; then
        eval $__result_var="'N/A'"
        return
    fi
    
    local mac=$(echo "$device_data" | cut -d, -f1)
    local duration=$(echo "$device_data" | cut -d, -f2)
    local name=$(echo "$device_data" | cut -d, -f3)
    
    if [ -z "$name" ] || [ "$name" = "" ]; then name="$mac"; fi
    safe_name=$(echo "$name" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
    
    local duration_formatted=$(wicens_format_duration $duration)
    
    eval $__result_var="'$safe_name (<code>$duration_formatted</code>)'"
}

# --- NEW: Function to get advanced statistics from archive ---
# Uses user_archive.db for all historical statistical analysis
get_advanced_statistics() {
    local __result_var_avg_session=$1
    local __result_var_stability=$2
    local __result_var_efficiency=$3
    local today_date=$(date +%Y-%m-%d)
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        eval $__result_var_avg_session="'N/A'"
        eval $__result_var_stability="'N/A'"
        eval $__result_var_efficiency="'N/A'"
        return
    fi
    
    # Average session duration - Best practice: Use median for robustness (outlier-resistant)
    # Falls back to mean if insufficient data points
    # Only count devices with meaningful session durations (at least 60 seconds)
    local device_count=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT COUNT(*) FROM device_session_stats WHERE date = '$today_date' AND avg_session_duration >= 60" 2>/dev/null)
    
    local avg_session_output="N/A"
    if [ -n "$device_count" ] && [ "$device_count" != "0" ] && [ "$device_count" != "" ]; then
        # Use median if we have enough data points (best practice: median is more robust)
        if [ "$device_count" -ge 3 ]; then
            local median_offset=$(awk -v c="$device_count" 'BEGIN {printf "%.0f", (c-1)/2}')
            local median_session=$(sqlite3 "$ARCHIVE_DB_FILE" \
                "SELECT avg_session_duration FROM device_session_stats 
                 WHERE date = '$today_date' AND avg_session_duration >= 60
                 ORDER BY avg_session_duration 
                 LIMIT 1 OFFSET $median_offset" 2>/dev/null)
            if [ -n "$median_session" ] && [ "$median_session" != "" ]; then
                local median_int=$(printf "%.0f" "$median_session" 2>/dev/null)
                avg_session_output=$(wicens_format_duration $median_int)
            fi
        fi
        
        # Fallback to mean if median unavailable
        if [ "$avg_session_output" = "N/A" ]; then
            local avg_session=$(sqlite3 "$ARCHIVE_DB_FILE" \
                "SELECT AVG(avg_session_duration) FROM device_session_stats WHERE date = '$today_date' AND avg_session_duration >= 60" 2>/dev/null)
            if [ -n "$avg_session" ] && [ "$avg_session" != "" ] && [ "$avg_session" != "NULL" ]; then
                local avg_session_int=$(printf "%.0f" "$avg_session" 2>/dev/null)
                avg_session_output=$(wicens_format_duration $avg_session_int)
            fi
        fi
    fi
    
    # Connection stability - Best practice: Use median and show distribution
    # Lower reconnection count indicates better stability
    local stability_output="N/A"
    local device_count_stable=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT COUNT(*) FROM device_session_stats WHERE date = '$today_date'" 2>/dev/null)
    
    if [ -n "$device_count_stable" ] && [ "$device_count_stable" != "0" ] && [ "$device_count_stable" != "" ]; then
        # Calculate median reconnection count (more robust than mean)
        local median_offset_stable=$(awk -v c="$device_count_stable" 'BEGIN {printf "%.0f", (c-1)/2}')
        local median_reconnects=$(sqlite3 "$ARCHIVE_DB_FILE" \
            "SELECT reconnection_count FROM device_session_stats 
             WHERE date = '$today_date'
             ORDER BY reconnection_count 
             LIMIT 1 OFFSET $median_offset_stable" 2>/dev/null)
        
        # Also get devices with zero reconnections (most stable)
        local stable_devices=$(sqlite3 "$ARCHIVE_DB_FILE" \
            "SELECT COUNT(*) FROM device_session_stats 
             WHERE date = '$today_date' AND reconnection_count = 0" 2>/dev/null)
        
        if [ -n "$median_reconnects" ] && [ "$median_reconnects" != "" ]; then
            local stable_pct=0
            if [ -n "$stable_devices" ] && [ "$device_count_stable" != "0" ]; then
                stable_pct=$(awk -v s="$stable_devices" -v t="$device_count_stable" 'BEGIN {printf "%.0f", (s/t)*100}')
            fi
            stability_output="<code>$median_reconnects</code> median (<code>${stable_pct}%</code> stable)"
        fi
    fi
    
    # Bandwidth efficiency (total data / total connection time across all devices)
    # Only calculate if we have meaningful connection time (at least 1 hour = 3600 seconds)
    local efficiency_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT 
         (SELECT SUM(total_bytes) FROM daily_usage WHERE date = '$today_date'),
         (SELECT SUM(total_connection_time) FROM device_session_stats WHERE date = '$today_date' AND total_connection_time >= 60)" 2>/dev/null)
    
    local efficiency_output="N/A"
    if [ -n "$efficiency_data" ] && [ "$efficiency_data" != "," ]; then
        local total_bytes=$(echo "$efficiency_data" | cut -d, -f1)
        local total_time=$(echo "$efficiency_data" | cut -d, -f2)
        # Only calculate if total_time is at least 1 hour (3600 seconds) to avoid unrealistic numbers
        if [ -n "$total_bytes" ] && [ -n "$total_time" ] && [ "$total_time" != "0" ] && [ "$total_time" != "" ] && [ "$total_time" -ge 3600 ]; then
            # Calculate bytes per hour
            local bytes_per_hour=$(awk -v b="$total_bytes" -v t="$total_time" 'BEGIN {if (t > 0) printf "%.0f", (b / t) * 3600; else print "0"}')
            local efficiency_human=$(bytes_to_human $bytes_per_hour)
            efficiency_output="<code>$efficiency_human</code>/hour"
        fi
    fi
    
    eval $__result_var_avg_session="'$avg_session_output'"
    eval $__result_var_stability="'$stability_output'"
    eval $__result_var_efficiency="'$efficiency_output'"
}

# --- NEW: Function to analyze ConnMon trends from archive ---
# Uses user_archive.db for all historical ConnMon quality analysis and trends
analyze_connmon_trends() {
    local __result_var_trend=$1
    local __result_var_best=$2
    local __result_var_stability=$3
    local today_date=$(date +%Y-%m-%d)
    local yesterday_date=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null)
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        eval $__result_var_trend="'N/A'"
        eval $__result_var_best="'N/A'"
        eval $__result_var_stability="'N/A'"
        return
    fi
    
    # Quality trend - Best practice: Use 7-day moving average for more reliable trend detection
    # Compares today's average with 7-day historical average (more statistically robust)
    local trend_output="N/A"
    local today_quality=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT avg_quality FROM connmon_history WHERE date = '$today_date'" 2>/dev/null)
    
    if [ -n "$today_quality" ] && [ "$today_quality" != "" ] && [ "$today_quality" != "NULL" ]; then
        # Get 7-day historical average (excluding today) for baseline comparison
        local seven_day_avg=$(sqlite3 "$ARCHIVE_DB_FILE" \
            "SELECT AVG(avg_quality) FROM connmon_history 
             WHERE date < '$today_date' AND date >= date('$today_date', '-7 days')" 2>/dev/null)
        
        if [ -n "$seven_day_avg" ] && [ "$seven_day_avg" != "" ] && [ "$seven_day_avg" != "NULL" ]; then
            # Calculate percentage change from baseline
            local quality_diff=$(awk -v t="$today_quality" -v b="$seven_day_avg" 'BEGIN {
                if (b > 0) printf "%.1f", ((t - b) / b) * 100
                else print "0.0"
            }')
            local abs_diff=$(awk -v d="$quality_diff" 'BEGIN {if (d < 0) print -d; else print d}')
            
            # Use 2% threshold for significance (best practice: avoid noise from small fluctuations)
            if [ $(awk -v d="$abs_diff" 'BEGIN {if (d >= 2.0) print 1; else print 0}') -eq 1 ]; then
                if [ $(awk -v d="$quality_diff" 'BEGIN {if (d > 0) print 1; else print 0}') -eq 1 ]; then
                    trend_output="🟢 Improving (+${quality_diff}%)"
                else
                    trend_output="🔴 Degrading (${quality_diff}%)"
                fi
            else
                trend_output="🟡 Stable (${quality_diff}%)"
            fi
        elif [ -n "$yesterday_date" ]; then
            # Fallback to yesterday if 7-day data not available
            local yesterday_quality=$(sqlite3 "$ARCHIVE_DB_FILE" \
                "SELECT avg_quality FROM connmon_history WHERE date = '$yesterday_date'" 2>/dev/null)
            
            if [ -n "$yesterday_quality" ] && [ "$yesterday_quality" != "" ]; then
                local quality_diff=$(awk -v t="$today_quality" -v y="$yesterday_quality" 'BEGIN {printf "%.1f", t - y}')
                local abs_diff=$(awk -v d="$quality_diff" 'BEGIN {if (d < 0) print -d; else print d}')
                
                if [ $(awk -v d="$abs_diff" 'BEGIN {if (d >= 2.0) print 1; else print 0}') -eq 1 ]; then
                    if [ $(awk -v d="$quality_diff" 'BEGIN {if (d > 0) print 1; else print 0}') -eq 1 ]; then
                        trend_output="🟢 Improving (+${quality_diff}%)"
                    else
                        trend_output="🔴 Degrading (${quality_diff}%)"
                    fi
                else
                    trend_output="🟡 Stable (${quality_diff}%)"
                fi
            fi
        fi
    fi
    
    # Best quality period (hour with highest average quality today)
    local best_hour_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT hour, avg_quality FROM connmon_quality_patterns 
         WHERE date = '$today_date' 
         ORDER BY avg_quality DESC 
         LIMIT 1" 2>/dev/null)
    
    local best_output="N/A"
    if [ -n "$best_hour_data" ] && [ "$best_hour_data" != "," ]; then
        local best_hour=$(echo "$best_hour_data" | cut -d, -f1)
        local best_quality=$(echo "$best_hour_data" | cut -d, -f2)
        if [ -n "$best_hour" ] && [ -n "$best_quality" ]; then
            local quality_formatted=$(printf "%.1f" "$best_quality" 2>/dev/null)
            best_output="${best_hour}:00 (<code>${quality_formatted}%</code>)"
        fi
    fi
    
    # Stability (standard deviation of quality across hours, lower is better)
    # Best practice: Use proper standard deviation calculation (sqrt of variance)
    local stability_output="N/A"
    local quality_variance=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT AVG((avg_quality - (SELECT AVG(avg_quality) FROM connmon_quality_patterns WHERE date = '$today_date')) * 
                    (avg_quality - (SELECT AVG(avg_quality) FROM connmon_quality_patterns WHERE date = '$today_date')))
         FROM connmon_quality_patterns WHERE date = '$today_date'" 2>/dev/null)
    
    if [ -n "$quality_variance" ] && [ "$quality_variance" != "" ] && [ "$quality_variance" != "NULL" ]; then
        # Calculate standard deviation (square root of variance)
        local quality_stddev=$(awk -v v="$quality_variance" 'BEGIN {
            if (v >= 0) printf "%.2f", sqrt(v)
            else print "0.00"
        }')
        local stddev_formatted=$(printf "%.1f" "$quality_stddev" 2>/dev/null)
        # Explain: Lower std dev = more consistent quality across hours (better stability)
        # 0.0% means all hours have the same quality (perfect consistency)
        if [ $(awk -v s="$stddev_formatted" 'BEGIN {if (s == 0.0) print 1; else print 0}') -eq 1 ]; then
            stability_output="<code>0.0%</code> (perfect consistency)"
        else
            stability_output="<code>${stddev_formatted}%</code> variance"
        fi
    fi
    
    eval $__result_var_trend="'$trend_output'"
    eval $__result_var_best="'$best_output'"
    eval $__result_var_stability="'$stability_output'"
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
# RAM calculation: Account for cache (cache is reclaimable, so shouldn't count as "used")
# $2 = total, $3 = used (includes cache), $4 = free, $6 = available (free + cache that can be freed)
# For health score: Use actual memory pressure = (total - available) / total
# For display: Show used percentage including cache for transparency
RAM_TOTAL=$(free | grep Mem | awk '{print $2}')
RAM_AVAILABLE=$(free | grep Mem | awk '{print $6}')
RAM_USED=$(free | grep Mem | awk '{print $3}')
RAM_FREE=$(free | grep Mem | awk '{print $4}')

# Actual memory pressure (excluding cache) for health score
RAM_ACTUAL_USED_PERCENTAGE=$(awk -v t="$RAM_TOTAL" -v a="$RAM_AVAILABLE" 'BEGIN {
    if (t > 0) printf "%.2f", ((t - a) / t) * 100.0
    else print "0.00"
}')

# Display percentage (includes cache for transparency)
RAM_USED_PERCENTAGE=$(awk -v t="$RAM_TOTAL" -v u="$RAM_USED" 'BEGIN {
    if (t > 0) printf "%.2f", (u / t) * 100.0
    else print "0.00"
}')

RAM_FREE_PERCENTAGE=$(awk -v t="$RAM_TOTAL" -v f="$RAM_FREE" 'BEGIN {
    if (t > 0) printf "%.2f", (f / t) * 100.0
    else print "0.00"
}')
SWAP_USED=$(free | grep Swap | awk '{ if ($2 > 0) { printf("%.2f", $3/$2 * 100.0) } else { print "0.00" } }')
LOAD_AVG=$(cat /proc/loadavg | awk '{printf "1 min: %.2f%% 5 mins: %.2f%% 15 mins: %.2f%%", $1, $2, $3}')
# AVERAGE_PING variable removed

# Get vnStat data usage
# Note: vnstat UI updates every 5 minutes, but all data is logged in logfiles
# Historical data is always available regardless of UI update frequency
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

# --- NEW: Define Date Labels for ConnMon History ---
LABEL_DATE_7DAY="($(date -d @$(($(date +%s) - 518400)) +"%b %d") - $(date +"%b %d"))"
LABEL_DATE_MONTH="($(date +"%B"))"
LABEL_DATE_YEAR="($(date +"%Y"))"

# ConnMon Historical Data Retrieval
get_connmon_history '-7 day' CONMON_WEEK_AVG
get_connmon_history 'start of month' CONMON_MONTH_AVG
get_connmon_history 'start of year' CONMON_YEAR_AVG
get_connmon_history '1970-01-01' CONMON_LIFETIME_AVG

# Alert Summary Retrieval (Sets $ALERT_SUMMARY_TEXT and $ALERT_COUNT_TODAY)
get_recent_alerts_summary

# --- NEW: Call function to get all Wicens data ---
get_wicens_all_stats
# --- END NEW ---


# --- Generate Top Users Lists ---

if [ ! -f "$LIVE_DB_FILE" ]; then
    TOP_USERS_TODAY_LIST="<b>🏆 Top 5 Users (Today)</b>
<i>Traffic DB not found.</i>"
    TOP_USERS_MONTH_LIST="<b>📅 Top 5 Users (This Month)</b>
<i>Traffic DB not found.</i>"
    TOP_USERS_YEAR_LIST="<b>🗓️ Top 5 Users (This Year)</b>
<i>Traffic DB not found.</i>"
    TOP_10_USERS_LIFE_LIST="<b>🌍 Top 10 Users (Lifetime)</b>
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
    # --- NEW: Get Top 10 users for lifetime ---
    build_top_10_users_from_archive_db "🌍 Top 10 Users (Lifetime)" "" TOP_10_USERS_LIFE_LIST
fi

# --- NEW: Get additional statistics ---
# Initialize trend variables
PING_TREND=""
JITTER_TREND=""
QUALITY_TREND=""
DAILY_USAGE_TREND=""
MONTHLY_USAGE_TREND=""

# Get yesterday's data usage for comparison
get_yesterday_data_usage YESTERDAY_USAGE

# Get previous month's data usage for comparison
get_previous_month_data_usage PREVIOUS_MONTH_USAGE

# Get current bandwidth speeds
get_current_bandwidth_speeds CURRENT_DOWNLOAD_SPEED CURRENT_UPLOAD_SPEED

# Get device statistics
get_device_statistics TOTAL_DEVICES_TODAY ACTIVE_DEVICES NEW_DEVICES_TODAY

# Get peak usage times
get_peak_usage_times PEAK_USAGE_HOUR PEAK_USAGE_DATA

# Calculate network health score
calculate_network_health_score NETWORK_HEALTH_SCORE

# --- NEW: Get device connection info from archive ---
get_device_connection_info DEVICE_CONNECTION_INFO

# --- NEW: Get usage patterns from archive ---
get_usage_patterns QUIET_HOURS BUSY_HOURS DAY_NIGHT_USAGE

# --- NEW: Get most active device from archive ---
get_most_active_device MOST_ACTIVE_DEVICE

# --- NEW: Get advanced statistics from archive ---
get_advanced_statistics AVG_SESSION_DURATION CONNECTION_STABILITY BANDWIDTH_EFFICIENCY

# --- NEW: Analyze ConnMon trends from archive ---
analyze_connmon_trends CONNMON_QUALITY_TREND CONNMON_BEST_PERIOD CONNMON_STABILITY

# Calculate trend indicators
# Daily usage trend - Best practice: Use 7-day average for more reliable trends
# Falls back to yesterday if 7-day data unavailable
TODAY_DATE_SQL=$(date +%Y-%m-%d)
if [ -n "$DAILY_USAGE_DECIMAL" ] && [ "$DAILY_USAGE_DECIMAL" != "N/A" ] && [ -f "$ARCHIVE_DB_FILE" ]; then
    # Try 7-day average first
    SEVEN_DAY_AVG_USAGE=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT AVG(total_bytes) FROM daily_usage 
         WHERE date < '$TODAY_DATE_SQL' AND date >= date('$TODAY_DATE_SQL', '-7 days')" 2>/dev/null)
    
    if [ -n "$SEVEN_DAY_AVG_USAGE" ] && [ "$SEVEN_DAY_AVG_USAGE" != "" ] && [ "$SEVEN_DAY_AVG_USAGE" != "NULL" ] && [ "$SEVEN_DAY_AVG_USAGE" != "0" ]; then
        # Convert to human readable for comparison
        SEVEN_DAY_AVG_HUMAN=$(bytes_to_human $SEVEN_DAY_AVG_USAGE)
        # Use the human-readable format directly for comparison
        calculate_percentage_change "$DAILY_USAGE_DECIMAL" "$SEVEN_DAY_AVG_HUMAN" DAILY_USAGE_TREND_PCT
        DAILY_USAGE_TREND=$(format_trend_indicator "$DAILY_USAGE_TREND_PCT" "false")
    elif [ -n "$YESTERDAY_USAGE" ] && [ "$YESTERDAY_USAGE" != "N/A" ]; then
        # Fallback to yesterday
        calculate_percentage_change "$DAILY_USAGE_DECIMAL" "$YESTERDAY_USAGE" DAILY_USAGE_TREND_PCT
        DAILY_USAGE_TREND=$(format_trend_indicator "$DAILY_USAGE_TREND_PCT" "false")
    fi
fi

# Monthly usage trend - Best practice: Use 30-day average for monthly patterns
# Falls back to previous month if 30-day data unavailable
if [ -n "$MONTHLY_USAGE_DECIMAL" ] && [ "$MONTHLY_USAGE_DECIMAL" != "N/A" ] && [ -f "$ARCHIVE_DB_FILE" ]; then
    # Try 30-day average first (best practice for monthly trends)
    THIRTY_DAY_AVG_USAGE=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT AVG(total_bytes) FROM daily_usage 
         WHERE date < '$TODAY_DATE_SQL' AND date >= date('$TODAY_DATE_SQL', '-30 days')" 2>/dev/null)
    
    if [ -n "$THIRTY_DAY_AVG_USAGE" ] && [ "$THIRTY_DAY_AVG_USAGE" != "" ] && [ "$THIRTY_DAY_AVG_USAGE" != "NULL" ] && [ "$THIRTY_DAY_AVG_USAGE" != "0" ]; then
        # Calculate monthly average (multiply daily average by ~30)
        THIRTY_DAY_MONTHLY_EST=$(awk -v d="$THIRTY_DAY_AVG_USAGE" 'BEGIN {printf "%.0f", d * 30}')
        THIRTY_DAY_MONTHLY_HUMAN=$(bytes_to_human $THIRTY_DAY_MONTHLY_EST)
        
        # Use the human-readable format directly for comparison
        calculate_percentage_change "$MONTHLY_USAGE_DECIMAL" "$THIRTY_DAY_MONTHLY_HUMAN" MONTHLY_USAGE_TREND_PCT
        MONTHLY_USAGE_TREND=$(format_trend_indicator "$MONTHLY_USAGE_TREND_PCT" "false")
    elif [ -n "$PREVIOUS_MONTH_USAGE" ] && [ "$PREVIOUS_MONTH_USAGE" != "N/A" ]; then
        # Fallback to previous month
        calculate_percentage_change "$MONTHLY_USAGE_DECIMAL" "$PREVIOUS_MONTH_USAGE" MONTHLY_USAGE_TREND_PCT
        MONTHLY_USAGE_TREND=$(format_trend_indicator "$MONTHLY_USAGE_TREND_PCT" "false")
    fi
fi

# Get historical ConnMon data for trend comparison
# Best practice: Use 7-day moving average for more reliable trend detection
# Falls back to 30-day average if 7-day unavailable, then yesterday
# (TODAY_DATE_SQL already defined above)
YESTERDAY_DATE=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null)

if [ -f "$ARCHIVE_DB_FILE" ]; then
    # Try 7-day moving average first (best practice for weekly patterns)
    SEVEN_DAY_CONNMON=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT AVG(avg_ping), AVG(avg_jitter), AVG(avg_quality) FROM connmon_history 
         WHERE date < '$TODAY_DATE_SQL' AND date >= date('$TODAY_DATE_SQL', '-7 days')" 2>/dev/null)
    
    if [ -n "$SEVEN_DAY_CONNMON" ] && [ "$SEVEN_DAY_CONNMON" != ",," ]; then
        SEVEN_DAY_PING=$(echo "$SEVEN_DAY_CONNMON" | cut -d, -f1)
        SEVEN_DAY_JITTER=$(echo "$SEVEN_DAY_CONNMON" | cut -d, -f2)
        SEVEN_DAY_QUALITY=$(echo "$SEVEN_DAY_CONNMON" | cut -d, -f3)
        
        # Use 7-day average for trends
        if [ -n "$SEVEN_DAY_PING" ] && [ "$SEVEN_DAY_PING" != "" ] && [ "$SEVEN_DAY_PING" != "NULL" ] && [ -n "$CONMON_PING" ] && [ "$CONMON_PING" != "N/A" ]; then
            calculate_percentage_change "${CONMON_PING} ms" "${SEVEN_DAY_PING} ms" PING_TREND_PCT
            PING_TREND=$(format_trend_indicator "$PING_TREND_PCT" "true")
        fi
        if [ -n "$SEVEN_DAY_JITTER" ] && [ "$SEVEN_DAY_JITTER" != "" ] && [ "$SEVEN_DAY_JITTER" != "NULL" ] && [ -n "$CONMON_JITTER" ] && [ "$CONMON_JITTER" != "N/A" ]; then
            calculate_percentage_change "${CONMON_JITTER} ms" "${SEVEN_DAY_JITTER} ms" JITTER_TREND_PCT
            JITTER_TREND=$(format_trend_indicator "$JITTER_TREND_PCT" "true")
        fi
        if [ -n "$SEVEN_DAY_QUALITY" ] && [ "$SEVEN_DAY_QUALITY" != "" ] && [ "$SEVEN_DAY_QUALITY" != "NULL" ] && [ -n "$CONMON_QUALITY" ] && [ "$CONMON_QUALITY" != "N/A" ]; then
            calculate_percentage_change "${CONMON_QUALITY}%" "${SEVEN_DAY_QUALITY}%" QUALITY_TREND_PCT
            QUALITY_TREND=$(format_trend_indicator "$QUALITY_TREND_PCT" "false")
        fi
    else
        # Fallback to 30-day moving average (best practice for monthly patterns)
        THIRTY_DAY_CONNMON=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
            "SELECT AVG(avg_ping), AVG(avg_jitter), AVG(avg_quality) FROM connmon_history 
             WHERE date < '$TODAY_DATE_SQL' AND date >= date('$TODAY_DATE_SQL', '-30 days')" 2>/dev/null)
        
        if [ -n "$THIRTY_DAY_CONNMON" ] && [ "$THIRTY_DAY_CONNMON" != ",," ]; then
            THIRTY_DAY_PING=$(echo "$THIRTY_DAY_CONNMON" | cut -d, -f1)
            THIRTY_DAY_JITTER=$(echo "$THIRTY_DAY_CONNMON" | cut -d, -f2)
            THIRTY_DAY_QUALITY=$(echo "$THIRTY_DAY_CONNMON" | cut -d, -f3)
            
            # Use 30-day average for trends
            if [ -n "$THIRTY_DAY_PING" ] && [ "$THIRTY_DAY_PING" != "" ] && [ "$THIRTY_DAY_PING" != "NULL" ] && [ -n "$CONMON_PING" ] && [ "$CONMON_PING" != "N/A" ]; then
                calculate_percentage_change "${CONMON_PING} ms" "${THIRTY_DAY_PING} ms" PING_TREND_PCT
                PING_TREND=$(format_trend_indicator "$PING_TREND_PCT" "true")
            fi
            if [ -n "$THIRTY_DAY_JITTER" ] && [ "$THIRTY_DAY_JITTER" != "" ] && [ "$THIRTY_DAY_JITTER" != "NULL" ] && [ -n "$CONMON_JITTER" ] && [ "$CONMON_JITTER" != "N/A" ]; then
                calculate_percentage_change "${CONMON_JITTER} ms" "${THIRTY_DAY_JITTER} ms" JITTER_TREND_PCT
                JITTER_TREND=$(format_trend_indicator "$JITTER_TREND_PCT" "true")
            fi
            if [ -n "$THIRTY_DAY_QUALITY" ] && [ "$THIRTY_DAY_QUALITY" != "" ] && [ "$THIRTY_DAY_QUALITY" != "NULL" ] && [ -n "$CONMON_QUALITY" ] && [ "$CONMON_QUALITY" != "N/A" ]; then
                calculate_percentage_change "${CONMON_QUALITY}%" "${THIRTY_DAY_QUALITY}%" QUALITY_TREND_PCT
                QUALITY_TREND=$(format_trend_indicator "$QUALITY_TREND_PCT" "false")
            fi
        elif [ -n "$YESTERDAY_DATE" ]; then
            # Final fallback to yesterday (if insufficient historical data)
            YESTERDAY_CONNMON=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
                "SELECT avg_ping, avg_jitter, avg_quality FROM connmon_history WHERE date = '$YESTERDAY_DATE'" 2>/dev/null)
            if [ -n "$YESTERDAY_CONNMON" ] && [ "$YESTERDAY_CONNMON" != ",," ]; then
                YESTERDAY_PING=$(echo "$YESTERDAY_CONNMON" | cut -d, -f1)
                YESTERDAY_JITTER=$(echo "$YESTERDAY_CONNMON" | cut -d, -f2)
                YESTERDAY_QUALITY=$(echo "$YESTERDAY_CONNMON" | cut -d, -f3)
                
                # Calculate trends using yesterday
                if [ -n "$YESTERDAY_PING" ] && [ "$YESTERDAY_PING" != "" ] && [ -n "$CONMON_PING" ] && [ "$CONMON_PING" != "N/A" ]; then
                    calculate_percentage_change "${CONMON_PING} ms" "${YESTERDAY_PING} ms" PING_TREND_PCT
                    PING_TREND=$(format_trend_indicator "$PING_TREND_PCT" "true")
                fi
                if [ -n "$YESTERDAY_JITTER" ] && [ "$YESTERDAY_JITTER" != "" ] && [ -n "$CONMON_JITTER" ] && [ "$CONMON_JITTER" != "N/A" ]; then
                    calculate_percentage_change "${CONMON_JITTER} ms" "${YESTERDAY_JITTER} ms" JITTER_TREND_PCT
                    JITTER_TREND=$(format_trend_indicator "$JITTER_TREND_PCT" "true")
                fi
                if [ -n "$YESTERDAY_QUALITY" ] && [ "$YESTERDAY_QUALITY" != "" ] && [ -n "$CONMON_QUALITY" ] && [ "$CONMON_QUALITY" != "N/A" ]; then
                    calculate_percentage_change "${CONMON_QUALITY}%" "${YESTERDAY_QUALITY}%" QUALITY_TREND_PCT
                    QUALITY_TREND=$(format_trend_indicator "$QUALITY_TREND_PCT" "false")
                fi
            fi
        fi
    fi
fi

## Telegram
TELEGRAM_AUTH="/jffs/telegram.env"
TOKEN=$(cat $TELEGRAM_AUTH | grep "TOKEN" | awk -F "=" '{print $2}')
CHATID=$(cat $TELEGRAM_AUTH | grep "CHAT_ID" | awk -F "=" '{print $2}')
API_TELEGRAM="https://api.telegram.org/bot$TOKEN/sendMessage?parse_mode=HTML"

DATE=$(date +"%I:%M %p, %B %d, %Y")
LIMIT_TEMP_CPU=73
unset BANNER

# --- START: FINAL sendMessage FUNCTION (Enhanced v2.0) ---
function sendMessage()
{
    # --- DYNAMIC BANNER LOGIC (v3.0 - Enhanced with Health Score) ---
    local headline=""
    local health_emoji=""
    
    # Determine health score emoji
    if [ -n "$NETWORK_HEALTH_SCORE" ] && [ "$NETWORK_HEALTH_SCORE" != "N/A" ]; then
        local score_num=$(echo "$NETWORK_HEALTH_SCORE" | sed 's/[^0-9]//g')
        if [ -n "$score_num" ]; then
            if [ "$score_num" -ge 90 ]; then
                health_emoji="🟢"
            elif [ "$score_num" -ge 70 ]; then
                health_emoji="🟡"
            else
                health_emoji="🔴"
            fi
        fi
    fi
    
    if [ "$ALERT_COUNT_TODAY" -gt 0 ]; then
        headline=$(printf "🚨 Status: ALERT (%d events)" "$ALERT_COUNT_TODAY")
    elif [ "$TEMP_CPU" -gt "$LIMIT_TEMP_CPU" ]; then
        headline=$(printf "🔥 Status: HIGH CPU (%sº)" "$TEMP_CPU")
    else
        headline="❄️ Status: ALL CLEAR"
    fi
    
    BANNER=$(printf "<b>%s</b>\n<code>CPU: %sº</code> | <code>Ping: %s ms</code> | <code>Daily: %s</code> | <code>Health: %s %s</code>" \
        "$headline" \
        "${TEMP_CPU:-N/A}" \
        "${CONMON_PING:-N/A}" \
        "${DAILY_USAGE_DECIMAL:-N/A}" \
        "${health_emoji}" \
        "${NETWORK_HEALTH_SCORE:-N/A}"
    )
    # --- END DYNAMIC BANNER LOGIC ---

    # --- Check if Historical ConnMon has any valid data ---
    local has_historical_data=false
    if (echo "$CONMON_WEEK_AVG" | grep -qv "N/A") || \
       (echo "$CONMON_MONTH_AVG" | grep -qv "N/A") || \
       (echo "$CONMON_YEAR_AVG" | grep -qv "N/A") || \
       (echo "$CONMON_LIFETIME_AVG" | grep -qv "N/A"); then
        has_historical_data=true
    fi

    # --- Format ConnMon Quality with emoji indicator ---
    local quality_emoji=""
    if [ -n "$CONMON_QUALITY" ] && [ "$CONMON_QUALITY" != "N/A" ]; then
        local quality_num=$(echo "$CONMON_QUALITY" | sed 's/[^0-9.]//g')
        if [ -n "$quality_num" ]; then
            # Use awk for floating point comparison (more portable than bc)
            local quality_check=$(awk -v q="$quality_num" 'BEGIN {
                if (q >= 95) print "green"
                else if (q >= 85) print "yellow"
                else print "red"
            }')
            case "$quality_check" in
                green) quality_emoji="🟢" ;;
                yellow) quality_emoji="🟡" ;;
                red) quality_emoji="🔴" ;;
            esac
        fi
    fi

    TEXT=$(cat <<EOF
$BANNER

<b>📊 Quick Stats</b>
 ┣ CPU: <code>$TEMP_CPUº</code>
 ┣ RAM: <code>$RAM_USED_PERCENTAGE%</code>
 ┣ Uptime: <code>$FORMATTED_UPTIME</code>
 ┣ Ping: <code>$CONMON_PING ms</code>${PING_TREND:+ $PING_TREND}
 ┣ Jitter: <code>$CONMON_JITTER ms</code>${JITTER_TREND:+ $JITTER_TREND}
 ┣ Quality: $quality_emoji <code>$CONMON_QUALITY%</code>${QUALITY_TREND:+ $QUALITY_TREND}
 ┣ Daily Usage: <code>$DAILY_USAGE_DECIMAL</code>${DAILY_USAGE_TREND:+ $DAILY_USAGE_TREND}
 ┗ Peak Hour: <code>${PEAK_USAGE_HOUR:-N/A}</code> (<code>${PEAK_USAGE_DATA:-N/A}</code>)

<b>📡 Bandwidth (Last Hour)</b>
 ┣ Download: <code>${CURRENT_DOWNLOAD_SPEED:-N/A}</code>
 ┗ Upload: <code>${CURRENT_UPLOAD_SPEED:-N/A}</code>

<b>📱 Device Activity</b>
 ┣ Total Devices: <code>${TOTAL_DEVICES_TODAY:-N/A}</code>
 ┣ Active Devices: <code>${ACTIVE_DEVICES:-N/A}</code>
 ┗ New Devices: <code>${NEW_DEVICES_TODAY:-N/A}</code>

$DEVICE_CONNECTION_INFO

$TOP_USERS_TODAY_LIST

<b>⚠️ Recent Alerts</b>
$ALERT_SUMMARY_TEXT

<b>🌡️ System Health</b>
 ┣ WLAN 2.4GHz: <code>$TEMP_WIFI24º</code>
 ┣ WLAN 5-1GHz: <code>$TEMP_WIFI5º</code>
 ┣ WLAN 5-2GHz: <code>$TEMP_WIFI5_1GHZº</code>
 ┣ Load Avg: <code>$LOAD_AVG</code>
 ┣ RAM Used: <code>$RAM_USED_PERCENTAGE%</code>
 ┣ RAM Free: <code>$RAM_FREE_PERCENTAGE%</code>
 ┗ Swap Used: <code>$SWAP_USED%</code>

<b>📈 Connection Quality (Last Hour: $CONMON_TIME)</b>
 ┣ Ping/Latency: <code>$CONMON_PING ms</code>${PING_TREND:+ $PING_TREND}
 ┣ Jitter: <code>$CONMON_JITTER ms</code>${JITTER_TREND:+ $JITTER_TREND}
 ┣ Quality: $quality_emoji <code>$CONMON_QUALITY%</code>${QUALITY_TREND:+ $QUALITY_TREND}
 ┣ Trend: ${CONNMON_QUALITY_TREND:-N/A}
 ┣ Best Period: ${CONNMON_BEST_PERIOD:-N/A}
 ┗ Stability: ${CONNMON_STABILITY:-N/A}
EOF
)

    # --- Conditionally add Historical ConnMon section ---
    if [ "$has_historical_data" = true ]; then
        TEXT=$(cat <<EOF
$TEXT

<b>📊 Historical Averages</b>
 ┣ Last 7 Days: <code>$CONMON_WEEK_AVG</code>
 ┣ This Month: <code>$CONMON_MONTH_AVG</code>
 ┣ This Year: <code>$CONMON_YEAR_AVG</code>
 ┗ All-Time: <code>$CONMON_LIFETIME_AVG</code>
EOF
)
    fi

    # Use global WAN variables (now exported from get_wicens_all_stats)
    TEXT=$(cat <<EOF
$TEXT

<b>🌐 WAN Connection</b>
 ┣ Current IP: <code>${IP_WAN0:-N/A}</code>
 ┣ Uptime: <code>${WIC_CURRENT_UPTIME:-N/A}</code>
 ┣ Connected Since: <code>${WIC_CURRENT_CONN_STR:-N/A}</code>
 ┣ Previous IP: <code>${WIC_OLD_IP_ADDR:-N/A}</code>
 ┣ Previous IP Since: <code>${WIC_OLD_IP_TIME_ACQUIRED:-N/A}</code>
 ┗ Previous Lease: <code>${WIC_OLD_IP_LEASE_DURATION:-N/A}</code>

<b>🔄 WAN Stats</b>
 ┣ Reboots Today: <code>${WIC_REBOOTS_TODAY:-0}</code>
 ┣ Reboots Month: <code>${WIC_REBOOTS_MONTH:-0}</code>
 ┣ Reboots Year: <code>${WIC_REBOOTS_YEAR:-0}</code>
 ┣ Reboots Lifetime: <code>${WIC_REBOOTS_LIFETIME:-0}</code>
 ┣ IP Changes Today: <code>${WIC_IP_CHANGES_TODAY:-0}</code>
 ┣ IP Changes Month: <code>${WIC_IP_CHANGES_MONTH:-0}</code>
 ┣ IP Changes Year: <code>${WIC_IP_CHANGES_YEAR:-0}</code>
 ┗ IP Changes Lifetime: <code>${WIC_IP_CHANGES_LIFETIME:-0}</code>

<b>📊 Data Usage</b>
 ┣ Today: <code>$DAILY_USAGE_DECIMAL</code>${DAILY_USAGE_TREND:+ $DAILY_USAGE_TREND}
 ┃   ${YESTERDAY_USAGE:+Yesterday: <code>$YESTERDAY_USAGE</code>}
 ┣ This Month: <code>$MONTHLY_USAGE_DECIMAL</code>${MONTHLY_USAGE_TREND:+ $MONTHLY_USAGE_TREND}
 ┃   ${PREVIOUS_MONTH_USAGE:+Last Month: <code>$PREVIOUS_MONTH_USAGE</code>}
 ┣ This Year: <code>$YEARLY_USAGE_DECIMAL</code>
 ┗ Lifetime: <code>$LIFETIME_USAGE_DECIMAL</code>

<b>📈 Usage Patterns</b>
 ┣ Quiet Hours: ${QUIET_HOURS:-N/A}
 ┣ Busiest Hours: ${BUSY_HOURS:-N/A}
 ┗ Day vs Night: ${DAY_NIGHT_USAGE:-N/A}

<b>📊 Advanced Statistics</b>
 ┣ Avg Session Duration: <code>${AVG_SESSION_DURATION:-N/A}</code>
 ┣ Most Active Device: ${MOST_ACTIVE_DEVICE:-N/A}
 ┣ Connection Stability: ${CONNECTION_STABILITY:-N/A}
 ┗ Bandwidth Efficiency: ${BANDWIDTH_EFFICIENCY:-N/A}

<b>👤 Top Device Usage</b>
$TOP_USERS_MONTH_LIST

$TOP_USERS_YEAR_LIST

$TOP_10_USERS_LIFE_LIST

<b>📃 System Info</b>
 ┣ Model: <code>$MODEL_NAME</code>
 ┣ Firmware: <code>$FIRMWARE_VERSION</code>
 ┣ SSID 2.4GHz: <code>$SSID_24GHZ</code>
 ┣ SSID 5GHz: <code>$SSID_5GHZ</code>
 ┣ SSID 5.1GHz: <code>$SSID_5_1GHZ</code>
 ┣ WAN IP: <code>$IP_WAN0</code>
 ┣ LAN IP: <code>$IP_LAN</code>
 ┗ Trend Micro: <code>$SIGN_DATE</code>

<code>🕒 Report Time: $DATE</code>
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
