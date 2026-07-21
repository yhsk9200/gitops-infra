# ADR-0002: 클러스터 토폴로지 — 단일 노드 채택

## 상태

승인됨

## 날짜

2026-06-09

## 개정 (2026-06-14)

> 본 ADR은 Always Free **4 OCPU / 24GB**를 전제로 작성되었으나, 이후 OCI가 Always Free A1 할당을 **2 OCPU / 12GB로 축소**했다. 단일 노드 채택이라는 본 결정의 본질(아래 근거 1~5)은 그대로 유효하지만, 자원 전제와 그 위 워크로드 배치는 **[ADR-0004](0004-refit-platform-for-12gb-free-tier.md)** 로 갱신되었다. 아래 본문의 24GB 수치는 작성 시점의 역사적 기록으로 둔다.

## 맥락

개인 포트폴리오 겸 학습용으로 OCI Always Free Ampere A1 자원(총 4 OCPU / 24GB RAM, 최대 4 인스턴스까지 분할 가능)에 이 `platform-infra` GitOps 스택을 새로 구축한다.

초기에는 "클러스터를 운영한다"는 모습을 보이려고 24GB를 **12GB × 2 노드로 분할**해 두었다. 그러나 실제로 k3s 클러스터를 부트스트랩하기 전에 이 2노드 구성이 비용 대비 어떤 가치를 주는지 재검토할 필요가 생겼다.

배포 대상 스택은 가볍지 않다.

- kube-prometheus-stack (Prometheus 단독으로도 수 GB)
- Loki / Alloy
- Harbor (core, registry, jobservice, portal, trivy, redis 등 다수 Pod)
- Keycloak (JVM)
- PostgreSQL, Redis
- ArgoCD, Sealed Secrets, cert-manager

정상 운영 시 약 8~12GB RAM을 사용하며, 24GB 총량 기준으로는 빡빡한 편이다.

또한 스토리지는 `platform-infra-storage`의 `local-path` provisioner를 사용한다. local-path PV는 **생성된 노드에 고정**되며 다른 노드로 따라가지 않는다.

## 결정

24GB를 단일 4 OCPU / 24GB k3s 노드로 합쳐 운영한다. 멀티노드 클러스터는 지금 도입하지 않고, 아래 "재검토 조건"이 충족될 때 별도로 설계한다.

## 근거

### 1. 2노드는 HA가 아니다

k3s의 임베디드 etcd HA는 쿼럼을 위해 홀수 **3노드**가 필요하다. 2노드 구성은 `1 서버 + 1 에이전트`이며 컨트롤 플레인이 단일 장애점으로 남는다. 노드를 2개로 늘려 운영 표면과 오버헤드는 키우지만 가용성 이득은 없다.

### 2. local-path 스토리지에서 stateful 워크로드는 이동성이 없다

PostgreSQL, Keycloak, Harbor 등 핵심 stateful 서비스는 단일 레플리카이고 PV가 local-path로 노드에 고정된다. 노드가 죽으면 볼륨이 없는 다른 노드로 Pod를 재스케줄할 수 없다. 즉 2노드여도 stateful 핵심의 복원력은 0이며, "Pod는 자기 PV가 있는 노드에만 떠야 한다"는 스케줄링 제약만 추가된다.

### 3. 2 × 12GB는 양쪽의 단점만 가진다

- OS + k3s 중복 오버헤드(서버 + 에이전트 각각의 OS·런타임)로 약 1.5GB를 추가로 잃는다.
- 가용 RAM이 노드당 약 10.5GB로 분절되어, Prometheus처럼 큰 단일 Pod 수용 여유가 줄어든다.
- 그 대가로 얻는 HA·stateful 복원력은 위 1·2에 따라 사실상 없다.

결과적으로 현재 2노드 구성은 오버헤드·분절·스케줄링 제약을 떠안으면서 가용성 이득이 없는 half-measure다.

### 4. 무거운 스택은 통합된 RAM이 유리하다

단일 24GB 노드는 워크로드 가용 RAM이 약 22.5GB로 통합되어 분절이 없고, 큰 Pod 스케줄링과 버스트 여유가 더 크다. 이 스택의 무게를 고려하면 자원을 한 노드에 모으는 편이 운영적으로 안전하다.

### 5. 이 프로젝트의 초점은 노드 수가 아니라 플랫폼 운영에 있다

이 저장소의 실질 자산은 GitOps App of Apps 설계, ArgoCD sync wave, observability 스택, IAM(Keycloak), 레지스트리(Harbor), Sealed Secrets, 백업 런북 등 **플랫폼 엔지니어링**이다. 노드 1개냐 2개냐는 여기에 거의 기여하지 않으며, 오히려 "HA도 아닌데 왜 실패 표면을 2배로 늘렸나"라는 안티패턴 지적을 받을 수 있다. 토폴로지 결정의 근거를 ADR로 남기는 것이 노드 수를 늘리는 것보다 역량을 더 잘 보여준다.

## 재검토 조건 (멀티노드 / HA로 전환)

아래가 충족되면 멀티노드를 *제대로* 설계해 전환한다. 단순히 노드를 2개로 쪼개는 방식으로는 돌아가지 않는다.

- **3노드 이상** — etcd 쿼럼을 만족하는 HA 컨트롤 플레인
- **복제 가능한 스토리지** — Longhorn 등으로 PV를 노드 간 복제(local-path 탈피)
- **stateful 복제** — PostgreSQL/Keycloak 등의 다중 레플리카 또는 외부 관리형 DB
- 위를 수용할 노드당 자원(현재 Always Free 24GB를 3노드로 쪼개면 노드당 8GB라 이 스택에는 부족 → 자원 증설 또는 스택 경량화 선행 필요)

k3s는 단일 서버에서 시작한 뒤 에이전트 노드를 명령 한 줄로 합류시킬 수 있으므로, 이 결정은 비가역이 아니다.

## 결과

- OCI 인스턴스를 4 OCPU / 24GB 단일 인스턴스로 재구성한다(콘솔 작업).
- k3s를 단일 서버 노드로 설치하고, ArgoCD → Sealed Secrets → Root App 순으로 부트스트랩한다.
- `README.md`와 `CLAUDE.md`의 클러스터 환경 정보(이전 2-node 구성 기준)를 새 단일 노드 정보로 갱신한다.
- 접근은 `docs/cluster-access-kubeconfig.md`의 방식 B(SSH 터널 + 로컬 kubeconfig)를 유지하되, 호스트/포트를 새 노드 값으로 갱신한다.

## 비목표

이 ADR은 아래를 결정하지 않는다.

- 멀티노드/HA 전환의 최종 시점
- 복제 스토리지 제품 확정(Longhorn 외 후보 포함)
- stateful 서비스의 HA 방식(앱 레벨 복제 vs 외부 관리형)
- 노드 OS 하드닝, SSH 포트 비표준화 등 보안 강화 항목(별도 진행)

## 미해결 질문

- 단일 노드의 정기 백업/복구 주기는 `docs/platform-backup-restore-runbook.md` 정책으로 충분한가?
- ~~무거운 스택을 단일 노드에서 안정 운영하려면 일부 컴포넌트(예: Trivy 스캔, retention)를 경량화해야 하는가?~~ → [ADR-0004](0004-refit-platform-for-12gb-free-tier.md)에서 결정됨 (Trivy 비활성화, Prometheus retention 5d, 로그 스택 on-demand).
- 향후 AI 시뮬레이터 플랫폼(ADR-0001) 도입 시 단일 노드 자원으로 MinIO/MLflow까지 수용 가능한가, 별도 노드/저장소가 필요한가?
