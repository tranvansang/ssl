#!/usr/bin/env bash
set -e

# crontab entry
# 0 15 * * * $HOME/ssl/watch.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
env_path="${DIR}/.env"
if [[ ! -f ${env_path} ]]; then
	echo '.env does not exist. check .env.example for sample configuration'
	exit 1
fi
# shellcheck source=.env
source "${env_path}"

send_slack() {
	local domain="$1"
	local msg_prefix="[ssl ${domain}]"
	local msg="$2"
	local full_msg="${msg_prefix} ${msg}"
	echo "${full_msg}"
	if [[ ${SLACK_WEBHOOK_URL} != "" ]]; then
		curl -X POST -H 'Content-type: application/json' --data "{'text': '${full_msg}'}" "${SLACK_WEBHOOK_URL}"
	fi
}

letsencrypt_path="${DIR}/build/letsencrypt"

check_domain() {
	local domain=$1
	if ! docker run --rm \
		"${CERTBOT_DOCKER_FLAGS[@]}" \
		-v "${letsencrypt_path}":/etc/letsencrypt:ro \
		--entrypoint /bin/sh \
		certbot/certbot:"${CERTBOT_VER}" \
		-c "if [ -f /etc/letsencrypt/live/${domain}/fullchain.pem ]; then exit 0; else exit 1; fi"; then
		send_slack "${domain}" "cert is not inited. please run ./run.sh"
		exit 1
	fi
	echo "check latest stat info ${domain}"
	if ! mod_date=$(docker run --rm \
		"${CERTBOT_DOCKER_FLAGS[@]}" \
		-v "${letsencrypt_path}":/etc/letsencrypt:ro \
		--entrypoint /bin/stat \
		certbot/certbot:"${CERTBOT_VER}" \
		-c '%y' \
		"/etc/letsencrypt/live/${domain}/fullchain.pem"); then
		send_slack "${domain}" "can not stat file for ${domain}"
		exit 1
	else
		echo "latest stat info is ${mod_date}"
	fi

	stat_path="${DIR}/build/stat-${domain}.txt"
	nginx_id_path="${DIR}/build/nginx.txt"
	echo "check last stat info at path ${stat_path}"
	if [[ -f ${stat_path} ]]; then
		if ! last_mod_date=$(cat "${stat_path}"); then
			send_slack "${domain}" "can not read info from ${stat_path}"
			exit 1
		else
			echo "last stat info is ${last_mod_date}"
		fi
		if [[ ${last_mod_date} != "${mod_date}" ]]; then
			echo "file has changed. restart nginx"
			if [[ ! -f ${nginx_id_path} ]]; then
				send_slack "${domain}" "nginx has not start. Can not restart nginx"
				exit 1
			fi
			nginx_container_name=$(cat "${nginx_id_path}")
			if ! docker restart "${nginx_container_name}"; then
				send_slack "${domain}" "!!!ssl cert updated. however, Can not restart nginx"
			else
				echo "${mod_date}" >"${stat_path}"
				send_slack "${domain}" "ssl cert updated. nginx has been restarted"
			fi
			exit 1
		else
			echo "SSL has not changed ${domain}"
		fi
	else
		echo "${stat_path} not found. create one without restart"
		echo "${mod_date}" >"${stat_path}"
	fi
}

IFS=, read -r -a domain_list < <(echo "${DOMAINS}")
for domain in "${domain_list[@]}"; do
	check_domain "${domain}"
done
