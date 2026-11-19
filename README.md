# Wi-Fi Exit

<img src="icon/AppIcon-1024.png" width="128" alt="Wi-Fi Exit 아이콘">

등록한 호스트(IP, CIDR, 도메인)가 **유선 랜과 VPN 터널을 쓰지 않고 Wi-Fi로만** 나가게 하는 macOS 메뉴바 앱과 CLI.
Wi-Fi가 없으면 그 호스트로는 연결되지 않는다. 유선이나 VPN으로 우회하지 않는다.
규칙마다 출구 순위(Wi-Fi·유선·테더링·VPN)와 조건(AND/OR)을 걸 수 있고, 라우팅 보기 창에서 연결이 어느 출구로 나가는지 실시간으로 볼 수 있다.

## 설치

macOS 15.2 이상, Apple Silicon.

1. [Releases](https://github.com/ynifamily3/wifi-exit/releases)에서 `Wi-Fi-Exit-<버전>.zip`을 받아 풀고 `Wi-Fi Exit.app`을 `/Applications`로 옮긴다 (Apple 공증을 받은 앱이다).
2. 앱을 연다. 메뉴바 아이콘 → "엔진 설치"(또는 터미널에서 `wifi-exit install`)로 root 엔진을 깐다. 관리자 암호를 한 번 묻는다.
3. CLI가 필요하면 링크를 만든다:
   ```bash
   ln -sf "/Applications/Wi-Fi Exit.app/Contents/MacOS/WifiExit" /usr/local/bin/wifi-exit
   ```

지우려면 `wifi-exit uninstall`로 엔진·pf 앵커·고정 라우트를 걷어 낸 뒤 앱을 버린다.

## 규칙 편집 창

메뉴바 팝업 아래 줄의 목록 단추(⌘,)나 규칙 줄을 눌러 나오는 **편집…**, 또는 `wifi-exit edit [대상]`(`wifi-exit://rules`)로 연다.
- **왼쪽:** 규칙 목록. 검색할 수 있고, 끌어서 순서를 바꾸고, 줄 끝의 상자로 켜고 끈다. 아래쪽은 네트워크 프로필 목록.
- **오른쪽:** 규칙 폼.
  - 대상: 여러 개 넣을 수 있고, 도메인은 지금 풀린 IP를 함께 보여 준다.
  - 출구 순위: 끌어서 바꾸고, 출구마다 지금 있는지 표시한다.
  - 없을 때 동작.
  - 조건: 빌더(모두/하나라도 묶음과 한 단계 하위 묶음) 또는 글로 쓰기.
  - "지금이라면" 미리보기와 가려진 규칙 경고.
- 저장은 CLI와 같은 엔진 명령(`add --new`/`set`/`on`/`off`/`move`)을 부르므로 설정 파일도 CLI로 만든 것과 같다.

## 앱별 스플리팅 (0.7)

메뉴바 팝업의 **앱별** 타일(또는 `wifi-exit apps`)로 창을 열고, 도구 막대의 **+**로 앱을 고르고, 출구 순위와 출구가 없을 때 동작을 저장한다.
도구 막대의 전원 단추를 켜면 처음 한 번 macOS가 시스템 확장과 프록시 구성의 허용을 요청한다.
시스템 설정 → 일반 → 로그인 항목 및 확장 → 네트워크 확장에서 Wi-Fi Exit를 허용한다.
본 앱을 `/Applications`에 설치한 뒤 켜야 한다. 기존 엔진이 있다면 먼저 **엔진 갱신**을 실행한다.

- 앱의 코드 서명 식별자와 제작자 팀을 함께 확인한다. 같은 제작자의 `앱ID.*` 보조 프로세스도 포함할 수 있다.
  팀 식별자가 없는 앱은 정확한 서명 ID로만 구분한다. 앱의 서명을 확인할 수 없는 연결은 해당 앱 규칙이 있으면 차단한다.
- **호스트 규칙 → 앱 규칙 → 시스템 경로** 순서다. 활성 호스트 규칙이 맡는 목적지는 기존 엔진이 처리한다.
  앱 규칙은 위에서 먼저 일치하는 규칙을 적용한다. 선택하지 않은 앱은 프록시가 그대로 시스템에 돌려보낸다.
- TCP 스트림과 UDP 데이터그램(QUIC 포함)을 선택한 인터페이스에 고정하여 그대로 중계한다. TLS를 복호화하지 않는다.
  IPv4와 IPv6 모두 같은 인터페이스를 요구한다. 이름 조회는 기존 시스템 DNS를 사용한다.
- 규칙 편집은 실행 중인 프록시에 즉시 전달하고 확장이 자기 설정을 저장한다. 편집 때 프록시를 재시작하지 않으며, 재시작 후에도 최신 규칙을 복원한다.
- 첫 사용 가능한 출구를 선택한다. 연결 중 출구·규칙이 바뀌면 중계 연결을 닫고, 앱이 새로 연결할 때 출구 순위를 다시 적용한다.
  출구가 없을 때 기본값은 차단이며, 원하면 시스템 경로로 넘기도록 정할 수 있다. VPN 별칭은 호스트 엔진의 최신 출구 상태에서 인식한다.
- 켜기·앱 추가 이전부터 열려 있던 연결은 새로 잡을 수 없으므로 해당 앱을 다시 열어야 한다.
  macOS 프록시를 끄거나 확장을 제거하면 앱별 보호도 해제된다. 창 상단의 연결 상태를 확인한다.
- **끄기**는 앱별 중계만 중단한다. 호스트 규칙은 메뉴바의 호스트 켜기/끄기로 따로 제어한다.
  창의 `…` 메뉴에서 프록시 구성과 확장도 제거할 수 있다. 전체 제거 명령은 두 기능을 함께 정리한다.

```sh
wifi-exit apps                         # 편집 창
wifi-exit apps add /Applications/Safari.app --via wifi --else block
wifi-exit apps status                  # 실제 프록시 연결·출구·누적 중계/차단 수 (JSON)
wifi-exit apps enable
wifi-exit apps off com.apple.Safari    # 한 앱 규칙만 끄기
wifi-exit apps rm com.apple.Safari
wifi-exit apps disable                 # 앱별 중계 끄기
wifi-exit apps remove                  # 프록시 구성·확장 제거
```

0.6의 **나머지 트래픽** 기능은 제거했다. 엔진 갱신 시 해당 설정과 이전에 설치한 나머지 라우트·pf 규칙을 회수하고 호스트 규칙을 유지한다.
검증은 `./tests/run.sh`로 정책·설정 마이그레이션과 실제 로컬 TCP/UDP 중계(큰 스트림, half-close, 빈 데이터그램, 복수 목적지)를 실행한다.
시스템 확장 활성화 후에는 `wifi-exit apps status`와 선택한 앱의 실제 새 연결도 함께 확인한다.

## 규칙

규칙은 위에서부터 본다. 한 주소에는 처음 맞는 규칙 하나만 적용한다.

- **출구 순위** (`--via`): `wifi`, `wired`(Ethernet·USB LAN), `tether`(iPhone USB), `vpn:<별칭>`(gpvpn 계열 클라이언트를 쓸 때: `~/.config/gpvpn/config` 의 별칭과 `/var/run/gpvpn/portal` 의 포털 주소로 맞춘다), `vpn:any`(어떤 VPN 터널이든), `none`(그냥 막기). 지금 쓸 수 있는 첫 출구로 보내고, 그 출구가 아닌 인터페이스로는 pf로 막는다.
- **없을 때** (`--else`): `block` 차단(기본) / `system` 규칙을 적용하지 않고 평소 경로 / `next` 다음 규칙에 넘김.
- **조건** (`--when`): 맞을 때만 규칙을 적용하고, 안 맞으면 건너뛴다(다음 규칙이 그 주소를 맡을 수 있다). 글로 쓴다.

  | 키 | 값 | 뜻 |
  |---|---|---|
  | `vpn` | `none` / `any` / `<별칭>` | 지금 붙은 VPN |
  | `link` | `wifi` / `wired` / `tether` | 그 링크가 살아 있음 |
  | `profile` | `<이름>` | 지금 망이 저장한 프로필(게이트웨이 IP + MAC)과 같음. `wifi-exit profile add <이름> [wifi\|wired]` 또는 메뉴의 "지금 망을 프로필로 저장" |
  | `default` | `wifi` / `wired` / `tether` / `vpn` | 기본 경로가 그쪽 |
  | `vpnover` | `wifi` / `wired` / `tether` | VPN 터널이 그 링크 위에 있음 |
  | `time` | `09:00-18:00` | 그 시간대 (자정을 넘겨도 됨) |
  | `day` | `mon-fri`, `sat,sun` | 요일 |

  `=`, `!=`, `and`(`&&`), `or`(`||`), `not`(`!`), 괄호. 예: `--when 'vpn=pass and (link=wired or profile=사무실)'`. `always`로 되돌린다.
- **도메인 조회**는 고른 출구의 DNS로 한다. 그 DNS 서버가 출구의 서브넷 밖이면 서버로 가는 길도 그 출구에 고정한다. 차단 중인 도메인은 조회도 막는다.
- **상태 점검:** 10초마다 출구마다 그 인터페이스에 묶어 TCP로 접속해 본다. 대상은 출구의 DNS 서버 53번, VPN이 아니면 1.1.1.1:443이다. 연달아 2번 실패하면 "응답 없음"으로 보고 다음 순위로 넘기고, 2번 성공하면 다시 쓴다. 규칙마다 `--check host:port`를 주면, 그 출구로 거기에 닿을 때만 그 출구를 쓴다. 점검 대상은 규칙 자신의 대상과 달라야 한다. 보호하는 주소를 피하려는 출구로 보내 볼 수는 없기 때문이다.
- **터널 붕괴 방지:** VPN 클라이언트가 물리 인터페이스에 고정해 둔 주소(VPN 게이트웨이)는 VPN 출구에서 자동으로 뺀다.

## 구성

| 파일 | 역할 |
|---|---|
| `engine.swift` | root 엔진 `wifi-exitd`. `/Library/PrivilegedHelperTools/com.miel.WifiExit.engine`에 root 소유로 깔린다. LaunchDaemon `ing.miel.wifi-exit`가 상주시킨다 |
| `app.swift` | 메뉴바 앱이자 `wifi-exit` CLI (같은 실행 파일). 창(규칙·앱별 스플리팅·라우팅 보기)은 SwiftUI 장면 |
| `popup.swift` | 메뉴바 아이콘과 팝업(NSPopover). Little Snitch Control Center 를 참고한 짜임: 맨 위 타일(전체 켜기·지금 망·앱별), 출구마다 그리로 나가는 규칙을 묶은 카드, 막는 중·쉬는 규칙 카드, 아래 줄의 창 단추 |
| `shared.swift` | 경로, 설정(v2), 상태 모델, 대상 검사 |
| `conditions.swift` | 조건 모델·파서·판단, 출구 결정, 조건 빌더 모델, 가려진 규칙 검사 (엔진과 앱이 함께 씀) |
| `rules_window.swift` | 규칙 편집 창 |
| `ui_kit.swift` | 세 화면이 같이 쓰는 모양: 상태 색(흑연 팔레트: 정상·켜짐은 무채색, 주의는 호박색, 막힘·오류는 산호색. 그라데이션으로 칠하지 않는다), 출구 기호(무채색 동그라미), 규칙 요약 문구, 경고 목록 |
| `exit_reasons.swift` | 출구가 "지금 없음"일 때 까닭 (네트워크 설정의 서비스 + 인터페이스 상태). 앱·CLI 쪽만 쓰므로 엔진 갱신이 필요 없다 |
| `routes_window.swift` | 라우팅 보기 창 (Little Snitch Network Monitor 를 참고한 짜임). 왼쪽: 연결 목록(앱 ▸ 목적지 · 출구 → 앱 · 규칙 → 앱으로 묶기, 검색, 줄마다 최근 12초 보냄·받음 막대)과 최근 10분 트래픽 막대(끌어서 되감기). 가운데: 앱 → 출구 → 목적지 흐름도. 목적지는 규칙마다 희미한 점선 묶음 안의 대상 줄(묶음 위 테두리에 규칙 이름과 지금 보내는 출구), 규칙 밖 연결은 "규칙 없음" 묶음 안의 목적지 줄이고, 줄 끝에 서버가 있는 나라를 붙인다. 선 색은 나간 출구, 굵기는 최근 6초 오간 양, 진하기는 열린 연결. 데이터가 오가면 경로를 따라 빛줄기가 흐르고 도착점에서 원이 퍼진다. 칸은 붙박이 자리에 머문다: 새 앱은 이어진 출구 높이 근처 빈자리에 들어가고, 빈자리·순서는 마우스를 올리지 않은 조용한 때(8초에 한 번까지) 한꺼번에 정리한다. 선·칸에 마우스를 올리면 그 경로만 강조하고, 두 번 누르거나 목록에서 고르면 그것만 본다(Esc·빈 곳 클릭으로 전체). 아래쪽에 떠 있는 범례와 배율(− + , ⌘−/⌘+/⌘0, 핀치). 오른쪽: 고른 것의 규칙·출구·이유·오간 양을 보여 주는 인스펙터 |
| `outside.swift` | 라우팅 보기의 "전체" 범위: 연결 표(netstat. macOS 27 처럼 앱이 띄운 netstat 에 표가 비어 보이면 nettop)를 1초마다 훑어 규칙 밖 연결의 열림·오감(받은/보낸 바이트 증가, 패킷 수는 1200바이트당 1개로 어림)·닫힘을 찾고, 역방향 조회로 이름을 붙임. 규칙 밖 연결은 목적지 등록 도메인(없으면 IP)마다 줄을 따로 두고(최대 8개, 넘치면 "그 밖의 목적지" 한 줄, 90초 조용하면 뺀다) |
| `routes_quick.swift` | 라우팅 보기에서 바로 규칙 만들기: 규칙 밖 목적지 줄을 누르면 그 목적지로 간 IP(원하면 /24 대역)·출구 순위·출구가 없을 때·이름을 그 자리에서 골라 추가하고("자세히…"는 규칙 창으로), 앱 칸을 누르면 그 앱이 간 곳을 골라 규칙으로 만들거나 앱별 스플리팅에 넣는다. IP → 나라(`GeoIP`) |
| `events.swift` | 연결 사건 흐름: `watch` 중에만 pf 기록을 켜고, pflog 를 해석해 열림·막힘을, `pfctl -vss` 계수기를 0.5초마다 읽어 오감(패킷·바이트 차이)·닫힘을 `/var/run/wifi-exit/events.sock` 으로 보냄. 한 연결의 사건은 열림 → 오감 → 닫힘 순서를 지킨다 (엔진에 들어감) |
| `names.swift` | 연결 이름 알아내기: `watch` 중에만 주소가 있는 인터페이스마다 `tcpdump` 를 하나씩 띄워(pktap 은 거르개를 걸 수 없어 쓰지 않는다) DNS 응답(질문 이름 ↔ A·AAAA)과 443 으로 가는 TLS ClientHello 의 SNI 를 읽어 IP → 이름 표를 메모리에 두고(30분, 4096개) 사건 소켓으로 보낸다. 라우팅 보기는 이 이름을 역방향 조회보다 먼저 쓴다. 암호화된 DNS·ECH 면 보이지 않는다 (엔진에 들어감) |
| `app_rules.swift`, `app_policy.swift`, `apprules/` | 앱별 스플리팅 편집·제어·서명 식별·출구 결정과 TCP/UDP 투명 프록시 시스템 확장. 본 앱에 함께 포함한다 |
| `icon/` | 앱 아이콘을 코드로 그리는 `make_icon.swift`와 `make_icns.sh` |
| `geo/` | 나라 표시용 `ipv4-country.bin`과 그것을 만드는 `make_geo.sh`·`make_geo.swift`. 원본은 DB-IP 의 무료 "IP to Country Lite"(CC BY 4.0, IP Geolocation by [DB-IP](https://db-ip.com)). 달마다 `geo/make_geo.sh`로 새로 만들 수 있다 |
| `dev.sh`, `dev_sample.swift`, `dev/sample/` | 개발 실행 (아래 "개발 실행"). `dev_sample.swift` 는 DEBUG 빌드에만 들어가는 표본 상태·가짜 연결 |

데이터는 `/Library/Application Support/WifiExit/`에 둔다.
- `config.json`: 규칙. root만 쓴다. 바뀌면 데몬이 곧바로 적용한다.
- `state/status.json`: 규칙별로 고른 출구와 이유, 주소별 경로와 차단 여부. 누구나 읽을 수 있고, 앱과 CLI는 sudo 없이 이것만 읽는다.
- `state/resolved.json`, `state/routes.json`, `state/log`.

## 동작

| 장치 | 하는 일 |
|---|---|
| 고정 라우트 | 대상 IP를 고른 출구의 게이트웨이로 보낸다 (VPN은 인터페이스로). 게이트웨이는 SystemConfiguration에서 그때그때 읽는다 |
| pf 차단 | 앵커 `com.apple/wifi-exit`에서 고른 출구가 아닌 인터페이스로 나가는 패킷을 거절한다. 출구가 없고 `block`이면 모든 곳에서 거절한다 |
| 도메인 해석 | 고른 출구의 DNS로 5분마다 다시 푼다. 새 IP는 바로 넣고, 답에서 빠진 IP는 1시간 더 둔다 (IPv6는 차단만 한다) |
| `/etc/resolver/<도메인>` | 앱들이 하는 조회도 같은 DNS로 보낸다. 출구가 없으면 조회를 막는다 |

데몬은 네트워크가 바뀌는 순간(SCDynamicStore: 링크·주소·라우터·DNS)과 `config.json`이 바뀌는 순간 적용한다. 놓친 변화는 30초마다 한 번 더 맞춘다. Wi-Fi를 끄면 1초 안에, 다시 켜면 3초 안에 맞춰지는 것을 확인했다.

## CLI

```
wifi-exit status [--json]      # 새는 대상이 있거나 엔진이 2분 넘게 멈춰 있으면 종료 코드 1
wifi-exit exits                # 지금 쓸 수 있는 출구, 없는 출구는 까닭(어댑터 안 보임·케이블 없음·주소 없음 …)
wifi-exit add <IP|IP/nn|도메인> [--via wired,wifi] [--else block|system|next] [메모]
wifi-exit set <대상|id> [--via …] [--else …] [--name 메모]
wifi-exit move <대상|id> up|down|top|bottom|<위치>
wifi-exit profile [add <이름> [wifi|wired|tether] | rm <이름>]
wifi-exit edit [대상|id]       # 규칙 편집 창
wifi-exit explain <대상|IP>     # 어떤 규칙이 왜 걸렸는지, 조건을 사실마다 따져 보여 준다
wifi-exit simulate [--wifi on|off] [--wired on|off] [--vpn none|any|<별칭>] [--profile <이름>|none] [--time HH:MM] [--day mon]
wifi-exit diag                 # pf 실제 상태 (규칙이 안 걸릴 때)
wifi-exit watch [--json]       # 규칙 대상으로 가는 새 연결을 실시간으로 (보는 동안만 pf 기록)
wifi-exit view                 # 라우팅 보기 창 (창이 열려 있는 동안만 pf 기록)
wifi-exit health [check]       # 출구·규칙 점검 결과
wifi-exit health fail <출구|인터페이스> [초] | health clear   # 시험: 출구를 잠시 응답 없음으로
wifi-exit rm|on|off <대상|규칙 id>
wifi-exit pause | resume
wifi-exit resolve | apply | log [n]
wifi-exit selftest [--port N] [--verbose]
wifi-exit install | uninstall
wifi-exit login [on|off]
```

`selftest`는 규칙마다 기본 경로와 각 인터페이스(en0, en6, utun…)에 묶어 TCP로 직접 접속해 본다. 그때 pf 규칙의 패킷 카운터가 오르는지로 "규칙이 막았는지"를 판정한다. Wi-Fi로는 나가고, 다른 출구는 막히거나 아예 못 나가야 통과다.

## 빌드·설치

Xcode, XcodeGen(`brew install xcodegen`), 개발자 계정과 Network Extension 권한이 있는 Developer ID 프로필이 필요하다. 본 앱과 확장을 함께 아카이브·서명한다.

```bash
./build.sh --install     # /Applications/Wi-Fi Exit.app + ~/.local/bin/wifi-exit
./build.sh --notarize --install   # 공증·스테이플까지 한 뒤 설치
icon/make_icns.sh       # 아이콘(icon/make_icon.swift)을 다시 그려 icon/AppIcon.icns 로
wifi-exit install        # engine.swift 가 바뀌었을 때 root 쪽 갱신 (sudo 암호 한 번)
```

서명은 키체인의 첫 "Developer ID Application" 인증서로 한다. 다른 인증서는 `WIFI_EXIT_IDENTITY`, 공증 프로필(`xcrun notarytool store-credentials`로 저장한 이름)은 `WIFI_EXIT_NOTARY_PROFILE`로 정한다.

앱 메뉴의 "엔진 갱신"도 같은 일을 한다. 깔린 엔진의 코드(CDHash)가 앱에 든 엔진과 다르면 앱이 갱신하라고 알려 준다. 서명 시각만 다른 재빌드는 갱신이 필요 없다. 처음 설치할 때 v1 설정(`hosts`, `resolved`, `routes`)은 자동으로 `config.json`과 `state/`로 옮긴다.

## 개발 실행

Xcode·Developer ID 없이 swiftc 만으로 앱을 빌드해 `/Applications/Wi-Fi Exit Dev.app` 으로 띄운다 (Command Line Tools 만 있으면 된다).

```bash
./dev.sh               # 깔린 엔진의 실제 상태로
./dev.sh --sample      # 엔진 없이 dev/sample 의 표본 규칙·출구와 가짜 연결로 (팝업·규칙 창·라우팅 보기)
./dev.sh --dark        # 어두운 모양으로 (--light: 밝은 모양). --sample 과 함께 써도 된다
./dev.sh --remove      # Dev 앱 지우기
```

- Dev 앱은 번들 ID 가 `com.miel.WifiExit.dev` 라 설치본과 설정·로그인 항목이 섞이지 않고, 로그인 항목으로 등록하지 않는다. 설치본이 실행 중이면 시작하지 않고, 이전 Dev 앱은 끄고 다시 띄운다.
- `/Applications` 에 두는 까닭: macOS 27 의 메뉴바 정리 앱(Hidden Bar 1.11 등)은 `/Applications` 에서 실행한 앱만 번들 ID 로 알아본다. 처음 한 번은 아이콘을 ⌘-드래그로 화살표 오른쪽에 옮긴다.
- 표본 상태에서 규칙 켜기·끄기와 일시정지는 메모리의 표본만 바꾸고, 그 밖의 편집은 하지 않는다.
- 스크립트는 엔진을 설치하지 않는다. Dev 앱에 든 엔진(ad-hoc 서명)으로 설치·갱신하려면 터미널에서 `"/Applications/Wi-Fi Exit Dev.app/Contents/MacOS/WifiExit" install` (관리자 암호), 지우려면 같은 경로로 `uninstall`.
- ad-hoc 서명이라 Network Extension 권한이 없어, 앱별 스플리팅 창은 열리지만 켤 수는 없다.

## 주의

- CDN처럼 한 IP를 여러 사이트가 같이 쓰면, 그 IP를 쓰는 다른 사이트도 Wi-Fi로 고정되거나 같이 막힌다.
- 도메인은 등록한 이름의 IP만 고정한다. 하위 도메인은 따로 등록해야 한다. 이름 조회 자체는 `/etc/resolver` 덕분에 하위 도메인도 Wi-Fi DNS로 간다.
- pf 앵커는 규칙이 바뀌었거나 시스템이 비웠을 때만 다시 올린다. 다시 올리면 카운터가 0이 되어 `selftest` 판정이 틀어지기 때문이다.
- pf 앵커는 주소마다 한 줄로 쓰고 `pfctl -o none`으로 올린다. 기본 최적화는 같은 줄이 여섯 개쯤 넘으면 `<__automatic_…>` 표로 묶는다. 그러면 규칙 하나에 주소가 여럿 들어가 주소별 카운터가 사라진다. 상태 판독은 표가 생겨도 표 내용을 읽어 맞춘다.
- `wifi-exit diag`는 진단을 위해 앵커를 기본 옵션으로 한 번 다시 올린다. 다음 적용 때 엔진이 원래대로 되돌린다.
- 개발용: `open wifi-exit://popup-preview` 는 메뉴바 팝업 내용을 보통 창으로 띄운다 (메뉴바 정리 앱이 아이콘을 숨겨도 화면을 확인할 수 있게).
- 라우팅 보기는 시스템 테마를 따르고, 도구 막대의 "늘 어둡게"로 어두운 화면에 고정할 수 있다 (`routesAlwaysDark`).
- 개발용: `defaults write com.miel.WifiExit routesDebugLog -bool true` 이면 라우팅 보기 창이 받은 사건(칸 이름 포함)을 `~/Library/Caches/wifi-exit-routes.jsonl` 에 남긴다. 끝나면 `defaults delete com.miel.WifiExit routesDebugLog`.

## 라이선스

[MIT](LICENSE)
