[![License](https://img.shields.io/github/license/AzagraMac/telegramInfoASUS.svg?style=for-the-badge&color=yellow)](LICENSE) <a href="https://www.paypal.com/paypalme/azagramac" target="_blank"><img src="https://www.nopcommerce.com/images/thumbs/0005707_paypalme-payment-method.png" alt="Buy Me A Coffee" style="height: 28px !important;" align="right" /></a><br/>

### Requirement
- ASUS router compatible with [firmware merlin](https://www.asuswrt-merlin.net), [List supported devices](https://github.com/RMerl/asuswrt-merlin.ng/wiki/Supported-Devices)
- Pendrive (recommended 4Gb minimum) formatted in Ext4 with [swap enabled](https://azagramac.gitbook.io/myblog/asus-router/habilitar-swap)
- Optional, but recommended, to have [Skynet](https://azagramac.gitbook.io/myblog/asus-router/instalar-skynet) installed.

### Tested
Asus RT-BE88U

- Firmware merlin: [v388.3_0](https://onedrive.live.com/?authkey=%21AJLLKAY%2D%2D4EBqDo&id=CCE5625ED3599CE0%2121144&cid=CCE5625ED3599CE0)

### Install
- You need a telegram token, you can apply for one at https://t.me/BotFather, and the Chat ID, you can request it at https://t.me/myidbot
- Edit telegram.env file with your credentials
- Copy file telegram.env to `/jffs/`
- Copy script `/jffs/scripts/`

### Capture
![v1.1](https://github.com/AzagraMac/telegramInfoASUS/assets/571796/ca3d0fce-b391-44d6-b777-47cd03199b17)


#### Cron job, in this example, it is executed every 2h
```
cru a status "0 */2 * * * /jffs/scripts/status.sh"
```

#### Thanks
[@juanrs_05](https://twitter.com/juanrs_05) and [@RMerlinDev](https://twitter.com/RMerlinDev)
