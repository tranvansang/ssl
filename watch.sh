#!/usr/bin/env bash

# crontab entry
# 0 15 * * * $HOME/ssl/watch.sh

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
env_path="${DIR}/.env"
if [[ ! -f ${env_path} ]]
then
	echo '.env does not exist. check .env.example for sample configuration'
	exit 1
fi
source "${env_path}"

send_slack () {
    local msg_prefix="[ssl ${DOMAINS}]"
	local msg="$1"
	local full_msg="${msg_prefix} ${msg}"
	echo ${full_msg}
	if [[ ${SLACK_WEBHOOK_URL} != "" ]]
	then
        curl -X POST -H 'Content-type: application/json' --data "{'text': '${full_msg}'}" ${SLACK_WEBHOOK_URL}
    fi
}

letsencrypt_path="${DIR}/build/letsencrypt"
if [[ ! -d ${letsencrypt_path} ]]
then
    send_slack "cert is not inited. please run ./run.sh"
    exit 1
fi

check_domain () {
    local domain=$1
    echo "check latest stat info ${domain}"
    mod_date=$( docker run \
        -v "${letsencrypt_path}":/etc/letsencrypt:ro \
        --rm \
        --entrypoint /bin/stat \
        certbot/certbot:${CERTBOT_VER} \
            -c '%y' \
            /etc/letsencrypt/live/${domain}/fullchain.pem )
    if [[ $? != 0 ]]
    then
        send_slack "can not stat file for ${domain}"
        exit 1
    else
        echo "latest stat info is ${mod_date}"
    fi

    stat_path="${DIR}/build/stat-${domain}.txt"
    nginx_id_path="${DIR}/build/nginx.txt"
    echo "check last stat info at path ${stat_path}"
    if [[ -f  ${stat_path} ]]
    then
        last_mod_date=$(cat "${stat_path}")
        if [[ $? != 0 ]]
        then
            send_slack "can not read info from ${stat_path}"
            exit 1
        else
            echo "last stat info is ${last_mod_date}"
        fi
        if [[ ${last_mod_date} != ${mod_date} ]]
        then
            echo "file has changed. restart nginx"
            if [[ ! -f ${nginx_id_path} ]]
            then
                send_slack "nginx has not start. Can not restart nginx"
                exit 1
            fi
            nginx_container_name=$( cat "${nginx_id_path}" )
            docker restart ${nginx_container_name}
            if [[ $? = 0 ]]
            then
                echo ${mod_date} > "${stat_path}"
                send_slack "ssl cert updated. nginx has been restarted"
            else
                send_slack "!!!ssl cert updated. however, Can not restart nginx"
            fi
            exit 1
        else
            echo "SSL has not changed ${domain}"
        fi
    else
        echo "${stat_path} not found. create one without restart"
        echo ${mod_date} > "${stat_path}"
fi
}

for domain in ${DOMAINS}
do
    check_domain "${domain}"
done
