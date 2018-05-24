#!/bin/bash

# Copyright 2014 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

KUBE_TOKEN=$(</var/run/secrets/kubernetes.io/serviceaccount/token)

function launchmaster() {
  if [[ ! -e /redis-master-data ]]; then
    echo "LaunchMaster => Redis master data doesn't exist, data won't be persistent!"
    mkdir /redis-master-data
  fi
  redis-server /redis-master/redis.conf --protected-mode no
}

function launchsentinel() {
  while true; do
    echo "LaunchSentinel => Checking if any current master exists"

    master=$(redis-cli -h ${REDIS_SENTINEL_SERVICE_HOST} -p ${REDIS_SENTINEL_SERVICE_PORT} --csv SENTINEL get-master-addr-by-name mymaster | tr ',' ' ' | cut -d' ' -f1)
    
    echo "LaunchSentinel => Current master is: $master"
    if [[ -n ${master} ]]; then
      master="${master//\"}"
    else
      master=$(curl -sSk -H "Authorization: Bearer $KUBE_TOKEN" https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_PORT_443_TCP_PORT/api/v1/namespaces/default/pods/redis-0 | jq '.status.podIP' --raw-output)
    fi
    if [[ "$?" == "0" ]]; then
      redis-cli -h ${master} INFO
      if [[ "$?" == "0" ]]; then
        echo "LaunchSentinel => Connected to master ${master}"
        break
      fi
    fi
    echo "LaunchSentinel => Connecting to master failed.  Waiting..."
    sleep 10
  done

  sentinel_conf=sentinel.conf

  echo "sentinel monitor mymaster ${master} 6379 2" > ${sentinel_conf}
  echo "sentinel down-after-milliseconds mymaster 2000" >> ${sentinel_conf}
  echo "sentinel failover-timeout mymaster 2000" >> ${sentinel_conf}
  echo "sentinel parallel-syncs mymaster 1" >> ${sentinel_conf}
  echo "bind 0.0.0.0" >> ${sentinel_conf}

  redis-sentinel ${sentinel_conf} --protected-mode no
}

function launchslave() {
  while true; do
    master=$(redis-cli -h ${REDIS_SENTINEL_SERVICE_HOST} -p ${REDIS_SENTINEL_SERVICE_PORT} --csv SENTINEL get-master-addr-by-name mymaster | tr ',' ' ' | cut -d' ' -f1)
    my_ip=$(curl -sSk -H "Authorization: Bearer $KUBE_TOKEN" https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_PORT_443_TCP_PORT/api/v1/namespaces/default/pods/redis-0 | jq '.status.podIP' --raw-output)
  
    if [[ "$master" == "$my_ip" ]]; then
      echo "LaunchSlave => Wait for other node to become master."
      sleep 10
      continue
    fi

    if [[ -n ${master} ]]; then
      master="${master//\"}"
    else
      echo "LaunchSlave => Failed to find master."
      sleep 60
      exit 1
    fi 
    redis-cli -h ${master} INFO
    if [[ "$?" == "0" ]]; then
      break
    fi
    echo "LaunchSlave => Connecting to master failed.  Waiting..."
    sleep 10
  done
  sed -i "s/%master-ip%/${master}/" /redis-slave/redis.conf
  sed -i "s/%master-port%/6379/" /redis-slave/redis.conf
  redis-server /redis-slave/redis.conf --protected-mode no
}


if [[ $(hostname) == "redis-0"  ]]; then
  my_ip=$(curl -sSk -H "Authorization: Bearer $KUBE_TOKEN" https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_PORT_443_TCP_PORT/api/v1/namespaces/default/pods/redis-0 | jq '.status.podIP' --raw-output)
  curr_master=$(redis-cli -h ${REDIS_SENTINEL_SERVICE_HOST} -p ${REDIS_SENTINEL_SERVICE_PORT} --csv SENTINEL get-master-addr-by-name mymaster)
  
  if [[ "$?" == "0" ]]; then
    curr_master2=$(echo $curr_master | tr ',' ' ' | cut -d' ' -f1)
    if [[ "$curr_master2" == "$my_ip" ]]; then
      echo "redis-0 => Current node was previous master - start in slave mode so data is not lost"
      launchslave
    else
      echo "redis-0 => Master already exists, start as slave"
      launchslave
    fi
  else
    echo "redis-0 => Failed to connect to sentinel to check for master - assume no other master exits => Launching new master"
    launchmaster
  fi

  exit 0
fi

if [[ "${SENTINEL}" == "true" ]]; then
  launchsentinel
  exit 0
fi

launchslave
