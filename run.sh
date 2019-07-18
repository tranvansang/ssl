#!/usr/bin/env bash

#usage
# ./run.sh
# ./run.sh stop

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
env_path="${DIR}/.env"
if [[ ! -f ${env_path} ]]
then
	echo '.env does not exist. check .env.example for sample configuration'
	exit 1
fi
source "${env_path}"
operator="$1"

# gen params.pem
dhparams_path="${DIR}/build/dhparams.pem"
if [[ -f ${dhparams_path} ]]
then
    openssl dhparam -out "${dhparams_path}" 2048
fi

# init certbot
nginx_id_path="${DIR}/build/nginx.txt"
www_nginx_path="${DIR}/build/www-nginx.conf"
www_path="${DIR}/build/www"
letsencrypt_path="${DIR}/build/letsencrypt"
domain_list=( ${DOMAINS} )
port_list=( ${PORTS} )
ndomain=${#domain_list[@]}
nport=${#port_list[@]}

if [[ ${ndomain} -gt ${nport} ]]
then
    echo "number of ports(${nport}) must equal or greater than number of domains(${ndomain}). exit now"
    exit 1
fi

stop_container_at_path () {
    local id_path="$1"
    echo "try stop container with id stored in ${id_path}"
    if [[ -f ${id_path} ]]
    then
        local container_id=$( cat "${id_path}" )
        docker stop ${container_id}
        if [[ $? != 0 ]]
        then
            echo "Can not stop currently running container id ${container_id} at path ${id_path}"
        else
            echo "container ${container_id} has been stopped"
        fi
        rm "${id_path}"
    else
        echo "${id_path} not found. skip stopping"
    fi
}
create_dir () {
    local dir_path="$1"
    echo "try making dir ${dir_path}"
    if [[ -f ${dir_path} ]]
    then
        echo "${dir_path} exists as a file. try deleting (non root)"
        rm -f "${dir_path}"
        if [[ $? != 0 ]]
        then
            echo "cannot remove ${dir_path}. You may need to remove it manually with sudo privilege. By running following command"
            echo "sudo rm -rf ${dir_path}"
            exit 1
        fi
    fi
    if [[ ! -d ${dir_path} ]]
    then
        echo "make dir ${www_path}"
        mkdir -p "${www_path}"
    fi
}
create_dir "${www_path}"
create_dir "${letsencrypt_path}"
init_domain() {
    local local_domain="$1"
    cert_path="${DIR}/build/letsencrypt/live/${local_domain}/fullchain.pem"
    echo "check domain ${local_domain}"
    if [[ ! -f ${cert_path} ]]
    then
        echo "cert not found. run initial setup"
        #stop nginx if running
        stop_container_at_path "${nginx_id_path}"
        #generate temporary nginx conf for initial ssl setup
        sed "s/{{DOMAIN}}/${local_domain}/g" "${DIR}/src/www-nginx.conf" > "${www_nginx_path}"
        echo "run temporary nginx server in background"
        temp_nginx_name=$( docker run -d \
            -v "${www_path}":/www:ro \
            -v "${www_nginx_path}":/etc/nginx/nginx.conf:ro \
            --rm \
            -p 80:80 \
            nginx:${NGINX_VER} )
        if [[ $? != 0 ]]
        then
            echo "can not start nginx"
            exit 1
        fi
        echo "generate initial ssl cert with certonly"
        docker run \
            -v "${letsencrypt_path}":/etc/letsencrypt \
            -v "${www_path}":/www \
            --rm \
            certbot/certbot:${CERTBOT_VER} \
            certonly \
                -d ${local_domain} \
                --webroot \
                --webroot-path /www \
                --non-interactive \
                --agree-tos \
                -m ${EMAIL}
        if [[ $? != 0 ]]
        then
            echo "Can not generate initial certificate. Is your DNS config correct?"
            echo "stop the temporary nginx server"
            docker stop ${temp_nginx_name}
            exit 1
        fi
        echo "stop the temporary nginx server"
        docker stop ${temp_nginx_name}
        if [[ $? != 0 ]]
        then
            echo "can not stop nginx"
            exit 1
        fi
    fi
}

i=0
while [[ ${i} -lt ${ndomain} ]]
do
    domain=domain_list[${i}]
    init_domain "${domain}"
    i=$((${i} + 1))
done

#assume that ssl cert has been created already
#main nginx server
nginx_path="${DIR}/build/nginx.conf"
cron_id_path="${DIR}/build/cron.txt"
stop_container_at_path "${nginx_id_path}"
if [[ ${operator} != "stop" ]]
then
    overwritten_nginx_path="${DIR}/nginx.conf"
    if [[ -f ${overwritten_nginx_path} ]]
    then
        echo "detect manual nginx overwritten. use that configuration"
        cp "${overwritten_nginx_path}" "${ngix_path}"
    else
        echo "generate nginx config from templates"
        i=0
        servers=
        while [[ ${i} -lt ${ndomain} ]]
        do
            domain=domain_list[${i}]
            port=port_list[${i}]
            server=$( sed "s/{{DOMAIN}}/${domain}/g" "${nginx_template_path}" \
                | sed -e "s/{{PORT}}/${port}/g" )
            servers="${servers}\n${server}"
            i=$((${i} + 1))
        done
        nginx_template_path="${DIR}/src/nginx.conf"
        sed "s/{{SERVERS}}/${servers}/g" "${nginx_template_path}" > "${nginx_path}"
    fi
    echo "start main nginx server in background"
    nginx_id=$( docker run -d \
        -v "${letsencrypt_path}":/etc/letsencrypt \
        -v "${www_path}":/www:ro \
        -v "${nginx_path}":/etc/nginx/nginx.conf:ro \
        -v "${dhparams_path}":/etc/ssl/private/dhparams.pem:ro \
        -v "${DIR}/src/conf.d":/etc/nginx/conf.d:ro \
        ${NGINX_DOCKER_FLAG} \
        --rm \
        --net=host \
        nginx:${NGINX_VER} )
    if [[ $? != 0 ]]
    then
        echo "can not start nginx"
        exit 1
    fi
    echo ${nginx_id} > "${nginx_id_path}"
fi

#ssl refresh crontab
stop_container_at_path "${cron_id_path}"
if [[ ${operator} != "stop" ]]
then
    echo "start crontab server in background to periodically refresh ssl cert"
    cron_id=$( docker run \
        -d \
        -v "${letsencrypt_path}":/etc/letsencrypt \
        -v "${www_path}":/www \
        -v "${DIR}/src/certbot-cron":/etc/cron.d/certbot-cron:ro \
        --rm \
        --entrypoint /usr/sbin/crond \
        certbot/certbot:${CERTBOT_VER} \
            -f -d 8 /etc/cron.d/certbot-cron )
    if [[ $? != 0 ]]
    then
        echo "can not start crontab job to refresh ssl periodically"
        exit 1
    fi
    echo ${cron_id} > "${cron_id_path}"
fi
echo "DONE!"
