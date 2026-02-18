#!/usr/bin/env bash

exec bundle exec rerun --background --no-notify --restart --signal USR2 "ruby bin/puma -p 5712 -C config/pumakiller.rb -w 2 --tag connectRT2 -e production"
# puma: bundle exec puma -C config/pumakiller.rb -b unix:///var/run/puma/my_app.sock -t1:16 -w 3
