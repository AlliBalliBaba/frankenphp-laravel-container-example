# Laravel Octane with FrankenPHP Docker example

This repo is a light-weight example on how to run a production-grade Docker image with Laravel/FrankenPHP on Octane.
For ease of use it contains a queue and scheduler. 
tini is used for process reaping and as supervisor.

This repo is purely out there to give more examples on how to run Laravel in container environments.
The final image ends up being roughly 250MB uncompressed with debian-slim and even smaller with a distroless base.

## Using the Docker image

This Docker image is meant a base image, it does not build your app. The image is based on Debian, so it contains
a shell and curl for debugging. To have an even more minimal image without shell, look at the `distroless.Dockerfile`.

```sh
# building the base image (quick example)
git clone https://github.com/AlliBalliBaba/frankenphp-laravel-container-example.git
cd frankenphp-laravel-container-example
docker build -t franken-laravel-base .
```

To run locally on http://localhost:8123 (quick example)

```sh
cd /path/to/your/laravel/app
docker run --rm -p 8123:80 -v .:/app franken-laravel-base
```

Or look into `more-examples/docker-compose.yml` for an example with Postgres.

## Production build example

```Dockerfile
# for production, you just need to copy the app into the image, also consider encrypting your .env file
FROM franken-laravel-base
ENV ARTISAN_CACHE=true
ENV MAX_THREADS=30

# copy the app (assuming you are in the laravel directory)
# for further hardening, make the relevant files read-only
COPY --chown=www-data:www-data . /app

# here you can now run composer install or npm run build etc (FROM node:lts)
```

## Adding more php extensions

```sh
docker build --build-arg PHP_EXTENSIONS="pdo_mysql opcache apcu @composer" -t franken-laravel-base .
```

## Queue

To use a queue, set these env vars: 

WITH_QUEUE=true
QUEUE_WORKER_NUMBER=3

## Scheduler

To use the schedules (supercronic), set this env var

```sh
WITH_QUEUE=true
```

This will run `php artisan schedule:run` every minute.

If you need proper logging to stdout of all scheduled commands, I'd also recommend setting `LARAVEL_CLOUD=1`

## Artisan optimize

To make the container run `php artisan:optimize` at startup, set

```sh
ARTISAN_CACHE=true
```

## Env encryption

If there is an encrypted environment file at /app/env.encrypted, it will automatically
be decrypted at startup with the according env var

```sh
LARAVEL_ENV_ENCRYPTION_KEY=xxxxxxxxxxxx
```

You just need to run `php artisan env:encrypt` with the same key in the build phase

## Caddyfile

The default Caddyfile will be used at /app/etc/Caddyfile. You can also use a different Caddyfile via

```sh
CADDYFILE=/path/to/Caddyfile
```

There are some examples in the examples folder

## Entrypoint scripts

At startup the container will also check for a file called
`/app/entrypoint.sh` and execute it if present before starting the app

## Additional supervised commands

tini supervises the server, schedule and queue, but you can pass additional command to supervise 
via EXTRA_COMMANDS, for example:

```sh
 EXTRA_COMMANDS:"php artisan horizon ; php artisan reverb:start --host=0.0.0.0 --port=8080"
```

## Hardening

The image is based on debian-slim and still has a shell and curl for debugging. For further hardening,
you can also swap it out with something like `gcr.io/distroless/base-debian13`.

The image already runs as the non-priviledged `www-data` user, 
for further hardening you can make everything read-only and just keep
these directories writable: 
`/data/caddy` `/config/caddy` `/app/storage` `/app/bootstrap/cache` `/tmp`