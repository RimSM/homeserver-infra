#!/usr/bin/env bash
# 프로젝트 하나에 대해 MinIO 버킷 + 전용 액세스키 + 정책을 한 번에 만든다.
#
# 왜 스크립트인가: MinIO 커뮤니티(AGPL) 빌드는 웹 콘솔에서 유저·정책 관리 기능을 걷어냈다
# (/api/v1/{users,policies,service-accounts}가 404 — 권한 문제가 아니라 경로 자체가 없음,
# 2026-07-28 실측). 그래서 프로비저닝 경로는 mc CLI로 고정된다.
#
# 사용법:
#   ./minio/provision-project.sh <project-name> [access-key]
#
# 예:
#   ./minio/provision-project.sh vault-rag
#   ./minio/provision-project.sh trading-bot tradingbot-prod
#
# 결과: 버킷 <project>, 정책 <project>-rw(그 버킷에만 s3:*), 유저 <access-key>가 생기고
# 시크릿이 stdout에 1회 출력된다. **시크릿은 다시 볼 수 없으니 바로 옮겨 적을 것.**
set -euo pipefail

PROJECT="${1:-}"
if [[ -z "$PROJECT" ]]; then
  echo "usage: $0 <project-name> [access-key]" >&2
  exit 1
fi
# 버킷 이름 규칙(S3): 소문자·숫자·하이픈, 3~63자.
if ! [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  echo "error: '$PROJECT'는 S3 버킷 이름 규칙에 안 맞음 (소문자/숫자/하이픈, 3~63자)" >&2
  exit 1
fi

ACCESS_KEY="${2:-${PROJECT}-app}"
CONTAINER="${MINIO_CONTAINER:-infra-minio}"
POLICY="${PROJECT}-rw"

# 루트 자격증명은 .env에서. (스크립트를 repo 루트 기준으로 실행하든 minio/ 안에서 하든 동작)
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE 없음 (.env.example을 복사해 채울 것)" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
: "${MINIO_ROOT_USER:?.env에 MINIO_ROOT_USER 필요}"
: "${MINIO_ROOT_PASSWORD:?.env에 MINIO_ROOT_PASSWORD 필요}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "error: 컨테이너 '$CONTAINER'가 안 떠 있음" >&2
  echo "  docker compose -f docker-compose.infra.yml up -d minio" >&2
  exit 1
fi

# 시크릿은 호스트에서 생성해 로그에 안 남게 stdin으로만 넘긴다.
# head -c로 고정 바이트만 읽고 cut으로 자른다. (`tr </dev/urandom | head`는 head가 파이프를
# 먼저 닫아 tr이 SIGPIPE로 죽고, set -o pipefail이 그걸 잡아 스크립트가 141로 종료된다.)
SECRET="$(head -c 512 /dev/urandom | LC_ALL=C base64 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-40)"

OUT="$(docker exec -i \
  -e MC_ROOT_USER="$MINIO_ROOT_USER" \
  -e MC_ROOT_PASS="$MINIO_ROOT_PASSWORD" \
  -e P_PROJECT="$PROJECT" \
  -e P_POLICY="$POLICY" \
  -e P_KEY="$ACCESS_KEY" \
  -e P_SECRET="$SECRET" \
  "$CONTAINER" sh -s <<'INNER'
set -e
mc alias set local http://localhost:9000 "$MC_ROOT_USER" "$MC_ROOT_PASS" >/dev/null

# -p: 이미 있으면 조용히 넘어감 (재실행해도 안전)
mc mb -p "local/$P_PROJECT" >/dev/null
echo "  버킷: $P_PROJECT"

# 자기 버킷에만 s3:* — 남의 버킷은 목록에도 안 뜬다.
cat > /tmp/policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": ["arn:aws:s3:::$P_PROJECT", "arn:aws:s3:::$P_PROJECT/*"]
    }
  ]
}
EOF
mc admin policy create local "$P_POLICY" /tmp/policy.json >/dev/null 2>&1 \
  || mc admin policy update local "$P_POLICY" /tmp/policy.json >/dev/null
rm -f /tmp/policy.json
echo "  정책: $P_POLICY (해당 버킷 전용)"

if mc admin user info local "$P_KEY" >/dev/null 2>&1; then
  echo "  유저: $P_KEY (이미 존재 — 시크릿 변경 안 함)"
  echo "  __EXISTING__"
else
  mc admin user add local "$P_KEY" "$P_SECRET" >/dev/null
  echo "  유저: $P_KEY (신규)"
fi
mc admin policy attach local "$P_POLICY" --user "$P_KEY" >/dev/null 2>&1 || true
INNER
)"

# 마커는 분기용이라 사용자에겐 안 보인다.
grep -v '^  __EXISTING__$' <<<"$OUT"

echo
echo "완료: $PROJECT"
echo "----------------------------------------"
echo "  S3 endpoint (내부):  http://minio:9000"
echo "  S3 endpoint (stage): http://localhost:9000"
echo "  S3 endpoint (공개):  https://s3.rimsm.com"
echo "  bucket:              $PROJECT"
echo "  AWS_ACCESS_KEY_ID:     $ACCESS_KEY"
if grep -q '^  __EXISTING__$' <<<"$OUT"; then
  # 이미 있던 유저의 시크릿은 MinIO도 되돌려주지 않는다. 새로 만든 시크릿을 찍으면
  # 실제로는 안 되는 값을 알려주는 꼴이라, 아예 출력하지 않는다.
  echo "  AWS_SECRET_ACCESS_KEY: (기존 유저 — 시크릿은 조회 불가)"
  echo "----------------------------------------"
  echo "시크릿을 잊었으면 새 키를 발급할 것:"
  echo "  docker exec $CONTAINER mc admin user add local <새키> <새시크릿>"
  echo "  docker exec $CONTAINER mc admin policy attach local $POLICY --user <새키>"
else
  echo "  AWS_SECRET_ACCESS_KEY: $SECRET"
  echo "----------------------------------------"
  echo "⚠️  시크릿은 지금만 보인다. 바로 옮겨 적을 것."
fi
