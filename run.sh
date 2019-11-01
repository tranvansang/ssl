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
if [[ ! -f "${DIR}/.env" ]]; then
	echo '.env does not exist. check .env.example for sample configuration'
	exit 1
fi
# shellcheck source=.env
source "${DIR}/.env"
operator="$1"
build_dir="${DIR}/build"
src_dir="${DIR}/src"
mkdir -p "${build_dir}"
mkdir -p "${build_dir}/www"

# gen params.pem
if [[ -f "${build_dir}/dhparams.pem" ]]; then
	docker --rm tranvansang/openssl:"${OPENSSL_VER}" openssl \
		-v "${build_dir}/dhparams.pem":/dhparams.pem \
		dhparam \
		-out "/dhparams.pem" \
		2048
fi

# init certbot
# shellcheck disable=SC2207
IFS=, read -r -a domain_list < <(echo "${DOMAINS}")
IFS=, read -r -a port_list < <(echo "${PORTS}")
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
		if ! docker stop "${container_id}"; then
			echo "Can not stop container. skipping..."
		fi
		rm "${id_path}"
	else
		echo "${id_path} not found. skip stopping"
	fi
}
init_domain() {
	local local_domain="$1"
	#stop nginx if running
	stop_container_at_path "${build_dir}/nginx.txt"
	#generate temporary nginx conf for initial ssl setup
	sed "s/{{DOMAIN}}/${local_domain}/g" "${src_dir}/www-nginx.conf" >"${build_dir}/www-nginx.conf"
	echo "run temporary nginx server in background"
	temp_nginx_name=$(docker run -d \
		-v "${build_dir}/www":/www:ro \
		-v "${build_dir}/www-nginx.conf":/etc/nginx/nginx.conf:ro \
		--rm \
		-p 80:80 \
		nginx:"${NGINX_VER}")
	echo "check domain ${local_domain}"
	echo "generate initial ssl cert or renew specific domain with certonly"
	if ! docker run --rm \
		"${CERTBOT_DOCKER_FLAGS[@]}" \
		-v "${build_dir}/letsencrypt":/etc/letsencrypt \
		-v "${build_dir}/www":/www \
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
}

for domain in "${domain_list[@]}"; do
	init_domain "${domain}"
done

#assume that ssl cert has been created already
#main nginx server
stop_container_at_path "${build_dir}/nginx.txt"
stop_container_at_path "${build_dir}/cron.txt"
if [[ ${operator} != "stop" ]]; then
	overwritten_nginx_path="${DIR}/nginx.conf"
	if [[ -f ${overwritten_nginx_path} ]]; then
		echo "detect manual nginx overwritten. use that configuration"
		cp "${overwritten_nginx_path}" "${build_dir}/nginx.conf"
	else
		echo "generate nginx config from templates"
		i=0
		servers=
		server_template_path="${src_dir}/server.conf"
		while [[ ${i} -lt ${ndomain} ]]; do
			domain="${domain_list[${i}]}"
			port="${port_list[${i}]}"
			server=$(sed "s/{{DOMAIN}}/${domain}/g" "${server_template_path}" |
				sed -e "s/{{PORT}}/${port}/g")
			servers="${servers}\n${server}"
			i=$(("${i}" + 1))
		done
		nginx_template_path="${src_dir}/nginx.conf"
		awk -v servers="${servers}" '{sub("{{SERVERS}}", servers, $0)} {print}' "${nginx_template_path}" \
		 >"${build_dir}/nginx.conf"
	fi
	echo "start main nginx server in background"
	# shellcheck disable=SC2086
	docker run --rm -d \
		"${NGINX_DOCKER_FLAGS[@]}" \
		--net=host \
		-v "${build_dir}/letsencrypt":/etc/letsencrypt \
		-v "${build_dir}/www":/www:ro \
		-v "${build_dir}/nginx.conf":/etc/nginx/nginx.conf:ro \
		-v "${build_dir}/dhparams.pem":/etc/ssl/private/dhparams.pem:ro \
		-v "${src_dir}/conf.d":/etc/nginx/conf.d:ro \
		nginx:"${NGINX_VER}" \
		>"${build_dir}/nginx.txt"

	#ssl refresh crontab
	echo "start crontab server in background to periodically refresh ssl cert"
	docker run --rm -d \
		"${CERTBOT_DOCKER_FLAGS[@]}" \
		-v "${build_dir}/letsencrypt":/etc/letsencrypt \
		-v "${build_dir}/www":/www \
		-v "${src_dir}/certbot-cron":/var/spool/cron/crontabs/root:ro \
		--entrypoint /usr/sbin/crond \
		certbot/certbot:"${CERTBOT_VER}" \
		-f -d 8 /etc/cron.d/certbot-cron \
		>"${build_dir}/cron.txt"
fi
echo "DONE!"
