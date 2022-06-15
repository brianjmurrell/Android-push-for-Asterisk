#!/bin/bash

if [ "$(tty)" = "not a tty" ] && ! ${DEBUG:-false}; then
    # will be in /var/lib/asterisk/push.sh.debug*
    exec 3> ${0##*/}.debug$$
    # don't do this.  this is the comms channel back to asterisk
    #exec 1>&3
    if [ -n "$1" ]; then
        rm ${0##*/}-${1##*/}.debug-latest
        ln ${0##*/}.debug$$ ${0##*/}-${1##*/}.debug-latest
    fi
#else
# this is the condition when run from cron at 15 past the hour
# so don't do this here
#    exec 3>/dev/null
fi
if [ ! -e /proc/$$/fd/3 ]; then
    exec 3>&1
fi
BASH_XTRACEFD=3

stacktrace() {
   local msg="$1"
   #set +x
   local i=0
   while true; do
      read -r line func file < <(caller $i)
      if [ -z "$line" ]; then
          # prevent cascading ERRs
          trap '' ERR
          break
      fi
      if [ $i -eq 0 ]; then
          echo -e "$msg: \c" >&2
      else
          echo -e "Called from: \c" >&2
      fi
      echo "$file:$line $func()" >&2
      ((i++))
   done
}

set -E
trap 'stacktrace "Unchecked error condition at"; { echo "environment:"; env; echo "args: $@"; ls -l /proc/self/fd} >&3; exit 1' ERR

#echo "Asterisk vars:" >&3
#cat >&3

#if ! $DEBUG; then
    #exec 1>&2
#fi

if [ -n "$AST_VERSION" ]; then
    # make &5 the channel back to asterisk
    exec 5>&1-
    # make &6 the channel from asterisk
    exec 6<&0-

    # dump stdin from agi
    echo "AGI Vars:" >&3
    line="init"
    while [ "${#line}" -gt "2" ]; do
            read -r line <&6
            echo "$line" >&3
    done

    echo "AGI Env:" >&3
else
    echo "Env:" >&3
fi
env >&3

set -x

ami_send() {
    local msg="$1"
    echo -e "$msg" >&${COPROC[1]}
}

ami_readline() {
    local timeout="$1"

    if [ -n "$timeout" ]; then
        timeout="-t $timeout"
    fi
    local line=""
    if ! read $timeout line <&${COPROC[0]}; then
        rc=${PIPESTATUS[0]}
        echo "Got an error reading from AMI: $rc" >&2
	return $rc
    fi
    line=$(echo "$line" | tr -d "\r")
    echo "$line"
}

function token_quote {
  local quoted=()
  for token; do
    quoted+=( "$(printf '%q' "$token")" )
  done
  printf '%s\n' "${quoted[*]}"
}

ami_receive() {
    local timeout="$1"

    set +x
    declare -A pdu
    local complete=false
    local line
    while ! $complete; do
        set -x
        if ! line=$(set +x; ami_readline "$timeout" 2>/dev/null); then
	    local rc=${PIPESTATUS[0]}
            if [ $rc -gt 128 ]; then
                # timeout
                return 0
            fi
	    return $rc
	fi
        set +x
        # End Of Message detected
        if [ -z "$line" ]; then
            complete=true
        else
            # Concat line read
	    local key=${line%%:*}
	    local value=${line##*: }
	    #value=${value// /\\\\ }
	    #value=${value//|/\\\\|}
	    #value=${value//</\\\\<}
	    #value=${value//>/\\\\>}
	    #value=${value//(/\\\\(}
	    #value=${value//)/\\\\)}
	    #value=${value//;/\\\\;}
	    ##value=${value//\'/\\\\\'}
	    value=$(token_quote "$value")
	    pdu[$key]=${value}
            #echo "pdu:" >&3
	    #set +x
            #for K in "${!pdu[@]}"; do
	    #    echo $K: ${pdu[$K]} >&3
	    #done
	    #set -x
        fi
    done
    local K
    for K in "${!pdu[@]}"; do
        echo -e "[$K]=${pdu[$K]} \c"
    done
    echo
    set -x
}

ami_start() {
    coproc ncat --no-shutdown 127.0.0.1 5038
    trap 'kill $COPROC_PID' EXIT
    if ! line=$(ami_readline); then
        echo "error, read returned ${PIPESTATUS[0]}"
	exit 1
    fi
    ami_send "Action: Login\r\nUsername: <username>\r\nSecret: <password>\r\n"
    eval "declare -A msg=( $(ami_receive) )"
    echo "Read back:" >&3
    set +x
    date >&3
    for K in "${!msg[@]}"; do
        echo $K: ${msg[$K]} >&3
    done
    set -x
    if [[ ${msg[Response]} != Success ]]; then
        echo "Failed to log into AMI"
	exit 1
    fi
}

get_ip_address() {
    local ext="$1"

    local addr
    declare -A msg

    ami_send "Action: PJSIPShowEndpoint\r\nActionID: $$\r\nEndpoint: $1\r\n"
    while [ "${msg[ActionID]}" != "$$" ]; do
        unset msg
        eval "declare -A msg=( $(ami_receive) )"
        set +x
        date >&3
        for K in "${!msg[@]}"; do
            echo $K: ${msg[$K]} >&3
        done
        set -x
    done
    while [ "${msg[Event]}" != "AorDetail" ] ||
          [ "${msg[ActionID]}" != "$$" ]; do
        unset msg
        eval "declare -A msg=( $(ami_receive) )"
        set +x
        date >&3
        for K in "${!msg[@]}"; do
            echo $K: ${msg[$K]} >&3
        done
        set -x
    done
    echo "Got the AOR" >&3
    addr=$(echo "${msg[Contacts]}" |
        #sed -E -ne "s/$ext\/sip:$ext@\[?([[:xdigit:]\.:]+)\]?:.*(:?;pn-(:?tok|prid)=([^;]+);.*)?/\1 \4/p")
        sed -E -ne "s/$ext\/sip:$ext@\[?([[:xdigit:]\.:]+)\]?:.*;pn-(:?tok|prid)=([^;]+);.*/\1 \3/p")
    # drain the endpoint data
    while [ "${msg[Event]}" != "EndpointDetailComplete" ]; do
        unset msg
        eval "declare -A msg=( $(ami_receive) )"
        set +x
        date >&3
        for K in "${!msg[@]}"; do
            echo $K: ${msg[$K]} >&3
        done
        set -x
    done

    echo "$addr"
}

# send an agi command and make sure it return success
agi_cmd() {
    local msg="$1"

    echo "$msg" >&5
    local line
    read line <&6
    echo "response: $line" >&3
    if [[ $line != 200\ * ]]; then
        echo "Got a non-success result from \"$msg\"" >&3
	exit 1
    fi
}

agi_msg() {
    local msg="$1"

    if [ -n "$AST_VERSION" ]; then
        agi_cmd "verbose \"$msg\""
    fi
}

date || true # how does date return an error?

FCM_KEY=""

send_push() {
    local EXT="$1"
    local TOK="$2"

    agi_msg "Sending push for $EXT"

    # \"registration_ids\": [ \"$TOK\" ],
    json_payload="{
        \"to\":\"$TOK\",
        \"priority\":\"high\",
        \"uuid\":\"<urn:uuid:$(uuidgen)>\",
        \"send-time\":\"$(date +%F\ %T)\"
    }"

    local tries=3
    local result=""
    while [ $tries -gt 0 ]; do
        (( tries-=1 ))
	# sadly this is unsupported on EL7
	# --happy-eyeballs-timeout-ms 200
        if !  result=$(curl -v --connect-timeout 1 -s -X POST            \
                               --header "Authorization: Key=$FCM_KEY"    \
                               --Header "Content-Type: application/json" \
	                    -d "$json_payload"                           \
	                    https://fcm.googleapis.com/fcm/send); then
	    date >&3
            continue
        fi
        if [[ $result = *MissingRegistration* ]]; then
	    date >&3
            continue
        fi
        break
    done
    if [[ $result != *\"success\":1* ]]; then
        ping -c 1 fcm.googleapis.com
        return 1
    fi

    return 0
}

declare -A toks

if [[ $1 = *pn-tok* ]]; then
    EXTS="${1//&/ }"

    for ext in $EXTS; do
        read host tok < <(echo "$ext" | sed -E -ne 's/.*:(.*)@.*pn-(tok|prid)=([^\;]*);.*/\1 \3/p')
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
    ami_start
    EXT="${1##*/}"
    d=($(get_ip_address "$EXT"))
    IPADDR=${d[0]}
    if [[ $IPADDR = *:* ]]; then
        BRACKETED_IPADDR="\[$IPADDR\]"
    else
        BRACKETED_IPADDR="$IPADDR"
    fi
    any_ipaddr_pcre="[?[[:xdigit:]\.:]+\]?"
    need_push="true"
    opportunistic_push="false"
    if ss -tnp | grep -P "^ESTAB\s+\d+\s+\d+\s+$any_ipaddr_pcre:5060\s+$BRACKETED_IPADDR:\d+\s+" >&3; then
        #echo "$EXT is still connected, no push needed"
	ping -W 1 -c 1 "$IPADDR" 2>&1 # requires selinux allows 2>&3 >&3
        agi_msg "$EXT was already registered"
        echo $SECONDS >&3
        echo "$EXT is supposedly still connected, sending a push just in case, but not waiting for the register"
        #exit 0
        opportunistic_push="true"
    else
        if [ -h /proc/$$/fd/4 ]; then
            echo "Client is no longer connected.  TCP sockets dump attached."
            ss -tnp >&4
	fi
    fi
    TOK=${d[1]}
    if [ -z "$TOK" ]; then
        echo "$EXT is not registered"
	echo "$r"
        exit 1
    fi
    toks[$EXT]="$TOK"
fi

if $need_push; then
    EVENT=""
    lines=0
    declare -A waiting
    #waittime=15
    #waittime=30
    waittime=60
    for host in ${!toks[@]}; do
        echo "Sending push for $host took:"
        if ! (exec 2>&1; time send_push "$host" "${toks[$host]}"); then
            echo "Push failed for $host"
            date
	    exit 1
        fi
        agi_msg "Waiting for $host to register"
        waiting[$host]=1
    done
    let timeout=$waittime-$SECONDS
    while ! $opportunistic_push && [ $timeout -gt 0 ]; do
        #if ! msg=$(ami_receive "$timeout"); then
        eval "declare -A msg=( $(ami_receive "$timeout") )"
        #    (( timeout=waittime-SECONDS )) || true
        #    continue
        #fi
        echo "$(date):"
        set +x
        date >&3
        for K in "${!msg[@]}"; do
            echo $K: ${msg[$K]}
        done
        set -x
        if [[ ${msg[Event]} = ContactStatus* ]]; then
            host="${msg[AOR]}"
	    if [ "${waiting[$host]}" = 1 ]; then
	        echo "${host} connected after $SECONDS seconds"
	        unset waiting[$host]
	        if [ ${#waiting[@]} -lt 1 ]; then
	            #exit 0
		    break
                fi
	    fi
        fi
        if [ "$SECONDS" != "$last_SECONDS" ]; then
            echo -e "waiting for: \c"
            for host in ${!waiting[@]}; do
                echo -e "$host \c"
            done
            echo "for $SECONDS seconds"
        fi
        last_SECONDS=$SECONDS
        (( lines++ )) || true
        (( timeout=waittime-SECONDS )) || true
    done
    date
    echo $SECONDS
    agi_msg "$host registered.  Took $SECONDS seconds to register."
fi

exit 0
