# 개발 환경 준비

## 기본 환경

- Apple Silicon Mac, macOS 14 이상
- Swift 6 개발 도구: `swift --version`으로 확인
- Node.js와 npm: 웹 채팅과 세션 조회 SDK 준비에 사용
- Python 3, Git, curl
- 앱 번들 빌드: 로컬 Apple Development 서명 인증서
- iPhone·iPad 연결: XcodeGen, 본인 Apple 개발팀, CloudKit 설정

## 화면과 소스부터 확인

```sh
swift build -j 2 --product Knarr
swift run -j 2 knarr-snapshot outputs/preview home-light
```

이 경로는 예시 데이터를 렌더합니다. 모델 호출이나 기존 Knarr 대화 데이터를 사용하지 않습니다. 저장소에는 웹 채팅 번들이 포함되어 있어 Swift 빌드만으로 화면 코드를 확인할 수 있습니다.

## 실제 실행에 필요한 OMP

Knarr는 OMP `18.7.0-knarr.2`를 사용합니다. 원본 OMP 18.7.0에 저장·재개와 문맥 재사용 관련 패치를 적용한 버전입니다. 앱과 설치 스크립트는 검토된 실행 파일의 SHA-256을 확인합니다.

릴리스에 제공되는 `knarr-omp-18.7.0-knarr.2-darwin-arm64.tar.gz`를 별도 폴더에 풀고, 그 안의 `omp` 절대 경로를 다음 명령에 전달합니다. 다운로드 위치는 [GitHub Releases](https://github.com/hks-Khan/Knarr/releases)입니다.

```sh
bash scripts/prepare-development.sh --check
bash scripts/prepare-development.sh /absolute/path/to/runtime/omp
```

이 스크립트는 OMP 체크섬·버전·서명을 확인하고 `.runtime/omp/18.7.0`에 설치합니다. 세션 조회 SDK를 `.runtime/session-api`에 준비하고 웹 채팅을 빌드합니다. 모델 계정 로그인과 앱 실행은 수행하지 않습니다.

소스에서 OMP를 재빌드하는 방법과 체크섬의 의미는 [OMP 연결과 패치](OMP_RUNTIME.md)에 있습니다. 체크섬이 다르면 검증을 생략하지 말고 빌드 결과를 먼저 검토해야 합니다.

## 개발 데이터로 실행

```sh
KNARR_SKIP_JITDECK_IMPORT=1 \
KNARR_DATA_DIRECTORY="$PWD/.runtime/dev-data" \
KNARR_OMP_EXECUTABLE="$PWD/.runtime/omp/18.7.0/omp" \
swift run -j 2 Knarr
```

`KNARR_DATA_DIRECTORY`는 이 개발 실행의 데이터 위치입니다. `KNARR_SKIP_JITDECK_IMPORT=1`은 예전 Jitdeck 프로젝트의 자동 가져오기를 생략합니다. OMP의 모델 계정은 OMP가 관리하며, 저장소에는 계정·키가 포함되지 않습니다. 실제 모델 사용에는 해당 제공자의 이용 조건과 비용이 적용됩니다.

## 서명된 앱 번들

로컬 개발 인증서를 준비한 뒤 다음을 실행합니다.

```sh
bash scripts/build-app.sh
```

결과는 `outputs/Knarr.app`입니다. 인증서 선택을 지정하려면 `KNARR_SIGN_IDENTITY`를 사용합니다. 기본 스크립트는 로컬 개발 서명을 사용하며 공증된 배포용 앱을 만들지는 않습니다.

`scripts/install-app.sh`는 `~/Applications/Knarr.app`을 교체하는 명령입니다. 기존 앱을 사용하는 개발자는 직접 설치 여부를 결정해야 합니다. 기본 소스 확인에는 설치가 필요하지 않습니다.

## iPhone·iPad 연결

Mac 기본 빌드에서는 CloudKit 프로비저닝 파일이 없으면 모바일 연결을 활성화하지 않습니다. 모바일을 빌드하려면 본인의 팀·앱 식별자·CloudKit 컨테이너를 준비해야 합니다.

- `Mobile/project.yml`의 `DEVELOPMENT_TEAM`에 본인 팀을 지정합니다.
- 본인 팀에 맞는 Bundle ID를 `Mobile/project.yml`에 설정합니다.
- CloudKit 컨테이너를 만들고 아래 파일의 컨테이너 식별자를 일치시킵니다.
  - `Mobile/project.yml`, `Mobile/KnarrMobile/KnarrMobile.entitlements`
  - `Mobile/MacProfile/Knarr.entitlements`, `Assets/Knarr.entitlements`
  - `Sources/KnarrSync/MobileRecords.swift`의 `MobileSchema.container`
- `xcodegen generate --spec Mobile/project.yml`로 프로젝트를 생성하고, Xcode에서 서명 설정을 확인합니다.

저장소에 있는 `com.kyen.knarr` 및 `iCloud.com.kyen.knarr`는 원 개발 프로젝트의 식별자입니다. 다른 개발팀에서 모바일 연결을 구성할 때는 자신의 등록 정보로 변경해야 합니다.
