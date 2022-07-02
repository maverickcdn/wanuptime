#!/bin/sh
################################################################################
#                                             _   _                            #
#                                            | | (_)                           #
#            __      ____ _ _ __  _   _ _ __ | |_ _ _ __ ___   ___             #
#            \ \ /\ / / _` | '_ \| | | | '_ \| __| | '_ ` _ \ / _ \            #
#             \ V  V / (_| | | | | |_| | |_) | |_| | | | | | |  __/            #
#              \_/\_/ \__,_|_| |_|\__,_| .__/ \__|_|_| |_| |_|\___|            #
#                                      | |                                     #
#                                      |_|                                     #
#                                                                              #
#                      written by Maverickcdn April 2022                  v1.1 #
################################################################################
# Calculates the difference from last wan-event connected, WAN up event to now
# script only searches disconnects, it cannot find service outage where you remain connected to your ISP
# relies on in order wan-event message, wan up message, or NTP sync message to calc uptime
# only has resolution to 364d23h59m59s as years are not recorded in logs
# thanks to ColinTaylor and Martinski for their ideas
# results are saved in /tmp/wanuptime.save  (msg epoch,msg,date found,uptime)
# HIGHLY recommended to let script create wan-event entries for best accuracy
# run with argument 'enable' 'disable' to enable(default) or disable/remove wan-event entries for this script
# run with argument 'log' to send uptimes to log with cron (ie. 'sh /jffs/scripts/wanuptime.sh log')
# run with argument 'unlock' should you be locked out by a NTP lock file
# run with argument 'uninstall' to remove wan-event entires and delete script
# run with argument '-f X' to force search method, X can be event, routes, restored, ntp, saved
# using -f if a successful result is found it will reset saved file, use with caution
### Start ######################################################################
create_wan_event='yes'
################################################################################
version='1.1'
script_ver_date='July 2 2022'
script_name_full="/jffs/scripts/$(basename "$0")"
wan_save_loc='/tmp/wanuptime.save'
[ ! -x "$script_name_full" ] && chmod a+rx "$script_name_full"
passed_option="$1" ;[ -z "$passed_option" ] && passed_option='manual'
F_printf() { printf '%s\n' "$1" ;}
F_pad() { printf '\n' ;}
F_sep() { F_printf "--------------------------------------------------------------------------------" ;}
F_log() { F_printf "$1" | /usr/sbin/logger -t "wanuptime[$$]" ;}
F_logp() { F_log "$1" ;F_printf "$1" ;}

# Set search methods
F_find_event() { search='event' ;next_fnd='routes' ;search_desc="'wan-event connected'" ;search_string="wan-event (args: .* connected)" ;F_search ;}
F_find_routes() { search='routes' ;next_fnd='restored' ;search_desc="WAN finish routes" ;search_string="wan: finish adding multi routes" ;F_search ;}
F_find_restored() { search='restored' ;next_fnd='ntp' ;search_desc="WAN was restored" ;search_string=": WAN was restored." ;F_search ;}
F_find_ntp() { search='ntp' ;next_fnd='saved' ;search_desc="NTP clock set" ;search_string="Initial clock set" ;F_search ;}
F_find_saved() { search='saved' ;search_desc="Saved in RAM" ;F_long_term lookup ;}

# syslog.log syslog.log-1 search function
F_search() {
	F_success() {
		F_printf "SUCCESS - Last $search_desc message found in $found_in"
		[ "$search" = 'restored' ] && F_printf "NOTICE  - WAN was restored messages are not always reliable"
		if [ "$search" = 'event' ] ;then
			F_printf "EVENT   - ${findlast:0:16}.....${findlast:38}"
		else
			F_printf "EVENT   - $findlast"
		fi
	}

	F_printf "SEARCH  - Looking for $search_desc in logs"
	findlast="$(grep "$search_string" /tmp/syslog.log 2>/dev/null | tail -n1)"
	[ -n "$findlast" ] && found_in='syslog.log' && F_success && F_date_format && return 0
	F_printf "FAIL    - $search_desc not found in syslog.log checking syslog.log-1"
	findlast="$(grep "$search_string" /tmp/syslog.log-1 2>/dev/null | tail -n1)"
	[ -n "$findlast" ] && found_in='syslog.log-1' && F_success && F_date_format && return 0
	# no results skip to next search method if not in force mode
	if [ -f '/tmp/syslog.log-1' ] ;then
		F_printf "FAIL    - $search_desc not found in syslog.log-1"
	else
		F_printf "FAIL    - syslog.log-1 does not exist"
	fi
	if [ "$passed_option" = '-f' ] ;then
		F_printf "FINISH  - Force search $search" ;F_pad
	else
		F_printf "RETRY   - Attempting to find $next_fnd message instead" ;F_sep
		F_find_"${next_fnd}"
	fi
}

# Format found log date/time to do diff (uptime) calc
F_date_format() {
	fnd_time="$(grep "$findlast" /tmp/"$found_in" | cut -c -15)"
	found_epoch="$(/bin/date --date="$cur_yr $fnd_time" -D '%Y %b %e %T' +'%s')"
	# try to detect year of message
	fnd_yr="$cur_yr"
	[ "$found_epoch" -gt "$cur_epoch" ] && fnd_yr=$((fnd_yr - 1)) && \
		found_epoch="$(/bin/date --date="$fnd_yr $fnd_time" -D '%Y %b %e %T' +'%s')"
	[ "$fnd_yr" -lt "$cur_yr" ] && F_printf "NOTICE  - Assuming message originated in year $fnd_yr - found date > current date"
	F_calc_diff
}

# calc uptime and validate results
F_calc_diff() {
	epoch_diff="$((cur_epoch - found_epoch))"

	# WAN uptime vs router uptime verify
	if [ "$epoch_diff" -gt "$router_secs" ] ;then
		F_printf "ERROR   - Calculated uptime ${epoch_diff}s > router uptime ${router_secs}s" ;F_sep
		case "$search" in
			'ntp') F_logp "ERROR   - NTP sync message time difference greater than router uptime" ;;
			'saved') F_logp "ERROR   - Impossible... time difference from saved RAM > router uptime" ;F_pad ;exit 0 ;;
		esac
		F_printf "RETRY   - Attempting to find $next_fnd message"
		findlast=''   # empty the result
		F_find_"${next_fnd}"
		return 0
	fi

	# msg post NTP validation   @ColinTaylor
	found_line="$(grep -n "$findlast" "/tmp/$found_in" 2> /dev/null | cut -d':' -f1)"
	ntp_line="$(grep -n "Initial clock set" "/tmp/syslog.log" 2> /dev/null | tail -n1 | cut -d':' -f1)"
	ntp_in='recent'
	if [ -z "$ntp_line" ] ;then
		ntp_line="$(grep -n "Initial clock set" "/tmp/syslog.log-1" 2> /dev/null | tail-n1 | cut -d':' -f1)"
		[ -n "$ntp_line" ] && ntp_in='older'
	fi

	# no ntp sync line means router and NTP have been up long enough to overwrite it and most recent find is valid
	if [ -n "$ntp_line" ] ;then
		# only check lines if found in the same logs
		if [ "$found_in" = 'syslog.log' ] && [ "$ntp_in" = 'recent' ] || [ "$found_in" = 'syslog.log-1' ] && [ "$ntp_in" = 'older' ] ;then  # found msg in newer log than NTP skip
			if [ "$found_line" -lt "$ntp_line" ] ;then
				F_printf "WARNING - Found message appears before NTP sync in logs"
				F_printf "RETRY   - Attempting to find $next_fnd message instead"
				findlast=''
				F_find_"${next_fnd}"
				return 0
			fi
		# if message in new, ntp in old result valid, if message in old, ntp in new result invalid
		elif [ "$found_in" = 'syslog.log-1' ] && [ "$ntp_in" = 'recent' ] ;then
			F_printf "WARNING - Found message appears before NTP sync in logs"
			F_printf "RETRY   - Attempting to find $next_fnd message instead"
			findlast=''
			F_find_"${next_fnd}"
			return 0
		fi
	fi

	wan_uptime="$(printf '%d day(s) %d hr(s) %d min(s) %d sec(s)\n' $((epoch_diff/86400)) $((epoch_diff%86400/3600)) $((epoch_diff%3600/60)) $((epoch_diff%60)))"
	F_long_term create   # save found results to ram incase logs get overwritten
	F_sep ;F_show_uptime ;F_pad
}

F_show_uptime() {
	F_printf "Router uptime  : $router_uptime"
	F_printf "WAN uptime     : $wan_uptime"
}

# save found wan up time to RAM incase logs get overwritten  @Martinski
F_long_term() {
	if [ "$1" = 'create' ] ;then
		if [ -s "$wan_save_loc" ] && [ "$(sed -n '1p' "$wan_save_loc")" = "$found_epoch" ] ;then
			[ "$search" != 'saved' ] && F_printf "INFO    - wanuptime save file exists with this record already"
			F_printf "NOTICE  - Updating saved record with new uptime calculation"
		fi
		{
		F_printf "$found_epoch"
		F_printf "$findlast"
		F_printf "Record created $(date +'%c')"
		F_printf "$wan_uptime"
		F_printf "$search"
		} > "$wan_save_loc"
		F_printf "SUCCESS - Saved record of last WAN up event to $wan_save_loc"
	elif [ "$1" = 'lookup' ] ;then
		F_printf "SEARCH  - Looking for $wan_save_loc record"
		if [ -s "$wan_save_loc" ] ;then
			found_epoch="$(sed -n '1p' "$wan_save_loc")"
			findlast="$(sed -n '2p' "$wan_save_loc" | cut -c -70)"
			saved_on="$(sed -n '3p' "$wan_save_loc")"
			wan_uptime="$(sed -n '4p' "$wan_save_loc")"
			F_printf "SUCCESS - Found last recorded event saved in RAM"
			F_printf "EVENT   - $findlast"
			F_printf "SAVED   - $saved_on"
			F_printf "INFO    - Uptime as of saved date $wan_uptime"
			F_calc_diff
		else
			F_printf "FAIL    - No $wan_save_loc file found" ;F_pad
		fi
	fi
}

# add/remove wan-event file
F_wan_event() {
	if [ "$1" = 'create' ] ;then
		if [ -f '/jffs/scripts/wan-event' ] ;then
			if grep -q $'\x0D' '/jffs/scripts/wan-event' 2>/dev/null ;then dos2unix '/jffs/scripts/wan-event' ;fi
			[ ! -x '/jffs/scripts/wan-event' ] && chmod a+rx '/jffs/scripts/wan-event'
			if ! grep -q '#!/bin/sh' '/jffs/scripts/wan-event' ; then
				F_printf "ERROR   - Your wan-event is missing a '#!/bin/sh' investigate and run again" ;F_pad
				exit 0
			else
				{
				F_printf "[ \"\$2\" = \"connected\" ] && (sh $script_name_full wanevent) & wanuptimepid=\$!  # added by wanuptime.sh $cur_date"
				F_printf "[ \"\$2\" = \"connected\" ] && logger -t \"wan-event[\$\$]\" \"Started wanuptime with pid \$wanuptimepid\"   # added by wanuptime.sh $cur_date"
				} >> '/jffs/scripts/wan-event'
			fi
		else
			F_printf "NOTICE  - Creating wan-event file in /jffs/scripts/"
			{
			F_printf "#!/bin/sh"
			F_printf "# Created by $script_name_full to trigger wan-event log messages - $cur_date"
			F_printf "[ \"\$2\" = \"connected\" ] && (sh $script_name_full wanevent) & wanuptimepid=\$!  # added by wanuptime.sh $cur_date"
			F_printf "[ \"\$2\" = \"connected\" ] && logger -t \"wan-event[\$\$]\" \"Started wanuptime with pid \$wanuptimepid\"   # added by wanuptime.sh $cur_date"
			} > '/jffs/scripts/wan-event'
			chmod a+rx '/jffs/scripts/wan-event'
		fi
	elif [ "$1" = 'remove' ] ;then
		F_printf "NOTICE  - Removing wanuptime.sh from wan-event"
		if [ -f '/jffs/scripts/wan-event' ]; then
			if grep -q "wanuptime" '/jffs/scripts/wan-event' 2> /dev/null ;then
				sed -i '/to trigger wan-event log messages -/d' '/jffs/scripts/wan-event'
				sed -i '/& wanuptimepid=/d' '/jffs/scripts/wan-event'
				sed -i '/Started wanuptime with pid/d' '/jffs/scripts/wan-event'
				F_printf "SUCCESS - Removed wan-event entry for wanuptime.sh"
			else
				F_printf "ERROR   - No entries for wanuptime in /jffs/scripts/wan-event to remove"
				return 0
			fi
			if [ "$(wc -l < /jffs/scripts/wan-event)" -eq 1 ]; then
				if grep -q "#!/bin/sh" "/jffs/scripts/wan-event"; then
					F_printf "NOTICE  - /jffs/scripts/wan-event appears empty, removing file"
					rm -f '/jffs/scripts/wan-event'
				fi
			fi
		else
			F_printf "ERROR   - /jffs/scripts/wan-event is already removed"
		fi
	elif [ "$1" = 'check' ] ;then
		if ! grep -q "added by wanuptime.sh" '/jffs/scripts/wan-event' ; then
			F_logp "NOTICE  - Adding wanuptime to /jffs/scripts/wan-event file"
			F_wan_event create
		fi
	fi
}

# ntp lock/wait
F_ntp() {
	ntp_lock='/tmp/wanuptime_ntp.lock'
	[ -f "$ntp_lock" ] && F_logp "NOTICE  - NTP lock exists" && F_pad && exit 0
	if [ "$(nvram get ntp_ready)" -ne 1 ] ;then
		{
		F_printf "$$"
		date +'%c'
		F_printf "wanuptime ntp lock"
		} > "$ntp_lock"
		ntp_wait_time=0
		F_logp "NOTICE  - NTP is not sync'd waiting 10m checking every sec for sync" ;F_pad
		while [ "$(nvram get ntp_ready)" -ne 1 ] && [ "$ntp_wait_time" -lt 600 ] ; do
			ntp_wait_time="$((ntp_wait_time + 1))"
			printf '\r%b%s' "\033[2K" "INFO    - Elapsed time : $ntp_wait_time secs "
			sleep 1
		done
		printf '%b' "\033[2K"
		if [ "$ntp_wait_time" -ge 600 ] ; then
			F_logp "ERROR   - NTP failed to sync and update router time after 10 mins" ;F_pad
			rm -f "$ntp_lock" 2>/dev/null && exit 0
		fi
		F_logp "SUCCESS - NTP sync complete after $ntp_wait_time secs, checking WAN uptime in 3s"
		sleep 3   # allow logs to settle
		rm -f "$ntp_lock" 2> /dev/null
	fi
	TZ="$(cat /etc/TZ)"
	export TZ
}

# Start of script control ######################################################
clear
sed -n '2,13p' "$script_name_full"   # Header
printf '%52s\n\n' "$(/bin/date +'%c')"

# Firmware compatibility check
build_no="$(nvram get buildno | cut -f1 -d'.')"
build_sub="$(nvram get buildno | cut -f2 -d'.')"
if [ "$build_no" -ne 386 ] || [ "$build_no" -eq 384 ] && [ "$build_sub" -lt 15 ] ; then
	F_printf "Sorry, this version of firmware is not compatible, please upgrade to 384.15 or newer" ;F_pad ;exit 0
elif [ "$build_no" -eq 374 ] ;then
	F_printf "Johns fork has WAN uptime in the GUI, why use this script?" ;F_pad ;exit 0
fi

# wan-event creation option
if [ "$passed_option" = 'enable' ] ;then
	sed -i "1,/create_wan_event=.*/{s/create_wan_event=.*/create_wan_event='yes'/;}" "$script_name_full"
	F_printf "NOTICE  - Enabled wan-event, re-run script to create/add entries" ;F_pad ;exit 0
elif [ "$passed_option" = 'disable' ] ;then
	sed -i "1,/create_wan_event=.*/{s/create_wan_event=.*/create_wan_event='no'/;}" "$script_name_full"
	F_printf "NOTICE  - Cleaning wan-event of entries if they exist"
	F_wan_event remove	
	F_printf "NOTICE  - Disabled wan-event" ;F_pad ;exit 0
fi

# not time sensitive options
case "$passed_option" in
	'unlock') rm -f "$ntp_lock" 2> /dev/null ;;
	'h'|'H'|'-h'|'-H'|'help'|'-help') sed -n '14,26p' "$script_name_full" ;F_pad ;exit 0 ;;
	'manual'|'log'|'wanevent'|'-f') ;;
	'uninstall') F_wan_event remove ;rm -f "$script_name_full" ;F_printf "Script removed" ;F_pad ;exit 0 ;;
	*) F_printf "Invalid option $passed_option" ;F_pad ;exit 0 ;;
esac

F_ntp   # check NTP move to setting all time values
cur_epoch="$(/bin/date +'%s')"   # current epoch time
cur_date="$(/bin/date +'%c')"
cur_yr="$(/bin/date +'%Y')"
router_secs="$(awk '{print $1}' /proc/uptime | cut -d"." -f1)"
router_uptime="$(printf '%d day(s) %d hr(s) %d min(s) %d sec(s)\n' $((router_secs/86400)) $((router_secs%86400/3600)) $((router_secs%3600/60)) $((router_secs%60)))"

# force a search method
if [ "$passed_option" = '-f' ] ;then
	if [ "$2" = 'event' ] || [ "$2" = 'routes' ] || [ "$2" = 'restored' ] || [ "$2" = 'ntp' ] || [ "$2" = 'saved' ] ;then
		F_printf "Running in force mode for $2 search" ;F_sep ;F_find_"${2}" ;exit 0
	else
		F_printf "Invalid option $2 use -h to see valid options" ;F_pad ;exit 0
	fi
fi

# check if WAN is even up   @ColinTaylor
if [ "$(nvram get wan0_state_t)" -ne 2 ] && [ "$(nvram get wan1_state_t)" -ne 2 ] ;then
	F_logp "ERROR   - WAN doesn't appear to be up, exiting. Use -f method to force" ;F_pad
	exit 0
fi

# script will go through all search methods wan-event,wan up, ntp sync till match found
[ "$create_wan_event" = 'yes' ] && F_wan_event check   # check if we exist in wan-event
if [ -s '/jffs/scripts/wan-event' ] ;then   # if wan-event exists router will log a connected trigger otherwise start with wan up msg
	F_find_event
else
	F_printf "NOTICE  - No wan-event file found in /jffs/scripts/ skipping." ;F_sep
	F_find_routes
fi

# waited for NTP, calc'd uptime
case "$passed_option" in
	'log') F_show_uptime | F_log ;;   # if log argument reprint uptime for syslog
	'wanevent') F_log "Started by wan-event, new event date/time recorded in RAM save file" ;;
esac

# F_printf "Clean exit, goodbye!" ;F_pad
exit 0
# EOF
