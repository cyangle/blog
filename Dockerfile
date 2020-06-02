# First ARGs only used in instruction FROM
ARG base_build_image="ruby:2.7.1-alpine"
ARG base_app_image="ruby:2.7.1-alpine"
# You can override ARG env vars on docker build or in docker-compose
# Need to redeclare ARG env vars defined before FROM instruction in order to use it
# ARG env vars are only available during building the image
ARG app_user=ruby
ARG app_user_group=ruby
ARG app_user_uid=1000
ARG app_user_gid=1000
ARG app_user_home="/home/$app_user"
ARG app_root="$app_user_home/app"
ARG rails_env=production
ARG node_env=production
ARG bundler_version="2.1.4"
ARG install_yarn=true
ARG app_port="3000"
ARG dev_ports="3000 4000 1234 26162"
# Alpine system packages required to build and run rails server
ARG alpine_build_packages=" \
  build-base curl-dev git \
  postgresql-dev yaml-dev zlib-dev tzdata \
  bash-completion git-bash-completion colordiff gzip sudo bash openssh stow"
ARG alpine_production_packages="tini tzdata postgresql-client curl"
# You can install extra system packages at build time by setting this var
ARG alpine_extra_build_packages=""
ARG alpine_extra_production_packages=""
# Debian system packages required to build and run rails server
ARG debian_build_packages=" \
  build-essential bash-completion sudo stow vim less"
ARG debian_production_packages="tini tzdata postgresql-client"
# You can install extra system packages at build time by setting this var
ARG debian_extra_build_packages=""
ARG debian_extra_production_packages=""

############### builder stage start ###############
FROM $base_build_image AS builder
ARG base_build_image
ARG app_user
ARG app_user_group
ARG app_user_uid
ARG app_user_gid
ARG app_user_home
ARG app_root
ARG rails_env
ARG node_env
ARG bundler_version
ARG install_yarn
ARG alpine_build_packages
ARG alpine_extra_build_packages
ARG debian_build_packages
ARG debian_extra_build_packages
# Default env vars and paths set inside the image
ENV BASE_DOCKER_IMAGE=$base_build_image
ENV APP_ROOT=$app_root
ENV PAGER="less -S"
ENV PATH="$app_user_home/.gem/bin:$PATH"
ENV SHELL="/bin/bash"
ENV RAILS_ENV=$rails_env
ENV NODE_ENV=$node_env
ENV BUNDLE_APP_CONFIG="$APP_ROOT/.bundle"
ENV APP_NODE_PATH="$APP_ROOT/node_modules"
ENV BUNDLE_PATH="$APP_ROOT/vendor/bundle"
# Reset user to root
USER root:root
# Install packages
RUN if $(which apt-get > /dev/null 2>&1) ; then \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    $debian_build_packages $debian_extra_build_packages && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* ; \
  else \
    apk update && \
    apk upgrade && \
    apk add --update --no-cache \
    $alpine_build_packages $alpine_extra_build_packages; \
  fi
# Install yarn and nodejs
RUN if [ "$install_yarn" = "true" ] ; then \
    if $(which apt-get > /dev/null 2>&1) ; then \
      curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
      echo "deb https://dl.yarnpkg.com/debian/ stable main" >> /etc/apt/sources.list.d/yarn.list && \
      curl -sL https://deb.nodesource.com/setup_14.x | bash - && \
      apt-get update -y && \
      apt-get install -y nodejs yarn ; \
    else \
      apk add --update --no-cache nodejs yarn ; \
    fi ; \
  fi
# Install bundler
RUN gem install bundler -v $bundler_version
# Add app user group
RUN if $(grep -i -e ":$app_user_gid:" /etc/group > /dev/null 2>&1) ; then \
    echo "App user gid already exists, not adding it" ; \
  else \
    addgroup --gid $app_user_gid $app_user_group ; \
  fi
# Add app user and setup sudo
RUN if $(id $app_user_uid > /dev/null 2>&1) ; then \
    echo "App user uid already exists, not adding it" ; \
  else \
    if $(which apt-get > /dev/null 2>&1) ; then \
      adduser --gecos "" --disabled-password --uid $app_user_uid --gid $app_user_gid $app_user && \
      usermod -aG sudo $app_user && \
      echo "%sudo ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers ; \
    else \
      app_user_group_name=$(getent group $app_user_gid | cut -d: -f1) && \
      adduser -D -u $app_user_uid -G $app_user_group_name $app_user && \
      addgroup $app_user wheel && \
      echo "%wheel ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers ; \
    fi ; \
  fi
RUN mkdir -p $APP_NODE_PATH && \
  mkdir -p $BUNDLE_PATH && \
  mkdir -p $app_user_home && \
  chown -R $app_user_uid:$app_user_gid $app_user_home && \
  chown -R $app_user_uid:$app_user_gid $APP_ROOT
WORKDIR $APP_ROOT
USER $app_user_uid:$app_user_gid
EXPOSE $dev_ports
CMD echo 'Stage: builder'
############### builder stage done ###############

############### libs stage start ###############
FROM builder AS libs
ARG rails_env
ARG app_user_uid
ARG app_user_gid
ENV RAILS_ENV=$rails_env
# Copy source files first
COPY --chown=$app_user_uid:$app_user_gid Gemfile* package.json yarn.lock ./
# Buld frontend assets
RUN if [ -f yarn.lock ] && $(which yarn > /dev/null 2>&1) ; then \
    yarn install --frozen-lockfile ; \
  fi
RUN if [ $RAILS_ENV = 'production' ] ; then \
    bundle config --local without 'development:test' ; \
  fi
RUN bundle config --local frozen 1 \
  && bundle config --local path 'vendor/bundle' \
  && bundle config --local jobs '4' \
  && bundle install \
  && cd $BUNDLE_PATH/ruby/$RUBY_MAJOR.0 \
  # Install gems and remove unneeded files (cached *.gem, *.o, *.c)
  && rm -rf cache/*.gem \
  && find gems/ -name '*.c' -delete \
  && find gems/ -name '*.o' -delete
############### libs stage done ###############

############### assets stage start ###############
FROM builder AS assets
ARG app_user_uid
ARG app_user_gid
# Secret key base is required to compile the assets
# Here we use a dummy key at build time
ARG SECRET_KEY_BASE=dummy
ENV NODE_ENV=production
ENV RAILS_ENV=production
# Remove folders not needed in resulting image
COPY --chown=$app_user_uid:$app_user_gid . .
COPY --from=libs --chown=$app_user_uid:$app_user_gid $BUNDLE_APP_CONFIG $BUNDLE_APP_CONFIG
COPY --from=libs --chown=$app_user_uid:$app_user_gid $APP_NODE_PATH $APP_NODE_PATH
COPY --from=libs --chown=$app_user_uid:$app_user_gid $BUNDLE_PATH $BUNDLE_PATH
# Run yarn build script if exists in package.json
RUN if $(which yarn > /dev/null 2>&1) && $(yarn run --non-interactive | grep -e "- build" > /dev/null 2>&1) ; then \
    yarn run build ; \
  fi
# Run assets:precompile task if it exists
RUN if $(bundle exec rake -T | grep -e "rake assets:precompile" > /dev/null 2>&1) ; then \
    bundle exec rake assets:precompile ; \
  fi
# Remove unneeded files
RUN rm -rf node_modules tmp/cache vendor/assets spec features
CMD echo 'Stage: assets'
############### libs stage done ###############

############### app stage start ###############
ARG base_app_image
FROM $base_app_image AS app
ARG base_app_image
ARG app_user
ARG app_user_group
ARG app_user_uid
ARG app_user_gid
ARG app_user_home
ARG app_root
ARG app_port
ARG bundler_version
ARG alpine_production_packages
ARG debian_production_packages
ARG alpine_extra_production_packages
ARG debian_extra_production_packages

ENV BASE_APP_IMAGE=$base_app_image
ENV APP_USER=$app_user
ENV APP_USER_GROUP=$app_user_group
ENV APP_USER_HOME=$app_user_home
ENV APP_ROOT=$app_root
ENV APP_PORT=$app_port
ENV PAGER="less -S"
ENV SHELL="/bin/sh"
ENV RAILS_ENV=production
ENV BUNDLE_APP_CONFIG="$APP_ROOT/.bundle"
ENV APP_NODE_PATH="$APP_ROOT/node_modules"
ENV BUNDLE_PATH="$APP_ROOT/vendor/bundle"
ENV RAILS_SERVE_STATIC_FILES=true
# Reset user to root
USER root:root
# install packages
RUN if $(which apt-get > /dev/null 2>&1) ; then \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    $debian_production_packages $debian_extra_production_packages && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* ; \
  else \
    apk update && \
    apk upgrade && \
    apk add --update --no-cache \
    $alpine_production_packages $alpine_extra_production_packages; \
  fi
# Install bundler
RUN gem install bundler -v $bundler_version
# Add app user group
RUN if $(grep -i -e ":$app_user_gid:" /etc/group > /dev/null 2>&1) ; then \
    echo "App user gid already exists, not adding it" ; \
  else \
    addgroup --gid $app_user_gid $app_user_group ; \
  fi
# Add app user and setup sudo
RUN if $(id $app_user_uid > /dev/null 2>&1) ; then \
    echo "App user uid already exists, not adding it" ; \
  else \
    if $(which apt-get > /dev/null 2>&1) ; then \
      adduser --gecos "" --disabled-password --uid $app_user_uid --gid $app_user_gid $app_user ; \
    else \
      app_user_group_name=$(getent group $app_user_gid | cut -d: -f1) && \
      adduser -D -u $app_user_uid -G $app_user_group_name $app_user ; \
    fi ; \
  fi
RUN mkdir -p $APP_NODE_PATH && \
  mkdir -p $BUNDLE_PATH && \
  mkdir -p $app_user_home && \
  chown -R $app_user_uid:$app_user_gid $app_user_home && \
  chown -R $app_user_uid:$app_user_gid $APP_ROOT
COPY --chown=$app_user_uid:$app_user_gid --from=assets $APP_ROOT $APP_ROOT
USER $app_user_uid:$app_user_gid
WORKDIR $APP_ROOT
EXPOSE $app_port
HEALTHCHECK --interval=1m --timeout=3s --start-period=20s --retries=5 \
  CMD curl -f http://localhost:$APP_PORT/ || exit 1
# Simple init for container
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/sh", "-c", "bin/rails_server.sh"]
############### app stage done ###############
