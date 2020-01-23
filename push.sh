#!/bin/bash

if [ "$(tty)" = "not a tty" ]; then
    # will be in /var/lib/asterisk/push.sh.debug*
    exec 2> ${0##*/}.debug$$
    if [ -n "$1" ]; then
        rm ${0##*/}-${1##*/}.debug-latest
        ln ${0##*/}.debug$$ ${0##*/}-${1##*/}.debug-latest
    fi
fi
exec 1>&2
env
set -x
date

FCM_KEY=""
ASTERISK_IP_ADDRESS=""

send_push() {
    local EXT="$1"
    local TOK="$2"

    # \"registration_ids\": [ \"$TOK\" ],
    json_payload="{
        \"to\":\"$TOK\",
        \"priority\":\"high\",
        \"uuid\":\"<urn:uuid:$(uuidgen)>\",
        \"send-time\":\"$(date +%F\ %T)\"
    }"

    result=$(curl -s -X POST --header "Authorization: Key=$FCM_KEY"    \
                             --Header "Content-Type: application/json" \
	            -d "$json_payload"                                 \
	            https://fcm.googleapis.com/fcm/send)
    if [[ $result = *MissingRegistration* ]]; then
	date
        exit 1
    fi
}

declare -A toks
if [[ $1 = *pn-tok* ]]; then
    EXTS="${1//&/ }"

    for ext in $EXTS; do
        read host tok < <(echo "$ext" | sed -ne 's/.*:\(.*\)@.*pn-tok=\([^\;]*\);.*/\1 \2/p')
        if [ -n "$host" ]; then
            toks[$host]="$tok"
        fi
    done
    echo ${#toks[@]}
    for host in ${!toks[@]}; do
        echo "$host: ${toks[$host]}"
    done
    if [ ${#toks[@]} -lt 1 ]; then
        exit 0
    fi
else
    EXT="${1##*/}"
    d=($(asterisk -r -x "database show registrar" | 
         sed -ne "/^\/registrar\/contact\/$EXT\;/s/.*{\"via_addr\":\"\([^\"]*\)\".*pn-tok=\([^\;]*\);.*/\1 \2/p" |
	 sort -u))
    IPADDR=${d[0]}
    #if lsof -n -p $(pidof asterisk) | grep "$ASTERISK_IP_ADDRESS:sip->$IPADDR:[0-9]* (ESTABLISHED)"; then
    if ss -tn | grep " 0  *$ASTERISK_IP_ADDRESS:5060  *$IPADDR:.*"; then
        echo "$EXT is still connected, no push needed"
        echo $SECONDS
        exit 0
    fi
    TOK=${d[1]}
    if [ -z "$TOK" ]; then
        echo "$EXT is not registered"
        exit 1
    fi
    toks[$EXT]="$TOK"
fi

EVENT=""
lines=0
declare -A waiting
coproc ncat --no-shutdown 127.0.0.1 5038
trap 'kill $COPROC_PID' EXIT
echo -e "Action: Login\r\nUsername: <username>\r\nSecret: <password>\r\n" >&${COPROC[1]}
waittime=60
let timeout=$waittime-$SECONDS
while [ $timeout -gt 0 ]; do
    read -t 1 line
    line=${line/$'\r'}
    if [ $lines = 0 ] || [ -z "foo$line" ]; then
        for host in ${!toks[@]}; do
            if ! send_push "$host" "${toks[$host]}"; then
	        echo "Push failed for $host"
	        date
	    fi
	    waiting[$host]=1
	done
    fi
    echo "$(date): $line"
    if [[ $line = Event:\ * ]]; then
        EVENT=${line#Event: }
    fi
    if [[ "$line" = "" ]]; then
        EVENT=""
    fi
    if [[ $line = EndpointName:\ * ]] && [ "$EVENT" = "ContactStatus" ]; then
	host="${line##*: }"
	if [ "${waiting[$host]}" = 1 ]; then
	    echo "${host} connected after $SECONDS seconds"
	    unset waiting[$host]
	    if [ ${#waiting[@]} -lt 1 ]; then
	        #kill $ncatpid
	        exit 0
            fi
	fi
    fi
    for host in ${!waiting[@]}; do
        echo "waiting: $host"
    done
    let lines++
    echo $SECONDS
    let timeout=$waittime-$SECONDS
done <&${COPROC[0]}
date  
echo $SECONDS
