# homeserver-infra

홈서버 공용 인프라. Docker Compose로 **Postgres(pgvector) + Ollama** (나중에 Airflow 추가).
서비스 repo들(`vault-rag`, `trading-bot` …)이 이 공용 인프라를 물어서 씀.

> 설계·결정 맥락은 코드가 아니라 vault에: `01_Projects/99_RIMSM/099.home-server/overview.md`,
> `004.vault-rag/overview.md`

## 환경 (stage / prod)

| | stage (맥북) | prod (맥미니) |
|---|---|---|
| 용도 | 개발·튜닝 샌드박스 | 상시 실사용 서비스 |
| Postgres | 이 compose로 로컬 기동 | 이 compose로 상시 기동 |
| Ollama | compose 컨테이너 (CPU) | compose 컨테이너 (CPU) |
| 실사용 질의 | ✗ (개발 때만) | ✓ 항상 여기로 |

## 구성

- `docker-compose.infra.yml` — Postgres(pgvector) + Ollama
- `initdb/01-init.sh` — 최초 1회: DB 격리(`vault_rag`/`airflow`) + role(`*_app`) + `CREATE EXTENSION vector` + schema `second_brain`. 비번은 `.env`에서 주입(git에 평문 X)
- `.env.example` — superuser + 앱별 role 비번 (`.env`로 복사해 사용, git 제외)

## 실행

```bash
# 1) 공용 네트워크 (최초 1회)
docker network create home-server-network

# 2) 환경변수
cp .env.example .env      # POSTGRES_PASSWORD 채우기

# 3) 기동
# stage(맥북)·prod(맥미니) 동일: 전체 (postgres + ollama)
docker compose -f docker-compose.infra.yml up -d
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
- [ ] `.env`에 role 비밀번호 실제 값 채우기 (secret 관리 방식 결정)
- [ ] Airflow 서비스 추가 (`vault_rag`/`airflow` DB 분리는 이미 반영됨)
- [ ] GitHub 원격 `homeserver-infra` 생성 후 push
