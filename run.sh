#!/usr/bin/env bash

MACHINE=`hostname --ip-address`
exec bundle exec rerun --background "ruby connectRT2.rb serve -p 5712 -o 0.0.0.0"
