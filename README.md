# homeserver-infra

홈서버 공용 인프라. Docker Compose로 **Postgres(pgvector) + Ollama + cloudflared + 모니터링(Prometheus/Grafana)**
(나중에 Airflow 추가). 서비스 repo들(`vault-rag`, `trading-bot` …)이 이 공용 인프라를 물어서 씀. **cloudflared는
서비스별로 터널을 분리**(`cloudflared-n8n/`, `cloudflared-rag/`, `cloudflared-grafana/`) — Cloudflare 터널은
CLI에 rename이 없고 대시보드 이름 변경은 비가역 마이그레이션이라, 공유보단 새 서비스마다 새 터널 파는 쪽이 더
쌈(2026-07-20).

> 설계·결정 맥락은 코드가 아니라 vault에: `01_Projects/99_RIMSM/099.home-server/overview.md`,
> `004.vault-rag/overview.md`

## 환경 (stage / prod)

| | stage (맥북) | prod (맥미니) |
|---|---|---|
| 용도 | 개발·튜닝 샌드박스 | 상시 실사용 서비스 |
| Postgres | 이 compose로 로컬 기동 | 이 compose로 상시 기동 |
| Ollama | compose 컨테이너 (CPU) | compose 컨테이너 (CPU) |
| 실사용 질의 | ✗ (개발 때만) | ✓ 항상 여기로 |
| cloudflared-n8n / cloudflared-rag | ✗ (터널 자격증명 없음) | ✓ (`--profile prod`로만 뜸) |

## 구성

- `docker-compose.infra.yml` — Postgres(pgvector) + Ollama + cloudflared-n8n + cloudflared-rag + cloudflared-grafana(모두 prod 전용, profile로 게이팅) + prometheus + grafana + node-exporter + cadvisor(모니터링, profile 제한 없음)
- `initdb/01-init.sh` — 최초 1회: DB 격리(`vault_rag`/`airflow`) + role(`*_app`) + `CREATE EXTENSION vector` + schema `second_brain`. 비번은 `.env`에서 주입(git에 평문 X)
- `.env.example` — superuser + 앱별 role 비번 + Grafana admin 비번 (`.env`로 복사해 사용, git 제외)
- `cloudflared-n8n/config.yml`, `cloudflared-rag/config.yml`, `cloudflared-grafana/config.yml` — 서비스별 터널의 ingress 규칙. 터널 자격증명(JSON)은 여기 없고 호스트 `~/.cloudflared/`에서 ro 마운트(터널 자격증명 다 같은 폴더에, 각 컨테이너는 자기 config.yml이 가리키는 파일만 씀)
- `prometheus/prometheus.yml` — node-exporter(호스트 CPU/RAM/네트워크) + cadvisor(컨테이너별 리소스) 스크래핑 설정

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

## 주의

- ⚠️ **macOS Docker는 Metal(GPU) 접근 불가** → 컨테이너 Ollama는 CPU 전용. 임베딩엔 충분(옵션1, stage=prod 일치). 로컬 LLM 생성 시 native Ollama(Metal)로 전환 고려.
- 비밀번호는 `.env`에서 주입되고 **git 추적 파일엔 안 들어감**. `.env`의 `change_me_*`는 운영 전 교체.
- `initdb`는 **데이터 볼륨이 비어있을 때만** 실행됨(최초 1회). 이후 스키마 변경은 마이그레이션으로.
- ⚠️ role 비번에 작은따옴표(`'`) 넣지 말 것 (init SQL 문자열에 그대로 들어감).

## TODO

- [x] ollama 컨테이너 기동 + `nomic-embed-text` pull (임베딩 768차원 확인, 2026-07-18)
- [x] cloudflared를 n8n repo에서 이전 (2026-07-20, 여러 서비스가 공유하는 공용 터널이라 L0 기준)
- [x] cloudflared 터널을 서비스별로 분리 (2026-07-20, 공유 터널의 대시보드 라벨 혼란 + n8n/rag 신뢰 경계 분리)
- [x] 모니터링 스택(prometheus/grafana/node-exporter/cadvisor) compose에 추가 (2026-07-26, 로컬 POC로 감 본 뒤 반영)
- [x] grafana 터널 생성 + DNS 라우팅 (2026-07-26, 맥미니 SSH로 `cloudflared tunnel create grafana` + `route dns` 실행, 기존 인증서 재사용)
- [x] `.env`에 `GRAFANA_ADMIN_USER`/`GRAFANA_ADMIN_PASSWORD` 채우기 + 맥미니 배포·재기동 (2026-07-26, grafana.rimsm.com HTTP 200 확인)
- [ ] Grafana에 Prometheus 데이터소스(`http://prometheus:9090`) 추가 + 대시보드 import (Node Exporter Full `1860`, cAdvisor `14282`)
- [ ] grafana.rimsm.com 앞에 Cloudflare Access(n8n처럼 이메일 OTP) 추가 검토 — 지금은 Grafana 자체 로그인만 걸려 있음
- [ ] `.env`에 role 비밀번호 실제 값 채우기 (secret 관리 방식 결정)
- [ ] Airflow 서비스 추가 (`vault_rag`/`airflow` DB 분리는 이미 반영됨)
- [ ] GitHub 원격 `homeserver-infra` 생성 후 push
