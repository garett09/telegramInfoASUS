#!/bin/sh
export PATH="/bin:/usr/bin:/sbin:/usr/sbin:/opt/bin:/opt/sbin"

#
# Dev: garett09
# version: 9.0 (FINAL - Removed old Ping)
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
    
    # Strip leading zeros if present (for small numbers) but don't use 10# for large numbers
    total_seconds=$(echo "$total_seconds" | sed 's/^0*//')
    if [ -z "$total_seconds" ]; then total_seconds=0; fi
    local days=$((total_seconds / 86400))
    local hours=$(((total_seconds % 86400) / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))
    
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
    
    # Strip leading zeros first before any comparisons
    total_seconds=$(echo "$total_seconds" | sed 's/^0*//')
    if [ -z "$total_seconds" ]; then total_seconds=0; fi
    
    if [ -z "$total_seconds" ] || [ "$total_seconds" -eq 0 ]; then
        echo "N/A"
        return
    fi
    local days=$((total_seconds / 86400))
    local hours=$(((total_seconds % 86400) / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))
    
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
# Schema is optimized for advanced statistics queries with proper indexes
init_archive_db() {
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        echo "Creating new user archive database..."
    fi
    
    # --- Core Tables ---
    # Daily usage per device (aggregated from TrafficAnalyzer)
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS daily_usage (
        mac TEXT NOT NULL,
        name TEXT,
        date TEXT NOT NULL,
        total_bytes INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(mac, date)
    );" 2>/dev/null
    
    # ConnMon daily averages (aggregated from minute-by-minute data)
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS connmon_history (
        date TEXT PRIMARY KEY NOT NULL,
        avg_ping REAL,
        avg_jitter REAL,
        avg_quality REAL
    );" 2>/dev/null
    
    # --- Wicens Tables ---
    # Wicens reboot history (archived daily)
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS wicens_reboot_history (
        date TEXT PRIMARY KEY NOT NULL,
        reboot_count INTEGER NOT NULL DEFAULT 0
    );" 2>/dev/null
    
    # --- Device Connection Tables ---
    # Device connection details (IP, method, duration, etc.)
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS device_connections (
        mac TEXT NOT NULL,
        ip TEXT,
        last_seen_timestamp INTEGER,
        connection_method TEXT,
        connection_duration_seconds INTEGER,
        date TEXT NOT NULL,
        PRIMARY KEY(mac, date)
    );" 2>/dev/null
    
    # Device session statistics (reconnections, session duration)
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS device_session_stats (
        mac TEXT NOT NULL,
        date TEXT NOT NULL,
        avg_session_duration INTEGER,
        reconnection_count INTEGER,
        total_connection_time INTEGER,
        PRIMARY KEY(mac, date)
    );" 2>/dev/null
    
    # --- Hourly Pattern Tables (for Advanced Statistics) ---
    # Hourly usage patterns (used by Network Load Factor and Hourly Data Rate)
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS hourly_usage_patterns (
        date TEXT NOT NULL,
        hour INTEGER NOT NULL CHECK(hour >= 0 AND hour <= 23),
        total_bytes INTEGER NOT NULL DEFAULT 0,
        device_count INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(date, hour)
    );" 2>/dev/null
    
    # ConnMon quality patterns per hour (used by Ping/Jitter Stats)
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS connmon_quality_patterns (
        date TEXT NOT NULL,
        hour INTEGER NOT NULL CHECK(hour >= 0 AND hour <= 23),
        avg_quality REAL,
        avg_ping REAL,
        avg_jitter REAL,
        PRIMARY KEY(date, hour)
    );" 2>/dev/null
    
    # --- Advanced Statistics Daily Table ---
    # Daily calculated statistics for 7-day averaging
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS advanced_statistics_daily (
        date TEXT PRIMARY KEY NOT NULL,
        quality_distribution_excellent INTEGER,
        quality_distribution_good INTEGER,
        quality_distribution_poor INTEGER,
        bandwidth_efficiency_pct REAL,
        connection_stability_score REAL,
        quality_consistency REAL,
        worst_quality_hour INTEGER,
        active_hours_count INTEGER,
        usage_variance REAL,
        peak_offpeak_ratio REAL,
        connection_reliability_pct REAL,
        ping_consistency REAL,
        jitter_consistency REAL
    );" 2>/dev/null
    
    # --- Weekly Aggregation Tables (for Advanced Statistics) ---
    # Weekly averages (7-day and 30-day rolling averages for comparisons)
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE TABLE IF NOT EXISTS weekly_averages (
        date TEXT PRIMARY KEY NOT NULL,
        avg_bytes_7d INTEGER,
        avg_ping_7d REAL,
        avg_jitter_7d REAL,
        quality_dist_excellent_7d REAL,
        quality_dist_good_7d REAL,
        quality_dist_poor_7d REAL,
        bandwidth_efficiency_7d REAL,
        connection_stability_7d REAL,
        quality_consistency_7d REAL,
        active_hours_7d REAL,
        usage_variance_7d REAL,
        peak_offpeak_ratio_7d REAL,
        connection_reliability_7d REAL,
        ping_consistency_7d REAL,
        jitter_consistency_7d REAL,
        avg_bytes_30d INTEGER,
        avg_ping_30d REAL,
        avg_jitter_30d REAL,
        quality_dist_excellent_30d REAL,
        quality_dist_good_30d REAL,
        quality_dist_poor_30d REAL,
        bandwidth_efficiency_30d REAL,
        connection_stability_30d REAL,
        quality_consistency_30d REAL,
        active_hours_30d REAL,
        usage_variance_30d REAL,
        peak_offpeak_ratio_30d REAL,
        connection_reliability_30d REAL,
        ping_consistency_30d REAL,
        jitter_consistency_30d REAL,
        avg_bytes_90d INTEGER,
        avg_ping_90d REAL,
        avg_jitter_90d REAL,
        quality_dist_excellent_90d REAL,
        quality_dist_good_90d REAL,
        quality_dist_poor_90d REAL,
        bandwidth_efficiency_90d REAL,
        connection_stability_90d REAL,
        quality_consistency_90d REAL,
        active_hours_90d REAL,
        usage_variance_90d REAL,
        peak_offpeak_ratio_90d REAL,
        connection_reliability_90d REAL,
        ping_consistency_90d REAL,
        jitter_consistency_90d REAL
    );" 2>/dev/null
    
    # --- Migration: Add columns to existing tables (for backward compatibility) ---
    # Note: These ALTER TABLE statements will fail silently if columns already exist (2>/dev/null)
    # This ensures existing databases get the new columns without breaking
    # New databases will have all columns from CREATE TABLE above, so these are just for migration
    
    # Add 7-day advanced statistics columns (if missing from older schema)
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN quality_dist_excellent_7d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN quality_dist_good_7d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN quality_dist_poor_7d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN bandwidth_efficiency_7d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN connection_stability_7d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN quality_consistency_7d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN active_hours_7d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN usage_variance_7d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN peak_offpeak_ratio_7d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN connection_reliability_7d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN ping_consistency_7d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN jitter_consistency_7d REAL;" 2>/dev/null
    
    # Add 30-day trend columns (for migration to support 30-day averages)
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN avg_bytes_30d INTEGER;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN avg_ping_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN avg_jitter_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN quality_dist_excellent_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN quality_dist_good_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN quality_dist_poor_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN bandwidth_efficiency_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN connection_stability_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN quality_consistency_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN active_hours_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN usage_variance_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN peak_offpeak_ratio_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN connection_reliability_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN ping_consistency_30d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN jitter_consistency_30d REAL;" 2>/dev/null
    
    # Add 90-day trend columns (for migration to support 90-day averages)
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN avg_bytes_90d INTEGER;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN avg_ping_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN avg_jitter_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN quality_dist_excellent_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN quality_dist_good_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN quality_dist_poor_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN bandwidth_efficiency_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN connection_stability_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN quality_consistency_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN active_hours_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN usage_variance_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN peak_offpeak_ratio_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN connection_reliability_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN ping_consistency_90d REAL;" 2>/dev/null
    sqlite3 "$ARCHIVE_DB_FILE" "ALTER TABLE weekly_averages ADD COLUMN jitter_consistency_90d REAL;" 2>/dev/null
    
    # --- Performance Indexes (for faster queries) ---
    # Index on daily_usage.date for date-based queries
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE INDEX IF NOT EXISTS idx_daily_usage_date ON daily_usage(date);" 2>/dev/null
    
    # Index on hourly_usage_patterns.date for date-based queries (used by Network Load Factor)
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE INDEX IF NOT EXISTS idx_hourly_usage_date ON hourly_usage_patterns(date);" 2>/dev/null
    
    # Index on connmon_quality_patterns.date for date-based queries (used by Ping/Jitter Stats)
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE INDEX IF NOT EXISTS idx_connmon_quality_date ON connmon_quality_patterns(date);" 2>/dev/null
    
    # Index on device_connections.date for date-based queries
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE INDEX IF NOT EXISTS idx_device_connections_date ON device_connections(date);" 2>/dev/null
    
    # Index on device_connections.last_seen_timestamp for sorting by recent activity
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE INDEX IF NOT EXISTS idx_device_connections_timestamp ON device_connections(last_seen_timestamp);" 2>/dev/null
    
    # Index on advanced_statistics_daily.date for date-based queries
    sqlite3 "$ARCHIVE_DB_FILE" "CREATE INDEX IF NOT EXISTS idx_advanced_stats_date ON advanced_statistics_daily(date);" 2>/dev/null
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
    # archive_device_connections
    
    # --- NEW: Archive hourly usage patterns ---
    archive_hourly_usage
    
    # --- NEW: Archive ConnMon quality patterns (hourly) ---
    archive_connmon_quality_patterns
    
    # --- NEW: Archive weekly averages (7-day history) ---
    archive_weekly_averages
    
    # --- NEW: Archive advanced statistics ---
    archive_advanced_statistics
    
    # --- NEW: Calculate and archive device session statistics ---
    # calculate_device_session_stats
}

# --- NEW: Function to calculate and archive weekly averages ---
archive_weekly_averages() {
    local today_date=$(date +%Y-%m-%d)
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Calculate 7-day average for Data Usage (Total bytes)
    # We look at the 7 days PRIOR to today to establish the baseline
    local avg_bytes_7d=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT AVG(total_bytes) FROM daily_usage WHERE date < '$today_date' AND date >= date('$today_date', '-7 days')" 2>/dev/null)
        
    # Calculate 7-day average for Ping and Jitter
    local avg_quality_7d=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT AVG(avg_ping), AVG(avg_jitter) FROM connmon_history WHERE date < '$today_date' AND date >= date('$today_date', '-7 days')" 2>/dev/null)
        
    local avg_ping_7d=""
    local avg_jitter_7d=""
    
    if [ -n "$avg_quality_7d" ] && [ "$avg_quality_7d" != "," ]; then
        avg_ping_7d=$(echo "$avg_quality_7d" | cut -d, -f1)
        avg_jitter_7d=$(echo "$avg_quality_7d" | cut -d, -f2)
    fi
    
    # Use 0 or NULL if empty
    if [ -z "$avg_bytes_7d" ]; then avg_bytes_7d="NULL"; fi
    if [ -z "$avg_ping_7d" ]; then avg_ping_7d="NULL"; fi
    if [ -z "$avg_jitter_7d" ]; then avg_jitter_7d="NULL"; fi
    
    # Calculate 7-day averages for new advanced statistics
    local advanced_stats_7d=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT 
         AVG(quality_distribution_excellent),
         AVG(quality_distribution_good),
         AVG(quality_distribution_poor),
         AVG(bandwidth_efficiency_pct),
         AVG(connection_stability_score),
         AVG(quality_consistency),
         AVG(active_hours_count),
         AVG(usage_variance),
         AVG(peak_offpeak_ratio),
         AVG(connection_reliability_pct),
         AVG(ping_consistency),
         AVG(jitter_consistency)
         FROM advanced_statistics_daily 
         WHERE date < '$today_date' AND date >= date('$today_date', '-7 days')" 2>/dev/null)
    
    local quality_exc_7d="NULL"
    local quality_good_7d="NULL"
    local quality_poor_7d="NULL"
    local bandwidth_eff_7d="NULL"
    local stability_7d="NULL"
    local quality_cons_7d="NULL"
    local active_hours_7d="NULL"
    local usage_var_7d="NULL"
    local peak_ratio_7d="NULL"
    local reliability_7d="NULL"
    local ping_cons_7d="NULL"
    local jitter_cons_7d="NULL"
    
    if [ -n "$advanced_stats_7d" ] && [ "$advanced_stats_7d" != "," ] && [ "$advanced_stats_7d" != ",,,,,,,,,,," ]; then
        quality_exc_7d=$(echo "$advanced_stats_7d" | cut -d, -f1)
        quality_good_7d=$(echo "$advanced_stats_7d" | cut -d, -f2)
        quality_poor_7d=$(echo "$advanced_stats_7d" | cut -d, -f3)
        bandwidth_eff_7d=$(echo "$advanced_stats_7d" | cut -d, -f4)
        stability_7d=$(echo "$advanced_stats_7d" | cut -d, -f5)
        quality_cons_7d=$(echo "$advanced_stats_7d" | cut -d, -f6)
        active_hours_7d=$(echo "$advanced_stats_7d" | cut -d, -f7)
        usage_var_7d=$(echo "$advanced_stats_7d" | cut -d, -f8)
        peak_ratio_7d=$(echo "$advanced_stats_7d" | cut -d, -f9)
        reliability_7d=$(echo "$advanced_stats_7d" | cut -d, -f10)
        ping_cons_7d=$(echo "$advanced_stats_7d" | cut -d, -f11)
        jitter_cons_7d=$(echo "$advanced_stats_7d" | cut -d, -f12)
        
        # Validate and set to NULL if empty
        if [ -z "$quality_exc_7d" ] || [ "$quality_exc_7d" = "" ]; then quality_exc_7d="NULL"; fi
        if [ -z "$quality_good_7d" ] || [ "$quality_good_7d" = "" ]; then quality_good_7d="NULL"; fi
        if [ -z "$quality_poor_7d" ] || [ "$quality_poor_7d" = "" ]; then quality_poor_7d="NULL"; fi
        if [ -z "$bandwidth_eff_7d" ] || [ "$bandwidth_eff_7d" = "" ]; then bandwidth_eff_7d="NULL"; fi
        if [ -z "$stability_7d" ] || [ "$stability_7d" = "" ]; then stability_7d="NULL"; fi
        if [ -z "$quality_cons_7d" ] || [ "$quality_cons_7d" = "" ]; then quality_cons_7d="NULL"; fi
        if [ -z "$active_hours_7d" ] || [ "$active_hours_7d" = "" ]; then active_hours_7d="NULL"; fi
        if [ -z "$usage_var_7d" ] || [ "$usage_var_7d" = "" ]; then usage_var_7d="NULL"; fi
        if [ -z "$peak_ratio_7d" ] || [ "$peak_ratio_7d" = "" ]; then peak_ratio_7d="NULL"; fi
        if [ -z "$reliability_7d" ] || [ "$reliability_7d" = "" ]; then reliability_7d="NULL"; fi
        if [ -z "$ping_cons_7d" ] || [ "$ping_cons_7d" = "" ]; then ping_cons_7d="NULL"; fi
        if [ -z "$jitter_cons_7d" ] || [ "$jitter_cons_7d" = "" ]; then jitter_cons_7d="NULL"; fi
    fi
    
    # Calculate 30-day averages for all metrics
    local avg_bytes_30d=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT AVG(total_bytes) FROM daily_usage WHERE date < '$today_date' AND date >= date('$today_date', '-30 days')" 2>/dev/null)
    
    local avg_quality_30d=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT AVG(avg_ping), AVG(avg_jitter) FROM connmon_history WHERE date < '$today_date' AND date >= date('$today_date', '-30 days')" 2>/dev/null)
    
    local avg_ping_30d=""
    local avg_jitter_30d=""
    
    if [ -n "$avg_quality_30d" ] && [ "$avg_quality_30d" != "," ]; then
        avg_ping_30d=$(echo "$avg_quality_30d" | cut -d, -f1)
        avg_jitter_30d=$(echo "$avg_quality_30d" | cut -d, -f2)
    fi
    
    if [ -z "$avg_bytes_30d" ]; then avg_bytes_30d="NULL"; fi
    if [ -z "$avg_ping_30d" ]; then avg_ping_30d="NULL"; fi
    if [ -z "$avg_jitter_30d" ]; then avg_jitter_30d="NULL"; fi
    
    # Calculate 30-day averages for advanced statistics
    local advanced_stats_30d=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT 
         AVG(quality_distribution_excellent),
         AVG(quality_distribution_good),
         AVG(quality_distribution_poor),
         AVG(bandwidth_efficiency_pct),
         AVG(connection_stability_score),
         AVG(quality_consistency),
         AVG(active_hours_count),
         AVG(usage_variance),
         AVG(peak_offpeak_ratio),
         AVG(connection_reliability_pct),
         AVG(ping_consistency),
         AVG(jitter_consistency)
         FROM advanced_statistics_daily 
         WHERE date < '$today_date' AND date >= date('$today_date', '-30 days')" 2>/dev/null)
    
    local quality_exc_30d="NULL"
    local quality_good_30d="NULL"
    local quality_poor_30d="NULL"
    local bandwidth_eff_30d="NULL"
    local stability_30d="NULL"
    local quality_cons_30d="NULL"
    local active_hours_30d="NULL"
    local usage_var_30d="NULL"
    local peak_ratio_30d="NULL"
    local reliability_30d="NULL"
    local ping_cons_30d="NULL"
    local jitter_cons_30d="NULL"
    
    if [ -n "$advanced_stats_30d" ] && [ "$advanced_stats_30d" != "," ] && [ "$advanced_stats_30d" != ",,,,,,,,,,," ]; then
        quality_exc_30d=$(echo "$advanced_stats_30d" | cut -d, -f1)
        quality_good_30d=$(echo "$advanced_stats_30d" | cut -d, -f2)
        quality_poor_30d=$(echo "$advanced_stats_30d" | cut -d, -f3)
        bandwidth_eff_30d=$(echo "$advanced_stats_30d" | cut -d, -f4)
        stability_30d=$(echo "$advanced_stats_30d" | cut -d, -f5)
        quality_cons_30d=$(echo "$advanced_stats_30d" | cut -d, -f6)
        active_hours_30d=$(echo "$advanced_stats_30d" | cut -d, -f7)
        usage_var_30d=$(echo "$advanced_stats_30d" | cut -d, -f8)
        peak_ratio_30d=$(echo "$advanced_stats_30d" | cut -d, -f9)
        reliability_30d=$(echo "$advanced_stats_30d" | cut -d, -f10)
        ping_cons_30d=$(echo "$advanced_stats_30d" | cut -d, -f11)
        jitter_cons_30d=$(echo "$advanced_stats_30d" | cut -d, -f12)
        
        # Validate and set to NULL if empty
        if [ -z "$quality_exc_30d" ] || [ "$quality_exc_30d" = "" ]; then quality_exc_30d="NULL"; fi
        if [ -z "$quality_good_30d" ] || [ "$quality_good_30d" = "" ]; then quality_good_30d="NULL"; fi
        if [ -z "$quality_poor_30d" ] || [ "$quality_poor_30d" = "" ]; then quality_poor_30d="NULL"; fi
        if [ -z "$bandwidth_eff_30d" ] || [ "$bandwidth_eff_30d" = "" ]; then bandwidth_eff_30d="NULL"; fi
        if [ -z "$stability_30d" ] || [ "$stability_30d" = "" ]; then stability_30d="NULL"; fi
        if [ -z "$quality_cons_30d" ] || [ "$quality_cons_30d" = "" ]; then quality_cons_30d="NULL"; fi
        if [ -z "$active_hours_30d" ] || [ "$active_hours_30d" = "" ]; then active_hours_30d="NULL"; fi
        if [ -z "$usage_var_30d" ] || [ "$usage_var_30d" = "" ]; then usage_var_30d="NULL"; fi
        if [ -z "$peak_ratio_30d" ] || [ "$peak_ratio_30d" = "" ]; then peak_ratio_30d="NULL"; fi
        if [ -z "$reliability_30d" ] || [ "$reliability_30d" = "" ]; then reliability_30d="NULL"; fi
        if [ -z "$ping_cons_30d" ] || [ "$ping_cons_30d" = "" ]; then ping_cons_30d="NULL"; fi
        if [ -z "$jitter_cons_30d" ] || [ "$jitter_cons_30d" = "" ]; then jitter_cons_30d="NULL"; fi
    fi
    
    # Insert into weekly_averages table with all metrics (7-day and 30-day)
    sqlite3 "$ARCHIVE_DB_FILE" \
        "INSERT OR REPLACE INTO weekly_averages 
         (date, avg_bytes_7d, avg_ping_7d, avg_jitter_7d,
          quality_dist_excellent_7d, quality_dist_good_7d, quality_dist_poor_7d,
          bandwidth_efficiency_7d, connection_stability_7d, quality_consistency_7d,
          active_hours_7d, usage_variance_7d, peak_offpeak_ratio_7d,
          connection_reliability_7d, ping_consistency_7d, jitter_consistency_7d,
          avg_bytes_30d, avg_ping_30d, avg_jitter_30d,
          quality_dist_excellent_30d, quality_dist_good_30d, quality_dist_poor_30d,
          bandwidth_efficiency_30d, connection_stability_30d, quality_consistency_30d,
          active_hours_30d, usage_variance_30d, peak_offpeak_ratio_30d,
          connection_reliability_30d, ping_consistency_30d, jitter_consistency_30d,
          avg_bytes_90d, avg_ping_90d, avg_jitter_90d,
          quality_dist_excellent_90d, quality_dist_good_90d, quality_dist_poor_90d,
          bandwidth_efficiency_90d, connection_stability_90d, quality_consistency_90d,
          active_hours_90d, usage_variance_90d, peak_offpeak_ratio_90d,
          connection_reliability_90d, ping_consistency_90d, jitter_consistency_90d)
         VALUES ('$today_date', $avg_bytes_7d, $avg_ping_7d, $avg_jitter_7d,
                 $quality_exc_7d, $quality_good_7d, $quality_poor_7d,
                 $bandwidth_eff_7d, $stability_7d, $quality_cons_7d,
                 $active_hours_7d, $usage_var_7d, $peak_ratio_7d,
                 $reliability_7d, $ping_cons_7d, $jitter_cons_7d,
                 $avg_bytes_30d, $avg_ping_30d, $avg_jitter_30d,
                 $quality_exc_30d, $quality_good_30d, $quality_poor_30d,
                 $bandwidth_eff_30d, $stability_30d, $quality_cons_30d,
                 $active_hours_30d, $usage_var_30d, $peak_ratio_30d,
                 $reliability_30d, $ping_cons_30d, $jitter_cons_30d,
                 $avg_bytes_90d, $avg_ping_90d, $avg_jitter_90d,
                 $quality_exc_90d, $quality_good_90d, $quality_poor_90d,
                 $bandwidth_eff_90d, $stability_90d, $quality_cons_90d,
                 $active_hours_90d, $usage_var_90d, $peak_ratio_90d,
                 $reliability_90d, $ping_cons_90d, $jitter_cons_90d);" 2>/dev/null
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
        # TrafficAnalyzer data is hourly (timestamps at :00)
        # We count the number of hourly records to determine total active time
        local num_timestamps=$(echo "$timestamps" | wc -w)
        local total_connection_time=$(($num_timestamps * 3600))
        
        # Count reconnections
        # Data points are hourly (3600s apart).
        # A gap of 3600s is normal continuity.
        # A gap > 4000s (e.g. 7200s) implies a disconnection (missed hour).
        local reconnection_count=0
        local prev_ts=""
        
        for current_ts in $timestamps; do
            if [ -n "$prev_ts" ]; then
                local gap=$(($current_ts - $prev_ts))
                # If gap is significantly larger than 1 hour (allow some buffer), count as reconnection
                if [ $gap -gt 4000 ]; then
                    reconnection_count=$(($reconnection_count + 1))
                fi
            fi
            prev_ts="$current_ts"
        done
        
        # Calculate average session duration
        # Total active time divided by number of sessions (reconnections + 1)
        local session_count=$(($reconnection_count + 1))
        local avg_session_duration=0
        
        if [ $session_count -gt 0 ]; then
            avg_session_duration=$(($total_connection_time / $session_count))
        fi
        
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
    local current_minute=$(date +%M | sed 's/^0*//')
    local current_second=$(date +%S | sed 's/^0*//')
    
    # Get current timestamp
    local now_ts=$(date +%s)
    
    # Calculate seconds into current hour
    # Ensure we have valid numbers (default to 0 if empty after stripping zeros)
    if [ -z "$current_minute" ]; then current_minute=0; fi
    if [ -z "$current_second" ]; then current_second=0; fi
    local seconds_into_hour=$((current_minute * 60 + current_second))
    
    # Last completed hour end = current time - seconds into current hour
    # This gives us the timestamp of the last :00 (when TrafficAnalyzer last saved)
    local last_hour_end=$((now_ts - seconds_into_hour))
    
    # Last completed hour start = last hour end - 3600 seconds
    local last_hour_start=$((last_hour_end - 3600))
    
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
    local current_minute=$(date +%M | sed 's/^0*//')
    local current_second=$(date +%S | sed 's/^0*//')
    local now_ts=$(date +%s)
    # Ensure we have valid numbers (default to 0 if empty after stripping zeros)
    if [ -z "$current_minute" ]; then current_minute=0; fi
    if [ -z "$current_second" ]; then current_second=0; fi
    local seconds_into_hour=$((current_minute * 60 + current_second))
    local last_hour_end=$((now_ts - seconds_into_hour))
    local last_hour_start=$((last_hour_end - 3600))
    
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
        # Remove leading zeros and calculate next hour safely
        local peak_hour_stripped=$(echo "$peak_hour" | sed 's/^0*//')
        if [ -z "$peak_hour_stripped" ]; then peak_hour_stripped=0; fi
        local peak_hour_num=$((peak_hour_stripped))
        local next_hour_num=$((peak_hour_num + 1))
        local next_hour=$(printf "%02d" $next_hour_num)
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
    
    # Get quiet hours - Based on 90-day trend (fallback to 30-day, 7-day, then today if needed)
    # This provides a more accurate pattern for longer-term trends (captures seasonal patterns in Philippines: summer/rain)
    local quiet_hours=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT hour, AVG(total_bytes) as avg_bytes
         FROM hourly_usage_patterns 
         WHERE date < '$today_date' AND date >= date('$today_date', '-90 days') AND total_bytes >= 1024
         GROUP BY hour
         ORDER BY avg_bytes ASC 
         LIMIT 3" 2>/dev/null)
    
    # Fallback to 30-day if 90-day has no data
    if [ -z "$quiet_hours" ] || [ "$quiet_hours" = "" ]; then
        quiet_hours=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
            "SELECT hour, AVG(total_bytes) as avg_bytes
             FROM hourly_usage_patterns 
             WHERE date < '$today_date' AND date >= date('$today_date', '-30 days') AND total_bytes >= 1024
             GROUP BY hour
             ORDER BY avg_bytes ASC 
             LIMIT 3" 2>/dev/null)
    fi
    
    # Fallback to 7-day if 30-day has no data
    if [ -z "$quiet_hours" ] || [ "$quiet_hours" = "" ]; then
        quiet_hours=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
            "SELECT hour, AVG(total_bytes) as avg_bytes
             FROM hourly_usage_patterns 
             WHERE date < '$today_date' AND date >= date('$today_date', '-7 days') AND total_bytes >= 1024
             GROUP BY hour
             ORDER BY avg_bytes ASC 
             LIMIT 3" 2>/dev/null)
    fi
    
    # Final fallback to today if no historical data
    if [ -z "$quiet_hours" ] || [ "$quiet_hours" = "" ]; then
        quiet_hours=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
            "SELECT hour, total_bytes
             FROM hourly_usage_patterns 
             WHERE date = '$today_date' AND total_bytes >= 1024
             ORDER BY total_bytes ASC 
             LIMIT 3" 2>/dev/null)
    fi
    
    local quiet_output="N/A"
    if [ -n "$quiet_hours" ]; then
        quiet_output=$(echo "$quiet_hours" | awk -F',' '{
            if (NR == 1) printf "%02d:00", $1
            else printf ", %02d:00", $1
        }')
    fi
    
    # Get top 3 busiest hours - Based on 90-day trend (fallback to 30-day, 7-day, then today if needed)
    # This provides a more accurate pattern for longer-term trends (captures seasonal patterns in Philippines: summer/rain)
    local busy_hours=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT hour, AVG(total_bytes) as avg_bytes
         FROM hourly_usage_patterns 
         WHERE date < '$today_date' AND date >= date('$today_date', '-90 days') AND total_bytes >= 1024
         GROUP BY hour
         ORDER BY avg_bytes DESC 
         LIMIT 3" 2>/dev/null)
    
    # Fallback to 30-day if 90-day has no data
    if [ -z "$busy_hours" ] || [ "$busy_hours" = "" ]; then
        busy_hours=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
            "SELECT hour, AVG(total_bytes) as avg_bytes
             FROM hourly_usage_patterns 
             WHERE date < '$today_date' AND date >= date('$today_date', '-30 days') AND total_bytes >= 1024
             GROUP BY hour
             ORDER BY avg_bytes DESC 
             LIMIT 3" 2>/dev/null)
    fi
    
    # Fallback to 7-day if 30-day has no data
    if [ -z "$busy_hours" ] || [ "$busy_hours" = "" ]; then
        busy_hours=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
            "SELECT hour, AVG(total_bytes) as avg_bytes
             FROM hourly_usage_patterns 
             WHERE date < '$today_date' AND date >= date('$today_date', '-7 days') AND total_bytes >= 1024
             GROUP BY hour
             ORDER BY avg_bytes DESC 
             LIMIT 3" 2>/dev/null)
    fi
    
    # Final fallback to today if no historical data
    if [ -z "$busy_hours" ] || [ "$busy_hours" = "" ]; then
        busy_hours=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
            "SELECT hour, total_bytes
             FROM hourly_usage_patterns 
             WHERE date = '$today_date' AND total_bytes >= 1024
             ORDER BY total_bytes DESC 
             LIMIT 3" 2>/dev/null)
    fi
    
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
    
    # Day vs Night comparison - Based on 90-day trend (fallback to 30-day, 7-day, then today if needed)
    # Day: 6 AM - 6 PM (12 hours), Night: 6 PM - 6 AM (12 hours)
    # Calculate average daily usage for day and night periods
    # 90-day captures seasonal patterns in Philippines (summer/rain seasons)
    local day_night_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT 
         AVG(day_total) as day_bytes,
         AVG(night_total) as night_bytes
         FROM (
             SELECT 
             date,
             SUM(CASE WHEN hour >= 6 AND hour < 18 THEN total_bytes ELSE 0 END) as day_total,
             SUM(CASE WHEN hour < 6 OR hour >= 18 THEN total_bytes ELSE 0 END) as night_total
             FROM hourly_usage_patterns 
             WHERE date < '$today_date' AND date >= date('$today_date', '-90 days')
             GROUP BY date
         )" 2>/dev/null)
    
    # Fallback to 30-day if 90-day has no data
    if [ -z "$day_night_data" ] || [ "$day_night_data" = "," ]; then
        day_night_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
            "SELECT 
             AVG(day_total) as day_bytes,
             AVG(night_total) as night_bytes
             FROM (
                 SELECT 
                 date,
                 SUM(CASE WHEN hour >= 6 AND hour < 18 THEN total_bytes ELSE 0 END) as day_total,
                 SUM(CASE WHEN hour < 6 OR hour >= 18 THEN total_bytes ELSE 0 END) as night_total
                 FROM hourly_usage_patterns 
                 WHERE date < '$today_date' AND date >= date('$today_date', '-30 days')
                 GROUP BY date
             )" 2>/dev/null)
    fi
    
    # Fallback to 7-day if 30-day has no data
    if [ -z "$day_night_data" ] || [ "$day_night_data" = "," ]; then
        day_night_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
            "SELECT 
             AVG(day_total) as day_bytes,
             AVG(night_total) as night_bytes
             FROM (
                 SELECT 
                 date,
                 SUM(CASE WHEN hour >= 6 AND hour < 18 THEN total_bytes ELSE 0 END) as day_total,
                 SUM(CASE WHEN hour < 6 OR hour >= 18 THEN total_bytes ELSE 0 END) as night_total
                 FROM hourly_usage_patterns 
                 WHERE date < '$today_date' AND date >= date('$today_date', '-7 days')
                 GROUP BY date
             )" 2>/dev/null)
    fi
    
    # Final fallback to today if no historical data
    if [ -z "$day_night_data" ] || [ "$day_night_data" = "," ]; then
        day_night_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
            "SELECT 
             SUM(CASE WHEN hour >= 6 AND hour < 18 THEN total_bytes ELSE 0 END) as day_bytes,
             SUM(CASE WHEN hour < 6 OR hour >= 18 THEN total_bytes ELSE 0 END) as night_bytes
             FROM hourly_usage_patterns 
             WHERE date = '$today_date'" 2>/dev/null)
    fi
    
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
                daynight_output="Day (06:00-18:00): <code>$day_human</code> (<code>${day_pct}%</code>) | Night (18:00-06:00): <code>$night_human</code> (<code>${night_pct}%</code>)"
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

# --- NEW: Extended Advanced Statistics Calculation Functions ---

# 1. Calculate Quality Distribution (Excellent/Good/Poor hours)
calculate_quality_distribution() {
    local today_date=$(date +%Y-%m-%d)
    local excellent=0
    local good=0
    local poor=0
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Count hours in each quality tier
    local quality_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT 
         COUNT(CASE WHEN avg_quality > 95 THEN 1 END) as excellent,
         COUNT(CASE WHEN avg_quality >= 85 AND avg_quality <= 95 THEN 1 END) as good,
         COUNT(CASE WHEN avg_quality < 85 AND avg_quality IS NOT NULL THEN 1 END) as poor
         FROM connmon_quality_patterns 
         WHERE date = '$today_date' AND avg_quality IS NOT NULL" 2>/dev/null)
    
    if [ -n "$quality_data" ] && [ "$quality_data" != "," ] && [ "$quality_data" != ",," ]; then
        excellent=$(echo "$quality_data" | cut -d, -f1)
        good=$(echo "$quality_data" | cut -d, -f2)
        poor=$(echo "$quality_data" | cut -d, -f3)
        
        # Validate counts
        if [ -z "$excellent" ] || [ "$excellent" = "" ] || [ "$excellent" = "NULL" ]; then excellent=0; fi
        if [ -z "$good" ] || [ "$good" = "" ] || [ "$good" = "NULL" ]; then good=0; fi
        if [ -z "$poor" ] || [ "$poor" = "" ] || [ "$poor" = "NULL" ]; then poor=0; fi
    fi
    
    # Store in archive
    sqlite3 "$ARCHIVE_DB_FILE" \
        "INSERT OR REPLACE INTO advanced_statistics_daily 
         (date, quality_distribution_excellent, quality_distribution_good, quality_distribution_poor) 
         VALUES ('$today_date', $excellent, $good, $poor);" 2>/dev/null
}

# 2. Calculate Bandwidth Efficiency (Peak vs Average utilization)
calculate_bandwidth_efficiency() {
    local today_date=$(date +%Y-%m-%d)
    local efficiency="NULL"
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Get peak and average bytes from hourly patterns
    local bandwidth_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT MAX(total_bytes), AVG(total_bytes) 
         FROM hourly_usage_patterns 
         WHERE date = '$today_date' AND total_bytes > 0" 2>/dev/null)
    
    if [ -n "$bandwidth_data" ] && [ "$bandwidth_data" != "," ]; then
        local peak_bytes=$(echo "$bandwidth_data" | cut -d, -f1)
        local avg_bytes=$(echo "$bandwidth_data" | cut -d, -f2)
        
        # Validate and calculate efficiency percentage
        # Use awk for floating point comparison
        local peak_check=$(awk -v p="$peak_bytes" 'BEGIN {if (p > 0) print 1; else print 0}')
        if [ -n "$peak_bytes" ] && [ "$peak_bytes" != "" ] && [ "$peak_bytes" != "NULL" ] && \
           [ -n "$avg_bytes" ] && [ "$avg_bytes" != "" ] && [ "$avg_bytes" != "NULL" ] && \
           [ "$peak_bytes" != "0" ] && [ "$peak_check" = "1" ]; then
            efficiency=$(awk -v a="$avg_bytes" -v p="$peak_bytes" 'BEGIN {
                if (p > 0) printf "%.2f", (a/p)*100
                else print "NULL"
            }')
            
            # Validate range (0-100)
            if [ -n "$efficiency" ] && [ "$efficiency" != "NULL" ]; then
                local eff_check=$(awk -v e="$efficiency" 'BEGIN {if (e >= 0 && e <= 100) print 1; else print 0}')
                if [ "$eff_check" != "1" ]; then efficiency="NULL"; fi
            fi
        fi
    fi
    
    # Store in archive
    sqlite3 "$ARCHIVE_DB_FILE" \
        "INSERT OR REPLACE INTO advanced_statistics_daily (date, bandwidth_efficiency_pct) 
         VALUES ('$today_date', $efficiency);" 2>/dev/null
}

# 3. Calculate Connection Stability Score (from Wicens data)
calculate_connection_stability() {
    local today_date=$(date +%Y-%m-%d)
    local stability="NULL"
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Get today's reboot count and uptime data
    local reboot_count=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT reboot_count FROM wicens_reboot_history WHERE date = '$today_date'" 2>/dev/null)
    
    if [ -z "$reboot_count" ] || [ "$reboot_count" = "" ] || [ "$reboot_count" = "NULL" ]; then
        reboot_count=0
    fi
    
    # Calculate stability score: 100 - (reboots * 10), minimum 0
    # Fewer reboots = higher stability
    if [ -n "$reboot_count" ] && [ "$reboot_count" != "" ]; then
        stability=$(awk -v r="$reboot_count" 'BEGIN {
            score = 100 - (r * 10)
            if (score < 0) score = 0
            if (score > 100) score = 100
            printf "%.2f", score
        }')
    fi
    
    # Store in archive
    sqlite3 "$ARCHIVE_DB_FILE" \
        "INSERT OR REPLACE INTO advanced_statistics_daily (date, connection_stability_score) 
         VALUES ('$today_date', $stability);" 2>/dev/null
}

# 4. Calculate Quality Consistency (Standard deviation of quality)
calculate_quality_consistency() {
    local today_date=$(date +%Y-%m-%d)
    local consistency="NULL"
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Calculate standard deviation of quality across hours
    local variance=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT AVG((avg_quality - (SELECT AVG(avg_quality) FROM connmon_quality_patterns WHERE date = '$today_date' AND avg_quality IS NOT NULL)) * 
                    (avg_quality - (SELECT AVG(avg_quality) FROM connmon_quality_patterns WHERE date = '$today_date' AND avg_quality IS NOT NULL)))
         FROM connmon_quality_patterns 
         WHERE date = '$today_date' AND avg_quality IS NOT NULL" 2>/dev/null)
    
    if [ -n "$variance" ] && [ "$variance" != "" ] && [ "$variance" != "NULL" ]; then
        # Calculate standard deviation (square root of variance)
        consistency=$(awk -v v="$variance" 'BEGIN {
            if (v >= 0) printf "%.2f", sqrt(v)
            else print "NULL"
        }')
        
        # Validate range (>= 0)
        if [ -n "$consistency" ] && [ "$consistency" != "NULL" ]; then
            local cons_check=$(awk -v c="$consistency" 'BEGIN {if (c >= 0) print 1; else print 0}')
            if [ "$cons_check" != "1" ]; then consistency="NULL"; fi
        fi
    fi
    
    # Store in archive
    sqlite3 "$ARCHIVE_DB_FILE" \
        "INSERT OR REPLACE INTO advanced_statistics_daily (date, quality_consistency) 
         VALUES ('$today_date', $consistency);" 2>/dev/null
}

# 5. Calculate Worst Quality Period (Hour with lowest quality)
calculate_worst_quality_period() {
    local today_date=$(date +%Y-%m-%d)
    local worst_hour="NULL"
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Find hour with lowest quality (get the hour that has the minimum quality value)
    local worst_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT hour 
         FROM connmon_quality_patterns 
         WHERE date = '$today_date' AND avg_quality IS NOT NULL 
         ORDER BY avg_quality ASC 
         LIMIT 1" 2>/dev/null)
    
    if [ -n "$worst_data" ] && [ "$worst_data" != "," ]; then
        worst_hour=$(echo "$worst_data" | cut -d, -f1)
        
        # Validate hour range (0-23)
        if [ -n "$worst_hour" ] && [ "$worst_hour" != "" ] && [ "$worst_hour" != "NULL" ]; then
            local hour_check=$(awk -v h="$worst_hour" 'BEGIN {if (h >= 0 && h <= 23) print 1; else print 0}')
            if [ "$hour_check" != "1" ]; then worst_hour="NULL"; fi
        else
            worst_hour="NULL"
        fi
    fi
    
    # Store in archive
    sqlite3 "$ARCHIVE_DB_FILE" \
        "INSERT OR REPLACE INTO advanced_statistics_daily (date, worst_quality_hour) 
         VALUES ('$today_date', $worst_hour);" 2>/dev/null
}

# 6. Calculate Active Hours Count (Hours with meaningful traffic >1MB)
calculate_active_hours() {
    local today_date=$(date +%Y-%m-%d)
    local active_hours=0
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Count hours with traffic > 1MB (1048576 bytes)
    local count=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT COUNT(*) 
         FROM hourly_usage_patterns 
         WHERE date = '$today_date' AND total_bytes > 1048576" 2>/dev/null)
    
    if [ -n "$count" ] && [ "$count" != "" ] && [ "$count" != "NULL" ]; then
        active_hours=$count
        # Validate range (0-24)
        if [ "$active_hours" -lt 0 ]; then active_hours=0; fi
        if [ "$active_hours" -gt 24 ]; then active_hours=24; fi
    fi
    
    # Store in archive
    sqlite3 "$ARCHIVE_DB_FILE" \
        "INSERT OR REPLACE INTO advanced_statistics_daily (date, active_hours_count) 
         VALUES ('$today_date', $active_hours);" 2>/dev/null
}

# 7. Calculate Usage Variance (Coefficient of variation)
calculate_usage_variance() {
    local today_date=$(date +%Y-%m-%d)
    local variance="NULL"
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Get mean and standard deviation of hourly usage
    local stats_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT AVG(total_bytes), 
         SQRT(AVG((total_bytes - (SELECT AVG(total_bytes) FROM hourly_usage_patterns WHERE date = '$today_date' AND total_bytes > 0)) * 
                  (total_bytes - (SELECT AVG(total_bytes) FROM hourly_usage_patterns WHERE date = '$today_date' AND total_bytes > 0))))
         FROM hourly_usage_patterns 
         WHERE date = '$today_date' AND total_bytes > 0" 2>/dev/null)
    
    if [ -n "$stats_data" ] && [ "$stats_data" != "," ]; then
        local mean=$(echo "$stats_data" | cut -d, -f1)
        local stddev=$(echo "$stats_data" | cut -d, -f2)
        
        # Calculate coefficient of variation (stddev/mean)
        # Use awk for floating point comparison
        local mean_check=$(awk -v m="$mean" 'BEGIN {if (m > 0) print 1; else print 0}')
        if [ -n "$mean" ] && [ "$mean" != "" ] && [ "$mean" != "NULL" ] && \
           [ -n "$stddev" ] && [ "$stddev" != "" ] && [ "$stddev" != "NULL" ] && \
           [ "$mean" != "0" ] && [ "$mean_check" = "1" ]; then
            variance=$(awk -v s="$stddev" -v m="$mean" 'BEGIN {
                if (m > 0) printf "%.4f", s/m
                else print "NULL"
            }')
            
            # Validate range (>= 0, reasonable upper bound)
            if [ -n "$variance" ] && [ "$variance" != "NULL" ]; then
                local var_check=$(awk -v v="$variance" 'BEGIN {if (v >= 0 && v < 1000) print 1; else print 0}')
                if [ "$var_check" != "1" ]; then variance="NULL"; fi
            fi
        fi
    fi
    
    # Store in archive
    sqlite3 "$ARCHIVE_DB_FILE" \
        "INSERT OR REPLACE INTO advanced_statistics_daily (date, usage_variance) 
         VALUES ('$today_date', $variance);" 2>/dev/null
}

# 8. Calculate Peak vs Off-Peak Ratio
calculate_peak_offpeak_ratio() {
    local today_date=$(date +%Y-%m-%d)
    local ratio="NULL"
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Get peak hour usage and average of quiet hours
    local peak_data=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT MAX(total_bytes) as peak,
         (SELECT AVG(total_bytes) FROM hourly_usage_patterns 
          WHERE date = '$today_date' AND total_bytes > 0 
          AND total_bytes < (SELECT MAX(total_bytes) FROM hourly_usage_patterns WHERE date = '$today_date')) as quiet_avg
         FROM hourly_usage_patterns 
         WHERE date = '$today_date' AND total_bytes > 0" 2>/dev/null)
    
    if [ -n "$peak_data" ] && [ "$peak_data" != "," ]; then
        local peak=$(echo "$peak_data" | cut -d, -f1)
        local quiet_avg=$(echo "$peak_data" | cut -d, -f2)
        
        # Calculate ratio (peak/quiet_avg)
        # Use awk for floating point comparison
        local quiet_check=$(awk -v q="$quiet_avg" 'BEGIN {if (q > 0) print 1; else print 0}')
        if [ -n "$peak" ] && [ "$peak" != "" ] && [ "$peak" != "NULL" ] && \
           [ -n "$quiet_avg" ] && [ "$quiet_avg" != "" ] && [ "$quiet_avg" != "NULL" ] && \
           [ "$quiet_avg" != "0" ] && [ "$quiet_check" = "1" ]; then
            ratio=$(awk -v p="$peak" -v q="$quiet_avg" 'BEGIN {
                if (q > 0) printf "%.2f", p/q
                else print "NULL"
            }')
            
            # Validate range (> 0, reasonable upper bound)
            if [ -n "$ratio" ] && [ "$ratio" != "NULL" ]; then
                local ratio_check=$(awk -v r="$ratio" 'BEGIN {if (r > 0 && r < 1000) print 1; else print 0}')
                if [ "$ratio_check" != "1" ]; then ratio="NULL"; fi
            fi
        fi
    fi
    
    # Store in archive
    sqlite3 "$ARCHIVE_DB_FILE" \
        "INSERT OR REPLACE INTO advanced_statistics_daily (date, peak_offpeak_ratio) 
         VALUES ('$today_date', $ratio);" 2>/dev/null
}

# 9. Calculate Connection Reliability (Percentage of hours with valid ConnMon data)
calculate_connection_reliability() {
    local today_date=$(date +%Y-%m-%d)
    local reliability="NULL"
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Count hours with valid ConnMon data vs total hours with any data
    local total_hours=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT COUNT(*) FROM connmon_quality_patterns WHERE date = '$today_date'" 2>/dev/null)
    
    local valid_hours=$(sqlite3 "$ARCHIVE_DB_FILE" \
        "SELECT COUNT(*) FROM connmon_quality_patterns WHERE date = '$today_date' AND avg_quality IS NOT NULL" 2>/dev/null)
    
    local reliability_data=""
    if [ -n "$valid_hours" ] && [ -n "$total_hours" ]; then
        reliability_data="${valid_hours},${total_hours}"
    fi
    
    if [ -n "$reliability_data" ] && [ "$reliability_data" != "," ] && [ -n "$valid_hours" ] && [ -n "$total_hours" ]; then
        local valid=$valid_hours
        local total=$total_hours
        
        # Calculate percentage
        # Use awk for floating point comparison
        local total_check=$(awk -v t="$total" 'BEGIN {if (t > 0) print 1; else print 0}')
        if [ -n "$valid" ] && [ "$valid" != "" ] && [ "$valid" != "NULL" ] && \
           [ -n "$total" ] && [ "$total" != "" ] && [ "$total" != "NULL" ] && \
           [ "$total" != "0" ] && [ "$total_check" = "1" ]; then
            reliability=$(awk -v v="$valid" -v t="$total" 'BEGIN {
                if (t > 0) printf "%.2f", (v/t)*100
                else print "NULL"
            }')
            
            # Validate range (0-100)
            if [ -n "$reliability" ] && [ "$reliability" != "NULL" ]; then
                local rel_check=$(awk -v r="$reliability" 'BEGIN {if (r >= 0 && r <= 100) print 1; else print 0}')
                if [ "$rel_check" != "1" ]; then reliability="NULL"; fi
            fi
        fi
    fi
    
    # Store in archive
    sqlite3 "$ARCHIVE_DB_FILE" \
        "INSERT OR REPLACE INTO advanced_statistics_daily (date, connection_reliability_pct) 
         VALUES ('$today_date', $reliability);" 2>/dev/null
}

# 10. Calculate Ping Consistency (Coefficient of variation for ping)
calculate_ping_consistency() {
    local today_date=$(date +%Y-%m-%d)
    local consistency="NULL"
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Get mean and standard deviation of ping
    local ping_stats=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT AVG(avg_ping),
         SQRT(AVG((avg_ping - (SELECT AVG(avg_ping) FROM connmon_quality_patterns WHERE date = '$today_date' AND avg_ping IS NOT NULL)) * 
                  (avg_ping - (SELECT AVG(avg_ping) FROM connmon_quality_patterns WHERE date = '$today_date' AND avg_ping IS NOT NULL))))
         FROM connmon_quality_patterns 
         WHERE date = '$today_date' AND avg_ping IS NOT NULL" 2>/dev/null)
    
    if [ -n "$ping_stats" ] && [ "$ping_stats" != "," ]; then
        local mean=$(echo "$ping_stats" | cut -d, -f1)
        local stddev=$(echo "$ping_stats" | cut -d, -f2)
        
        # Calculate coefficient of variation
        # Use awk for floating point comparison
        local mean_check=$(awk -v m="$mean" 'BEGIN {if (m > 0) print 1; else print 0}')
        if [ -n "$mean" ] && [ "$mean" != "" ] && [ "$mean" != "NULL" ] && \
           [ -n "$stddev" ] && [ "$stddev" != "" ] && [ "$stddev" != "NULL" ] && \
           [ "$mean" != "0" ] && [ "$mean_check" = "1" ]; then
            consistency=$(awk -v s="$stddev" -v m="$mean" 'BEGIN {
                if (m > 0) printf "%.4f", s/m
                else print "NULL"
            }')
            
            # Validate range (>= 0, reasonable upper bound)
            if [ -n "$consistency" ] && [ "$consistency" != "NULL" ]; then
                local cons_check=$(awk -v c="$consistency" 'BEGIN {if (c >= 0 && c < 1000) print 1; else print 0}')
                if [ "$cons_check" != "1" ]; then consistency="NULL"; fi
            fi
        fi
    fi
    
    # Store in archive
    sqlite3 "$ARCHIVE_DB_FILE" \
        "INSERT OR REPLACE INTO advanced_statistics_daily (date, ping_consistency) 
         VALUES ('$today_date', $consistency);" 2>/dev/null
}

# 11. Calculate Jitter Consistency (Coefficient of variation for jitter)
calculate_jitter_consistency() {
    local today_date=$(date +%Y-%m-%d)
    local consistency="NULL"
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Get mean and standard deviation of jitter
    local jitter_stats=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT AVG(avg_jitter),
         SQRT(AVG((avg_jitter - (SELECT AVG(avg_jitter) FROM connmon_quality_patterns WHERE date = '$today_date' AND avg_jitter IS NOT NULL)) * 
                  (avg_jitter - (SELECT AVG(avg_jitter) FROM connmon_quality_patterns WHERE date = '$today_date' AND avg_jitter IS NOT NULL))))
         FROM connmon_quality_patterns 
         WHERE date = '$today_date' AND avg_jitter IS NOT NULL" 2>/dev/null)
    
    if [ -n "$jitter_stats" ] && [ "$jitter_stats" != "," ]; then
        local mean=$(echo "$jitter_stats" | cut -d, -f1)
        local stddev=$(echo "$jitter_stats" | cut -d, -f2)
        
        # Calculate coefficient of variation
        # Use awk for floating point comparison
        local mean_check=$(awk -v m="$mean" 'BEGIN {if (m > 0) print 1; else print 0}')
        if [ -n "$mean" ] && [ "$mean" != "" ] && [ "$mean" != "NULL" ] && \
           [ -n "$stddev" ] && [ "$stddev" != "" ] && [ "$stddev" != "NULL" ] && \
           [ "$mean" != "0" ] && [ "$mean_check" = "1" ]; then
            consistency=$(awk -v s="$stddev" -v m="$mean" 'BEGIN {
                if (m > 0) printf "%.4f", s/m
                else print "NULL"
            }')
            
            # Validate range (>= 0, reasonable upper bound)
            if [ -n "$consistency" ] && [ "$consistency" != "NULL" ]; then
                local cons_check=$(awk -v c="$consistency" 'BEGIN {if (c >= 0 && c < 1000) print 1; else print 0}')
                if [ "$cons_check" != "1" ]; then consistency="NULL"; fi
            fi
        fi
    fi
    
    # Store in archive
    sqlite3 "$ARCHIVE_DB_FILE" \
        "INSERT OR REPLACE INTO advanced_statistics_daily (date, jitter_consistency) 
         VALUES ('$today_date', $consistency);" 2>/dev/null
}

# 12. Archive all advanced statistics (called from archive_daily_data)
archive_advanced_statistics() {
    # Call all calculation functions
    calculate_quality_distribution
    calculate_bandwidth_efficiency
    calculate_connection_stability
    calculate_quality_consistency
    calculate_worst_quality_period
    calculate_active_hours
    calculate_usage_variance
    calculate_peak_offpeak_ratio
    calculate_connection_reliability
    calculate_ping_consistency
    calculate_jitter_consistency
}

# --- NEW: Function to get advanced statistics from archive ---
# Uses user_archive.db for all historical statistical analysis
get_advanced_statistics() {
    local __result_var_ratio=$1
    local __result_var_rate=$2
    local __result_var_ping=$3
    local __result_var_jitter=$4
    local __result_var_load=$5
    
    local today_date=$(date +%Y-%m-%d)
    local midnight_today=$(date -d "00:00:00" +%s)
    
    # Initialize defaults
    eval $__result_var_ratio="'N/A'"
    eval $__result_var_rate="'N/A'"
    eval $__result_var_ping="'N/A'"
    eval $__result_var_jitter="'N/A'"
    eval $__result_var_load="'N/A'"
    
    # 1. Traffic Ratio (Down/Up)
    # Best practice: Calculate ratio from live DB for today's traffic
    if [ -f "$LIVE_DB_FILE" ]; then
        local traffic_data=$(sqlite3 -separator ',' "$LIVE_DB_FILE" \
            "SELECT COALESCE(SUM(rx), 0), COALESCE(SUM(tx), 0) FROM traffic WHERE timestamp >= $midnight_today" 2>/dev/null)
            
        if [ -n "$traffic_data" ] && [ "$traffic_data" != "," ]; then
            local rx=$(echo "$traffic_data" | cut -d, -f1)
            local tx=$(echo "$traffic_data" | cut -d, -f2)
            
            # Validate and default to 0 if empty or NULL
            if [ -z "$rx" ] || [ "$rx" = "" ] || [ "$rx" = "NULL" ]; then rx=0; fi
            if [ -z "$tx" ] || [ "$tx" = "" ] || [ "$tx" = "NULL" ]; then tx=0; fi
            
            local total=$(awk -v r="$rx" -v t="$tx" 'BEGIN {
                r_num = r + 0
                t_num = t + 0
                printf "%.0f", r_num + t_num
            }')
            
            # Only calculate ratio if we have meaningful traffic (at least 1KB)
            # Use awk for floating point comparison
            local total_check=$(awk -v t="$total" 'BEGIN {if (t >= 1024) print 1; else print 0}')
            if [ -n "$total" ] && [ "$total" != "" ] && [ "$total" != "0" ] && [ "$total_check" = "1" ]; then
                local rx_pct=$(awk -v r="$rx" -v tot="$total" 'BEGIN {
                    if (tot > 0) printf "%.0f", (r/tot)*100
                    else print 0
                }')
                local tx_pct=$(awk -v t="$tx" -v tot="$total" 'BEGIN {
                    if (tot > 0) printf "%.0f", (t/tot)*100
                    else print 0
                }')
                
                # Validate percentages sum to 100 (with small tolerance for rounding)
                # Use awk for floating point comparison
                local sum_check=$(awk -v r="$rx_pct" -v t="$tx_pct" 'BEGIN {printf "%.0f", r + t}')
                local sum_range_check=$(awk -v s="$sum_check" 'BEGIN {if (s >= 99 && s <= 101) print 1; else print 0}')
                if [ "$sum_range_check" = "1" ]; then
                    # Get 7-day average for comparison
                    # Note: We don't store separate rx/tx in daily_usage, so we can't compare ratio history directly without schema change.
                    # Skipping ratio comparison for now to avoid complexity/schema changes.
                    
                    eval $__result_var_ratio="'Download: ${rx_pct}% | Upload: ${tx_pct}%'"
                fi
            fi
        fi
    fi
    
    # 2. Hourly Data Rate (Current Pace)
    # Use Total Bytes Today / Hours Elapsed
    # Best practice: Count actual hours with data from hourly_usage_patterns for accuracy
    # This avoids issues with early-day calculations and provides more accurate rates
    if [ -f "$ARCHIVE_DB_FILE" ]; then
        # Count hours that have data (more accurate than using current hour)
        local hours_with_data=$(sqlite3 "$ARCHIVE_DB_FILE" \
            "SELECT COUNT(*) FROM hourly_usage_patterns WHERE date = '$today_date' AND total_bytes > 0" 2>/dev/null)
        
        # Fallback: Calculate actual elapsed hours if no data yet
        local hours_elapsed=1
        if [ -n "$hours_with_data" ] && [ "$hours_with_data" != "" ] && [ "$hours_with_data" != "0" ]; then
            hours_elapsed=$hours_with_data
        else
            # If no hourly data yet, calculate from current time
            local current_hour=$(date +%H)
            local current_minute=$(date +%M)
            # Calculate actual hours elapsed (including partial hour as full hour for rate calculation)
            hours_elapsed=$(awk -v h="$current_hour" -v m="$current_minute" 'BEGIN {
                if (h == 0 && m < 5) print 1  # Very early morning, assume 1 hour
                else print h + 1
            }')
        fi
        
        # Ensure minimum of 1 hour to avoid division by zero
        if [ -z "$hours_elapsed" ] || [ "$hours_elapsed" = "0" ]; then
            hours_elapsed=1
        fi
        
        local total_bytes=$(sqlite3 "$ARCHIVE_DB_FILE" "SELECT SUM(total_bytes) FROM daily_usage WHERE date = '$today_date'" 2>/dev/null)
        
        if [ -n "$total_bytes" ] && [ "$total_bytes" != "" ] && [ "$total_bytes" != "0" ]; then
             local avg_rate=$(awk -v b="$total_bytes" -v h="$hours_elapsed" 'BEGIN {
                 if (h > 0) printf "%.0f", b / h
                 else print 0
             }')
             local rate_human=$(bytes_to_human $avg_rate)
             
             # Get 7-day average rate from weekly_averages table
             local seven_day_avg=$(sqlite3 "$ARCHIVE_DB_FILE" \
                "SELECT avg_bytes_7d FROM weekly_averages WHERE date = '$today_date'" 2>/dev/null)
             
             local comparison_str=""
             if [ -n "$seven_day_avg" ] && [ "$seven_day_avg" != "" ] && [ "$seven_day_avg" != "NULL" ] && [ "$seven_day_avg" != "0" ]; then
                 local seven_day_rate=$(awk -v d="$seven_day_avg" 'BEGIN {printf "%.0f", d / 24}')
                 local seven_day_human=$(bytes_to_human $seven_day_rate)
                 comparison_str=" (vs ${seven_day_human})"
             fi
             
             eval $__result_var_rate="'$rate_human/hour${comparison_str}'"
        fi
    fi
    
    # 3. Peak vs Avg Ping & Jitter
    # Best practice: Only show stats if we have sufficient data (at least 2 hours) for meaningful comparison
    if [ -f "$ARCHIVE_DB_FILE" ]; then
        # Check if we have enough data points for meaningful stats
        local hours_count=$(sqlite3 "$ARCHIVE_DB_FILE" \
            "SELECT COUNT(*) FROM connmon_quality_patterns WHERE date = '$today_date' AND avg_ping IS NOT NULL" 2>/dev/null)
        
        if [ -n "$hours_count" ] && [ "$hours_count" != "" ] && [ "$hours_count" != "0" ]; then
            local conn_stats=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
                "SELECT MAX(avg_ping), AVG(avg_ping), MAX(avg_jitter), AVG(avg_jitter) FROM connmon_quality_patterns WHERE date = '$today_date' AND avg_ping IS NOT NULL" 2>/dev/null)
                
            if [ -n "$conn_stats" ] && [ "$conn_stats" != "," ] && [ "$conn_stats" != ",,," ]; then
                local max_ping=$(echo "$conn_stats" | cut -d, -f1)
                local avg_ping=$(echo "$conn_stats" | cut -d, -f2)
                local max_jitter=$(echo "$conn_stats" | cut -d, -f3)
                local avg_jitter=$(echo "$conn_stats" | cut -d, -f4)
                
                # Validate that we have numeric values
                if [ -n "$max_ping" ] && [ "$max_ping" != "" ] && [ "$max_ping" != "NULL" ] && \
                   [ -n "$avg_ping" ] && [ "$avg_ping" != "" ] && [ "$avg_ping" != "NULL" ]; then
                    # Get 7-day averages for comparison from weekly_averages table
                    local seven_day_stats=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
                        "SELECT avg_ping_7d, avg_jitter_7d FROM weekly_averages WHERE date = '$today_date'" 2>/dev/null)
                    local seven_day_ping=""
                    local seven_day_jitter=""
                    if [ -n "$seven_day_stats" ] && [ "$seven_day_stats" != "," ]; then
                        seven_day_ping=$(echo "$seven_day_stats" | cut -d, -f1)
                        seven_day_jitter=$(echo "$seven_day_stats" | cut -d, -f2)
                    fi

                    # Format ping stats with validation
                    local max_fmt=$(printf "%.0f" "$max_ping" 2>/dev/null || echo "0")
                    local avg_fmt=$(printf "%.0f" "$avg_ping" 2>/dev/null || echo "0")
                    
                    local ping_comp=""
                    if [ -n "$seven_day_ping" ] && [ "$seven_day_ping" != "" ] && [ "$seven_day_ping" != "NULL" ]; then
                        local s_ping_fmt=$(printf "%.0f" "$seven_day_ping" 2>/dev/null || echo "0")
                        ping_comp=" (vs ${s_ping_fmt}ms)"
                    fi
                    
                    eval $__result_var_ping="'Avg: ${avg_fmt}ms${ping_comp} | Peak: ${max_fmt}ms'"
                fi
                
                # Format jitter stats with validation
                if [ -n "$max_jitter" ] && [ "$max_jitter" != "" ] && [ "$max_jitter" != "NULL" ] && \
                   [ -n "$avg_jitter" ] && [ "$avg_jitter" != "" ] && [ "$avg_jitter" != "NULL" ]; then
                    local max_j_fmt=$(printf "%.1f" "$max_jitter" 2>/dev/null || echo "0.0")
                    local avg_j_fmt=$(printf "%.1f" "$avg_jitter" 2>/dev/null || echo "0.0")
                    
                    local jitter_comp=""
                    if [ -n "$seven_day_jitter" ] && [ "$seven_day_jitter" != "" ] && [ "$seven_day_jitter" != "NULL" ]; then
                        local s_jitter_fmt=$(printf "%.1f" "$seven_day_jitter" 2>/dev/null || echo "0.0")
                        jitter_comp=" (vs ${s_jitter_fmt}ms)"
                    fi
                    
                    eval $__result_var_jitter="'Avg: ${avg_j_fmt}ms${jitter_comp} | Peak: ${max_j_fmt}ms'"
                fi
            fi
        fi
    fi
    
    # 4. Network Load Factor (Avg / Peak)
    # Best practice: Calculate load factor only with sufficient data points for accuracy
    if [ -f "$ARCHIVE_DB_FILE" ]; then
        # Check if we have enough data points (hours) to make this meaningful
        # If only 1 or 2 hours of data, "Avg" will be close to "Peak", misleadingly showing "Constant"
        local hours_count=$(sqlite3 "$ARCHIVE_DB_FILE" \
            "SELECT COUNT(*) FROM hourly_usage_patterns WHERE date = '$today_date' AND total_bytes > 0" 2>/dev/null)
        
        if [ -n "$hours_count" ] && [ "$hours_count" != "" ] && [ "$hours_count" != "0" ] && [ "$hours_count" -ge 3 ]; then
            local load_stats=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
                "SELECT MAX(total_bytes), AVG(total_bytes) FROM hourly_usage_patterns WHERE date = '$today_date' AND total_bytes > 0" 2>/dev/null)
                
            if [ -n "$load_stats" ] && [ "$load_stats" != "," ]; then
                local max_bytes=$(echo "$load_stats" | cut -d, -f1)
                local avg_bytes=$(echo "$load_stats" | cut -d, -f2)
                
                # Validate that we have meaningful data
                if [ -n "$max_bytes" ] && [ "$max_bytes" != "0" ] && [ "$max_bytes" != "" ] && [ "$max_bytes" != "NULL" ] && \
                   [ -n "$avg_bytes" ] && [ "$avg_bytes" != "" ] && [ "$avg_bytes" != "NULL" ]; then
                    # Calculate load factor with division by zero protection
                    local load_factor=$(awk -v a="$avg_bytes" -v m="$max_bytes" 'BEGIN {
                        if (m > 0) printf "%.0f", (a/m)*100
                        else print 0
                    }')
                    
                    # Validate load_factor is within reasonable range (0-100)
                    # Use awk for floating point comparison
                    local load_range_check=$(awk -v l="$load_factor" 'BEGIN {if (l >= 0 && l <= 100) print 1; else print 0}')
                    if [ -n "$load_factor" ] && [ "$load_factor" != "" ] && [ "$load_range_check" = "1" ]; then
                        # 100% = Constant load, Low % = Bursty
                        local load_desc=""
                        local load_80_check=$(awk -v l="$load_factor" 'BEGIN {if (l >= 80) print 1; else print 0}')
                        local load_50_check=$(awk -v l="$load_factor" 'BEGIN {if (l >= 50) print 1; else print 0}')
                        if [ "$load_80_check" = "1" ]; then load_desc="Constant";
                        elif [ "$load_50_check" = "1" ]; then load_desc="Balanced";
                        else load_desc="Bursty"; fi
                        
                        eval $__result_var_load="'${load_factor}% ($load_desc)'"
                    fi
                fi
            fi
        elif [ -n "$hours_count" ] && [ "$hours_count" != "" ] && [ "$hours_count" != "0" ]; then
            # Less than 3 hours of data - show collecting message
            eval $__result_var_load="'Collecting Data...'"
        fi
    fi
}

# --- NEW: Function to get extended advanced statistics with 7-day comparisons ---
# Uses simple, user-friendly labels and includes 7-day averages for context
get_extended_advanced_statistics() {
    local today_date=$(date +%Y-%m-%d)
    
    # Initialize all result variables to N/A
    local __result_var_quality_breakdown=$1
    local __result_var_speed_efficiency=$2
    local __result_var_connection_stability=$3
    local __result_var_quality_consistency=$4
    local __result_var_worst_hour=$5
    local __result_var_active_hours=$6
    local __result_var_usage_consistency=$7
    local __result_var_peak_quiet=$8
    local __result_var_data_reliability=$9
    # Access parameters 10 and 11 directly (bash supports ${10}, ${11})
    local __result_var_ping_consistency="${10}"
    local __result_var_jitter_consistency="${11}"
    
    eval $__result_var_quality_breakdown="'N/A'"
    eval $__result_var_speed_efficiency="'N/A'"
    eval $__result_var_connection_stability="'N/A'"
    eval $__result_var_quality_consistency="'N/A'"
    eval $__result_var_worst_hour="'N/A'"
    eval $__result_var_active_hours="'N/A'"
    eval $__result_var_usage_consistency="'N/A'"
    eval $__result_var_peak_quiet="'N/A'"
    eval $__result_var_data_reliability="'N/A'"
    eval $__result_var_ping_consistency="'N/A'"
    eval $__result_var_jitter_consistency="'N/A'"
    
    if [ ! -f "$ARCHIVE_DB_FILE" ]; then
        return
    fi
    
    # Get today's statistics
    local today_stats=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT 
         quality_distribution_excellent, quality_distribution_good, quality_distribution_poor,
         bandwidth_efficiency_pct, connection_stability_score, quality_consistency,
         worst_quality_hour, active_hours_count, usage_variance,
         peak_offpeak_ratio, connection_reliability_pct, ping_consistency, jitter_consistency
         FROM advanced_statistics_daily 
         WHERE date = '$today_date'" 2>/dev/null)
    
    # Get 7-day, 30-day, and 90-day averages for comparison
    local weekly_stats=$(sqlite3 -separator ',' "$ARCHIVE_DB_FILE" \
        "SELECT 
         quality_dist_excellent_7d, quality_dist_good_7d, quality_dist_poor_7d,
         bandwidth_efficiency_7d, connection_stability_7d, quality_consistency_7d,
         active_hours_7d, usage_variance_7d, peak_offpeak_ratio_7d,
         connection_reliability_7d, ping_consistency_7d, jitter_consistency_7d,
         quality_dist_excellent_30d, quality_dist_good_30d, quality_dist_poor_30d,
         bandwidth_efficiency_30d, connection_stability_30d, quality_consistency_30d,
         active_hours_30d, usage_variance_30d, peak_offpeak_ratio_30d,
         connection_reliability_30d, ping_consistency_30d, jitter_consistency_30d,
         quality_dist_excellent_90d, quality_dist_good_90d, quality_dist_poor_90d,
         bandwidth_efficiency_90d, connection_stability_90d, quality_consistency_90d,
         active_hours_90d, usage_variance_90d, peak_offpeak_ratio_90d,
         connection_reliability_90d, ping_consistency_90d, jitter_consistency_90d
         FROM weekly_averages 
         WHERE date = '$today_date'" 2>/dev/null)
    
    # Always parse 7-day and 30-day trends (even if today's stats are missing)
    local exc_7d=""
    local good_7d=""
    local poor_7d=""
    local eff_7d=""
    local stability_7d=""
    local q_cons_7d=""
    local active_7d=""
    local usage_var_7d=""
    local peak_ratio_7d=""
    local reliability_7d=""
    local ping_cons_7d=""
    local jitter_cons_7d=""
    local exc_30d=""
    local good_30d=""
    local poor_30d=""
    local eff_30d=""
    local stability_30d=""
    local q_cons_30d=""
    local active_30d=""
    local usage_var_30d=""
    local peak_ratio_30d=""
    local reliability_30d=""
    local ping_cons_30d=""
    local jitter_cons_30d=""
    
    if [ -n "$weekly_stats" ] && [ "$weekly_stats" != "," ] && [ "$weekly_stats" != ",,,,,,,,,,," ]; then
        # Parse 7-day averages (fields 1-12)
        exc_7d=$(echo "$weekly_stats" | cut -d, -f1)
        good_7d=$(echo "$weekly_stats" | cut -d, -f2)
        poor_7d=$(echo "$weekly_stats" | cut -d, -f3)
        eff_7d=$(echo "$weekly_stats" | cut -d, -f4)
        stability_7d=$(echo "$weekly_stats" | cut -d, -f5)
        q_cons_7d=$(echo "$weekly_stats" | cut -d, -f6)
        active_7d=$(echo "$weekly_stats" | cut -d, -f7)
        usage_var_7d=$(echo "$weekly_stats" | cut -d, -f8)
        peak_ratio_7d=$(echo "$weekly_stats" | cut -d, -f9)
        reliability_7d=$(echo "$weekly_stats" | cut -d, -f10)
        ping_cons_7d=$(echo "$weekly_stats" | cut -d, -f11)
        jitter_cons_7d=$(echo "$weekly_stats" | cut -d, -f12)
        # Parse 30-day averages (fields 13-24)
        exc_30d=$(echo "$weekly_stats" | cut -d, -f13)
        good_30d=$(echo "$weekly_stats" | cut -d, -f14)
        poor_30d=$(echo "$weekly_stats" | cut -d, -f15)
        eff_30d=$(echo "$weekly_stats" | cut -d, -f16)
        stability_30d=$(echo "$weekly_stats" | cut -d, -f17)
        q_cons_30d=$(echo "$weekly_stats" | cut -d, -f18)
        active_30d=$(echo "$weekly_stats" | cut -d, -f19)
        usage_var_30d=$(echo "$weekly_stats" | cut -d, -f20)
        peak_ratio_30d=$(echo "$weekly_stats" | cut -d, -f21)
        reliability_30d=$(echo "$weekly_stats" | cut -d, -f22)
        ping_cons_30d=$(echo "$weekly_stats" | cut -d, -f23)
        jitter_cons_30d=$(echo "$weekly_stats" | cut -d, -f24)
        # Parse 90-day averages (fields 25-36)
        exc_90d=$(echo "$weekly_stats" | cut -d, -f25)
        good_90d=$(echo "$weekly_stats" | cut -d, -f26)
        poor_90d=$(echo "$weekly_stats" | cut -d, -f27)
        eff_90d=$(echo "$weekly_stats" | cut -d, -f28)
        stability_90d=$(echo "$weekly_stats" | cut -d, -f29)
        q_cons_90d=$(echo "$weekly_stats" | cut -d, -f30)
        active_90d=$(echo "$weekly_stats" | cut -d, -f31)
        usage_var_90d=$(echo "$weekly_stats" | cut -d, -f32)
        peak_ratio_90d=$(echo "$weekly_stats" | cut -d, -f33)
        reliability_90d=$(echo "$weekly_stats" | cut -d, -f34)
        ping_cons_90d=$(echo "$weekly_stats" | cut -d, -f35)
        jitter_cons_90d=$(echo "$weekly_stats" | cut -d, -f36)
    else
        # Initialize 90-day variables to empty
        exc_90d=""
        good_90d=""
        poor_90d=""
        eff_90d=""
        stability_90d=""
        q_cons_90d=""
        active_90d=""
        usage_var_90d=""
        peak_ratio_90d=""
        reliability_90d=""
        ping_cons_90d=""
        jitter_cons_90d=""
    fi
    
    if [ -n "$today_stats" ] && [ "$today_stats" != "," ] && [ "$today_stats" != ",,,,,,,,,,," ]; then
        # Parse today's values
        local exc=$(echo "$today_stats" | cut -d, -f1)
        local good=$(echo "$today_stats" | cut -d, -f2)
        local poor=$(echo "$today_stats" | cut -d, -f3)
        local eff=$(echo "$today_stats" | cut -d, -f4)
        local stability=$(echo "$today_stats" | cut -d, -f5)
        local q_cons=$(echo "$today_stats" | cut -d, -f6)
        local worst_h=$(echo "$today_stats" | cut -d, -f7)
        local active=$(echo "$today_stats" | cut -d, -f8)
        local usage_var=$(echo "$today_stats" | cut -d, -f9)
        local peak_ratio=$(echo "$today_stats" | cut -d, -f10)
        local reliability=$(echo "$today_stats" | cut -d, -f11)
        local ping_cons=$(echo "$today_stats" | cut -d, -f12)
        local jitter_cons=$(echo "$today_stats" | cut -d, -f13)
    fi
    
    # Always format output with trends (even if today's stats are missing)
    # 1. Quality Breakdown (Excellent/Good/Poor hours)
    # Always show trends even if today's data is missing
    local exc=""
    local good=""
    local poor=""
    if [ -n "$today_stats" ] && [ "$today_stats" != "," ] && [ "$today_stats" != ",,,,,,,,,,," ]; then
        exc=$(echo "$today_stats" | cut -d, -f1)
        good=$(echo "$today_stats" | cut -d, -f2)
        poor=$(echo "$today_stats" | cut -d, -f3)
    fi
    
    # Format 7-day, 30-day, and 90-day trends with proper units
    local exc_7d_str="N/A"
    local exc_30d_str="N/A"
    local exc_90d_str="N/A"
    if [ -n "$exc_7d" ] && [ "$exc_7d" != "" ] && [ "$exc_7d" != "NULL" ]; then
        local val=$(printf "%.0f" "$exc_7d" 2>/dev/null || echo "N/A")
        if [ "$val" != "N/A" ]; then exc_7d_str="${val}h"; else exc_7d_str="N/A"; fi
    fi
    if [ -n "$exc_30d" ] && [ "$exc_30d" != "" ] && [ "$exc_30d" != "NULL" ]; then
        local val=$(printf "%.0f" "$exc_30d" 2>/dev/null || echo "N/A")
        if [ "$val" != "N/A" ]; then exc_30d_str="${val}h"; else exc_30d_str="N/A"; fi
    fi
    if [ -n "$exc_90d" ] && [ "$exc_90d" != "" ] && [ "$exc_90d" != "NULL" ]; then
        local val=$(printf "%.0f" "$exc_90d" 2>/dev/null || echo "N/A")
        if [ "$val" != "N/A" ]; then exc_90d_str="${val}h"; else exc_90d_str="N/A"; fi
    fi
    
    # Format today's values if available
    if [ -n "$exc" ] && [ "$exc" != "" ] && [ "$exc" != "NULL" ] && \
       [ -n "$good" ] && [ "$good" != "" ] && [ "$good" != "NULL" ] && \
       [ -n "$poor" ] && [ "$poor" != "" ] && [ "$poor" != "NULL" ]; then
        local total_hours=$(awk -v e="$exc" -v g="$good" -v p="$poor" 'BEGIN {printf "%.0f", e + g + p}')
        # Use awk for floating point comparison
        local total_check=$(awk -v t="$total_hours" 'BEGIN {if (t > 0) print 1; else print 0}')
        if [ "$total_check" = "1" ]; then
            local exc_pct=$(awk -v e="$exc" -v t="$total_hours" 'BEGIN {if (t > 0) printf "%.0f", (e/t)*100; else print 0}')
            eval $__result_var_quality_breakdown="'Exc: <code>${exc}h</code> (<code>${exc_pct}%</code>) | 7d:<code>${exc_7d_str}</code> 30d:<code>${exc_30d_str}</code> 90d:<code>${exc_90d_str}</code> | Good:<code>${good}h</code> Poor:<code>${poor}h</code>'"
        else
            eval $__result_var_quality_breakdown="'Exc: N/A | 7d:<code>${exc_7d_str}</code> 30d:<code>${exc_30d_str}</code> 90d:<code>${exc_90d_str}</code> | Good:N/A Poor:N/A'"
        fi
    else
        # Show trends even if today's data is missing
        eval $__result_var_quality_breakdown="'Exc: N/A | 7d:<code>${exc_7d_str}</code> 30d:<code>${exc_30d_str}</code> 90d:<code>${exc_90d_str}</code> | Good:N/A Poor:N/A'"
    fi
        
    # 2. Speed Efficiency (Bandwidth efficiency percentage)
    local eff=""
    if [ -n "$today_stats" ] && [ "$today_stats" != "," ] && [ "$today_stats" != ",,,,,,,,,,," ]; then
        eff=$(echo "$today_stats" | cut -d, -f4)
    fi
    local eff_fmt="N/A"
    if [ -n "$eff" ] && [ "$eff" != "" ] && [ "$eff" != "NULL" ]; then
        eff_fmt=$(printf "%.1f" "$eff" 2>/dev/null || echo "N/A")
    fi
    local comp_7d="N/A"
    local comp_30d="N/A"
    if [ -n "$eff_7d" ] && [ "$eff_7d" != "" ] && [ "$eff_7d" != "NULL" ]; then
        comp_7d=$(printf "%.1f" "$eff_7d" 2>/dev/null || echo "N/A")
    fi
    if [ -n "$eff_30d" ] && [ "$eff_30d" != "" ] && [ "$eff_30d" != "NULL" ]; then
        comp_30d=$(printf "%.1f" "$eff_30d" 2>/dev/null || echo "N/A")
    fi
    # Format: add % only if value is not N/A
    local eff_display="${eff_fmt}"
    if [ "$eff_fmt" != "N/A" ]; then eff_display="${eff_fmt}%"; fi
    local comp_7d_display="${comp_7d}"
    if [ "$comp_7d" != "N/A" ]; then comp_7d_display="${comp_7d}%"; fi
    local comp_30d_display="${comp_30d}"
    if [ "$comp_30d" != "N/A" ]; then comp_30d_display="${comp_30d}%"; fi
    local comp_90d="N/A"
    if [ -n "$eff_90d" ] && [ "$eff_90d" != "" ] && [ "$eff_90d" != "NULL" ]; then
        comp_90d=$(printf "%.1f" "$eff_90d" 2>/dev/null || echo "N/A")
    fi
    local comp_90d_display="${comp_90d}"
    if [ "$comp_90d" != "N/A" ]; then comp_90d_display="${comp_90d}%"; fi
    eval $__result_var_speed_efficiency="'${eff_display} | 7d:${comp_7d_display} 30d:${comp_30d_display} 90d:${comp_90d_display}'"
    
    # 3. Connection Stability (Stability score)
    local stability=""
    if [ -n "$today_stats" ] && [ "$today_stats" != "," ] && [ "$today_stats" != ",,,,,,,,,,," ]; then
        stability=$(echo "$today_stats" | cut -d, -f5)
    fi
    local stab_fmt="N/A"
    if [ -n "$stability" ] && [ "$stability" != "" ] && [ "$stability" != "NULL" ]; then
        stab_fmt=$(printf "%.0f" "$stability" 2>/dev/null || echo "N/A")
    fi
    local comp_7d="N/A"
    local comp_30d="N/A"
    if [ -n "$stability_7d" ] && [ "$stability_7d" != "" ] && [ "$stability_7d" != "NULL" ]; then
        comp_7d=$(printf "%.0f" "$stability_7d" 2>/dev/null || echo "N/A")
    fi
    if [ -n "$stability_30d" ] && [ "$stability_30d" != "" ] && [ "$stability_30d" != "NULL" ]; then
        comp_30d=$(printf "%.0f" "$stability_30d" 2>/dev/null || echo "N/A")
    fi
    local comp_90d="N/A"
    if [ -n "$stability_90d" ] && [ "$stability_90d" != "" ] && [ "$stability_90d" != "NULL" ]; then
        comp_90d=$(printf "%.0f" "$stability_90d" 2>/dev/null || echo "N/A")
    fi
    eval $__result_var_connection_stability="'${stab_fmt} | 7d:${comp_7d} 30d:${comp_30d} 90d:${comp_90d}'"
    
    # 4. Quality Consistency (Standard deviation)
    local q_cons=""
    if [ -n "$today_stats" ] && [ "$today_stats" != "," ] && [ "$today_stats" != ",,,,,,,,,,," ]; then
        q_cons=$(echo "$today_stats" | cut -d, -f6)
    fi
    local q_cons_fmt="N/A"
    if [ -n "$q_cons" ] && [ "$q_cons" != "" ] && [ "$q_cons" != "NULL" ]; then
        q_cons_fmt=$(printf "%.2f" "$q_cons" 2>/dev/null || echo "N/A")
    fi
    local comp_7d="N/A"
    local comp_30d="N/A"
        if [ -n "$q_cons_7d" ] && [ "$q_cons_7d" != "" ] && [ "$q_cons_7d" != "NULL" ]; then
            comp_7d=$(printf "%.2f" "$q_cons_7d" 2>/dev/null || echo "N/A")
        fi
    if [ -n "$q_cons_30d" ] && [ "$q_cons_30d" != "" ] && [ "$q_cons_30d" != "NULL" ]; then
        comp_30d=$(printf "%.2f" "$q_cons_30d" 2>/dev/null || echo "N/A")
    fi
    local comp_90d="N/A"
    if [ -n "$q_cons_90d" ] && [ "$q_cons_90d" != "" ] && [ "$q_cons_90d" != "NULL" ]; then
        comp_90d=$(printf "%.2f" "$q_cons_90d" 2>/dev/null || echo "N/A")
    fi
    eval $__result_var_quality_consistency="'${q_cons_fmt} | 7d:${comp_7d} 30d:${comp_30d} 90d:${comp_90d}'"
        
        # 5. Worst Hour (Hour with lowest quality)
        if [ -n "$worst_h" ] && [ "$worst_h" != "" ] && [ "$worst_h" != "NULL" ]; then
            local worst_h_fmt=$(printf "%02d:00" "$worst_h" 2>/dev/null || echo "N/A")
            eval $__result_var_worst_hour="'${worst_h_fmt}'"
        fi
        
        # 6. Active Hours (Hours with meaningful traffic)
        local active=""
        if [ -n "$today_stats" ] && [ "$today_stats" != "," ] && [ "$today_stats" != ",,,,,,,,,,," ]; then
            active=$(echo "$today_stats" | cut -d, -f8)
        fi
    local active_fmt="N/A"
    if [ -n "$active" ] && [ "$active" != "" ] && [ "$active" != "NULL" ]; then
        local val=$(printf "%.0f" "$active" 2>/dev/null || echo "N/A")
        if [ "$val" != "N/A" ]; then active_fmt="${val}h"; else active_fmt="N/A"; fi
    fi
    local comp_7d="N/A"
    local comp_30d="N/A"
        if [ -n "$active_7d" ] && [ "$active_7d" != "" ] && [ "$active_7d" != "NULL" ]; then
            local val=$(printf "%.1f" "$active_7d" 2>/dev/null || echo "N/A")
            if [ "$val" != "N/A" ]; then comp_7d="${val}h"; else comp_7d="N/A"; fi
        fi
    if [ -n "$active_30d" ] && [ "$active_30d" != "" ] && [ "$active_30d" != "NULL" ]; then
        local val=$(printf "%.1f" "$active_30d" 2>/dev/null || echo "N/A")
        if [ "$val" != "N/A" ]; then comp_30d="${val}h"; else comp_30d="N/A"; fi
    fi
    local comp_90d="N/A"
    if [ -n "$active_90d" ] && [ "$active_90d" != "" ] && [ "$active_90d" != "NULL" ]; then
        local val=$(printf "%.1f" "$active_90d" 2>/dev/null || echo "N/A")
        if [ "$val" != "N/A" ]; then comp_90d="${val}h"; else comp_90d="N/A"; fi
    fi
    eval $__result_var_active_hours="'<code>${active_fmt}</code> | 7d:<code>${comp_7d}</code> 30d:<code>${comp_30d}</code> 90d:<code>${comp_90d}</code>'"
    
    # 7. Usage Consistency (Coefficient of variation)
    local usage_var=""
    if [ -n "$today_stats" ] && [ "$today_stats" != "," ] && [ "$today_stats" != ",,,,,,,,,,," ]; then
        usage_var=$(echo "$today_stats" | cut -d, -f9)
    fi
    local usage_var_fmt="N/A"
    if [ -n "$usage_var" ] && [ "$usage_var" != "" ] && [ "$usage_var" != "NULL" ]; then
        usage_var_fmt=$(printf "%.4f" "$usage_var" 2>/dev/null || echo "N/A")
    fi
    local comp_7d="N/A"
    local comp_30d="N/A"
        if [ -n "$usage_var_7d" ] && [ "$usage_var_7d" != "" ] && [ "$usage_var_7d" != "NULL" ]; then
            comp_7d=$(printf "%.4f" "$usage_var_7d" 2>/dev/null || echo "N/A")
        fi
    if [ -n "$usage_var_30d" ] && [ "$usage_var_30d" != "" ] && [ "$usage_var_30d" != "NULL" ]; then
        comp_30d=$(printf "%.4f" "$usage_var_30d" 2>/dev/null || echo "N/A")
    fi
    local comp_90d="N/A"
    if [ -n "$usage_var_90d" ] && [ "$usage_var_90d" != "" ] && [ "$usage_var_90d" != "NULL" ]; then
        comp_90d=$(printf "%.4f" "$usage_var_90d" 2>/dev/null || echo "N/A")
    fi
    eval $__result_var_usage_consistency="'<code>${usage_var_fmt}</code> | 7d:<code>${comp_7d}</code> 30d:<code>${comp_30d}</code> 90d:<code>${comp_90d}</code>'"
    
    # 8. Peak vs Quiet (Peak/off-peak ratio)
    local peak_ratio=""
    if [ -n "$today_stats" ] && [ "$today_stats" != "," ] && [ "$today_stats" != ",,,,,,,,,,," ]; then
        peak_ratio=$(echo "$today_stats" | cut -d, -f10)
    fi
    local peak_ratio_fmt="N/A"
    if [ -n "$peak_ratio" ] && [ "$peak_ratio" != "" ] && [ "$peak_ratio" != "NULL" ]; then
        local val=$(printf "%.2f" "$peak_ratio" 2>/dev/null || echo "N/A")
        if [ "$val" != "N/A" ]; then peak_ratio_fmt="${val}x"; else peak_ratio_fmt="N/A"; fi
    fi
    local comp_7d="N/A"
    local comp_30d="N/A"
        if [ -n "$peak_ratio_7d" ] && [ "$peak_ratio_7d" != "" ] && [ "$peak_ratio_7d" != "NULL" ]; then
            local val=$(printf "%.2f" "$peak_ratio_7d" 2>/dev/null || echo "N/A")
            if [ "$val" != "N/A" ]; then comp_7d="${val}x"; else comp_7d="N/A"; fi
        fi
    if [ -n "$peak_ratio_30d" ] && [ "$peak_ratio_30d" != "" ] && [ "$peak_ratio_30d" != "NULL" ]; then
        local val=$(printf "%.2f" "$peak_ratio_30d" 2>/dev/null || echo "N/A")
        if [ "$val" != "N/A" ]; then comp_30d="${val}x"; else comp_30d="N/A"; fi
    fi
    local comp_90d="N/A"
    if [ -n "$peak_ratio_90d" ] && [ "$peak_ratio_90d" != "" ] && [ "$peak_ratio_90d" != "NULL" ]; then
        local val=$(printf "%.2f" "$peak_ratio_90d" 2>/dev/null || echo "N/A")
        if [ "$val" != "N/A" ]; then comp_90d="${val}x"; else comp_90d="N/A"; fi
    fi
    eval $__result_var_peak_quiet="'<code>${peak_ratio_fmt}</code> | 7d:<code>${comp_7d}</code> 30d:<code>${comp_30d}</code> 90d:<code>${comp_90d}</code>'"
    
    # 9. Data Reliability (Connection reliability percentage)
    local reliability=""
    if [ -n "$today_stats" ] && [ "$today_stats" != "," ] && [ "$today_stats" != ",,,,,,,,,,," ]; then
        reliability=$(echo "$today_stats" | cut -d, -f11)
    fi
    local rel_fmt="N/A"
    if [ -n "$reliability" ] && [ "$reliability" != "" ] && [ "$reliability" != "NULL" ]; then
        rel_fmt=$(printf "%.1f" "$reliability" 2>/dev/null || echo "N/A")
    fi
    local comp_7d="N/A"
    local comp_30d="N/A"
    if [ -n "$reliability_7d" ] && [ "$reliability_7d" != "" ] && [ "$reliability_7d" != "NULL" ]; then
        comp_7d=$(printf "%.1f" "$reliability_7d" 2>/dev/null || echo "N/A")
    fi
    if [ -n "$reliability_30d" ] && [ "$reliability_30d" != "" ] && [ "$reliability_30d" != "NULL" ]; then
        comp_30d=$(printf "%.1f" "$reliability_30d" 2>/dev/null || echo "N/A")
    fi
    # Format: add % only if value is not N/A
    local rel_display="${rel_fmt}"
    if [ "$rel_fmt" != "N/A" ]; then rel_display="${rel_fmt}%"; fi
    local comp_7d_display="${comp_7d}"
    if [ "$comp_7d" != "N/A" ]; then comp_7d_display="${comp_7d}%"; fi
    local comp_30d_display="${comp_30d}"
    if [ "$comp_30d" != "N/A" ]; then comp_30d_display="${comp_30d}%"; fi
    local comp_90d="N/A"
    if [ -n "$reliability_90d" ] && [ "$reliability_90d" != "" ] && [ "$reliability_90d" != "NULL" ]; then
        comp_90d=$(printf "%.1f" "$reliability_90d" 2>/dev/null || echo "N/A")
    fi
    local comp_90d_display="${comp_90d}"
    if [ "$comp_90d" != "N/A" ]; then comp_90d_display="${comp_90d}%"; fi
    eval $__result_var_data_reliability="'${rel_display} | 7d:${comp_7d_display} 30d:${comp_30d_display} 90d:${comp_90d_display}'"
    
    # 10. Ping Consistency (Coefficient of variation)
    local ping_cons=""
    if [ -n "$today_stats" ] && [ "$today_stats" != "," ] && [ "$today_stats" != ",,,,,,,,,,," ]; then
        ping_cons=$(echo "$today_stats" | cut -d, -f12)
    fi
    local ping_cons_fmt="N/A"
    if [ -n "$ping_cons" ] && [ "$ping_cons" != "" ] && [ "$ping_cons" != "NULL" ]; then
        ping_cons_fmt=$(printf "%.4f" "$ping_cons" 2>/dev/null || echo "N/A")
    fi
    local comp_7d="N/A"
    local comp_30d="N/A"
        if [ -n "$ping_cons_7d" ] && [ "$ping_cons_7d" != "" ] && [ "$ping_cons_7d" != "NULL" ]; then
            comp_7d=$(printf "%.4f" "$ping_cons_7d" 2>/dev/null || echo "N/A")
        fi
    if [ -n "$ping_cons_30d" ] && [ "$ping_cons_30d" != "" ] && [ "$ping_cons_30d" != "NULL" ]; then
        comp_30d=$(printf "%.4f" "$ping_cons_30d" 2>/dev/null || echo "N/A")
    fi
    local comp_90d="N/A"
    if [ -n "$ping_cons_90d" ] && [ "$ping_cons_90d" != "" ] && [ "$ping_cons_90d" != "NULL" ]; then
        comp_90d=$(printf "%.4f" "$ping_cons_90d" 2>/dev/null || echo "N/A")
    fi
    eval $__result_var_ping_consistency="'<code>${ping_cons_fmt}</code> | 7d:<code>${comp_7d}</code> 30d:<code>${comp_30d}</code> 90d:<code>${comp_90d}</code>'"
    
    # 11. Jitter Consistency (Coefficient of variation)
    local jitter_cons=""
    if [ -n "$today_stats" ] && [ "$today_stats" != "," ] && [ "$today_stats" != ",,,,,,,,,,," ]; then
        jitter_cons=$(echo "$today_stats" | cut -d, -f13)
    fi
    local jitter_cons_fmt="N/A"
    if [ -n "$jitter_cons" ] && [ "$jitter_cons" != "" ] && [ "$jitter_cons" != "NULL" ]; then
        jitter_cons_fmt=$(printf "%.4f" "$jitter_cons" 2>/dev/null || echo "N/A")
    fi
    local comp_7d="N/A"
    local comp_30d="N/A"
        if [ -n "$jitter_cons_7d" ] && [ "$jitter_cons_7d" != "" ] && [ "$jitter_cons_7d" != "NULL" ]; then
            comp_7d=$(printf "%.4f" "$jitter_cons_7d" 2>/dev/null || echo "N/A")
        fi
    if [ -n "$jitter_cons_30d" ] && [ "$jitter_cons_30d" != "" ] && [ "$jitter_cons_30d" != "NULL" ]; then
        comp_30d=$(printf "%.4f" "$jitter_cons_30d" 2>/dev/null || echo "N/A")
    fi
    local comp_90d="N/A"
    if [ -n "$jitter_cons_90d" ] && [ "$jitter_cons_90d" != "" ] && [ "$jitter_cons_90d" != "NULL" ]; then
        comp_90d=$(printf "%.4f" "$jitter_cons_90d" 2>/dev/null || echo "N/A")
    fi
    eval $__result_var_jitter_consistency="'<code>${jitter_cons_fmt}</code> | 7d:<code>${comp_7d}</code> 30d:<code>${comp_30d}</code> 90d:<code>${comp_90d}</code>'"
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
            stability_output="<code>${stddev_formatted}%</code> fluctuation"
        fi
    fi
    
    eval $__result_var_trend="'$trend_output'"
    eval $__result_var_best="'$best_output'"
    eval $__result_var_stability="'$stability_output'"
}

# --- Main Logic Starts Here ---

# Initialize DB first - CRITICAL: Must run before any data collection/archiving
# This ensures all tables and columns exist, including 30-day trend columns
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
# get_device_statistics TOTAL_DEVICES_TODAY ACTIVE_DEVICES NEW_DEVICES_TODAY

# Get peak usage times
get_peak_usage_times PEAK_USAGE_HOUR PEAK_USAGE_DATA

# Calculate network health score
calculate_network_health_score NETWORK_HEALTH_SCORE

# --- NEW: Get device connection info from archive ---
# get_device_connection_info DEVICE_CONNECTION_INFO

# --- NEW: Get usage patterns from archive ---
get_usage_patterns QUIET_HOURS BUSY_HOURS DAY_NIGHT_USAGE

# --- NEW: Get most active device from archive ---
# get_most_active_device MOST_ACTIVE_DEVICE

# --- NEW: Get advanced statistics from archive ---
get_advanced_statistics TRAFFIC_RATIO HOURLY_DATA_RATE PING_STATS JITTER_STATS NETWORK_LOAD

# --- NEW: Get extended advanced statistics with 7-day comparisons ---
get_extended_advanced_statistics QUALITY_BREAKDOWN SPEED_EFFICIENCY CONNECTION_STABILITY QUALITY_CONSISTENCY WORST_HOUR ACTIVE_HOURS USAGE_CONSISTENCY PEAK_QUIET DATA_RELIABILITY PING_CONSISTENCY JITTER_CONSISTENCY

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

    # --- Always show Historical ConnMon section (even if data is N/A) ---
    # This lets users know the feature exists and is collecting data
    local has_historical_data=true

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

<b>📈 Usage Patterns (90-Day Trend)</b>
 ┣ Quiet Hours: ${QUIET_HOURS:-N/A}
 ┣ Busiest Hours: ${BUSY_HOURS:-N/A}
 ┗ Day vs Night: ${DAY_NIGHT_USAGE:-N/A}

<b>📊 Advanced Statistics</b>
 ┣ Traffic Ratio: ${TRAFFIC_RATIO:-N/A}
 ┣ Avg Data/Hour: <code>${HOURLY_DATA_RATE:-N/A}</code>
 ┣ Ping Stats: ${PING_STATS:-N/A}
 ┣ Jitter Spikes: ${JITTER_STATS:-N/A}
 ┣ Network Load: ${NETWORK_LOAD:-N/A}
 ┣ Quality Breakdown: ${QUALITY_BREAKDOWN:-N/A}
 ┣ Speed Efficiency: <code>${SPEED_EFFICIENCY:-N/A}</code>
 ┣ Connection Stability: <code>${CONNECTION_STABILITY:-N/A}</code>
 ┣ Quality Consistency: <code>${QUALITY_CONSISTENCY:-N/A}</code>
 ┣ Worst Hour: <code>${WORST_HOUR:-N/A}</code>
 ┣ Active Hours: <code>${ACTIVE_HOURS:-N/A}</code>
 ┣ Usage Consistency: <code>${USAGE_CONSISTENCY:-N/A}</code>
 ┣ Peak vs Quiet: <code>${PEAK_QUIET:-N/A}</code>
 ┣ Data Reliability: <code>${DATA_RELIABILITY:-N/A}</code>
 ┣ Ping Consistency: <code>${PING_CONSISTENCY:-N/A}</code>
 ┗ Jitter Consistency: <code>${JITTER_CONSISTENCY:-N/A}</code>

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
    # Use --data-urlencode for text to properly handle special characters and HTML
    curl -s -X POST "$API_TELEGRAM" \
        --data-urlencode "chat_id=$CHATID" \
        --data-urlencode "text=$TEXT" > /dev/null 2>&1
}
# --- END: FINAL sendMessage FUNCTION ---

# --- Final Execution ---
sendMessage
