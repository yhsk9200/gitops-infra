# tailnet 편입 + MinIO@NAS 런북 (실행계획 Step 0·1 / ADR-0008 Phase A)

MLOps 실행계획(CLAUDE.md)의 Step 0(tailnet 편입)·Step 1(MinIO@NAS)을 실행하는
절차. 전부 클러스터 밖 수동 작업이라 GitOps로 코드화되지 않는 대신, 이 문서가
재구축 시에도 재사용되는 기준 절차다. 완료 후의 활성화 순서는
[platform-mlops-setup.md](platform-mlops-setup.md), 설계 근거는
[ADR-0008](adr/0008-mlops-platform-pivot.md)·[ADR-0009](adr/0009-isolated-ml-experiment-cluster.md).

**전제 (2026-07-16 실측)**: 운영 단말(Mac)은 이미 tailnet 편입 완료
(`100.114.123.60`, yhsk9200 계정). 남은 편입 대상은 OCI 노드와 NAS 두 대.
tailnet IP는 장비당 최초 1회 배정 후 고정되므로, 여기서 확정되는 IP를 git
매니페스트(`MLFLOW_S3_ENDPOINT_URL`)에 하드코딩해도 안전하다.

> **Step 0 완료 (2026-07-18 실측)**: 노드 `aporiax-instance` = `100.69.52.25`,
> NAS `yhs-ds920` = `100.69.142.125`. 3자 상호 ping 성공(노드 경로는 DERP
> 릴레이 — 아래 0.1 참고), 방식 C kubectl 전환 완료. 본문 중 취소선/정정
> 표기는 검증 과정에서 기각된 가설의 기록이다.

---

## Step 0: tailnet 편입

### 0.1 OCI 노드 (144.24.81.104, Ubuntu arm64)

```bash
ssh -i ~/.ssh/id_rsa ubuntu@144.24.81.104
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# → 출력되는 인증 URL을 브라우저에서 열어 yhsk9200 계정으로 승인
tailscale ip -4        # 배정된 100.x IP 기록 → 이 값이 "노드 tailnet IP"
```

- 아웃바운드로 동작하므로 **OCI Security List 변경 불필요** (WireGuard는
  노드가 먼저 나가는 연결. 직결 실패 시 DERP 릴레이로 자동 폴백).
- 선택 최적화: `tailscale ping` 결과가 계속 `via DERP`면 Security List에
  **UDP 41641 인바운드**를 열면 직결(direct)로 승격된다. 필수는 아님 —
  릴레이여도 기능은 동일하고 지연만 손해.

**~~주의 — Oracle 기본 iptables INPUT REJECT~~ → 기각된 가설 (2026-07-18
실측)**: Oracle 이미지의 INPUT REJECT 룰이 tailnet 인바운드 서비스 접근을
막을 것으로 예상했으나, **실측 결과 막히지 않는다** — tailscaled가
netfilter-mode=on(기본)에서 `ts-input` 체인을 INPUT의 REJECT 룰보다 앞에
삽입하고 `-i tailscale0 -j ACCEPT`를 스스로 관리한다(`iptables -S INPUT`
및 Mac→노드 6443 TCP 성공으로 확인). **수동 iptables 변경 불필요.**
단, tailscale을 `--netfilter-mode=off`로 돌리는 경우에만 이 가설이
되살아난다.

DERP 릴레이의 실제 원인은 호스트 방화벽이 아니라 **OCI Security List의
UDP 41641 인바운드 차단**이다. 노드 경로(Mac↔노드 ~178ms, 노드↔NAS 71ms —
둘 다 도쿄 DERP 경유)를 직결로 올리려면 Security List에서 UDP 41641
인바운드를 열면 된다. 아티팩트 벌크 전송(노드→NAS)이 시작되는 Step 1
이후에는 릴레이 대역폭 제한이 체감될 수 있어 **개방 권장**.

### 0.2 NAS (Synology DS920+, DSM 7)

1. 패키지 센터 → **Tailscale** 공식 패키지 설치 → 앱 열어 yhsk9200 계정 로그인.
2. Tailscale 앱(또는 admin console https://login.tailscale.com/admin/machines)에서
   NAS의 100.x IP 기록 → 이 값이 **"NAS tailnet IP"**
   (= `manifests/mlops/mlflow-deployment.yaml`의 `REPLACE-NAS-TAILNET-IP` 치환값).
3. DSM 알려진 특성: DSM 메이저 업데이트 후 Tailscale 패키지가 중지될 수 있음 —
   업데이트 후 패키지 실행 상태 확인을 습관화.

### 0.3 검증 (완료 판정)

```bash
# Mac에서
tailscale status                      # 노드·NAS가 목록에 있고 offline 아님
tailscale ping <노드 tailnet IP>       # pong (direct/DERP 여부도 표시)
tailscale ping <NAS tailnet IP>

# OCI 노드에서 — MLflow가 실제로 쓸 경로(노드→NAS)라 이 방향이 핵심
tailscale ping <NAS tailnet IP>
```

3자 상호 ping이 전부 성공하면 Step 0의 전송로는 완료.

### 0.4 kubeconfig 방식 C 전환 — ✅ 완료 (2026-07-18, 노드 무변경)

원래 계획은 tls-san 추가 + k3s 재시작이었으나 **불필요했다**: k3s 서빙
인증서 SAN에 노드 호스트네임(`DNS:aporiax-instance`)이 기본 포함돼 있고,
tailnet 장비명이 호스트네임과 동일해서 **MagicDNS 단축명으로 접속하면
인증서 검증이 그대로 통과**한다(openssl SAN 실측 + `kubectl get nodes`
성공). 실행한 것:

```bash
# Mac에서 — server를 IP가 아닌 MagicDNS 단축명으로
cp ~/.kube/oci-platform.yaml ~/.kube/oci-platform-tailnet.yaml
sed -i '' 's|https://127.0.0.1:6443|https://aporiax-instance:6443|' ~/.kube/oci-platform-tailnet.yaml
KUBECONFIG=~/.kube/oci-platform-tailnet.yaml kubectl get nodes   # Ready 확인
```

tailnet **IP**(`100.69.52.25`)로 붙고 싶은 경우에만 SAN에 IP가 없어
tls-san 추가가 필요하다 — 단축명 방식이 노드 무변경이라 우선.
(이 방식의 전제 = tailnet 장비명과 노드 호스트네임 일치. 장비명을 바꾸면
깨지므로 바꾸지 말 것.) 방식 B SSH 터널은 tailnet 장애 폴백으로 유지 —
`cluster-access-kubeconfig.md` 방식 C 섹션에 정식 기록됨.

---

## Step 1: MinIO@NAS

### 1.1 기동 — 루프백 바인딩 + tailscaled 인바운드 프록시 (2026-07-18 정정)

**원계획(tailnet IP 바인딩)은 이 NAS에서 불가** — DSM에 TUN 디바이스가 없어
Tailscale이 **userspace networking 모드**로 동작하고, 이 모드에서는
`tailscale0` 인터페이스도, 호스트에 배정된 100.x IP도 존재하지 않아
`-p 100.69.142.125:...` 바인딩이 실패한다. 대신 userspace 모드의 정석 구성:
**컨테이너를 127.0.0.1에 바인딩**하면 tailscaled가 tailnet 인바운드 TCP를
127.0.0.1로 프록시해 준다 (실측: DSM 5000/5001이 tailnet IP로 접속됨 —
프록시 동작 증명). 공인·LAN 어디에도 안 열리므로 노출 표면은 tailnet IP
바인딩보다 오히려 좁다. **클러스터 쪽 엔드포인트는 변경 없음** —
`http://100.69.142.125:9000`으로 접속하면 tailscaled가 받아서 로컬 MinIO로
넘긴다.

DSM Container Manager UI는 바인딩 IP 지정을 지원하지 않으므로
SSH(제어판 → 터미널에서 활성화)로 docker CLI를 쓴다.

```bash
ssh <admin>@<NAS-LAN-IP>
sudo mkdir -p /volume1/docker/minio/data

sudo docker run -d --restart unless-stopped --name minio \
  -p 127.0.0.1:9000:9000 \
  -p 127.0.0.1:9001:9001 \
  -e MINIO_ROOT_USER='<루트 계정 — 비밀번호 관리자에서 생성>' \
  -e MINIO_ROOT_PASSWORD='<루트 비밀번호 — 동일>' \
  -v /volume1/docker/minio/data:/data \
  minio/minio:RELEASE.2025-09-07T16-13-09Z \
  server /data --console-address ":9001"
```

userspace 모드의 트레이드오프 (수용):
- WireGuard 암복호화가 커널이 아닌 프로세스에서 돌아 **처리량이 낮다**
  (J4125에서 체감 가능). 대용량 아티팩트에서 병목이 확인되면 TUN 활성화
  (`sudo /var/packages/Tailscale/target/bin/tailscale configure-host` 후
  패키지 재시작, DSM 업데이트 후 재실행 필요할 수 있음) + tailnet IP
  바인딩으로 전환.
- MinIO 접근 로그의 소스 IP가 전부 127.0.0.1로 보인다 (인증은 key 기반이라
  무해).
- 프록시는 TCP 전용 (S3는 TCP라 무관).
- tailnet의 **모든** 장비가 프록시를 통해 도달 가능 — 현재 tailnet에 타
  사용자 장비(choco8411)가 있으므로, 신경 쓰이면 Tailscale ACL로 9000
  접근을 노드·운영 단말로 한정 (미해결 항목 "tailnet ACL 설계"의 일부).

- **핀 태그 = `RELEASE.2025-09-07T16-13-09Z`** (2026-07-18 Docker Hub 실측 —
  community 최신. `latest` 금지는 레포 전반의 핀 원칙과 동일). DS920+
  J4125에서 `illegal instruction`이 나오면 동일 버전의 `-cpuv1` 태그로 폴백.
  참고: 2025년 이후 community 이미지는 웹 콘솔 기능이 대부분 제거됨 —
  관리는 아래 `mc` CLI 기준.
- 루트 자격증명은 생성 즉시 비밀번호 관리자로. 쉘 히스토리 주의
  (platform-mlops-setup.md 4단계와 동일한 요령).
- ~~재부팅 함정(tailnet IP 바인딩 시점 의존)~~ → 루프백 바인딩으로 **해소**:
  127.0.0.1 바인딩은 Tailscale 기동 여부와 무관하게 항상 성공한다. 대신
  Tailscale 패키지가 죽으면 (MinIO는 살아 있어도) tailnet에서 접근만 안 됨
  — 트러블슈팅 표 참조.
- 공인 비노출 이중 확인: 홈 라우터에 9000/9001 포트포워딩·UPnP 없음 확인 +
  외부망(폰 LTE)에서 `http://<집 공인IP>:9000` 접속 실패 확인 + LAN IP로
  `curl http://<NAS-LAN-IP>:9000` 실패 확인(루프백 바인딩 증명). 루프백
  바인딩이 1차 방어, NAT 비노출이 2차.

### 1.2 버킷 + MLflow 전용 키 (최소 권한) — mc는 컨테이너로 (2026-07-18 정정)

루트 키를 MLflow에 주지 않는다 — 버킷 한정 전용 사용자를 만든다.

**mc 실행 방법 정정**: ~~Mac에서 brew minio-mc~~ → macOS 네이티브 mc
바이너리는 Apple M5에서 cgo SIGSEGV로 즉사한다(2026-07-18 `mc --version`
실측). **Linux 컨테이너 mc는 정상**(go1.24.6 linux/arm64 실측) — 컨테이너로
실행한다. NAS에서 실행하면 루프백 바인딩에 직결이라 프록시 의존도 없어
**권장**. Mac(OrbStack)에서 실행해도 됨 — 컨테이너→tailnet 라우팅 실측
확인, alias만 `http://100.69.142.125:9000`으로.

```bash
# NAS에서 (MinIO 기동한 SSH 세션 이어서) — 컨테이너 셸 진입
sudo docker run --rm -it --network host \
  --entrypoint /bin/sh minio/mc:RELEASE.2025-08-13T08-35-41Z
```

이하 명령은 전부 컨테이너 셸 안에서. `--rm` 일회용 셸이라 히스토리가
호스트에 남지 않으므로 시크릿을 인자로 넘겨도 잔류하지 않는다:

```bash
mc alias set nasminio http://127.0.0.1:9000 '<루트 계정>'   # secret key는 프롬프트로 입력
mc mb nasminio/mlflow-artifacts

# 버킷 한정 read/write 정책
cat > /tmp/mlflow-rw.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::mlflow-artifacts"] },
    { "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::mlflow-artifacts/*"] }
  ]
}
EOF
mc admin policy create nasminio mlflow-rw /tmp/mlflow-rw.json
mc admin user add nasminio mlflow '<MLflow 전용 secret key — 비밀번호 관리자에서 생성>'
mc admin policy attach nasminio mlflow-rw --user mlflow
exit   # 컨테이너 종료 = 셸 기록·/tmp 정책 파일 소멸
```

여기서 만든 `mlflow` / secret key 쌍이 platform-mlops-setup.md 5단계
SealedSecret의 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`다.
버전닝은 기본 비활성 유지 (MLflow가 요구하지 않고, NAS 용량만 소모).

### 1.3 클러스터에서 실측 (완료 판정)

2단계로 검증한다 — 연결성(자격증명 불필요)과 인증 접근을 분리:

```bash
# (1) 연결성: MinIO 무인증 health 엔드포인트 → HTTP 200이면 파드→tailnet 경로 성립
kubectl run s3check --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sS -o /dev/null -w "%{http_code}\n" http://<NAS tailnet IP>:9000/minio/health/live

# (2) 인증: 전용 키로 버킷 목록 (자격증명은 프롬프트 입력 — 히스토리 잔류 방지)
read -rs AK && read -rs SK
kubectl run s3auth --rm -i --restart=Never --image=amazon/aws-cli \
  --env AWS_ACCESS_KEY_ID="$AK" --env AWS_SECRET_ACCESS_KEY="$SK" -- \
  --endpoint-url http://<NAS tailnet IP>:9000 s3 ls s3://mlflow-artifacts
unset AK SK
```

**파드 안에서는 MagicDNS 이름(`nas` 등)이 해석되지 않는다** — 파드는 클러스터
DNS를 쓰고 노드의 100.100.100.100을 모른다. 그래서 매니페스트·검증 모두
tailnet **IP**를 쓴다 (IP는 고정이라 문제없음).

(1)이 200, (2)가 빈 목록(에러 없이)이면 Step 1 완료 →
platform-mlops-setup.md 4단계(mlflow_db)부터 이어서 진행.

---

## 트러블슈팅 요약

| 증상 | 원인 후보 | 조치 |
|---|---|---|
| `tailscale ping` OK, 노드 서비스 포트 접속 실패 | (기본 구성에선 미발생 — ts-input이 tailscale0 ACCEPT를 자체 관리, 2026-07-18 실측) `--netfilter-mode=off`로 바꾼 경우에만 발현 | netfilter-mode 기본값 유지, 또는 `iptables -I INPUT -i tailscale0 -j ACCEPT` |
| ping이 계속 `via DERP` (노드 경로 실측: 도쿄 DERP, Mac↔노드 ~178ms·노드↔NAS 71ms) | OCI Security List UDP 41641 인바운드 차단 | 기능상 무해. 아티팩트 벌크 전송 대역폭 위해 Security List UDP 41641 개방 권장 |
| 방식 C kubectl TLS 오류 | server를 tailnet **IP**로 지정 (SAN에 IP 없음) | `https://aporiax-instance:6443`(MagicDNS 단축명 = SAN의 호스트네임) 사용 — 0.4. IP 고정이 꼭 필요할 때만 tls-san 추가 |
| tailnet에서 NAS 9000 접속 불가 (MinIO 컨테이너는 정상) | Tailscale 패키지 중지 — userspace 프록시가 인바운드를 전달 못 함 (DSM 업데이트 후 흔함) | 패키지 센터에서 Tailscale 실행 확인. 로컬 확인: NAS에서 `curl http://127.0.0.1:9000/minio/health/live` |
| `-p <tailnet IP>:9000` 바인딩 실패 (cannot assign requested address) | TUN 부재 → userspace 모드라 100.x IP가 호스트에 없음 | 정상 — 1.1의 루프백 바인딩 구성 사용 (2026-07-18 실측 정정) |
| 파드에서 `nas:9000` 해석 실패 | MagicDNS는 파드 DNS 밖 | tailnet IP 직접 사용 (정상 동작) |
