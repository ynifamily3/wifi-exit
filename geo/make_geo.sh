#!/bin/zsh
# make_geo.sh [YYYY-MM]: DB-IP 의 무료 "IP to Country Lite"(CC BY 4.0)를 받아 geo/ipv4-country.bin 을 다시 만든다.
# 앱은 이 파일로 라우팅 보기의 목적지 옆에 서버가 있는 나라(KR, US …)를 붙인다. 달마다 새 판이 나온다.
# 출처 표기: "IP Geolocation by DB-IP" (https://db-ip.com) — 앱의 라우팅 보기 범례에 적는다.
set -euo pipefail
cd ${0:A:h}
month=${1:-$(date +%Y-%m)}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
curl -sSfL -o $tmp/db.csv.gz "https://download.db-ip.com/free/dbip-country-lite-$month.csv.gz"
gzip -dc $tmp/db.csv.gz | swift make_geo.swift ipv4-country.bin
print "만들었어요: ${0:A:h}/ipv4-country.bin ($month)"
