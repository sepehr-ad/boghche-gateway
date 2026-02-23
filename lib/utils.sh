#!/bin/bash

log() {
  echo "$(date '+%F %T') - $1" >> /var/log/boghche/boghche.log
}

validate_ip() {
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}
