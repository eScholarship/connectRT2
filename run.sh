#!/usr/bin/env bash

exec bundle exec rerun --background --no-notify --restart --signal USR2 "ruby bin/puma -p 5712 --tag connectRT2 -e production"
