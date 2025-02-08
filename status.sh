#!/bin/sh

#
# Dev: garett09
# version: 2.10
#

# Unset vars
unset IP_PWAN0
unset IP_LAN
unset FIRMWARE_VERSION
unset MODEL_NAME
unset SSID_5GHZ
unset SSID_24GHZ
unset TEMP_CPU
unset TEMP_WIFI24
unset TEMP_WIFI5
unset RAM_TOTAL
unset RAM_USED
unset RAM_FREE
unset RAM_USED_PERCENTAGE
unset RAM_FREE_PERCENTAGE
unset SWAP_USED
unset CPU_USED_1M
unset CPU_USED_5M
unset CPU_USED_15M
unset UPTIME
unset SKYNET_VERSION
unset IPS_BANNED
unset IN_BLOCK
unset OUT_BLOCK
unset SIGN_DATE
unset DAILY_USAGE
unset MONTHLY_USAGE
unset YEARLY_USAGE
unset LIFETIME_USAGE

IP_WAN0=$(nvram get wan0_ipaddr)
IP_LAN=$(nvram get lan_ipaddr)

# Fetch the firmware version from webs_state_info
WEB_STATE_INFO=$(nvram get webs_state_info)
FIRMWARE_VERSION=$(echo $WEB_STATE_INFO | awk -F'_' '{print $1"."$2"."$3}')

MODEL_NAME=$(nvram get wps_device_name)

# Try different variables for SSID values
SSID_5GHZ=$(nvram get wl1.1_ssid)
SSID_24GHZ=$(nvram get wl0.1_ssid)

# Fallback if the above variables don't work
if [ -z "$SSID_5GHZ" ]; then
    SSID_5GHZ=$(nvram get wl_ssid)
fi

if [ -z "$SSID_24GHZ" ]; then
    SSID_24GHZ=$(nvram get wl_ssid)
fi

TEMP_CPU=$(cat /sys/class/thermal/thermal_zone0/temp | awk '{printf("%.0f\n", $1 / 1000) }')

# Use wl0 and wl1 for temperature readings
TEMP_WIFI24=$(wl -i wl0 phy_tempsense | awk '{print $1 / 2 + 20}')
TEMP_WIFI5=$(wl -i wl1 phy_tempsense | awk '{print $1 / 2 + 20}')

RAM_TOTAL=$(free | grep -i mem | awk '{print $2}')
RAM_USED=$(free | grep -i mem | awk '{print $3}')
RAM_FREE=$(free | grep -i mem | awk '{print $4}')
RAM_USED_PERCENTAGE=$(free | grep Mem | awk '{ printf("%.2f", $3/$2 * 100.0) }')
RAM_FREE_PERCENTAGE=$(free | grep Mem | awk '{ printf("%.2f", $4/$2 * 100.0) }')
SWAP_USED=$(free | grep Swap | awk '{ printf("%.2f", $3/$2 * 100.0) }')

CPU_USED_1M=$(cat /proc/loadavg | awk '{print $1}')
CPU_USED_5M=$(cat /proc/loadavg | awk '{print $2}')
CPU_USED_15M=$(cat /proc/loadavg | awk '{print $3}')

# Function to format uptime
format_uptime() {
    local uptime=$1
    if echo "$uptime" | grep -q "min"; then
        echo "Uptime: $uptime minutes"
    elif echo "$uptime" | grep -q "day"; then
        echo "Uptime: $uptime days"
    elif echo "$uptime" | grep -q "sec"; then
        echo "Uptime: Less than a minute"
    elif echo "$uptime" | grep -q "hour"; then
        echo "Uptime: $uptime hours"
    elif echo "$uptime" | grep -q "month"; then
        echo "Uptime: $uptime months"
    elif echo "$uptime" | grep -q "year"; then
        echo "Uptime: $uptime years"
    else
        echo "Uptime: $uptime"
    fi
}

# Get the raw uptime value
RAW_UPTIME=$(uptime | awk -F'up ' '{print $2}' | awk -F',  load average' '{print $1}')

# Check if uptime includes days, hours, and minutes
if echo "$RAW_UPTIME" | grep -q "day"; then
    DAYS=$(echo "$RAW_UPTIME" | awk '{print $1}')
    TIME=$(echo "$RAW_UPTIME" | awk '{print $3}')
    HOURS=$(echo "$TIME" | awk -F':' '{print $1}')
    MINUTES=$(echo "$TIME" | awk -F':' '{print $2}')
    FORMATTED_UPTIME="Uptime: $DAYS days, $HOURS hours and $MINUTES minutes"
elif echo "$RAW_UPTIME" | grep -q ":"; then
    HOURS=$(echo "$RAW_UPTIME" | awk -F':' '{print $1}')
    MINUTES=$(echo "$RAW_UPTIME" | awk -F':' '{print $2}')
    FORMATTED_UPTIME="Uptime: $HOURS hours and $MINUTES minutes"
else
    # Format the uptime
    FORMATTED_UPTIME=$(format_uptime "$RAW_UPTIME")
fi

# Function to convert data usage from binary to decimal
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

# Get data usage from vnStat for eth0 with data directory on USB
DAILY_USAGE=$(vnstat -i ppp0 -d --dbdir /opt/var/lib/vnstat | grep "$(date +'%Y-%m-%d')" | awk '{print $8, $9}')
MONTHLY_USAGE=$(vnstat -i ppp0 -m --dbdir /opt/var/lib/vnstat | grep "$(date +'%Y-%m')" | awk '{print $8, $9}')
YEARLY_USAGE=$(vnstat -i ppp0 -y --dbdir /opt/var/lib/vnstat | grep "$(date +'%Y')" | awk '{print $8, $9}')
LIFETIME_USAGE=$(vnstat -i ppp0 --dbdir /opt/var/lib/vnstat | grep "total:" | awk '{print $8, $9}')

# Extract values and units
DAILY_VALUE=$(echo $DAILY_USAGE | awk '{print $1}')
DAILY_UNIT=$(echo $DAILY_USAGE | awk '{print $2}')
MONTHLY_VALUE=$(echo $MONTHLY_USAGE | awk '{print $1}')
MONTHLY_UNIT=$(echo $MONTHLY_USAGE | awk '{print $2}')
YEARLY_VALUE=$(echo $YEARLY_USAGE | awk '{print $1}')
YEARLY_UNIT=$(echo $YEARLY_USAGE | awk '{print $2}')
LIFETIME_VALUE=$(echo $LIFETIME_USAGE | awk '{print $1}')
LIFETIME_UNIT=$(echo $LIFETIME_USAGE | awk '{print $2}')

# Convert data usage to decimal
DAILY_USAGE_DECIMAL=$(convert_usage $DAILY_VALUE $DAILY_UNIT)
MONTHLY_USAGE_DECIMAL=$(convert_usage $MONTHLY_VALUE $MONTHLY_UNIT)
YEARLY_USAGE_DECIMAL=$(convert_usage $YEARLY_VALUE $YEARLY_UNIT)
LIFETIME_USAGE_DECIMAL=$(convert_usage $LIFETIME_VALUE $LIFETIME_UNIT)

## Sign Trend
SIGN_DATE=$(nvram get bwdpi_sig_ver)

## Telegram
TELEGRAM_AUTH="/jffs/telegram.env"
TOKEN=$(cat $TELEGRAM_AUTH | grep "TOKEN" | awk -F "=" '{print $2}')
CHATID=$(cat $TELEGRAM_AUTH | grep "CHAT_ID" | awk -F "=" '{print $2}')
API_TELEGRAM="https://api.telegram.org/bot$TOKEN/sendMessage?parse_mode=HTML"

DATE=$(date +"%I:%M %p, %B %d, %Y")
LIMIT_TEMP_CPU=70
unset BANNER

function sendMessage()
{
    TEXT=$(cat <<EOF
<b>$BANNER</b>

🕒 Time: $DATE

<b>📊 Status</b>
🌡️ CPU Temp: $TEMP_CPUº
🌡️ WLAN 2.4 Temp: $TEMP_WIFI24º
🌡️ WLAN 5 Temp: $TEMP_WIFI5º
⏱️ $FORMATTED_UPTIME
💻 Load Average: $LOAD_AVG
🧠 RAM Used: $RAM_USED_PERCENTAGE% / Free: $RAM_FREE_PERCENTAGE%
💾 Swap Used: $SWAP_USED%

<b>📅 Data Usage</b>
Daily Data Usage: $DAILY_USAGE_DECIMAL (Date: $(date +'%B %d, %Y'))
Monthly Data Usage: $MONTHLY_USAGE_DECIMAL (Month: $(date +'%B %Y'))
Yearly Data Usage: $YEARLY_USAGE_DECIMAL (Year: $(date +'%Y'))
Lifetime Data Usage: $LIFETIME_USAGE_DECIMAL (February 7, 2025)

<b>📃 Info</b>
📶 Model: $MODEL_NAME
🛠️ Firmware: $FIRMWARE_VERSION
📡 SSID 2.4Ghz: $SSID_24GHZ
📡 SSID 5Ghz: $SSID_5GHZ
🌐 IP WAN: $IP_WAN0
🌐 IP LAN: $IP_LAN
🕒 Trend Micro sign: $SIGN_DATE
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
