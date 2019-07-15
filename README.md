SSL + nginx configuration via docker

This is production level configuration of nginx server with ssl, which supports auto update SSL cert

# How to
- Create environment file `.env` from template at [.env.example](./.env.example).
- Stop all processes which are listening to ports `80` or `443` except the processes executed in this project.
- Start/Restart nginx and ssl refresh jobs by executing [run.sh](./run.sh)
- Add following crontab entry to refresh the server when
```
#15 UTC ~ 0AM JST
0 15 * * * $HOME/ssl/watch.sh
```

- To stop, run `./run.sh stop`

# Custom nginx config
The nginx configuration is defined in [src/nginx.conf](./src/nginx.conf).
 It is configured base on [server-configs-nginx](https://github.com/h5bp/server-configs-nginx) project.
 The configuration should serve file from `/www` with `http://{{DOMAIN}}/.well-known` request.
 
 If there is `nginx.conf` file exists in the root directory of the project, this file will be used instead of the [src/nginx.conf](./src/nginx.conf).
 You can clone and add your own configuration without touching the git repository because the `nginx.conf` in the root directory is ignored.
