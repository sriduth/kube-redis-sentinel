#!/bin/bash

random_text=$(openssl rand -base64 1024)

for i in `seq 1 10000`; do
    redis-cli -h 192.168.99.100 -p 30857 SET "key$i" "value$i$random_text"
done

for i in `seq 500 9000`; do
    redis-cli -h 192.168.99.100 -p 30857 del "key$1"
    redis-cli -h 192.168.99.100 -p 30857 set "key2$1" "value2$i$random_text"
done
