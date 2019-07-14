#!/usr/bin/env bash

# crontab entry
# 0 15 * * * ./watch.sh

cur_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
env_path=${cur_dir}/.env
if [[ ! -f ${env_path} ]]
then
	echo '.env does not exist. check .env.example for sample configuration'
	exit 1
fi
export $(grep -v '^\(#\|\s*$\)' ${env_path} | xargs -0)

send_slack () {
    local msg_prefix="[ssl ${DOMAIN}]"
	local msg=$1
	local full_msg="${msg_prefix} ${msg}"
	echo ${full_msg}
	if [[ ${SLACK_WEBHOOK_URL} != "" ]]
	then
        curl -X POST -H 'Content-type: application/json' --data "{'text': '${full_msg}'}" ${SLACK_WEBHOOK_URL}
    fi
}

cert_path=${cur_dir}/build/letsencrypt/live/${DOMAIN}/fullchain.pem
if [[ ! -f ${cert_path} ]]
then
    send_slack "cert is not inited. please run ./run.sh"
    exit 1
fi
letsencrypt_path=${cur_dir}/build/letsencrypt
echo "check latest stat info"
mod_date=$( docker run \
    -v ${letsencrypt_path}:/etc/letsencrypt:ro \
    --rm \
    --entrypoint /bin/stat \
    certbot/certbot \
        -c '%y' \
        /etc/letsencrypt/live/${DOMAIN}/fullchain.pem )
if [[ $? != 0 ]]
then
    send_slack "can not stat file"
    exit 1
else
    echo "latest stat info is ${mod_date}"
fi

stat_path=${cur_dir}/build/stat.txt
nginx_id_path=${cur_dir}/build/nginx.txt
echo "check last stat info at path ${stat_path}"
if [[ -f  ${stat_path} ]]
then
    last_mod_date=$(cat ${stat_path})
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
        nginx_container_name=$( cat ${nginx_id_path} )
        docker restart ${nginx_container_name}
        if [[ $? = 0 ]]
        then
            echo ${mod_date} > ${stat_path}
            send_slack "ssl cert updated. nginx has been restarted"
        else
            send_slack "!!!ssl cert updated. however, Can not restart nginx"
        fi
    else
        echo "SSL has not changed"
    fi
else
    echo ${mod_date} > ${stat_path}
    echo "${stat_path} not found. create one without restart"
fi
