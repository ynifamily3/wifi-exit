# 검증

`./tests/run.sh`는 출구 순위·단절 차단·시스템 복귀·서명/제작자 일치·설정 마이그레이션과 캐시 복구를 검사한다.
실제 로컬 IPv4/IPv6 TCP·UDP 소켓을 사용해 1MB TCP 스트림, TCP half-close, 빈/64KB UDP 패킷과 복수 목적지의 원본 데이터를 확인한다.
빌드된 앱이 있으면 `codesign`의 제작자 정보와 앱 선택 코드의 결과도 대조한다.

`python3 tests/package_check.py 'build/Wi-Fi Exit.app'`는 최종 내보낸 앱의 호스트/확장 ID, Mach 서비스와 앱 그룹, 코드 서명, 세 실행 파일의 최소 OS 버전을 확인한다. `build.sh`에서도 실행한다.

## 실제 확장을 통한 연결

서명된 설치본과 macOS의 확장·프록시 승인이 필요하다. 테스트 규칙은 `Split Probe`에만 추가한다.

```sh
./tests/build_probe.sh
wifi-exit apps add "$PWD/build/Split Probe.app" --via wifi --else block
wifi-exit apps enable
wifi-exit apps status
# connected=true와 사용 가능한 출구를 확인한 뒤 실행
'build/Split Probe.app/Contents/MacOS/SplitProbe' tcp
'build/Split Probe.app/Contents/MacOS/SplitProbe' udp
wifi-exit apps status
```

Probe는 1.1.1.1의 TCP 80으로 HTTP 요청, UDP 53으로 example.com DNS 조회를 보낸다.
응답뿐 아니라 확장의 accepted 증가와 마지막 출구 인터페이스를 함께 확인한다. 연결 전 Probe 실행은 시스템 경로로 나갈 수 있어 중계 증거로 사용하지 않는다.

`--via wired`, `--via vpn:missing,wired`, `--via vpn:missing --else block`, `--via vpn:missing --else system`도 같은 방식으로 확인한다.
규칙 편집 전후 provider PID와 connected 상태가 유지돼야 하며, 차단 규칙을 적용한 동안 선택하지 않은 curl의 HTTPS 연결은 정상이어야 한다.
같은 제작자의 `com.miel.WifiExit.SplitProbe.helper`로 서명한 복사본으로 보조 프로세스 포함도 확인할 수 있다.

끝나면 테스트 규칙을 삭제한다. 검증용으로 중계를 켰다면 끈다.

```sh
wifi-exit apps rm com.miel.WifiExit.SplitProbe
wifi-exit apps disable
```
