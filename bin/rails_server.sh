#!/bin/sh

BIN_DIR=$(dirname $0)
echo $BIN_DIR

cd $BIN_DIR
cd ..

bundle exec rails db:create
bundle exec rails db:migrate

exec bundle exec rails s -p 3000 -b '0.0.0.0'
