#!/bin/sh

#
# Dev: garett09
# version: 2.11
#

# Load Telegram credentials from the .env file
TELEGRAM_AUTH="/jffs/telegram.env"
TOKEN=$(cat $TELEGRAM_AUTH | grep "TOKEN" | awk -F "=" '{print $2}')
CHATID=$(cat $TELEGRAM_AUTH | grep "CHAT_ID" | awk -F "=" '{print $2}')
API_TELEGRAM="https://api.telegram.org/bot$TOKEN/sendMessage?parse_mode=HTML"

# Ensure that the token and chat ID are set
if [ -z "$TOKEN" ]; then
    echo "ERROR: TOKEN not set in $TELEGRAM_AUTH"
    exit 1
fi

if [ -z "$CHATID" ]; then
    echo "ERROR: CHAT_ID not set in $TELEGRAM_AUTH"
    exit 1
fi

# Unset vars
unset IP_WAN0
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
unset AVG_PING

# Fetch basic network and system details
IP_WAN0=$(nvram get wan0_ipaddr)
IP_LAN=$(nvram get lan_ipaddr)

# Fetch firmware version
WEB_STATE_INFO=$(nvram get webs_state_info)
FIRMWARE_VERSION=$(echo $WEB_STATE_INFO | awk -F'_' '{print $1"."$2"."$3}')

MODEL_NAME=$(nvram get wps_device_name)

# SSID values
SSID_5GHZ=$(nvram get wl1.1_ssid)
SSID_24GHZ=$(nvram get wl0.1_ssid)

if [ -z "$SSID_5GHZ" ]; then
    SSID_5GHZ=$(nvram get wl_ssid)
fi

if [ -z "$SSID_24GHZ" ]; then
    SSID_24GHZ=$(nvram get wl_ssid)
fi

TEMP_CPU=$(cat /sys/class/thermal/thermal_zone0/temp | awk '{printf("%.0f\n", $1 / 1000) }')

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

# Function to calculate average ping over 5 pings
calculate_avg_ping() {
    local target="1.1.1.1"
    local count=5  # 5 pings to average

    # Run the ping command 5 times and calculate the average ping
    AVG_PING=$(ping -c $count $target | awk -F'=' '/time=/{sum+=$NF; count++} END {if (count>0) printf("%.2f ms", sum/count); else print "N/A"}')
}

# Call the function
calculate_avg_ping

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

RAW_UPTIME=$(uptime | awk -F'up ' '{print $2}' | awk -F',  load average' '{print $1}')

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
    FORMATTED_UPTIME=$(format_uptime "$RAW_UPTIME")
fi

LOAD_AVG=$(uptime | awk -F'load average: ' '{print $2}' | awk -F', ' '{printf "1 min: %.2f%% 5 mins: %.2f%% 15 mins: %.2f%%", $1*100, $2*100, $3*100}')

SIGN_DATE=$(nvram get bwdpi_sig_ver)

DATE=$(date +"%I:%M %p, %B %d, %Y")
LIMIT_TEMP_CPU=70
unset BANNER

function sendMessage()
{
    TEXT=$(cat <<EOF
<b>$BANNER</b>

<b>📊 Status</b>
🌡️ WLAN 2.4 Temp: $TEMP_WIFI24º
🌡️ WLAN 5 Temp: $TEMP_WIFI5º
⏱️ $FORMATTED_UPTIME
💻 Load Average: $LOAD_AVG
📡 Average Ping: $AVG_PING
🧠 RAM Used: $RAM_USED_PERCENTAGE% / Free: $RAM_FREE_PERCENTAGE%
💾 Swap Used: $SWAP_USED%

<b>📃 Info</b>
📶 Model: $MODEL_NAME
🛠️ Firmware: $FIRMWARE_VERSION
📡 SSID 2.4Ghz: $SSID_24GHZ
📡 SSID 5Ghz: $SSID_5GHZ
🌐 IP WAN: $IP_WAN0
🌐 IP LAN: $IP_LAN
🕒 Trend Micro sign: $SIGN_DATE

🕒 Time of report: $DATE
EOF
)

    # Send message
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
