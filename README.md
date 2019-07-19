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
- Generate initial configuration by run `./run.sh`
- Copy the default configuration from `build/nginx.conf` to project root
- Modify the copied configuration. This file will be used instead of the default
- Re rune `./run.sh` to restart the server

 The default config is based on [server-configs-nginx](https://github.com/h5bp/server-configs-nginx) project.
 The configuration should serve files from `/www` with `http://{{DOMAIN}}/.well-known` request.
