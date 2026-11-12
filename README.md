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

메뉴바의 목록 아이콘이나 규칙 줄의 슬라이더 아이콘, 또는 `wifi-exit edit [대상]`(`wifi-exit://rules`)로 연다.
- **왼쪽:** 규칙 목록. 끌어서 순서를 바꾼다. 아래쪽은 네트워크 프로필 목록.
- **오른쪽:** 규칙 폼.
  - 대상: 여러 개 넣을 수 있고, 도메인은 지금 풀린 IP를 함께 보여 준다.
  - 출구 순위: 끌어서 바꾸고, 출구마다 지금 있는지 표시한다.
  - 없을 때 동작.
  - 조건: 빌더(모두/하나라도 묶음과 한 단계 하위 묶음) 또는 글로 쓰기.
  - "지금이라면" 미리보기와 가려진 규칙 경고.
- 저장은 CLI와 같은 엔진 명령(`add --new`/`set`/`on`/`off`/`move`)을 부르므로 설정 파일도 CLI로 만든 것과 같다.

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
| `app.swift` | 메뉴바 앱이자 `wifi-exit` CLI (같은 실행 파일) |
| `shared.swift` | 경로, 설정(v2), 상태 모델, 대상 검사 |
| `conditions.swift` | 조건 모델·파서·판단, 출구 결정, 조건 빌더 모델, 가려진 규칙 검사 (엔진과 앱이 함께 씀) |
| `rules_window.swift` | 규칙 편집 창 |
| `exit_reasons.swift` | 출구가 "지금 없음"일 때 까닭 (네트워크 설정의 서비스 + 인터페이스 상태). 앱·CLI 쪽만 쓰므로 엔진 갱신이 필요 없다 |
| `routes_window.swift` | 라우팅 보기 창. 연결이 열리면 앱 → 규칙 → 출구로 길이 그려지고(출발 포트·목적 포트 표시), 패킷이 오갈 때마다 그 길로 캡슐이 움직인다(나감 = 출구 색 캡슐, 들어옴 = 작은 점; 많으면 표본으로 줄이되 한 번이라도 오가면 최소 1개). 닫히면 길이 흐려진다. 최근 10분 타임라인·되감기. 앱·규칙·출구 칸을 두 번 누르거나 "보기" 메뉴로 그것만 집중해서 보기 |
| `outside.swift` | 라우팅 보기의 "전체" 범위: 연결 표를 1초마다 훑어 규칙 밖 연결의 열림·오감(받은/보낸 바이트 증가, 패킷 수는 1200바이트당 1개로 어림)·닫힘을 찾고, 역방향 조회로 이름을 붙임. 규칙 밖 연결은 목적지 등록 도메인(없으면 IP)마다 칸을 따로 두고(최대 8개), 칸을 눌러 "이 목적지로 규칙 만들기" |
| `events.swift` | 연결 사건 흐름: `watch` 중에만 pf 기록을 켜고, pflog 를 해석해 열림·막힘을, `pfctl -vss` 계수기를 0.5초마다 읽어 오감(패킷·바이트 차이)·닫힘을 `/var/run/wifi-exit/events.sock` 으로 보냄. 한 연결의 사건은 열림 → 오감 → 닫힘 순서를 지킨다 (엔진에 들어감) |
| `icon/` | 앱 아이콘을 코드로 그리는 `make_icon.swift`와 `make_icns.sh` |

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

```bash
./build.sh --install     # /Applications/Wi-Fi Exit.app + ~/.local/bin/wifi-exit
./build.sh --notarize --install   # 공증·스테이플까지 한 뒤 설치
icon/make_icns.sh       # 아이콘(icon/make_icon.swift)을 다시 그려 icon/AppIcon.icns 로
wifi-exit install        # engine.swift 가 바뀌었을 때 root 쪽 갱신 (sudo 암호 한 번)
```

서명은 키체인의 첫 "Developer ID Application" 인증서로 한다. 다른 인증서는 `WIFI_EXIT_IDENTITY`, 공증 프로필(`xcrun notarytool store-credentials`로 저장한 이름)은 `WIFI_EXIT_NOTARY_PROFILE`로 정한다.

앱 메뉴의 "엔진 갱신"도 같은 일을 한다. 깔린 엔진의 코드(CDHash)가 앱에 든 엔진과 다르면 앱이 갱신하라고 알려 준다. 서명 시각만 다른 재빌드는 갱신이 필요 없다. 처음 설치할 때 v1 설정(`hosts`, `resolved`, `routes`)은 자동으로 `config.json`과 `state/`로 옮긴다.

## 주의

- CDN처럼 한 IP를 여러 사이트가 같이 쓰면, 그 IP를 쓰는 다른 사이트도 Wi-Fi로 고정되거나 같이 막힌다.
- 도메인은 등록한 이름의 IP만 고정한다. 하위 도메인은 따로 등록해야 한다. 이름 조회 자체는 `/etc/resolver` 덕분에 하위 도메인도 Wi-Fi DNS로 간다.
- pf 앵커는 규칙이 바뀌었거나 시스템이 비웠을 때만 다시 올린다. 다시 올리면 카운터가 0이 되어 `selftest` 판정이 틀어지기 때문이다.
- pf 앵커는 주소마다 한 줄로 쓰고 `pfctl -o none`으로 올린다. 기본 최적화는 같은 줄이 여섯 개쯤 넘으면 `<__automatic_…>` 표로 묶는다. 그러면 규칙 하나에 주소가 여럿 들어가 주소별 카운터가 사라진다. 상태 판독은 표가 생겨도 표 내용을 읽어 맞춘다.
- `wifi-exit diag`는 진단을 위해 앵커를 기본 옵션으로 한 번 다시 올린다. 다음 적용 때 엔진이 원래대로 되돌린다.
- 개발용: `defaults write com.miel.WifiExit routesDebugLog -bool true` 이면 라우팅 보기 창이 받은 사건(칸 이름 포함)을 `~/Library/Caches/wifi-exit-routes.jsonl` 에 남긴다. 끝나면 `defaults delete com.miel.WifiExit routesDebugLog`.

## 라이선스

[MIT](LICENSE)
