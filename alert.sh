#!/bin/sh

#
# Script: connmon_alert.sh (Real-Time ConnMon Monitoring)
# Version: 1.21 FINAL - Correct PATH definition for Cron
# Purpose: Ensures all commands (awk, grep, nvram) are found by any shell.
#

# --- CRITICAL: Define the full path for all binaries ---
export PATH="/bin:/usr/bin:/sbin:/usr/sbin:/opt/bin:/opt/sbin"

# --- Database Paths & Telegram Config ---
CONMON_DB="/jffs/addons/connmon.d/connstats.db"
TELEGRAM_AUTH="/jffs/telegram.env"

# --- Load Telegram Variables ---
TOKEN=$(cat "$TELEGRAM_AUTH" | grep "TOKEN" | awk -F "=" '{print $2}')
CHATID=$(cat "$TELEGRAM_AUTH" | grep "CHAT_ID" | awk -F "=" '{print $2}')
API_TELEGRAM="https://api.telegram.org/bot$TOKEN/sendMessage?parse_mode=HTML"

# --- Alert Thresholds (PRODUCTION VALUES) ---
LIMIT_PING=100.0     # Alert if Ping is over 100 ms
LIMIT_JITTER=15.0    # Alert if Jitter is over 15.0 ms
LIMIT_QUALITY=90.0   # Alert if Quality is below 90.0%

# --- Log Path ---
ALERT_LOG="/jffs/connmon_alerts.log"

# --- Ensure Log File Exists ---
touch "$ALERT_LOG"
chmod 644 "$ALERT_LOG"

# --- Helper Function: Get ConnMon Data (Uses fixed DB query) ---
get_conmon_stats() {
    local db_file=$1
    
    if [ ! -f "$db_file" ]; then echo "N/A|N/A|N/A|N/A|N/A"; return; fi 
    
    local metrics_raw=$(sqlite3 -separator ',' "$db_file" \
        "SELECT Ping, Jitter, LineQuality, Timestamp FROM connstats ORDER BY Timestamp DESC LIMIT 1" 2>/dev/null)
        
    if [ -z "$metrics_raw" ] || [ "$metrics_raw" = ",,,," ]; then echo "N/A|N/A|N/A|N/A|N/A"; return; fi

    local ping_val=$(echo "$metrics_raw" | cut -d, -f1)
    local jitter_val=$(echo "$metrics_raw" | cut -d, -f2)
    local quality_val=$(echo "$metrics_raw" | cut -d, -f3)
    local time_raw=$(echo "$metrics_raw" | cut -d, -f4)
    
    if [ -z "$ping_val" ] || [ -z "$jitter_val" ] || [ -z "$quality_val" ]; then echo "N/A|N/A|N/A|N/A|N/A"; return; fi

    local current_time=$(date -d "@$time_raw" +"%H:%M" 2>/dev/null)
    local current_date=$(date -d "@$time_raw" +"%b %d, %Y" 2>/dev/null) 
    
    # Use PIPE '|' as the separator
    printf "%s|%s|%.2f|%.2f|%.2f" "$current_time" "$current_date" "$ping_val" "$jitter_val" "$quality_val" 
}

# --- Main Alert Check Function ---
check_and_send_alert() {
    # 1. Get current ConnMon data
    local CONMON_DATA=$(get_conmon_stats "$CONMON_DB")
    
    # Use IFS='|' to parse the pipe-separated data string
    IFS='|' read -r CONMON_TIME CONMON_DATE CONMON_PING CONMON_JITTER CONMON_QUALITY <<EOF
$CONMON_DATA
EOF

    local ALERT_DETAILS="" 
    local alert_count=0
    local MODEL_NAME=$(nvram get wps_device_name)
    local CURRENT_DATETIME=$(date +"%Y-%m-%d %H:%M:%S") 

    # Exit if data retrieval failed
    if [ "$CONMON_TIME" = "N/A" ] || [ "$CONMON_PING" = "N/A" ]; then return; fi

    # 2. Check Thresholds and build both alert strings
    
    if echo "$CONMON_PING $LIMIT_PING" | awk '{if ($1 > $2) print 1}' | grep -q 1; then
        local detail_string="HIGH PING: ${CONMON_PING}ms"
        ALERT_DETAILS_TG="${ALERT_DETAILS_TG}‼️ ${detail_string} (Limit: ${LIMIT_PING}ms)
"
        LOG_DETAILS="${LOG_DETAILS}${detail_string}; "
        alert_count=$((alert_count + 1))
    fi
    if echo "$CONMON_JITTER $LIMIT_JITTER" | awk '{if ($1 > $2) print 1}' | grep -q 1; then
        local detail_string="HIGH JITTER: ${CONMON_JITTER}ms"
        ALERT_DETAILS_TG="${ALERT_DETAILS_TG}‼️ ${detail_string} (Limit: ${LIMIT_JITTER}ms)
"
        LOG_DETAILS="${LOG_DETAILS}${detail_string}; "
        alert_count=$((alert_count + 1))
    fi
    if echo "$CONMON_QUALITY $LIMIT_QUALITY" | awk '{if ($1 < $2) print 1}' | grep -q 1; then
        local detail_string="LOW QUALITY: ${CONMON_QUALITY}%"
        ALERT_DETAILS_TG="${ALERT_DETAILS_TG}❌ ${detail_string} (Limit: ${LIMIT_QUALITY}%)
"
        LOG_DETAILS="${LOG_DETAILS}${detail_string}; "
        alert_count=$((alert_count + 1))
    fi

    # 3. Send Alert and Log if needed
    if [ "$alert_count" -gt 0 ]; then
        # --- LOGGING CODE ---
        local final_log_details=$(echo "$LOG_DETAILS" | sed 's/; $//') # Remove trailing semicolon
        echo "[${CURRENT_DATETIME}] | $alert_count | $final_log_details" >> "$ALERT_LOG"
        # --------------------

        # --- Use Heredoc for MESSAGE CONSTRUCTION ---
        local TEXT=$(cat <<EOF
<b>🚨🚨 NETWORK ALERT: $MODEL_NAME</b>
<b>‼️ $alert_count PROBLEM(S) DETECTED</b>

${ALERT_DETAILS_TG}
--- Metrics at $CONMON_TIME ($CONMON_DATE) ---
<b>Ping:</b> $CONMON_PING ms
<b>Jitter:</b> $CONMON_JITTER ms
<b>Quality:</b> $CONMON_QUALITY%
EOF
)
        
        # Use the proven curl structure from status.sh
        curl -s -X POST $API_TELEGRAM \
            -d chat_id=$CHATID \
            -d text="$TEXT" > /dev/null 2>&1
    fi
}

# --- Execute ---
check_and_send_alert
