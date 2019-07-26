#!/usr/bin/env bash
set -e

#usage
# ./run.sh
# ./run.sh stop

check_cmd() {
	cmd="$1"
	if [[ ! -x $(command -v "${cmd}") ]]; then
		echo "${cmd} is required to run this script. please install it"
		exit 1
	fi
}
check_cmd awk
check_cmd docker
check_cmd sed

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
env_path="${DIR}/.env"
if [[ ! -f ${env_path} ]]; then
	echo '.env does not exist. check .env.example for sample configuration'
	exit 1
fi
# shellcheck source=.env
source "${env_path}"
operator="$1"

# gen params.pem
dhparams_path="${DIR}/build/dhparams.pem"
if [[ -f ${dhparams_path} ]]; then
	openssl dhparam -out "${dhparams_path}" 2048
fi

# init certbot
nginx_id_path="${DIR}/build/nginx.txt"
www_nginx_path="${DIR}/build/www-nginx.conf"
www_path="${DIR}/build/www"
letsencrypt_path="${DIR}/build/letsencrypt"
domain_list=(${DOMAINS})
port_list=(${PORTS})
ndomain=${#domain_list[@]}
nport=${#port_list[@]}

if [[ ${ndomain} -gt ${nport} ]]; then
	echo "number of ports(${nport}) must equal or greater than number of domains(${ndomain}). exit now"
	exit 1
fi

stop_container_at_path() {
	local id_path="$1"
	echo "try stop container with id stored in ${id_path}"
	if [[ -f ${id_path} ]]; then
		local container_id
		container_id=$(cat "${id_path}")
		docker stop "${container_id}"
		rm "${id_path}"
	else
		echo "${id_path} not found. skip stopping"
	fi
}
mkdir -p "${www_path}"
mkdir -p "${DIR}/build"
init_domain() {
	local local_domain="$1"
	echo "check domain ${local_domain}"
	if ! docker run --rm \
		-v "${letsencrypt_path}":/etc/letsencrypt:ro \
		--entrypoint /bin/sh \
		certbot/certbot:"${CERTBOT_VER}" \
		-c "if [ -f /etc/letsencrypt/live/${local_domain}/fullchain.pem ]; then exit 0; else exit 1; fi"; then
		echo "cert not found. run initial setup"
		#stop nginx if running
		stop_container_at_path "${nginx_id_path}"
		#generate temporary nginx conf for initial ssl setup
		sed "s/{{DOMAIN}}/${local_domain}/g" "${DIR}/src/www-nginx.conf" >"${www_nginx_path}"
		echo "run temporary nginx server in background"
		temp_nginx_name=$(docker run -d \
			-v "${www_path}":/www:ro \
			-v "${www_nginx_path}":/etc/nginx/nginx.conf:ro \
			--rm \
			-p 80:80 \
			nginx:"${NGINX_VER}")
		echo "generate initial ssl cert with certonly"
		if ! docker run \
			-v "${letsencrypt_path}":/etc/letsencrypt \
			-v "${www_path}":/www \
			--rm \
			certbot/certbot:"${CERTBOT_VER}" \
			certonly \
			-d "${local_domain}" \
			--webroot \
			--webroot-path /www \
			--non-interactive \
			--agree-tos \
			-m "${EMAIL}"; then
			echo "Can not generate initial certificate. Is your DNS config correct?"
			echo "stop the temporary nginx server"
			docker stop "${temp_nginx_name}"
			exit 1
		fi
		echo "stop the temporary nginx server"
		docker stop "${temp_nginx_name}"
	fi
}

for domain in ${DOMAINS}; do
	init_domain "${domain}"
done

#assume that ssl cert has been created already
#main nginx server
nginx_path="${DIR}/build/nginx.conf"
cron_id_path="${DIR}/build/cron.txt"
stop_container_at_path "${nginx_id_path}"
stop_container_at_path "${cron_id_path}"
if [[ ${operator} != "stop" ]]; then
	overwritten_nginx_path="${DIR}/nginx.conf"
	if [[ -f ${overwritten_nginx_path} ]]; then
		echo "detect manual nginx overwritten. use that configuration"
		cp "${overwritten_nginx_path}" "${nginx_path}"
	else
		echo "generate nginx config from templates"
		i=0
		servers=
		server_template_path="${DIR}/src/server.conf"
		while [[ ${i} -lt ${ndomain} ]]; do
			domain="${domain_list[${i}]}"
			port="${port_list[${i}]}"
			server=$(sed "s/{{DOMAIN}}/${domain}/g" "${server_template_path}" |
				sed -e "s/{{PORT}}/${port}/g")
			servers="${servers}\n${server}"
			i=$(("${i}" + 1))
		done
		nginx_template_path="${DIR}/src/nginx.conf"
		awk -v servers="${servers}" '{sub("{{SERVERS}}", servers, $0)} {print}' "${nginx_template_path}" >"${nginx_path}"
	fi
	echo "start main nginx server in background"
	nginx_id=$(docker run -d --rm \
		--net=host \
		-v "${letsencrypt_path}":/etc/letsencrypt \
		-v "${www_path}":/www:ro \
		-v "${nginx_path}":/etc/nginx/nginx.conf:ro \
		-v "${dhparams_path}":/etc/ssl/private/dhparams.pem:ro \
		-v "${DIR}/src/conf.d":/etc/nginx/conf.d:ro \
		${NGINX_DOCKER_FLAG} \
		nginx:"${NGINX_VER}")
	echo "${nginx_id}" >"${nginx_id_path}"

	#ssl refresh crontab
	echo "start crontab server in background to periodically refresh ssl cert"
	cron_id=$(docker run \
		-d --rm \
		-v "${letsencrypt_path}":/etc/letsencrypt \
		-v "${www_path}":/www \
		-v "${DIR}/src/certbot-cron":/etc/cron.d/certbot-cron:ro \
		--rm \
		--entrypoint /usr/sbin/crond \
		certbot/certbot:"${CERTBOT_VER}" \
		-f -d 8 /etc/cron.d/certbot-cron)
	if [[ $? != 0 ]]; then
		echo "can not start crontab job to refresh ssl periodically"
		exit 1
	fi
	echo "${cron_id}" >"${cron_id_path}"
fi
echo "DONE!"
