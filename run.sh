#!/usr/bin/env bash

cur_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
env_path=${cur_dir}/.env
if [[ ! -f ${env_path} ]]
then
	echo '.env does not exist. check .env.example for sample configuration'
	exit 1
fi
source ${env_path}
to_stop=$1

# gen params.pem
params_path=${cur_dir}/build/dhparams.pem
if [[ -f ${params_path} ]]
then
    openssl dhparam -out ${params_path} 2048
fi

# init certbot
nginx_id_path=${cur_dir}/build/nginx.txt
www_nginx_path=${cur_dir}/build/www-nginx.conf
www_path=${cur_dir}/build/www
letsencrypt_path=${cur_dir}/build/letsencrypt

stop_container_at_path () {
    local id_path=$1
    echo "try stop container with id stored in ${id_path}"
    if [[ -f ${id_path} ]]
    then
        local container_id=$( cat ${nginx_id_path} )
        docker stop ${container_id}
        if [[ $? != 0 ]]
        then
            echo "Can not stop currently running container id ${container_id} at path ${id_path}"
            exit 1
        else
            echo "container ${container_id} has been stopped"
            rm ${id_path}
        fi
    else
        echo "${id_path} not found. skip stopping"
    fi
}
if [[ ! -f ${www_path} ]]
then
    echo "make dir ${www_path}"
    mkdir -p ${www_path}
fi
if [[ ! -f ${letsencrypt_path} ]]
then
    echo "make dir ${letsencrypt_path}"
    mkdir -p ${letsencrypt_path}
fi
cert_path=${cur_dir}/build/letsencrypt/live/${DOMAIN}/fullchain.pem
if [[ ! -f ${cert_path} ]]
then
    echo "cert not found. run initial setup"
    #stop nginx if running
    stop_container_at_path ${nginx_id_path}
    #generate temporary nginx conf for initial ssl setup
    sed "s/{{DOMAIN}}/${DOMAIN}/g" ${cur_dir}/src/www-nginx.conf > ${www_nginx_path}
    echo "run temporary nginx server in background"
    temp_nginx_name=$( docker run -d \
        -v ${www_path}:/www:ro \
        -v ${www_nginx_path}:/etc/nginx/nginx.conf:ro \
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
        -v ${letsencrypt_path}:/etc/letsencrypt \
        -v ${www_path}:/www \
        --rm \
        certbot/certbot:${CERTBOT_VER} \
        certonly \
            -d ${DOMAIN} \
            --rm \
            --webroot \
            --webroot-path /www \
            --non-interactive \
            --agree-tos \
            -m ${EMAIL}
    echo "stop the temporary nginx server"
    docker stop ${temp_nginx_name}
    if [[ $? != 0 ]]
    then
        echo "can not stop nginx"
        exit 1
    fi
fi

#assume that ssl cert has been created already
#main nginx server
nginx_path=${cur_dir}/build/nginx.conf
cron_id_path=${cur_dir}/build/cron.txt
stop_container_at_path ${nginx_id_path}
if [[ ${to_stop} != "stop" ]]
then
    overwritten_nginx_path=${cur_dir}/nginx.conf
    if [[ -f ${overwritten_nginx_path} ]]
    then
        nginx_template_path=${overwritten_nginx_path}
    else
        nginx_template_path=${cur_dir}/src/nginx.conf
    fi
    sed "s/{{DOMAIN}}/${DOMAIN}/g" ${nginx_template_path} \
        | sed -e "s/{{PORT}}/${PORT}/g" \
        > ${nginx_path}
    echo "start main nginx server in background"
    nginx_name=$( docker run -d \
        -v ${letsencrypt_path}:/etc/letsencrypt \
        -v ${www_path}:/www:ro \
        -v ${nginx_path}:/etc/nginx/nginx.conf:ro \
        -v ${params_path}:/etc/ssl/private/dhparams.pem:ro \
        -v ${cur_dir}/src/conf.d:/etc/nginx/conf.d:ro \
        ${NGINX_DOCKER_FLAG} \
        --rm \
        --net=host \
        nginx:${NGINX_VER} )
    if [[ $? != 0 ]]
    then
        echo "can not start nginx"
        exit 1
    fi
    echo ${nginx_name} > ${nginx_id_path}
fi

#ssl refresh crontab
stop_container_at_path ${cron_id_path}
if [[ ${to_stop} != "stop" ]]
then
    echo "start crontab server in background to periodically refresh ssl cert"
    cron_id=$( docker run \
        -d \
        -v ${letsencrypt_path}:/etc/letsencrypt \
        -v ${www_path}:/www \
        -v ${cur_dir}/src/certbot-cron:/etc/cron.d/certbot-cron:ro \
        --rm \
        --entrypoint /usr/sbin/crond \
        certbot/certbot:${CERTBOT_VER} \
            -f -d 8 /etc/cron.d/certbot-cron )
    if [[ $? != 0 ]]
    then
        echo "can not start crontab job to refresh ssl periodically"
        exit 1
    fi
    echo ${cron_id} > ${cron_id_path}
fi
echo "DONE!"
