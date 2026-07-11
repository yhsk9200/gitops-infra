# 클러스터 접근: kubeconfig 기반 kubectl 운영 가이드

이 문서는 운영 클러스터(OCI k3s)에 어떤 방식으로 접근해 운영할지에 대한 테크리드 관점의 의사결정과 절차를 정리한 것입니다. 단순 명령어 모음이 아니라, 왜 이 방식을 택했고 어떤 위험을 어떻게 통제하는지를 함께 기록합니다.

## 배경

현재 플랫폼은 ArgoCD GitOps로 선언적으로 관리됩니다. 즉 **정상 경로의 변경은 Git → ArgoCD sync**이고, kubectl은 변경 도구가 아니라 **관찰(observe)과 장애 진단(diagnose)** 도구로 사용합니다.

문제는 운영자가 클러스터 상태를 확인하려 할 때마다 매번 서버에 SSH로 들어가 `sudo kubectl`을 실행하는 방식이 비효율적이고, 다음과 같은 문제를 만든다는 점입니다.

- SSH 세션 안에서만 kubectl을 쓰므로 로컬 도구 체인(k9s, kubectx, IDE 플러그인, 스크립트)과 단절됩니다.
- 서버에 직접 들어가는 빈도가 높아질수록 노드 자체를 건드릴 위험과 휴먼 에러 표면이 커집니다.
- 작업 이력이 서버 셸 히스토리에만 남아 추적이 어렵습니다.

그래서 **kubeconfig를 운영자 로컬로 가져와 kubectl로 원격 운영**하는 방식을 채택합니다. 이 문서는 그 방식의 설계와 한계를 다룹니다.

## 핵심 원칙

- kubectl은 **읽기 우선** 도구입니다. 변경은 Git을 통합니다.
- 클러스터 API 엔드포인트를 **공인 인터넷에 직접 노출하지 않습니다.**
- kubeconfig는 **클러스터 관리자 자격증명**이므로 비밀키와 동일하게 취급합니다.
- 노드 SSH 접근과 클러스터 API 접근은 **분리된 권한**으로 다룹니다.

## 접근 모델 비교

운영자가 클러스터 API에 도달하는 경로는 크게 세 가지입니다. 각각의 트레이드오프를 정리합니다.

| 방식 | 보안 | 편의성 | 추천도 | 비고 |
| --- | --- | --- | --- | --- |
| A. API(6443) 공인 노출 | 낮음 | 높음 | 비추천 | 인터넷에 클러스터 컨트롤 플레인을 직접 노출 |
| B. SSH 터널 + 로컬 kubeconfig | 높음 | 중간 | 권장(기본) | 기존 SSH 키 재사용, 추가 인프라 불필요 |
| C. VPN/Tailscale 오버레이 | 높음 | 높음 | 권장(성숙 단계) | 별도 네트워크 계층, 다수 운영자에 유리 |

### A. API 6443 직접 노출 — 왜 피하는가

k3s API 서버는 `6443/tcp`에서 동작합니다. 이 포트를 OCI Security List/NSG와 노드 방화벽에서 열어버리면 로컬 kubectl이 바로 붙긴 합니다. 하지만:

- 컨트롤 플레인이 인터넷 스캐닝/무차별 대입의 직접 표적이 됩니다.
- k3s 기본 서버 인증서 SAN에 공인 IP가 없으면 `x509: certificate is valid for ...` 오류가 나고, 이를 우회하려고 `insecure-skip-tls-verify`를 켜면 MITM 위험이 생깁니다.
- 인증서 SAN을 맞추려면 `--tls-san <공인IP>`로 k3s를 재기동해야 하는데, 이는 노출을 정당화하는 방향의 변경이라 권장하지 않습니다.

결론: **단순함의 대가로 컨트롤 플레인을 노출하는 트레이드오프는 받아들이지 않습니다.**

### B. SSH 터널 + 로컬 kubeconfig — 기본 채택

이미 노드 SSH 접근(`144.24.81.104:22`, OCI 키)이 있으므로, **추가 인프라 없이** 가장 안전하게 시작할 수 있는 방식입니다.

핵심 아이디어: API 6443은 노드 로컬(`127.0.0.1`)에만 열어두고, SSH 로컬 포트 포워딩으로 운영자 PC의 `localhost:6443`을 노드의 `localhost:6443`에 연결합니다. kubeconfig의 `server`는 `https://127.0.0.1:6443`을 그대로 두면 인증서 SAN(`127.0.0.1`은 k3s 기본 SAN에 포함)과도 어긋나지 않습니다.

```text
[운영자 PC] kubectl → localhost:6443
        │ (SSH 암호화 터널, 포트 22)
        ▼
[k3s 노드] 127.0.0.1:6443 → kube-apiserver
```

장점:

- 6443을 인터넷에 열지 않습니다.
- 기존 SSH 키/감사 경로를 그대로 재사용합니다.
- 인증서 SAN 변경이나 k3s 재기동이 필요 없습니다.

단점:

- 작업할 때마다 터널을 띄워야 합니다(스크립트화로 완화).
- 운영자 수가 늘면 키 배포/회수 관리 부담이 커집니다 → 이때 C로 전환.

### C. VPN / Tailscale 오버레이 — 성숙 단계 전환

`known_hosts`에 `100.114.123.60`(Tailscale CGNAT 대역 `100.64.0.0/10`)이 보입니다. 이미 Tailscale 등 메시 VPN을 쓰고 있다면, 노드의 tailnet IP로 6443을 **사설 오버레이 안에서만** 노출하는 방식이 가장 깔끔합니다.

- 운영자별 디바이스 인증/ACL로 접근을 통제합니다.
- SSH 터널을 매번 띄울 필요가 없습니다.
- 6443은 여전히 공인 인터넷에는 닫혀 있습니다.

이 경우 kubeconfig의 `server`를 노드의 tailnet IP로 두고, k3s `--tls-san`에 해당 tailnet IP를 추가합니다(이것은 공인 노출이 아니므로 허용 가능한 변경입니다).

다만 운영자가 소수이고 변경 빈도가 낮은 현재 단계에서는 **B로 시작하고, 운영 인원이 늘거나 접근 빈도가 높아지면 C로 승격**하는 것을 권장합니다.

## 절차 (방식 B 기준)

### 1. 노드에서 kubeconfig 확보

k3s는 admin kubeconfig를 노드의 아래 경로에 둡니다.

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

이 파일에는 cluster CA, client cert/key가 base64로 들어 있습니다. **클러스터 전체 관리자 자격증명**이므로 평문 공유 채널(메신저/이메일)로 옮기지 않습니다.

### 2. 로컬로 안전하게 복사

```bash
# 운영자 PC에서 (SCP, 22 포트)
scp -i ~/.ssh/id_rsa -P 22 \
  ubuntu@144.24.81.104:/etc/rancher/k3s/k3s.yaml \
  ~/.kube/oci-platform.yaml
```

> k3s.yaml은 `root:root 600`인 경우가 많아 일반 사용자 SCP가 막힐 수 있습니다. 그럴 때는 노드에서 `sudo cp`로 사용자 소유 임시본을 만들고 권한을 조정한 뒤 가져오고, 복사 후 임시본을 삭제합니다.

### 3. server 주소 정리

`k3s.yaml`의 `server: https://127.0.0.1:6443`는 **그대로 둡니다.** 방식 B는 SSH 터널로 로컬 6443을 노드 6443에 연결하므로 `127.0.0.1`이 맞고, 이 값이 인증서 SAN과도 일치합니다.

여러 클러스터를 다룬다면 context/cluster/user 이름이 기본값 `default`로 충돌하므로 구분되게 바꿉니다.

```bash
# 예: 컨텍스트 이름을 oci-platform로 변경
kubectl --kubeconfig ~/.kube/oci-platform.yaml config rename-context default oci-platform
```

### 4. SSH 터널 기동

```bash
ssh -i ~/.ssh/id_rsa -p 22 -N -L 6443:127.0.0.1:6443 ubuntu@144.24.81.104
```

- `-N`: 원격 명령 없이 포트 포워딩만 수행
- `-L 6443:127.0.0.1:6443`: 로컬 6443 → 노드의 127.0.0.1:6443

별도 터미널을 점유하지 않으려면 `-f`(백그라운드)와 `-o ExitOnForwardFailure=yes`를 함께 씁니다.

### 5. 연결 검증

```bash
export KUBECONFIG=~/.kube/oci-platform.yaml
kubectl get nodes
kubectl get applications -n argocd
```

`kubectl get nodes`가 노드 1개(`aporiax-instance`)를 반환하면 정상입니다.

### 6. 서비스 UI 접속 (터널 연결 후)

ArgoCD·Prometheus·Alertmanager는 ClusterIP라 6443 터널만으로는 안 열립니다. 각 UI마다 별도 포트포워딩이 필요합니다.

```bash
# ArgoCD (https://localhost:8080, self-signed 경고 무시)
kubectl port-forward -n argocd svc/argocd-server 8080:443
# 초기 admin 비밀번호
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d

# Prometheus (http://localhost:9090)
kubectl port-forward -n platform-monitoring svc/platform-monitoring-promet-prometheus 9090:9090

# Alertmanager (http://localhost:9093)
kubectl port-forward -n platform-monitoring svc/platform-monitoring-promet-alertmanager 9093:9093
```

각 명령은 포그라운드를 점유하므로 별도 터미널(또는 `-f`로 백그라운드)에서 실행합니다. 공개 노출된 Grafana(`aporiax.duckdns.org`)·Keycloak(`aporiax-auth.duckdns.org`)·aporiax-pulse(`pulse.aporiax.duckdns.org`)는 터널 없이 바로 접속합니다 — 목록은 `README.md`의 "서비스 접속" 표 참조.

## RBAC: admin 자격증명을 그대로 쓸 것인가

`k3s.yaml`은 `cluster-admin` 권한입니다. 1인 운영 초기에는 실용적이지만, 테크리드 관점에서는 다음을 권장합니다.

- **일상 관찰용은 읽기 전용 ServiceAccount + kubeconfig**를 별도로 발급해 사용합니다(view ClusterRole 바인딩).
- **변경 권한이 필요한 작업은 ArgoCD를 경유**합니다. kubectl로 직접 apply/edit/delete 하지 않습니다.
- admin kubeconfig는 **부트스트랩과 긴급 복구(break-glass)** 용도로만 보관합니다.

읽기 전용 자격증명은 자격증명 유출 시 영향 범위를 관찰로 한정하고, "kubectl로는 못 바꾼다"는 제약 자체가 GitOps 규율을 강제합니다.

## 운영 수칙

- kubeconfig 파일은 `~/.kube/`에 `600` 권한으로 두고 Git/공유 폴더에 올리지 않습니다.
- 클러스터별 kubeconfig를 분리하고 context 이름을 명확히 합니다(실수로 다른 클러스터를 건드리는 사고 방지).
- 변경 작업은 Git PR → ArgoCD sync로 수행하고, kubectl은 진단/관찰에 한정합니다.
- 불가피한 긴급 수동 변경은 반드시 사후에 Git에 반영(reconcile)하고 문서에 남깁니다.
- 운영자 퇴장/키 분실 시 절차: 노드 SSH 키 회수 → 해당 ServiceAccount 토큰 폐기 → 필요 시 k3s 인증서 로테이션.

## 위험과 완화

| 위험 | 영향 | 완화 |
| --- | --- | --- |
| kubeconfig 유출 | 클러스터 장악 | 600 권한, 읽기 전용 SA 분리, 공유 채널 금지 |
| 6443 공인 노출 | 컨트롤 플레인 공격 표면 | SSH 터널/VPN만 허용, 6443은 노드 로컬 바인딩 |
| 잘못된 context로 변경 | 다른 환경 사고 | context 분리/명명, 읽기 전용 기본화 |
| kubectl 직접 변경으로 GitOps 드리프트 | 상태 불일치 | 변경은 Git 경유, drift는 ArgoCD가 탐지/복구 |
| SSH 키 유출 | 노드 접근 | 키 회전, fail2ban, 필요 시 비표준 포트 전환 |

## 다음 단계

- [ ] 방식 B(SSH 터널) 스크립트화: 터널 기동/종료 래퍼 작성
- [ ] 읽기 전용 ServiceAccount + kubeconfig 발급 및 배포
- [ ] admin kubeconfig는 break-glass 보관소로 격리
- [ ] 운영자 2인 이상 또는 접근 빈도 증가 시 방식 C(Tailscale/VPN) 전환 검토
- [ ] k3s `--tls-san` 정책 결정(C 전환 시 tailnet IP 추가)

## 관련 문서

- `README.md`: 전체 배포 구조와 부트스트랩
- `docs/keycloak-operations.md`: 컴포넌트 단위 kubectl 점검 예시
- `docs/platform-backup-restore-runbook.md`: 백업/복구 시 kubectl 사용 맥락
