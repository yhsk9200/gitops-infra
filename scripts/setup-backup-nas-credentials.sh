#!/usr/bin/env bash
# setup-backup-nas-credentials.sh
#   플랫폼 백업의 NAS(MinIO) 자격증명을 발급하고 SealedSecret까지 만듭니다.
#   런북 §14 "최초 설정"을 한 번에 수행합니다.
#
# ── 설계 원칙: 비밀값이 어디에도 안 남게 ────────────────────────────────────
#   1. 백업 사용자 비밀번호는 이 스크립트가 생성합니다(openssl). 화면에 찍지
#      않고, 오직 600 권한 파일 하나로만 기록합니다.
#   2. MinIO 루트 비밀번호는 프롬프트로 받고(입력 중 화면에 안 보임) 변수로만
#      다룹니다. 셸 히스토리에 남지 않습니다.
#   3. 비밀값을 명령행 인자로 넘기지 않습니다 — 호스트의 `ps` 출력에 노출되기
#      때문입니다. 컨테이너에는 환경변수로, kubectl에는 파일로 전달합니다.
#   4. 따라서 이 스크립트를 AI 에이전트가 대신 실행하더라도 비밀값이 대화
#      기록에 들어가지 않습니다. 사람이 값을 보는 순간은 마지막 한 번뿐입니다.
#
# ── 왜 사람이 값을 알아야 하는가 ────────────────────────────────────────────
#   이 플랫폼은 sealed-secrets 컨트롤러 키를 백업하지 않는 대신 "패스워드
#   매니저에 보관한 평문으로 재봉인(reseal)"을 기본 복구 경로로 삼습니다
#   (scripts/platform-backup.sh 주석, 런북 §6). 평문 보관자가 사람이 아니면
#   그 복구 경로가 성립하지 않습니다 — 자동화로 대체할 수 없는 부분입니다.
#
# ── 사용법 ──────────────────────────────────────────────────────────────────
#   ./scripts/setup-backup-nas-credentials.sh              # 실행
#   ./scripts/setup-backup-nas-credentials.sh --preflight  # 사전 점검만(변경 없음)
#   ROTATE=1 ./scripts/setup-backup-nas-credentials.sh     # 기존 사용자 비밀번호 교체
#
#   반드시 **사람이 터미널에서** 실행하세요(비밀번호 프롬프트에 TTY가 필요).
#   Claude Code 안에서는 프롬프트 앞에 `!` 를 붙여 실행하면 됩니다.

set -euo pipefail

# ── 설정 (환경변수로 덮어쓰기 가능) ─────────────────────────────────────────
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://100.69.142.125:9000}"   # NAS tailnet 주소
MINIO_ROOT_USER_DEFAULT="minioadmin"
BUCKET="${BUCKET:-platform-backups}"
BK_USER="${BK_USER:-platform-backup}"
POLICY="${POLICY:-platform-backup-rw}"
NS="${NS:-platform-db}"
SECRET_NAME="${SECRET_NAME:-platform-backup-nas-secret}"
CONTROLLER_NAME="${CONTROLLER_NAME:-sealed-secrets-controller}"
CONTROLLER_NS="${CONTROLLER_NS:-platform-system}"
MC_IMAGE="${MC_IMAGE:-minio/mc:RELEASE.2025-08-13T08-35-41Z}"     # arm64 가드 등록 태그
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEALED_OUT="$REPO_DIR/manifests/security/platform-backup-nas-sealed-secret.yaml"
PLAINTEXT_OUT="${PLAINTEXT_OUT:-$HOME/platform-backup-nas.secret}"
# 다른 버킷 접근이 막히는지 확인할 대상(있으면 자동으로 음성 테스트 수행)
NEGATIVE_BUCKET="${NEGATIVE_BUCKET:-mlflow-artifacts}"

PREFLIGHT_ONLY=0
[ "${1:-}" = "--preflight" ] && PREFLIGHT_ONLY=1

# ── 출력 헬퍼 ───────────────────────────────────────────────────────────────
c_step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
c_ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
c_info() { printf '    %s\n' "$*"; }
c_warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()    { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

WORK=""
cleanup() {
  # 임시 자격증명(mc 설정, 비밀번호 파일)을 반드시 지웁니다.
  [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"
  unset MC_ROOT_PW BK_PW 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cat <<'BANNER'
╭──────────────────────────────────────────────────────────────╮
│  플랫폼 백업 — NAS(MinIO) 자격증명 설정                       │
│  런북 §14 최초 설정 1~2단계를 자동으로 수행합니다.            │
╰──────────────────────────────────────────────────────────────╯
BANNER

# ═══ 0. 사전 점검 ═══════════════════════════════════════════════════════════
c_step "0/6  사전 점검 — 필요한 도구와 접근 확인"

for cmd in docker kubectl kubeseal openssl; do
  command -v "$cmd" >/dev/null || die "$cmd 를 찾을 수 없습니다. 설치 후 다시 실행하세요."
done
c_ok "도구 확인: docker, kubectl, kubeseal, openssl"

docker info >/dev/null 2>&1 || die "Docker가 실행 중이 아닙니다. Docker/OrbStack을 켜고 다시 실행하세요."
c_ok "Docker 데몬 응답"

kubectl get ns "$NS" >/dev/null 2>&1 \
  || die "네임스페이스 $NS 에 접근할 수 없습니다. KUBECONFIG를 확인하세요 (예: export KUBECONFIG=~/.kube/oci-platform-tailnet.yaml)"
c_ok "클러스터 접근 OK — 네임스페이스 $NS"

kubectl get deploy "$CONTROLLER_NAME" -n "$CONTROLLER_NS" >/dev/null 2>&1 \
  || die "sealed-secrets 컨트롤러($CONTROLLER_NS/$CONTROLLER_NAME)를 찾을 수 없습니다."
c_ok "sealed-secrets 컨트롤러 확인"

# NAS 도달성 — MinIO는 인증 없이도 health 엔드포인트를 열어둡니다.
if curl -s -o /dev/null -m 8 "$MINIO_ENDPOINT/minio/health/live"; then
  c_ok "MinIO 도달 가능 — $MINIO_ENDPOINT"
else
  die "MinIO($MINIO_ENDPOINT)에 닿지 않습니다. NAS 전원과 Tailscale 연결을 확인하세요."
fi

if [ "$PREFLIGHT_ONLY" = "1" ]; then
  printf '\n\033[32m사전 점검만 수행했습니다. 변경된 것은 없습니다.\033[0m\n'
  exit 0
fi

# ═══ 1. MinIO 루트 자격증명 입력 ════════════════════════════════════════════
c_step "1/6  MinIO 루트 자격증명 (버킷·사용자를 만들 때만 씁니다)"
c_info "입력한 값은 화면에 표시되지 않고 셸 히스토리에도 남지 않습니다."

[ -t 0 ] || die "터미널에서 직접 실행해야 합니다 — 비밀번호 입력에 TTY가 필요합니다.
    Claude Code 안이라면 프롬프트 앞에 ! 를 붙여 실행하세요:
      ! ./scripts/setup-backup-nas-credentials.sh"

printf '    MinIO 루트 계정명 [%s]: ' "$MINIO_ROOT_USER_DEFAULT"
read -r MC_ROOT_USER
MC_ROOT_USER="${MC_ROOT_USER:-$MINIO_ROOT_USER_DEFAULT}"

printf '    MinIO 루트 비밀번호: '
read -rs MC_ROOT_PW; echo
[ -n "$MC_ROOT_PW" ] || die "비밀번호가 비어 있습니다."
export MC_ROOT_USER MC_ROOT_PW MINIO_ENDPOINT

WORK="$(mktemp -d)"; chmod 700 "$WORK"; mkdir -p "$WORK/mc" "$WORK/mcb"

# mc를 컨테이너로 실행합니다 — Apple Silicon 네이티브 바이너리 크래시 이력
# (docs/tailnet-minio-runbook.md). 비밀값은 -e 로만 전달해 호스트 ps에 안 남깁니다.
mc_root() {
  docker run --rm -i \
    -e MINIO_ENDPOINT -e MC_ROOT_USER -e MC_ROOT_PW \
    -v "$WORK/mc:/root/.mc" -v "$WORK:/work" \
    --entrypoint sh "$MC_IMAGE" -c '
      mc alias set r "$MINIO_ENDPOINT" "$MC_ROOT_USER" "$MC_ROOT_PW" >/dev/null 2>&1 || exit 91
      '"$*"''
}

if ! mc_root 'mc ls r >/dev/null'; then
  die "루트 자격증명으로 로그인하지 못했습니다. 계정명/비밀번호를 확인하세요."
fi
c_ok "루트 인증 성공"

# ═══ 2. 버킷 ════════════════════════════════════════════════════════════════
c_step "2/6  백업 버킷 준비 — $BUCKET"
mc_root "mc mb --ignore-existing r/$BUCKET >/dev/null" || die "버킷 생성 실패"
c_ok "버킷 준비됨 (이미 있으면 그대로 사용)"

# ═══ 3. 정책 ════════════════════════════════════════════════════════════════
c_step "3/6  최소권한 정책 — $POLICY"
c_info "이 버킷에만 읽기·쓰기를 허용합니다."
c_info "삭제(s3:DeleteObject)는 주지 않습니다 — 백업 주체가 백업을 지울 수 없어야 합니다."

cat > "$WORK/policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::$BUCKET"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": ["arn:aws:s3:::$BUCKET/*"]
    }
  ]
}
JSON

# 정책 내용은 결정적이라 있으면 덮어써도 안전합니다.
mc_root "mc admin policy create r $POLICY /work/policy.json >/dev/null 2>&1 || true"
if mc_root "mc admin policy info r $POLICY >/dev/null 2>&1"; then
  c_ok "정책 등록됨"
else
  die "정책 생성에 실패했습니다."
fi

# ═══ 4. 전용 사용자 ═════════════════════════════════════════════════════════
c_step "4/6  백업 전용 사용자 — $BK_USER"

USER_EXISTS=0
mc_root "mc admin user info r $BK_USER >/dev/null 2>&1" && USER_EXISTS=1 || true

if [ "$USER_EXISTS" = "1" ] && [ "${ROTATE:-0}" != "1" ]; then
  die "사용자 '$BK_USER' 가 이미 있습니다.
    비밀번호를 새로 발급하려면(기존 백업 잡은 새 SealedSecret 적용 전까지 실패합니다):
      ROTATE=1 $0"
fi

# URL·환경변수 어디에 들어가도 깨지지 않도록 영숫자만 사용합니다(40자 ≈ 충분히 강함).
# `head -c`가 아니라 `cut`을 쓰는 이유: head는 원하는 만큼 읽고 파이프를 닫아
# 앞 단계에 SIGPIPE를 보내는데, set -o pipefail 아래에서는 그게 스크립트 중단으로
# 이어집니다. cut은 입력을 끝까지 읽습니다.
BK_PW="$(openssl rand -base64 90 | tr -dc 'A-Za-z0-9' | cut -c1-40)"
[ "${#BK_PW}" -eq 40 ] || die "비밀번호 생성에 실패했습니다."
export BK_USER BK_PW

if [ "$USER_EXISTS" = "1" ]; then
  c_warn "기존 사용자의 비밀번호를 교체합니다 (ROTATE=1)"
fi
mc_root 'mc admin user add r "$BK_USER" "$BK_PW" >/dev/null' || die "사용자 생성/교체 실패"
mc_root "mc admin policy attach r $POLICY --user $BK_USER >/dev/null 2>&1 || true"
c_ok "사용자 준비 + 정책 연결 완료 (비밀번호는 화면에 표시하지 않습니다)"

# ═══ 5. 권한 검증 ═══════════════════════════════════════════════════════════
c_step "5/6  실제로 의도한 권한만 있는지 검증"

mc_bk() {
  docker run --rm -i \
    -e MINIO_ENDPOINT -e BK_USER -e BK_PW \
    -v "$WORK/mcb:/root/.mc" \
    --entrypoint sh "$MC_IMAGE" -c '
      mc alias set b "$MINIO_ENDPOINT" "$BK_USER" "$BK_PW" >/dev/null 2>&1 || exit 91
      '"$*"''
}

mc_bk "mc ls b/$BUCKET >/dev/null" || die "백업 사용자가 버킷을 조회하지 못합니다."
c_ok "조회(ListBucket) 가능"

mc_bk "echo setup-check | mc pipe b/$BUCKET/.setup-check >/dev/null" || die "쓰기(PutObject) 실패"
c_ok "쓰기(PutObject) 가능"

mc_bk "mc cat b/$BUCKET/.setup-check >/dev/null" || die "읽기(GetObject) 실패 — 반출 후 재검증이 불가능합니다."
c_ok "읽기(GetObject) 가능 — 반출 후 checksum 재검증에 필요"

if mc_bk "mc rm b/$BUCKET/.setup-check >/dev/null 2>&1"; then
  c_warn "삭제가 가능합니다 — 의도와 다릅니다. 정책에 DeleteObject가 섞여 있는지 확인하세요."
else
  c_ok "삭제(DeleteObject) 차단됨 — 의도대로"
fi

if mc_root "mc ls r/$NEGATIVE_BUCKET >/dev/null 2>&1"; then
  if mc_bk "mc ls b/$NEGATIVE_BUCKET >/dev/null 2>&1"; then
    c_warn "다른 버킷($NEGATIVE_BUCKET)에 접근됩니다 — 권한이 과합니다. 정책 연결을 확인하세요."
  else
    c_ok "다른 버킷($NEGATIVE_BUCKET) 접근 차단됨 — 최소권한 확인"
  fi
else
  c_info "($NEGATIVE_BUCKET 버킷이 없어 음성 테스트는 건너뜁니다)"
fi

mc_root "mc rm r/$BUCKET/.setup-check >/dev/null 2>&1 || true"   # 테스트 흔적 정리(루트로)
c_ok "테스트 오브젝트 정리 완료"

# ═══ 6. SealedSecret ════════════════════════════════════════════════════════
c_step "6/6  SealedSecret 생성"

kubeseal --fetch-cert \
  --controller-name="$CONTROLLER_NAME" \
  --controller-namespace="$CONTROLLER_NS" > "$WORK/pub-cert.pem" 2>/dev/null \
  || die "컨트롤러 공개키를 받지 못했습니다."
c_ok "컨트롤러 공개키 수신"

# 비밀값을 --from-literal 로 넘기면 호스트 ps에 노출됩니다 → 파일로 전달합니다.
printf '%s' "$BK_USER" > "$WORK/ACCESS_KEY"
printf '%s' "$BK_PW"   > "$WORK/SECRET_KEY"
chmod 600 "$WORK/ACCESS_KEY" "$WORK/SECRET_KEY"

kubectl create secret generic "$SECRET_NAME" \
  --namespace="$NS" \
  --from-file=ACCESS_KEY="$WORK/ACCESS_KEY" \
  --from-file=SECRET_KEY="$WORK/SECRET_KEY" \
  --dry-run=client -o yaml \
  | kubeseal --cert "$WORK/pub-cert.pem" --format yaml \
  > "$SEALED_OUT" \
  || die "SealedSecret 생성에 실패했습니다."

grep -q "encryptedData" "$SEALED_OUT" || die "생성된 파일에 암호문이 없습니다 — 중단합니다."
c_ok "생성됨: ${SEALED_OUT#"$REPO_DIR"/}"
c_info "이 파일은 암호문이라 git에 커밋해도 안전합니다."

# ── 평문 보관용 파일 (사람이 패스워드 매니저로 옮기고 삭제) ─────────────────
umask 077
cat > "$PLAINTEXT_OUT" <<TXT
# 플랫폼 백업 NAS(MinIO) 자격증명 — $(date -Iseconds)
#
# 이 값을 패스워드 매니저에 옮긴 뒤 **이 파일을 삭제**하세요:
#     rm -P "$PLAINTEXT_OUT"
#
# 왜 사람이 보관해야 하는가: 이 플랫폼은 sealed-secrets 컨트롤러 키를 백업하지
# 않는 대신 "패스워드 매니저의 평문으로 재봉인(reseal)"을 기본 복구 경로로
# 삼습니다(런북 §6). 클러스터를 재구축하면 이 값으로 SealedSecret을 다시
# 만들어야 합니다.

MinIO endpoint : $MINIO_ENDPOINT
Bucket         : $BUCKET
Access key     : $BK_USER
Secret key     : $BK_PW
Policy         : $POLICY (해당 버킷 읽기·쓰기, 삭제 불가)
Kubernetes     : secret/$SECRET_NAME @ namespace $NS
TXT
chmod 600 "$PLAINTEXT_OUT"

# ── 마무리 안내 ─────────────────────────────────────────────────────────────
cat <<DONE

╭──────────────────────────────────────────────────────────────╮
│  완료                                                         │
╰──────────────────────────────────────────────────────────────╯

  평문 자격증명이 아래 파일에만 기록되었습니다 (권한 600):
      $PLAINTEXT_OUT

  다음 순서로 마무리하세요.

    1) 위 파일을 열어 Access/Secret key를 패스워드 매니저에 저장
         open "$PLAINTEXT_OUT"      (또는 cat)

    2) 저장을 확인했다면 파일 삭제
         rm -P "$PLAINTEXT_OUT"

    3) SealedSecret 커밋 (암호문이라 안전합니다)
         git add ${SEALED_OUT#"$REPO_DIR"/}
         git commit -m "feat: 백업 NAS 자격증명 SealedSecret"
         git push

  머지되면 ArgoCD가 Secret과 백업 CronJob을 배포합니다. 스케줄(02:00 KST)을
  기다리지 말고 수동으로 첫 실행을 검증하세요 — 절차는 런북 §14의 4단계에
  있습니다.

DONE
