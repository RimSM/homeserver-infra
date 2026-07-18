#!/bin/bash
set -euo pipefail

# 공용 Postgres 초기화 (컨테이너 최초 기동 = 데이터 볼륨 비었을 때만 1회 자동 실행)
# 비번은 compose가 넘긴 환경변수에서 읽음 → git 추적 파일엔 평문 0
# 설계: 컨테이너 1개 안 논리 DB 격리 (vault_rag / airflow / 나중 trading) + 앱별 role(*_app)
# 이 스크립트는 postgres 컨테이너(리눅스) 안에서 실행 → 호스트가 맥북이든 맥미니든 동일 동작
# ⚠️ 비번에 작은따옴표(') 넣지 말 것 (아래 SQL 문자열에 그대로 들어감)

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
-- ===== vault_rag (RAG용, pgvector) =====
CREATE ROLE vault_rag_app LOGIN PASSWORD '${VAULT_RAG_DB_PASSWORD}';
CREATE DATABASE vault_rag OWNER vault_rag_app;

-- ===== airflow (메타DB 전용 격리) =====
CREATE ROLE airflow_app LOGIN PASSWORD '${AIRFLOW_DB_PASSWORD}';
CREATE DATABASE airflow OWNER airflow_app;

-- ===== 나중: trading (쓸 때 띄움) =====
-- CREATE ROLE trading_app LOGIN PASSWORD '...';
-- CREATE DATABASE trading OWNER trading_app;
EOSQL

# vault_rag DB 안에서 pgvector 확장 + 코퍼스 스키마
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname vault_rag <<EOSQL
CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS second_brain AUTHORIZATION vault_rag_app;   -- 옵시디언 vault 코퍼스
-- 나중 외부자료: CREATE SCHEMA articles / papers AUTHORIZATION vault_rag_app;
EOSQL

echo "[init] vault_rag(second_brain) + airflow DB/role 생성 완료"
