!/bin/sh

#
# Dev: garett09
# version: 2.01
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

UPTIME=$(uptime | awk -F'( |,|:)+' '{print $6,$7",",$8,"hours,",$9,"minutes"}')
LOAD_AVG=$(uptime | awk -F'( |,|:)+' '{printf "1 min: %.2f%% 5 mins: %.2f%% 15 mins: %.2f%%", $12*100, $13*100, $14*100}')

# Get data usage from vnStat for eth0 with data directory on USB
DAILY_USAGE=$(vnstat -i ppp0 -d --dbdir /opt/var/lib/vnstat | grep "$(date +'%Y-%m-%d')" | awk '{print $8, $9}')
MONTHLY_USAGE=$(vnstat -i ppp0 -m --dbdir /opt/var/lib/vnstat | grep "$(date +'%Y-%m')" | awk '{print $8, $9}')
YEARLY_USAGE=$(vnstat -i ppp0 -y --dbdir /opt/var/lib/vnstat | grep "$(date +'%Y')" | awk '{print $8, $9}')
LIFETIME_USAGE=$(vnstat -i ppp0 --dbdir /opt/var/lib/vnstat | grep "total:" | awk '{print $8, $9}')

# Get lifetime usage as of February 7th
LIFETIME_USAGE_FEB7=$(vnstat -i ppp0 --dbdir /opt/var/lib/vnstat | grep "total:" | awk '{print $8, $9}')

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

📊 Status
🌡️ CPU Temp: $TEMP_CPUº
🌡️ WLAN 2.4 Temp: $TEMP_WIFI24º
🌡️ WLAN 5 Temp: $TEMP_WIFI5º
⏱️ Uptime: $UPTIME
💻 Load Average: $LOAD_AVG
🧠 RAM Used: $RAM_USED_PERCENTAGE% / Free: $RAM_FREE_PERCENTAGE%
💾 Swap Used: $SWAP_USED%

📅 Data Usage
Daily Data Usage: $DAILY_USAGE (Date: $(date +'%B %d, %Y'))
Monthly Data Usage: $MONTHLY_USAGE (Month: $(date +'%B %Y'))
Yearly Data Usage: $YEARLY_USAGE (Year: $(date +'%Y'))
Lifetime Data Usage: $LIFETIME_USAGE (February 7, 2025)

📃 Info
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
