# homeserver-infra

홈서버 공용 인프라. Docker Compose로 **Postgres(pgvector) + Ollama + MinIO(S3 호환 스토리지) + cloudflared +
모니터링(Prometheus/Grafana)** (나중에 Airflow 추가). 서비스 repo들(`vault-rag`, `trading-bot` …)이 이 공용
인프라를 물어서 씀. **cloudflared는 서비스별로 터널을 분리**(`cloudflared-n8n/`, `cloudflared-rag/`,
`cloudflared-grafana/`, `cloudflared-minio/`) — Cloudflare 터널은 CLI에 rename이 없고 대시보드 이름 변경은
비가역 마이그레이션이라, 공유보단 새 서비스마다 새 터널 파는 쪽이 더 쌈(2026-07-20).

> 설계·결정 맥락은 코드가 아니라 vault에: `01_Projects/99_RIMSM/099.home-server/overview.md`,
> `004.vault-rag/overview.md`

## 환경 (stage / prod)

| | stage (맥북) | prod (맥미니) |
|---|---|---|
| 용도 | 개발·튜닝 샌드박스 | 상시 실사용 서비스 |
| Postgres | 이 compose로 로컬 기동 | 이 compose로 상시 기동 |
| Ollama | compose 컨테이너 (CPU) | compose 컨테이너 (CPU) |
| MinIO | 이 compose로 로컬 기동 (버킷 데이터 별개) | 이 compose로 상시 기동 |
| 실사용 질의 | ✗ (개발 때만) | ✓ 항상 여기로 |
| cloudflared-* (n8n/rag/grafana/minio) | ✗ (터널 자격증명 없음) | ✓ (`--profile prod`로만 뜸) |

## 구성

- `docker-compose.infra.yml` — Postgres(pgvector) + Ollama + cloudflared-n8n + cloudflared-rag + cloudflared-grafana(모두 prod 전용, profile로 게이팅) + prometheus + grafana + node-exporter + cadvisor(모니터링, profile 제한 없음)
- `initdb/01-init.sh` — 최초 1회: DB 격리(`vault_rag`/`airflow`) + role(`*_app`) + `CREATE EXTENSION vector` + schema `second_brain`. 비번은 `.env`에서 주입(git에 평문 X)
- `.env.example` — superuser + 앱별 role 비번 + Grafana admin 비번 (`.env`로 복사해 사용, git 제외)
- `cloudflared-n8n/config.yml`, `cloudflared-rag/config.yml`, `cloudflared-grafana/config.yml` — 서비스별 터널의 ingress 규칙. 터널 자격증명(JSON)은 여기 없고 호스트 `~/.cloudflared/`에서 ro 마운트(터널 자격증명 다 같은 폴더에, 각 컨테이너는 자기 config.yml이 가리키는 파일만 씀)
- `prometheus/prometheus.yml` — node-exporter(호스트 CPU/RAM/네트워크) + cadvisor(컨테이너별 리소스) + minio(스토리지 사용량) 스크래핑 설정
- `minio/provision-project.sh` — 프로젝트별 버킷 + 전용 액세스키 + 정책을 한 번에 생성 (아래 "오브젝트 스토리지" 참고)

## 실행

```bash
# 1) 공용 네트워크 (최초 1회)
docker network create home-server-network

# 2) 환경변수
cp .env.example .env      # POSTGRES_PASSWORD 채우기

# 3) 기동
# stage(맥북): postgres만 (cloudflared는 prod 전용, ollama는 native)
docker compose -f docker-compose.infra.yml up -d postgres
# prod(맥미니): 전체 (postgres + ollama + cloudflared-n8n + cloudflared-rag)
docker compose -f docker-compose.infra.yml --profile prod up -d
# 최초 1회: 임베딩 모델 pull
docker exec infra-ollama ollama pull nomic-embed-text

# 4) 확인
docker compose -f docker-compose.infra.yml ps
psql "postgresql://vault_rag_app@localhost:5432/vault_rag" -c '\dx'   # vector 확장 확인
psql "postgresql://vault_rag_app@localhost:5432/vault_rag" -c '\dn'   # second_brain 스키마 확인
```

## 오브젝트 스토리지 (MinIO) — S3 대용

S3 API 호환이라 **기존 S3 코드가 `endpoint_url`만 바꾸면 그대로 붙는다**(boto3로 put/get/list/presigned
URL/멀티파트 업로드까지 검증, 2026-07-28). 프로젝트별로 버킷 + 전용 액세스키를 발급해 서로 못 보게 격리한다.

```bash
# 프로젝트 하나 붙이기 (버킷 + 전용 키 + 정책이 한 번에 생김). 재실행해도 안전.
./minio/provision-project.sh vault-rag
# → bucket=vault-rag, AWS_ACCESS_KEY_ID=vault-rag-app, SECRET은 이때 1회만 출력
```

발급된 키는 **자기 버킷만** 보이고 남의 버킷은 목록에도 안 뜬다(`AccessDenied`). 앱에서는:

```python
s3 = boto3.client("s3",
    endpoint_url="http://minio:9000",        # 같은 docker network 안에서
    # endpoint_url="http://localhost:9000",  # stage 맥북 로컬
    # endpoint_url="https://s3.rimsm.com",   # 외부에서
    aws_access_key_id=..., aws_secret_access_key=...)
```

| 접근 경로 | 주소 |
|---|---|
| S3 API (내부, 같은 네트워크) | `http://minio:9000` |
| S3 API (stage 로컬) | `http://localhost:9000` |
| S3 API (공개) | `https://s3.rimsm.com` |
| 웹 콘솔 (로컬 / 공개) | `http://localhost:9001` / `https://minio.rimsm.com` |

⚠️ **버킷·유저·정책 생성은 반드시 `mc` CLI로.** MinIO 커뮤니티(AGPL) 빌드는 웹 콘솔에서 관리 기능을
걷어냈다 — `/api/v1/{users,policies,service-accounts}`가 403이 아니라 **404**(바이너리에 경로 자체가 없음),
`/api/v1/admin/info`는 501. 콘솔에 남은 건 **로그인 + 버킷/객체 브라우저**뿐이다(RELEASE.2025-09-07 실측).
이건 터널 노출 여부와 무관하며, 내부망에서 접속해도 동일하다.

## 주의

- ⚠️ **macOS Docker는 Metal(GPU) 접근 불가** → 컨테이너 Ollama는 CPU 전용. 임베딩엔 충분(옵션1, stage=prod 일치). 로컬 LLM 생성 시 native Ollama(Metal)로 전환 고려.
- 비밀번호는 `.env`에서 주입되고 **git 추적 파일엔 안 들어감**. `.env`의 `change_me_*`는 운영 전 교체.
- `initdb`는 **데이터 볼륨이 비어있을 때만** 실행됨(최초 1회). 이후 스키마 변경은 마이그레이션으로.
- ⚠️ role 비번에 작은따옴표(`'`) 넣지 말 것 (init SQL 문자열에 그대로 들어감).
- ⚠️ **MinIO S3 API가 `s3.rimsm.com`으로 인터넷에 열려 있다.** 인증은 MinIO 자체 SigV4 서명이라 키
  없이는 아무것도 안 되지만, 액세스키가 유출되면 그 버킷은 밖에서 바로 털린다. `MINIO_ROOT_*`는
  프로비저닝 전용으로만 쓰고 앱엔 절대 넣지 말 것.
- MinIO 메트릭은 `MINIO_PROMETHEUS_AUTH_TYPE=public`이라 인증이 없다. 이게 9000(공개 포트)에 붙어 있어서
  `cloudflared-minio/config.yml`에서 `/minio/v2/metrics` 경로를 404로 막아뒀다. prometheus는 내부
  네트워크로 직접 긁으므로 영향 없음.

## TODO

- [x] ollama 컨테이너 기동 + `nomic-embed-text` pull (임베딩 768차원 확인, 2026-07-18)
- [x] cloudflared를 n8n repo에서 이전 (2026-07-20, 여러 서비스가 공유하는 공용 터널이라 L0 기준)
- [x] cloudflared 터널을 서비스별로 분리 (2026-07-20, 공유 터널의 대시보드 라벨 혼란 + n8n/rag 신뢰 경계 분리)
- [x] 모니터링 스택(prometheus/grafana/node-exporter/cadvisor) compose에 추가 (2026-07-26, 로컬 POC로 감 본 뒤 반영)
- [x] grafana 터널 생성 + DNS 라우팅 (2026-07-26, 맥미니 SSH로 `cloudflared tunnel create grafana` + `route dns` 실행, 기존 인증서 재사용)
- [x] `.env`에 `GRAFANA_ADMIN_USER`/`GRAFANA_ADMIN_PASSWORD` 채우기 + 맥미니 배포·재기동 (2026-07-26, grafana.rimsm.com HTTP 200 확인)
- [x] MinIO 도입 가능성 검증 (2026-07-28, arm64/S3 API/boto3/presigned/멀티파트/키 격리/메트릭 전부 확인)
- [x] MinIO compose 서비스 + `provision-project.sh` 추가 (2026-07-28, stage에서 기동·프로비저닝 검증 완료)
- [x] minio 터널 생성 + DNS 라우팅 (2026-07-28, 맥미니 SSH로 `cloudflared tunnel create minio` + `route dns` 2건, 기존 인증서 재사용)
- [x] 맥미니 `.env`에 `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` + `MINIO_BROWSER_REDIRECT_URL=https://minio.rimsm.com` 설정 (2026-07-28)
- [ ] `minio.rimsm.com`(콘솔) 앞에 Cloudflare Access 추가 검토 — 지금은 MinIO 자체 로그인만. `s3.rimsm.com`(API)은 SigV4라 Access를 걸면 SDK가 깨지므로 대상 아님
- [ ] MinIO 이미지 버전 핀 고정 (`latest` → 특정 RELEASE 태그)
- [x] 맥미니 Docker VM 메모리 여유 확인 (2026-07-28, compose `mem_limit` 합계 ≈5.75GB vs Docker Desktop 할당 12GB → 여유 충분)
- [ ] Grafana에 Prometheus 데이터소스(`http://prometheus:9090`) 추가 + 대시보드 import (Node Exporter Full `1860`, cAdvisor `14282`, MinIO `13502`)
- [ ] grafana.rimsm.com 앞에 Cloudflare Access(n8n처럼 이메일 OTP) 추가 검토 — 지금은 Grafana 자체 로그인만 걸려 있음
- [ ] `.env`에 role 비밀번호 실제 값 채우기 (secret 관리 방식 결정)
- [ ] Airflow 서비스 추가 (`vault_rag`/`airflow` DB 분리는 이미 반영됨)
- [x] GitHub 원격 `homeserver-infra` 생성 후 push (완료 — `origin`이 이미 붙어 있음)
