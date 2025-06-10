#!/usr/bin/env bash

rm -rf bin gems Gemfile.lock
mkdir bin
bundle config path gems --local
bundle install
bundle binstubs --all
