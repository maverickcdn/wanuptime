# wanuptime.sh

## For AsusWRT-Merlin 384.15+ to estimate current WAN uptime

Script is written to try and take advantage of your pre-existing logs but will create entires for itself in
wan-event or create wan-event in /jffs/scripts/ to trigger new save points that are stored in RAM.

* Calculates the difference from last wan-event connected, WAN up event to now
* Script only searches disconnects, it cannot find service outage where you remain connected to your ISP
* Relies on in order wan-event message, wan up message, link up message or NTP sync message to calc uptime
* Only has resolution to 364d23h59m59s as years are not recorded in logs
* Thanks to ColinTaylor and Martinski for their ideas
* Results are saved in /tmp/wanuptime.save  (msg epoch,msg,date found,uptime)
* HIGHLY recommended to let script create wan-event entries for best accuracy
* run with argument 'enable' 'disable' to enable(default) or disable/remove wan-event entries for this script
* run with argument 'log' to send uptimes to log with cron (ie. 'sh /jffs/scripts/wanuptime.sh log')
* run with argument 'unlock' should you be locked out by a NTP lock file
* run with argument 'uninstall' to remove wan-event entires and delete script
* run with argument '-f X' to force search method, X can be event, routes, restored, ntp, saved
* Using -f if a successful result is found it will reset saved file, use with caution

To download, copy/paste in an SSH terminal

`curl --retry 3 "https://raw.githubusercontent.com/maverickcdn/wanuptime/master/wanuptime.sh" -o "/jffs/scripts/wanuptime.sh" && chmod a+rx "/jffs/scripts/wanuptime.sh"`

To extract uptime for use in your own script, run script (redirect output to temp file if necessary)
and pull saved uptime from /tmp/wanuptime.save

`sh /jffs/scripts/wanuptime.sh > /tmp/wanuptime.temp`
`wanuptime="$(sed -n '4p' /tmp/wanuptime.save 2> /dev/null`
