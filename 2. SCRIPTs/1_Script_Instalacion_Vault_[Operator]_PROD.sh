#!/bin/bash

# =============================================================================
# INSTALACIÓN / DESINSTALACIÓN - VAULT HA (PRODUCCIÓN) - [OPENSHIFT OPERATOR]
# =============================================================================
# INSTALA o ELIMINA Vault en modo HA Raft (3 réplicas, TLS) en OPENSHIFT por medio de OPENSHIFT OPERATOR. 
# Todos los recursos se crean con: oc apply -f -.
#
# CARACTERÍSTICAS:
#   _ RÉPLICAS  : 3 (HA Raft integrated storage)
#   _ CPU       : request 250m  / limit 500m
#   _ MEMORIA   : request 256Mi / limit 512Mi
#   _ STORAGE   : 10Gi data + 5Gi audit por nodo (ocs-storagecluster-ceph-rbd)
#   _ TLS       : habilitado — CA + cert generados por pod transitorio ubi9
#   _ SEGURIDAD : 5 unseal keys / threshold 3, Secret K8s con credenciales
#   _ ROUTE     : passthrough HTTPS (TLS llega directo al pod)
#   _ EXTRAS    : VAULTCONNECTION + VAULTAUTH, kubernetes auth method
#
# PRERREQUISITOS:
#   1. NAMESPACE "${NAMESPACE}" existente: $ oc create namespace ${NAMESPACE}
#   2. IBM ENTITLEMENT-KEY aplicado en el NAMESPACE "${NAMESPACE}" antes de este SCRIPT:
#      $ oc create secret docker-registry ibm-entitlement-key \
#          --docker-server=cp.icr.io --docker-username=cp \
#          --docker-password=<ENTITLEMENT_KEY> -n ${NAMESPACE}
#   3. Autenticación en OPENSHIFT activa: $ oc login ...
#   4. Instalación del OPERATOR: 'VAULT-SECRET-OPERATOR' en todos los NAMESPACES.
#
# REQUERIMIENTOS DE INFRAESTRUCTURA:
#   _ CPU     : 3 nodos con al menos 250m disponibles c/u (request) / 500m (limit)
#   _ MEMORIA : 3 nodos con al menos 256Mi disponibles c/u (request) / 512Mi (limit)
#   _ STORAGE : 3 × 10Gi data + 3 × 5Gi audit = 45Gi total (ocs-storagecluster-ceph-rbd)
#   _ NODOS   : mínimo 3 workers para distribución HA RAFT
#
# USO:
#   $ sh ./1_Script_Instalacion_Vault_[Operator]_PROD.sh --modalidad=install
#   $ sh ./1_Script_Instalacion_Vault_[Operator]_PROD.sh --modalidad=delete
# =============================================================================

set -e
set -o pipefail

# Limpiar variables Vault heredadas de Windows para evitar que MSYS2
# convierta paths Unix en rutas Windows al pasarlos a oc exec.
unset VAULT_CACERT VAULT_TLSCERT VAULT_TLSKEY VAULT_ADDR VAULT_TOKEN VAULT_NAMESPACE

# =============================================================================
# ARGUMENTOS
# =============================================================================
MODALIDAD=""

for ARG in "$@"; do
  case "${ARG}" in
    --modalidad=install) MODALIDAD="install" ;;
    --modalidad=delete)  MODALIDAD="delete"  ;;
    --modalidad=*)
      echo "ERROR: Modalidad desconocida '${ARG}'."
      echo "       Usa: --modalidad=install  o  --modalidad=delete"
      exit 1
      ;;
    *)
      echo "ERROR: Argumento desconocido '${ARG}'."
      echo "       Uso: sh ./1_Script_Instalacion_Vault_[Operator]_PROD.sh --modalidad=install|delete"
      exit 1
      ;;
  esac
done

if [ -z "${MODALIDAD}" ]; then
  echo ""
  echo "ERROR: Debes indicar la modalidad de ejecución."
  echo "  sh ./1_Script_Instalacion_Vault_[Operator]_PROD.sh --modalidad=install"
  echo "  sh ./1_Script_Instalacion_Vault_[Operator]_PROD.sh --modalidad=delete"
  echo ""
  exit 1
fi

# =============================================================================
# PARÁMETROS
# =============================================================================
NAMESPACE="vault"
RELEASE_NAME="vault"

VAULT_IMAGE="registry.connect.redhat.com/hashicorp/vault:1.21.2-ubi"

STORAGE_CLASS="ocs-storagecluster-ceph-rbd"
DATA_PVC_SIZE="10Gi"
AUDIT_PVC_SIZE="5Gi"

VAULT_CPU_REQUEST="250m"
VAULT_CPU_LIMIT="500m"
VAULT_MEM_REQUEST="256Mi"
VAULT_MEM_LIMIT="512Mi"

ROUTER_DOMAIN="apps.itz-l7d2s4.infra01-lb.wdc07.techzone.ibm.com"
VAULT_ROUTE_HOST="vault-ui-${NAMESPACE}.${ROUTER_DOMAIN}"

TLS_SECRET_NAME="${RELEASE_NAME}-tls"
VSO_NAMESPACE="vault-secrets-operator-system"

# --- Utilidades ---
print_step() {
  echo ""
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
}

# limpiar_todo — elimina todos los recursos del namespace, incluidos PVCs.
# Se invoca desde --modalidad=delete y al inicio de --modalidad=install.
limpiar_todo() {
  print_step "LIMPIEZA COMPLETA — namespace: ${NAMESPACE}"

  echo "--- StatefulSet"
  oc delete statefulset "${RELEASE_NAME}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo "--- Esperando 10s para que los pods terminen..."
  sleep 10

  echo "--- Services"
  oc delete service "${RELEASE_NAME}"          -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete service "${RELEASE_NAME}-internal" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete service "${RELEASE_NAME}-active"   -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete service "${RELEASE_NAME}-standby"  -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete service "${RELEASE_NAME}-ui"       -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo "--- ConfigMap"
  oc delete configmap "${RELEASE_NAME}-config" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo "--- Secrets"
  oc delete secret "${TLS_SECRET_NAME}"               -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete secret "${RELEASE_NAME}-init-credentials" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo "--- Pods / Jobs residuales TLS"
  oc delete pods -l vault-tls-gen=true -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete jobs -l vault-tls-gen=true -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo "--- ServiceAccount y RBAC"
  oc delete serviceaccount "${RELEASE_NAME}"                          -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete clusterrolebinding "${RELEASE_NAME}-server-binding"       --ignore-not-found 2>/dev/null || true
  oc delete role        "${RELEASE_NAME}-tls-creator"                 -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete rolebinding "${RELEASE_NAME}-tls-creator"                 -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete role        "${RELEASE_NAME}-service-registration"        -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete rolebinding "${RELEASE_NAME}-service-registration"        -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete role        "${RELEASE_NAME}-init-secret-writer"          -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete rolebinding "${RELEASE_NAME}-init-secret-writer"          -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo "--- PVCs"
  oc delete pvc -l "app.kubernetes.io/name=${RELEASE_NAME}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  for i in 0 1 2; do
    oc delete pvc "data-${RELEASE_NAME}-${i}"  -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
    oc delete pvc "audit-${RELEASE_NAME}-${i}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  done

  echo "--- Route"
  oc delete route "${RELEASE_NAME}-ui" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo "--- Recursos VSO"
  oc delete vaultconnections.secrets.hashicorp.com    --all -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete vaultauths.secrets.hashicorp.com          --all -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete vaultstaticsecrets.secrets.hashicorp.com  --all -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete vaultdynamicsecrets.secrets.hashicorp.com --all -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete vaultpkisecrets.secrets.hashicorp.com     --all -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo ""
  echo "  Esperando 5s finales..."
  sleep 5
  echo "  Limpieza completada."
}

modalidad_delete() {
  limpiar_todo
  echo ""
  echo "=========================================================================="
  echo "  [FIN DE ELIMINACIÓN] Vault eliminado del NAMESPACE: '${NAMESPACE}'."
  echo "  El NAMESPACE: '${NAMESPACE}' NO fue eliminado."
  echo "=========================================================================="
}

# generate_tls — genera CA + certificado autofirmado dentro del clúster.
generate_tls() {
  print_step "PASO 3/13: GENERANDO CERTIFICADOS TLS"

  TLS_POD_NAME="${RELEASE_NAME}-tls-helper-$$"

  echo "  --> Creando RBAC temporal (SA 'default' puede crear Secrets)..."
  oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${RELEASE_NAME}-tls-creator
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create","get","patch","update","delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${RELEASE_NAME}-tls-creator
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: default
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: ${RELEASE_NAME}-tls-creator
EOF

  echo "  --> Lanzando pod TLS '${TLS_POD_NAME}'..."
  oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${TLS_POD_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    vault-tls-gen: "true"
spec:
  restartPolicy: Never
  serviceAccountName: default
  containers:
    - name: tls-gen
      image: registry.access.redhat.com/ubi9/ubi:latest
      env:
        - name: TLS_NAMESPACE
          value: "${NAMESPACE}"
        - name: TLS_SECRET
          value: "${TLS_SECRET_NAME}"
        - name: TLS_ROUTE
          value: "${VAULT_ROUTE_HOST}"
      command:
        - /bin/bash
        - -c
        - |
          set -e
          W=/tmp/tls
          NS=\$TLS_NAMESPACE
          SECRET=\$TLS_SECRET
          ROUTE=\$TLS_ROUTE
          mkdir -p \$W

          openssl genrsa -out \$W/ca.key 2048 2>/dev/null
          openssl req -new -x509 -days 3650 -key \$W/ca.key -out \$W/ca.crt \
            -subj "/CN=vault.\${NS}.svc.cluster.local/O=HashiCorpVaultCA" 2>/dev/null
          openssl genrsa -out \$W/srv.key 2048 2>/dev/null

          printf '%s\n' \
            '[req]' 'default_bits=2048' 'prompt=no' 'default_md=sha256' \
            'distinguished_name=dn' 'req_extensions=req_ext' \
            '[dn]' \
            "CN=vault.\${NS}.svc.cluster.local" 'O=HashiCorpVault' \
            '[req_ext]' 'subjectAltName=@alt_names' \
            '[alt_names]' \
            'DNS.1=vault' \
            "DNS.2=vault.\${NS}" \
            "DNS.3=vault.\${NS}.svc" \
            "DNS.4=vault.\${NS}.svc.cluster.local" \
            'DNS.5=vault-internal' \
            "DNS.6=vault-internal.\${NS}" \
            "DNS.7=vault-internal.\${NS}.svc" \
            "DNS.8=vault-internal.\${NS}.svc.cluster.local" \
            'DNS.9=vault-0.vault-internal' \
            "DNS.10=vault-0.vault-internal.\${NS}" \
            "DNS.11=vault-0.vault-internal.\${NS}.svc.cluster.local" \
            'DNS.12=vault-1.vault-internal' \
            "DNS.13=vault-1.vault-internal.\${NS}" \
            "DNS.14=vault-1.vault-internal.\${NS}.svc.cluster.local" \
            'DNS.15=vault-2.vault-internal' \
            "DNS.16=vault-2.vault-internal.\${NS}" \
            "DNS.17=vault-2.vault-internal.\${NS}.svc.cluster.local" \
            'DNS.18=vault-active' \
            "DNS.19=vault-active.\${NS}.svc.cluster.local" \
            'DNS.20=vault-standby' \
            "DNS.21=vault-standby.\${NS}.svc.cluster.local" \
            "DNS.22=\${ROUTE}" \
            'IP.1=127.0.0.1' \
            > \$W/san.cnf

          printf '%s\n' \
            'subjectAltName=@alt_names' \
            'basicConstraints=CA:FALSE' \
            'keyUsage=digitalSignature,keyEncipherment' \
            'extendedKeyUsage=serverAuth' \
            '[alt_names]' \
            'DNS.1=vault' \
            "DNS.2=vault.\${NS}" \
            "DNS.3=vault.\${NS}.svc" \
            "DNS.4=vault.\${NS}.svc.cluster.local" \
            'DNS.5=vault-internal' \
            "DNS.6=vault-internal.\${NS}" \
            "DNS.7=vault-internal.\${NS}.svc" \
            "DNS.8=vault-internal.\${NS}.svc.cluster.local" \
            'DNS.9=vault-0.vault-internal' \
            "DNS.10=vault-0.vault-internal.\${NS}" \
            "DNS.11=vault-0.vault-internal.\${NS}.svc.cluster.local" \
            'DNS.12=vault-1.vault-internal' \
            "DNS.13=vault-1.vault-internal.\${NS}" \
            "DNS.14=vault-1.vault-internal.\${NS}.svc.cluster.local" \
            'DNS.15=vault-2.vault-internal' \
            "DNS.16=vault-2.vault-internal.\${NS}" \
            "DNS.17=vault-2.vault-internal.\${NS}.svc.cluster.local" \
            'DNS.18=vault-active' \
            "DNS.19=vault-active.\${NS}.svc.cluster.local" \
            'DNS.20=vault-standby' \
            "DNS.21=vault-standby.\${NS}.svc.cluster.local" \
            "DNS.22=\${ROUTE}" \
            'IP.1=127.0.0.1' \
            > \$W/ext.cnf

          openssl req -new -key \$W/srv.key -out \$W/srv.csr \
            -config \$W/san.cnf 2>/dev/null
          openssl x509 -req -days 3650 -in \$W/srv.csr \
            -CA \$W/ca.crt -CAkey \$W/ca.key -CAcreateserial \
            -out \$W/srv.crt -extfile \$W/ext.cnf 2>/dev/null

          CA_B64=\$(base64 -w0 \$W/ca.crt)
          CRT_B64=\$(base64 -w0 \$W/srv.crt)
          KEY_B64=\$(base64 -w0 \$W/srv.key)

          TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
          CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          API=https://kubernetes.default.svc

          curl -sk -X DELETE --cacert \$CACERT \
            -H "Authorization: Bearer \$TOKEN" \
            "\$API/api/v1/namespaces/\$NS/secrets/\$SECRET" || true

          curl -sf -X POST --cacert \$CACERT \
            -H "Authorization: Bearer \$TOKEN" \
            -H "Content-Type: application/json" \
            "\$API/api/v1/namespaces/\$NS/secrets" \
            -d "{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"\$SECRET\",\"namespace\":\"\$NS\"},\"data\":{\"vault.ca\":\"\$CA_B64\",\"vault.crt\":\"\$CRT_B64\",\"vault.key\":\"\$KEY_B64\"}}" \
            && echo "SECRET_TLS_OK" || echo "SECRET_TLS_FAILED"
EOF

  echo "  --> Esperando Secret '${TLS_SECRET_NAME}' (timeout 4 min)..."
  WAIT_S=0
  until oc get secret "${TLS_SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; do
    sleep 5
    WAIT_S=$((WAIT_S + 5))
    POD_PHASE=$(oc get pod "${TLS_POD_NAME}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "${WAIT_S}" -ge 240 ]; then
      echo "  ERROR: Secret TLS no creado en 240s. Estado pod: ${POD_PHASE}"
      oc logs "${TLS_POD_NAME}" -n "${NAMESPACE}" -c tls-gen 2>/dev/null || true
      oc delete pod "${TLS_POD_NAME}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
      exit 1
    fi
    echo "  ... ${WAIT_S}s — pod: ${POD_PHASE}"
  done
  echo "  Secret '${TLS_SECRET_NAME}' creado correctamente."

  oc delete pod "${TLS_POD_NAME}"    -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete rolebinding "${RELEASE_NAME}-tls-creator" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete role        "${RELEASE_NAME}-tls-creator" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  echo "  TLS listo."
}

modalidad_install() {
  print_step "INICIO DE INSTALACIÓN — namespace: ${NAMESPACE}"

  limpiar_todo

  print_step "PASO 1/13: SERVICEACCOUNT Y CLUSTERROLEBINDING"

  oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${RELEASE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
EOF

  # system:auth-delegator: permite a VAULT validar tokens de Kubernetes (auth method)
  oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${RELEASE_NAME}-server-binding
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: ${RELEASE_NAME}
    namespace: ${NAMESPACE}
EOF

  # service-registration: Vault necesita GET/PATCH pods para registrar estado active/standby en HA
  oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${RELEASE_NAME}-service-registration
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get","list","watch","patch","update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${RELEASE_NAME}-service-registration
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
subjects:
  - kind: ServiceAccount
    name: ${RELEASE_NAME}
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: ${RELEASE_NAME}-service-registration
EOF

  # init-secret-writer: vault-0 crea el SECRET de credenciales via curl durante init
  oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${RELEASE_NAME}-init-secret-writer
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create","get","patch","update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${RELEASE_NAME}-init-secret-writer
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
subjects:
  - kind: ServiceAccount
    name: ${RELEASE_NAME}
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: ${RELEASE_NAME}-init-secret-writer
EOF

  echo "  ServiceAccount, ClusterRoleBinding y RBAC aplicados."

  generate_tls

  print_step "PASO 4/13: CONFIGMAP DE CONFIGURACIÓN VAULT"

  oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${RELEASE_NAME}-config
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
data:
  vault.hcl: |
    ui = true
    cluster_name = "${RELEASE_NAME}-ha-cluster"

    storage "raft" {
      path = "/vault/data"
      retry_join {
        leader_api_addr         = "https://${RELEASE_NAME}-0.${RELEASE_NAME}-internal:8200"
        leader_ca_cert_file     = "/vault/userconfig/${TLS_SECRET_NAME}/vault.ca"
        leader_client_cert_file = "/vault/userconfig/${TLS_SECRET_NAME}/vault.crt"
        leader_client_key_file  = "/vault/userconfig/${TLS_SECRET_NAME}/vault.key"
      }
      retry_join {
        leader_api_addr         = "https://${RELEASE_NAME}-1.${RELEASE_NAME}-internal:8200"
        leader_ca_cert_file     = "/vault/userconfig/${TLS_SECRET_NAME}/vault.ca"
        leader_client_cert_file = "/vault/userconfig/${TLS_SECRET_NAME}/vault.crt"
        leader_client_key_file  = "/vault/userconfig/${TLS_SECRET_NAME}/vault.key"
      }
      retry_join {
        leader_api_addr         = "https://${RELEASE_NAME}-2.${RELEASE_NAME}-internal:8200"
        leader_ca_cert_file     = "/vault/userconfig/${TLS_SECRET_NAME}/vault.ca"
        leader_client_cert_file = "/vault/userconfig/${TLS_SECRET_NAME}/vault.crt"
        leader_client_key_file  = "/vault/userconfig/${TLS_SECRET_NAME}/vault.key"
      }
    }

    listener "tcp" {
      address         = "[::]:8200"
      cluster_address = "[::]:8201"
      tls_cert_file   = "/vault/userconfig/${TLS_SECRET_NAME}/vault.crt"
      tls_key_file    = "/vault/userconfig/${TLS_SECRET_NAME}/vault.key"
      tls_min_version = "tls12"
    }

    service_registration "kubernetes" {}
    disable_mlock = true
EOF

  echo "  ConfigMap aplicado."

  print_step "PASO 5/13: SERVICES (headless, ClusterIP, active, standby, ui)"

  oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${RELEASE_NAME}-internal
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
  annotations:
    service.alpha.kubernetes.io/tolerate-unready-endpoints: "true"
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  ports:
    - name: https
      port: 8200
      targetPort: 8200
    - name: https-internal
      port: 8201
      targetPort: 8201
  selector:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
    component: server
EOF

  oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${RELEASE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
spec:
  ports:
    - name: https
      port: 8200
      targetPort: 8200
    - name: https-internal
      port: 8201
      targetPort: 8201
  selector:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
    component: server
EOF

  oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${RELEASE_NAME}-active
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
spec:
  ports:
    - name: https
      port: 8200
      targetPort: 8200
    - name: https-internal
      port: 8201
      targetPort: 8201
  selector:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
    component: server
    vault-active: "true"
EOF

  oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${RELEASE_NAME}-standby
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
spec:
  ports:
    - name: https
      port: 8200
      targetPort: 8200
    - name: https-internal
      port: 8201
      targetPort: 8201
  selector:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
    component: server
    vault-active: "false"
EOF

  oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${RELEASE_NAME}-ui
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
spec:
  ports:
    - name: https
      port: 8200
      targetPort: 8200
  selector:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
    component: server
EOF

  echo "  Todos los SERVICES aplicados."

  print_step "PASO 6/13: STATEFULSET VAULT (3 réplicas, HA Raft, TLS)"

  oc apply -f - <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${RELEASE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
spec:
  serviceName: ${RELEASE_NAME}-internal
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: ${RELEASE_NAME}
      app.kubernetes.io/instance: ${RELEASE_NAME}
      component: server
  podManagementPolicy: Parallel
  updateStrategy:
    type: OnDelete
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${RELEASE_NAME}
        app.kubernetes.io/instance: ${RELEASE_NAME}
        component: server
    spec:
      serviceAccountName: ${RELEASE_NAME}
      terminationGracePeriodSeconds: 10
      volumes:
        - name: config
          configMap:
            name: ${RELEASE_NAME}-config
        - name: ${RELEASE_NAME}-tls
          secret:
            secretName: ${TLS_SECRET_NAME}
        - name: home
          emptyDir: {}
      containers:
        - name: ${RELEASE_NAME}
          image: ${VAULT_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - "/bin/sh"
            - "-ec"
          args:
            - |
              cp /vault/config/vault.hcl /tmp/vault.hcl
              exec vault server -config=/tmp/vault.hcl
          ports:
            - containerPort: 8200
              name: https
              protocol: TCP
            - containerPort: 8201
              name: https-internal
              protocol: TCP
            - containerPort: 8202
              name: https-rep
              protocol: TCP
          env:
            - name: HOST_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: VAULT_K8S_POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: VAULT_K8S_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: VAULT_ADDR
              value: "https://127.0.0.1:8200"
            - name: VAULT_API_ADDR
              value: "https://\$(POD_IP):8200"
            - name: VAULT_CLUSTER_ADDR
              value: "https://\$(VAULT_K8S_POD_NAME).${RELEASE_NAME}-internal:8201"
            - name: VAULT_RAFT_NODE_ID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: VAULT_CACERT
              value: "/vault/userconfig/${TLS_SECRET_NAME}/vault.ca"
            - name: VAULT_TLSCERT
              value: "/vault/userconfig/${TLS_SECRET_NAME}/vault.crt"
            - name: VAULT_TLSKEY
              value: "/vault/userconfig/${TLS_SECRET_NAME}/vault.key"
            - name: SKIP_CHOWN
              value: "true"
            - name: SKIP_SETCAP
              value: "true"
            - name: HOME
              value: "/home/vault"
          volumeMounts:
            - name: config
              mountPath: /vault/config
            - name: ${RELEASE_NAME}-tls
              mountPath: /vault/userconfig/${TLS_SECRET_NAME}
              readOnly: true
            - name: data
              mountPath: /vault/data
            - name: audit
              mountPath: /vault/audit
            - name: home
              mountPath: /home/vault
          readinessProbe:
            httpGet:
              path: /v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204
              port: 8200
              scheme: HTTPS
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
            successThreshold: 1
          lifecycle:
            preStop:
              exec:
                command:
                  - "/bin/sh"
                  - "-c"
                  - "sleep 5 && kill -SIGTERM \$(pidof vault)"
          resources:
            requests:
              cpu: "${VAULT_CPU_REQUEST}"
              memory: "${VAULT_MEM_REQUEST}"
            limits:
              cpu: "${VAULT_CPU_LIMIT}"
              memory: "${VAULT_MEM_LIMIT}"
  volumeClaimTemplates:
    - metadata:
        name: data
        labels:
          app.kubernetes.io/name: ${RELEASE_NAME}
          app.kubernetes.io/instance: ${RELEASE_NAME}
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: ${STORAGE_CLASS}
        resources:
          requests:
            storage: ${DATA_PVC_SIZE}
    - metadata:
        name: audit
        labels:
          app.kubernetes.io/name: ${RELEASE_NAME}
          app.kubernetes.io/instance: ${RELEASE_NAME}
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: ${STORAGE_CLASS}
        resources:
          requests:
            storage: ${AUDIT_PVC_SIZE}
EOF

  echo "  StatefulSet aplicado."

  print_step "PASO 7/13: ROUTE OPENSHIFT (reencrypt TLS)"

  # reencrypt: el router OCP termina TLS con su wildcard cert (confianza del browser)
  # y re-encripta al pod usando el CA autofirmado del secret vault-tls.
  # Se extrae el CA del Secret para incluirlo como destinationCACertificate.
  VAULT_DEST_CA=$(oc get secret "${TLS_SECRET_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.data.vault\.ca}' | base64 -d 2>/dev/null)

  oc apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${RELEASE_NAME}-ui
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
spec:
  host: ${VAULT_ROUTE_HOST}
  port:
    targetPort: https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
    destinationCACertificate: |
$(echo "${VAULT_DEST_CA}" | sed 's/^/      /')
  to:
    kind: Service
    name: ${RELEASE_NAME}-ui
    weight: 100
  wildcardPolicy: None
EOF

  echo "  Route aplicada (reencrypt — TLS del router OCP hacia el browser, re-cifrado hacia el pod)."

  # Los pods arrancan SEALED (readinessProbe falla → 0/1 Running).
  # Se espera que el proceso vault responda antes de ejecutar el init.
  print_step "PASO 8/13: ESPERANDO PODS Running"

  echo "  Esperando 45s iniciales..."
  sleep 45

  echo "  Verificando que ${RELEASE_NAME}-0 responda (timeout 2 min)..."
  WAIT_SECS=0
  MAX_WAIT=120
  until oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
        vault status -tls-skip-verify >/dev/null 2>&1 \
     || oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
        vault status -tls-skip-verify 2>&1 | grep -qE "Sealed|Initialized"; do
    if [ "${WAIT_SECS}" -ge "${MAX_WAIT}" ]; then
      echo "  ADVERTENCIA: ${RELEASE_NAME}-0 no respondió en ${MAX_WAIT}s. Continuando..."
      break
    fi
    echo "  ... ${RELEASE_NAME}-0 no responde, reintentando en 10s (${WAIT_SECS}/${MAX_WAIT}s)"
    sleep 10
    WAIT_SECS=$((WAIT_SECS + 10))
  done

  echo ""
  echo "  Estado actual de los PODs:"
  oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/name="${RELEASE_NAME}"

  print_step "PASO 9/13: INVENTARIO DE RECURSOS"
  oc get pods,svc,pvc,configmap,route \
    -n "${NAMESPACE}" \
    -l app.kubernetes.io/name="${RELEASE_NAME}" 2>&1 || true

  # oc exec ... > INIT_FILE (redirección a disco, nunca a $()).
  # Capturar JSON grande en $() mata el proceso en Git Bash/Windows. 
  print_step "PASO 10/13: INICIALIZACIÓN DE VAULT"

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && { pwd -W 2>/dev/null || pwd; })"
  INIT_FILE="${SCRIPT_DIR}/${RELEASE_NAME}-init-$(date +%Y%m%d%H%M%S).json"

  INIT_STATUS=$(oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
    vault status -tls-skip-verify 2>/dev/null \
    | grep "^Initialized" | awk '{print $2}' || echo "unknown")

  if [ "${INIT_STATUS}" = "true" ]; then
    # Vault ya inicializado: leer credenciales del Secret existente
    echo "  Vault ya inicializado. Leyendo credenciales del Secret existente..."
    SKIP_INIT=true
  else
    SKIP_INIT=false
    echo "  Vault no inicializado. Ejecutando VAULT OPERATOR INIT..."
    echo "  (Guardando JSON en: ${INIT_FILE})"

    oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
      vault operator init -key-shares=5 -key-threshold=3 -tls-skip-verify \
      -format=json > "${INIT_FILE}" 2>/dev/null

    if [ ! -s "${INIT_FILE}" ]; then
      echo "  ERROR: El archivo de init quedó vacío (${INIT_FILE})."
      echo "  Revisa los LOGs: oc logs ${RELEASE_NAME}-0 -n ${NAMESPACE}"
      exit 1
    fi
    echo "  Init completado. JSON guardado en: ${INIT_FILE}"
    echo "  *** CUSTODIAR — contiene todas las unseal keys y el root token ***"
  fi

  if [ "${SKIP_INIT}" = "false" ] && [ -s "${INIT_FILE}" ]; then
    UNSEAL_KEY_1=$(grep -o '"[A-Za-z0-9+/=]\{44,\}"' "${INIT_FILE}" | sed 's/"//g' | sed -n '1p')
    UNSEAL_KEY_2=$(grep -o '"[A-Za-z0-9+/=]\{44,\}"' "${INIT_FILE}" | sed 's/"//g' | sed -n '2p')
    UNSEAL_KEY_3=$(grep -o '"[A-Za-z0-9+/=]\{44,\}"' "${INIT_FILE}" | sed 's/"//g' | sed -n '3p')
    UNSEAL_KEY_4=$(grep -o '"[A-Za-z0-9+/=]\{44,\}"' "${INIT_FILE}" | sed 's/"//g' | sed -n '4p')
    UNSEAL_KEY_5=$(grep -o '"[A-Za-z0-9+/=]\{44,\}"' "${INIT_FILE}" | sed 's/"//g' | sed -n '5p')
    ROOT_TOKEN=$(grep -o '"hvs\.[A-Za-z0-9.]*"' "${INIT_FILE}" | head -1 | sed 's/"//g')

    echo "  Keys extraídas:"
    echo "    Key 1: ${UNSEAL_KEY_1:0:8}...   Root token: ${ROOT_TOKEN:0:12}..."

    K1B=$(printf '%s' "${UNSEAL_KEY_1}" | base64 -w0 2>/dev/null || printf '%s' "${UNSEAL_KEY_1}" | base64)
    K2B=$(printf '%s' "${UNSEAL_KEY_2}" | base64 -w0 2>/dev/null || printf '%s' "${UNSEAL_KEY_2}" | base64)
    K3B=$(printf '%s' "${UNSEAL_KEY_3}" | base64 -w0 2>/dev/null || printf '%s' "${UNSEAL_KEY_3}" | base64)
    K4B=$(printf '%s' "${UNSEAL_KEY_4}" | base64 -w0 2>/dev/null || printf '%s' "${UNSEAL_KEY_4}" | base64)
    K5B=$(printf '%s' "${UNSEAL_KEY_5}" | base64 -w0 2>/dev/null || printf '%s' "${UNSEAL_KEY_5}" | base64)
    RTB=$(printf '%s' "${ROOT_TOKEN}"   | base64 -w0 2>/dev/null || printf '%s' "${ROOT_TOKEN}"   | base64)

    oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- sh -c "
      TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
      CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      curl -sf -X DELETE --cacert \$CACERT -H \"Authorization: Bearer \$TOKEN\" \
        'https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/secrets/${RELEASE_NAME}-init-credentials' \
        >/dev/null 2>&1 || true
      curl -sf -X POST --cacert \$CACERT \
        -H \"Authorization: Bearer \$TOKEN\" \
        -H 'Content-Type: application/json' \
        'https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/secrets' \
        -d '{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"${RELEASE_NAME}-init-credentials\",\"namespace\":\"${NAMESPACE}\"},\"data\":{\"unseal-key-1\":\"${K1B}\",\"unseal-key-2\":\"${K2B}\",\"unseal-key-3\":\"${K3B}\",\"unseal-key-4\":\"${K4B}\",\"unseal-key-5\":\"${K5B}\",\"root-token\":\"${RTB}\"}}' \
        && echo 'CREDENTIALS_SAVED' || echo 'CREDENTIALS_SAVE_FAILED'
    " 2>/dev/null

    echo "  Credenciales guardadas en Secret '${RELEASE_NAME}-init-credentials'."

  elif [ "${SKIP_INIT}" = "true" ]; then
    UNSEAL_KEY_1=$(oc get secret "${RELEASE_NAME}-init-credentials" -n "${NAMESPACE}" \
      -o jsonpath='{.data.unseal-key-1}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    UNSEAL_KEY_2=$(oc get secret "${RELEASE_NAME}-init-credentials" -n "${NAMESPACE}" \
      -o jsonpath='{.data.unseal-key-2}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    UNSEAL_KEY_3=$(oc get secret "${RELEASE_NAME}-init-credentials" -n "${NAMESPACE}" \
      -o jsonpath='{.data.unseal-key-3}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    UNSEAL_KEY_4=$(oc get secret "${RELEASE_NAME}-init-credentials" -n "${NAMESPACE}" \
      -o jsonpath='{.data.unseal-key-4}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    UNSEAL_KEY_5=$(oc get secret "${RELEASE_NAME}-init-credentials" -n "${NAMESPACE}" \
      -o jsonpath='{.data.unseal-key-5}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    ROOT_TOKEN=$(oc get secret "${RELEASE_NAME}-init-credentials" -n "${NAMESPACE}" \
      -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  fi

  # Root token inválido: regenerar con generate-root (cada oc exec devuelve
  # salida pequeña — seguro capturar con $() en Git Bash).
  if echo "${ROOT_TOKEN}" | grep -qE '^hvs\.[A-Za-z0-9]{10,}'; then
    echo "  Root token válido (${#ROOT_TOKEN} chars)."
  else
    echo "  ADVERTENCIA: root-token no válido. Regenerando con generate-root..."

    oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
      vault operator generate-root -cancel -tls-skip-verify >/dev/null 2>&1 || true

    GR_INIT=$(oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
      vault operator generate-root -init -tls-skip-verify 2>/dev/null)
    GR_NONCE=$(echo "${GR_INIT}" | grep '^Nonce' | awk '{print $2}' | tr -d '\r')
    GR_OTP=$(echo   "${GR_INIT}" | grep '^OTP '  | awk '{print $2}' | tr -d '\r')

    oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
      vault operator generate-root -tls-skip-verify \
      -nonce="${GR_NONCE}" "${UNSEAL_KEY_1}" >/dev/null 2>&1 || true
    oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
      vault operator generate-root -tls-skip-verify \
      -nonce="${GR_NONCE}" "${UNSEAL_KEY_2}" >/dev/null 2>&1 || true

    GR_R3=$(oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
      vault operator generate-root -tls-skip-verify \
      -nonce="${GR_NONCE}" "${UNSEAL_KEY_3}" 2>/dev/null)
    GR_ENCODED=$(echo "${GR_R3}" | grep '^Encoded Token' | awk '{print $3}' | tr -d '\r')

    ROOT_TOKEN=$(oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
      vault operator generate-root -tls-skip-verify \
      -otp="${GR_OTP}" -decode="${GR_ENCODED}" 2>/dev/null | tr -d '\r\n ')

    if [ -z "${ROOT_TOKEN}" ] || [ "${#ROOT_TOKEN}" -lt 20 ]; then
      echo "  ERROR CRÍTICO: no se pudo regenerar el root token (len=${#ROOT_TOKEN})."
      exit 1
    fi
    echo "  Root token regenerado: ${ROOT_TOKEN:0:12}... (${#ROOT_TOKEN} chars)"

    RTB=$(printf '%s' "${ROOT_TOKEN}" | base64 -w0 2>/dev/null || printf '%s' "${ROOT_TOKEN}" | base64)
    oc patch secret "${RELEASE_NAME}-init-credentials" -n "${NAMESPACE}" \
      --type='merge' -p="{\"data\":{\"root-token\":\"${RTB}\"}}" 2>/dev/null \
      && echo "  Secret actualizado." \
      || echo "  ADVERTENCIA: no se pudo actualizar el Secret (el token sigue siendo válido)."
  fi

  print_step "PASO 11/13: UNSEAL AUTOMÁTICO DE LOS 3 PODS"

  if [ "${SKIP_INIT}" = "true" ]; then
    echo "  Sin credenciales. Unseal manual:"
    echo "    oc exec -it ${RELEASE_NAME}-0 -n ${NAMESPACE} -- vault operator unseal -tls-skip-verify <KEY>"
  else
    echo "  Esperando 15s para que los pods estén disponibles..."
    sleep 15

    for POD in "${RELEASE_NAME}-0" "${RELEASE_NAME}-1" "${RELEASE_NAME}-2"; do
      echo ""
      echo "  --> Unseal de ${POD}..."
      POD_PHASE=$(oc get pod "${POD}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
      if [ "${POD_PHASE}" != "Running" ]; then
        echo "  ADVERTENCIA: ${POD} en estado '${POD_PHASE}'. Esperando 20s..."
        sleep 20
      fi
      oc exec "${POD}" -n "${NAMESPACE}" -- \
        vault operator unseal -tls-skip-verify "${UNSEAL_KEY_1}" >/dev/null 2>&1 \
        && echo "    Key 1 OK" || echo "    Key 1 ADVERTENCIA"
      oc exec "${POD}" -n "${NAMESPACE}" -- \
        vault operator unseal -tls-skip-verify "${UNSEAL_KEY_2}" >/dev/null 2>&1 \
        && echo "    Key 2 OK" || echo "    Key 2 ADVERTENCIA"
      oc exec "${POD}" -n "${NAMESPACE}" -- \
        vault operator unseal -tls-skip-verify "${UNSEAL_KEY_3}" >/dev/null 2>&1 \
        && echo "    Key 3 OK" || echo "    Key 3 ADVERTENCIA"
      echo "  ${POD}: unseal completado (3/5 keys)."
    done

    echo ""
    echo "  Esperando 10s para que RAFT elija líder..."
    sleep 10
    echo "  Estado de los pods:"
    oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/name="${RELEASE_NAME}"
  fi

  print_step "PASO 12/13: KUBERNETES AUTH METHOD + POLÍTICA VSO + ROL"

  if [ "${SKIP_INIT}" = "true" ]; then
    echo "  Sin credenciales. Configura kubernetes auth manualmente."
  else
    oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- sh -c "
      export VAULT_ADDR=https://127.0.0.1:8200

      vault login -tls-skip-verify '${ROOT_TOKEN}' >/dev/null

      vault secrets enable -path=secret kv-v2 2>/dev/null || true

      vault auth enable kubernetes 2>/dev/null || true

      vault write auth/kubernetes/config \
        kubernetes_host=https://kubernetes.default.svc:443

      vault policy write vault-vso-policy - << 'POLICY'
path \"secret/*\" { capabilities = [\"read\", \"list\"] }
path \"secret/data/*\" { capabilities = [\"read\", \"list\"] }
path \"sys/mounts\" { capabilities = [\"read\"] }
POLICY

      vault write auth/kubernetes/role/vault-default-role \
        bound_service_account_names='${RELEASE_NAME},default,vault-secrets-operator-controller-manager' \
        bound_service_account_namespaces='${NAMESPACE},${VSO_NAMESPACE}' \
        policies=vault-vso-policy \
        ttl=24h

      echo 'Kubernetes auth, secrets engine y rol configurados.'
    " && echo "  Kubernetes auth habilitado." || \
      echo "  ADVERTENCIA: error al configurar kubernetes auth."
  fi

  # VaultConnection + VaultAuth visibles en: Operadores → Vault Secrets Operator → Instancias
  print_step "PASO 13/13: RECURSOS VSO (VaultConnection + VaultAuth)"

  oc apply -f - <<EOF
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: ${RELEASE_NAME}-default
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
spec:
  address: https://${RELEASE_NAME}.${NAMESPACE}.svc.cluster.local:8200
  skipTLSVerify: true
EOF

  oc apply -f - <<EOF
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: ${RELEASE_NAME}-default
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
spec:
  vaultConnectionRef: ${RELEASE_NAME}-default
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: ${RELEASE_NAME}-default-role
    serviceAccount: ${RELEASE_NAME}
    audiences:
      - vault
EOF

  echo "  Esperando 8s para que VSO reconcilie..."
  sleep 8
  oc get vaultconnection,vaultauth -n "${NAMESPACE}" 2>/dev/null || true

  # ==========================================================================
  # RESUMEN FINAL
  # ==========================================================================
  VAULT_ROUTE=$(oc get route "${RELEASE_NAME}-ui" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "${VAULT_ROUTE_HOST}")

  VS_INITIALIZED=$(oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
    vault status -tls-skip-verify 2>/dev/null | grep "^Initialized" | awk '{print $2}' || echo "?")
  VS_SEALED=$(oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
    vault status -tls-skip-verify 2>/dev/null | grep "^Sealed" | awk '{print $2}' || echo "?")
  VS_HA_MODE=$(oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
    vault status -tls-skip-verify 2>/dev/null | grep "^HA Mode" | awk '{print $3}' || echo "?")
  VS_VERSION=$(oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
    vault status -tls-skip-verify 2>/dev/null | grep "^Version" | awk '{print $2}' || echo "?")

  RAFT_PEERS=$(oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
    vault operator raft list-peers -tls-skip-verify 2>/dev/null \
    | grep -E "leader|follower" | awk '{print $1"("$3")"}' | tr '\n' '  ' || echo "?")

  POD_STATUS=$(oc get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name="${RELEASE_NAME}" \
    --no-headers 2>/dev/null | awk '{print $1": "$2}' | tr '\n' '  ' || echo "?")

  echo ""
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║                                                                      ║"
  echo "║        INSTALACIÓN COMPLETADA - VAULT HA  (NAMESPACE: ${NAMESPACE})  ║"
  echo "║                                                                      ║"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  ┌─ CLUSTER ──────────────────────────────────────────────────────────┐"
  echo "  │  _ NAMESPACE   : ${NAMESPACE}"
  echo "  │  _ MODO        : HA Raft (3 nodos) | TLS | Sin Helm"
  echo "  │  _ IMAGEN      : ${VAULT_IMAGE}"
  echo "  │  _ STORAGE     : 3 × data-${DATA_PVC_SIZE} + 3 × audit-${AUDIT_PVC_SIZE} (ceph-rbd)"
  echo "  │  _ VERSIÓN     : ${VS_VERSION}"
  echo "  │  _ INITIALIZED : ${VS_INITIALIZED}   Sealed: ${VS_SEALED}   HA Mode: ${VS_HA_MODE}"
  echo "  │  _ RAFT PEERS  : ${RAFT_PEERS}"
  echo "  │  _ PODS        : ${POD_STATUS}"
  echo "  └────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  ┌─ ACCESO UI ────────────────────────────────────────────────────────┐"
  echo "  │                                                                    │"
  echo "  │   https://${VAULT_ROUTE}/ui"
  echo "  │                                                                    │"
  echo "  │   MÉTODO DE LOGIN : Token                                          │"
  echo "  └────────────────────────────────────────────────────────────────────┘"
  echo ""

  if [ "${SKIP_INIT}" = "false" ]; then
    echo "  ┌─ ROOT TOKEN ── ⚠  COPIAR AHORA — NO SE VUELVE A MOSTRAR  ⚠ ───┐"
    echo "  │                                                                 │"
    echo "  │   ${ROOT_TOKEN}"
    echo "  │                                                                 │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  ┌─ UNSEAL KEYS ── ⚠  GUARDAR EN LUGAR SEGURO  ⚠ ────────────────┐"
    echo "  │  _ KEY 1 : ${UNSEAL_KEY_1}"
    echo "  │  _ KEY 2 : ${UNSEAL_KEY_2}"
    echo "  │  _ KEY 3 : ${UNSEAL_KEY_3}"
    echo "  │  _ KEY 4 : ${UNSEAL_KEY_4}"
    echo "  │  _ KEY 5 : ${UNSEAL_KEY_5}"
    echo "  └────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  ┌─ ARCHIVO DE CLAVES (DISCO LOCAL) ──────────────────────────────────┐"
    echo "  │  ${INIT_FILE}"
    echo "  │  ⚠  Eliminar tras custodiar en un KMS/HSM:  rm \"${INIT_FILE}\""
    echo "  └────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  ┌─ SECRET EN OPENSHIFT ───────────────────────────────────────────────┐"
    echo "  │  $ oc get secret ${RELEASE_NAME}-init-credentials -n ${NAMESPACE} -o yaml"
    echo "  │  ⚠  Eliminar tras custodiar:"
    echo "  │  $ oc delete secret ${RELEASE_NAME}-init-credentials -n ${NAMESPACE}"
    echo "  └────────────────────────────────────────────────────────────────────┘"
  fi

  echo ""
  echo "  ┌─ USO — VAULT SECRETS OPERATOR ─────────────────────────────────────┐"
  echo "  │  VaultConnection : ${RELEASE_NAME}-default"
  echo "  │    ADDRESS       : https://${RELEASE_NAME}.${NAMESPACE}.svc.cluster.local:8200"
  echo "  │  VaultAuth       : ${RELEASE_NAME}-default"
  echo "  │    METHOD        : kubernetes  |  role: vault-default-role"
  echo "  │  Visibles en     : Operadores → Vault Secrets Operator → Instancias"
  echo "  └────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  ┌─ ACCESO INTERNO ───────────────────────────────────────────────────┐"
  echo "  │  https://${RELEASE_NAME}.${NAMESPACE}.svc.cluster.local:8200"
  echo "  └────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║  FIN DE INSTALACIÓN - VAULT HA (NAMESPACE: ${NAMESPACE})             ║"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
  echo ""
}

case "${MODALIDAD}" in
  install) modalidad_install ;;
  delete)  modalidad_delete  ;;
esac
