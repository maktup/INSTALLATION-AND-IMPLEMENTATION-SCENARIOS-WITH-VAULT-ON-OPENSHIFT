#!/bin/bash

# =============================================================================
# INSTALACIÓN / DESINSTALACIÓN - VAULT DEV (DESARROLLO) - [OPENSHIFT OPERATOR]
# =============================================================================
# INSTALA o ELIMINA Vault en modo single-node (1 réplica, Raft, sin TLS real) en OPENSHIFT por medio de OPENSHIFT OPERATOR. 
# Todos los recursos se crean con: $ oc apply -f -.
#
# DIFERENCIAS respecto al script de PRODUCCIÓN:
#   - 1 réplica       → sin HA, sin TLS entre pods
#   - tls-skip-verify → sin certificado firmado, Vault usa TLS self-signed mínimo
#   - Sin PVC audit   → solo PVC de datos (2Gi)
#   - Route edge      → termina TLS en el router OCP, no passthrough
#   - Recursos mínimos → 100m CPU / 128Mi RAM
#
# CARACTERÍSTICAS:
#   _ NAMESPACE : ${NAMESPACE} ← definido en sección PARÁMETROS
#   _ RÉPLICAS  : 1 (single-node Raft, sin HA)
#   _ CPU       : request 100m  / limit 250m
#   _ MEMORIA   : request 128Mi / limit 256Mi
#   _ STORAGE   : 2Gi data por nodo (ocs-storagecluster-ceph-rbd) — sin PVC audit
#   _ TLS       : deshabilitado — HTTP puerto 8200 (tls_disable = true)
#   _ SEGURIDAD : 1 unseal key / threshold 1, Secret K8s con credenciales
#   _ ROUTE     : edge HTTPS (router OCP termina TLS)
#   _ EXTRAS    : Uso de VAULTCONNECTION + VAULTAUTH (solo si CRD existe)
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
#   _ CPU     : 1 nodo con al menos 100m disponibles (request) / 250m (limit)
#   _ MEMORIA : 1 nodo con al menos 128Mi disponibles (request) / 256Mi (limit)
#   _ STORAGE : 1 × 2Gi data (ocs-storagecluster-ceph-rbd) — sin PVC
#   _ NODOS   : 1 worker suficiente (single-node, sin HA)
#
# USO:
#   $ sh ./1_Script_Instalacion_Vault_[Operator]_DESA.sh --modalidad=install 
#   $ sh ./1_Script_Instalacion_Vault_[Operator]_DESA.sh --modalidad=delete  
# =============================================================================

set -e
set -o pipefail

# Limpiar variables Vault heredadas de Windows para evitar que MSYS2
# convierta paths Unix en rutas Windows al pasarlos a oc exec.
unset VAULT_CACERT VAULT_TLSCERT VAULT_TLSKEY VAULT_ADDR VAULT_TOKEN VAULT_NAMESPACE

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
      echo "       Uso: sh ./1_Script_Instalacion_Vault_[Operator]_DESA.sh --modalidad=install|delete"
      exit 1
      ;;
  esac
done

if [ -z "${MODALIDAD}" ]; then
  echo ""
  echo "ERROR: Debes indicar la modalidad de ejecución."
  echo "  sh ./1_Script_Instalacion_Vault_[Operator]_DESA.sh --modalidad=install"
  echo "  sh ./1_Script_Instalacion_Vault_[Operator]_DESA.sh --modalidad=delete"
  echo ""
  exit 1
fi

# =============================================================================
# PARÁMETROS
# =============================================================================
NAMESPACE="vault"
RELEASE_NAME="vault"

VAULT_IMAGE="registry.connect.redhat.com/hashicorp/vault:1.21.2-ubi"

# StorageClass disponible en el clúster de desarrollo.
STORAGE_CLASS="ocs-storagecluster-ceph-rbd"
DATA_PVC_SIZE="2Gi"

VAULT_CPU_REQUEST="100m"
VAULT_CPU_LIMIT="250m"
VAULT_MEM_REQUEST="128Mi"
VAULT_MEM_LIMIT="256Mi"

ROUTER_DOMAIN="apps.itz-l7d2s4.infra01-lb.wdc07.techzone.ibm.com"
VAULT_ROUTE_HOST="vault-ui-${NAMESPACE}.${ROUTER_DOMAIN}"

VSO_NAMESPACE="vault-secrets-operator-system"

# --- Utilidades ---
print_step() {
  echo ""
  echo "============================================================"
  echo "  $1"
  echo "============================================================"
}

# limpiar_todo — elimina todos los recursos del namespace.
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
  oc delete service "${RELEASE_NAME}-ui"       -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo "--- ConfigMap"
  oc delete configmap "${RELEASE_NAME}-config" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo "--- Secrets"
  oc delete secret "${RELEASE_NAME}-init-credentials" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo "--- ServiceAccount y RBAC"
  oc delete serviceaccount "${RELEASE_NAME}"                        -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete clusterrolebinding "${RELEASE_NAME}-server-binding"     --ignore-not-found 2>/dev/null || true
  oc delete role        "${RELEASE_NAME}-service-registration"      -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete rolebinding "${RELEASE_NAME}-service-registration"      -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete role        "${RELEASE_NAME}-init-secret-writer"        -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete rolebinding "${RELEASE_NAME}-init-secret-writer"        -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo "--- PVCs"
  oc delete pvc -l "app.kubernetes.io/name=${RELEASE_NAME}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  oc delete pvc "data-${RELEASE_NAME}-0" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

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
  echo "  [FIN DE ELIMINACIÓN] VAULT eliminado del namespace '${NAMESPACE}'."
  echo "  El namespace '${NAMESPACE}' NO fue eliminado."
  echo "=========================================================================="
}

modalidad_install() {
  print_step "INICIO DE INSTALACIÓN — namespace: ${NAMESPACE}"

  limpiar_todo

  # -------------------------------------------------------------------------
  print_step "PASO 1/10: SERVICEACCOUNT Y RBAC"

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

  # system:auth-delegator: permite a Vault validar tokens de Kubernetes (auth method)
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

  # service-registration: Vault necesita GET/PATCH pods para registrar estado active/standby
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

  # init-secret-writer: el pod vault-0 crea el Secret de credenciales via curl durante init
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

  echo "  ServiceAccount & RBAC aplicados."

  # -------------------------------------------------------------------------
  print_step "PASO 3/10: CONFIGMAP DE CONFIGURACIÓN VAULT"

  # Single-node Raft sin TLS entre peers. tls-skip-verify en comandos vault.
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
    cluster_name = "${RELEASE_NAME}-desa-cluster"
    disable_mlock = true

    storage "raft" {
      path    = "/vault/data"
      node_id = "${RELEASE_NAME}-0"
    }

    listener "tcp" {
      address     = "[::]:8200"
      tls_disable = "true"
    }

    service_registration "kubernetes" {}
EOF

  echo "  ConfigMap aplicado."

  # -------------------------------------------------------------------------
  print_step "PASO 4/10: SERVICES (headless + ClusterIP + UI)"

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
    - name: http
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
    - name: http
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
  name: ${RELEASE_NAME}-ui
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
spec:
  ports:
    - name: http
      port: 8200
      targetPort: 8200
  selector:
    app.kubernetes.io/name: ${RELEASE_NAME}
    app.kubernetes.io/instance: ${RELEASE_NAME}
    component: server
EOF

  echo "  Services aplicados."

  # -------------------------------------------------------------------------
  print_step "PASO 5/10: STATEFULSET VAULT (1 réplica, single-node, HTTP)"

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
  replicas: 1
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
        - name: home
          emptyDir: {}
      containers:
        - name: vault
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
              name: http
              protocol: TCP
            - containerPort: 8201
              name: https-internal
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
              value: "http://127.0.0.1:8200"
            - name: VAULT_API_ADDR
              value: "http://\$(POD_IP):8200"
            - name: VAULT_CLUSTER_ADDR
              value: "https://\$(VAULT_K8S_POD_NAME).${RELEASE_NAME}-internal:8201"
            - name: VAULT_RAFT_NODE_ID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: SKIP_CHOWN
              value: "true"
            - name: SKIP_SETCAP
              value: "true"
            - name: HOME
              value: "/home/vault"
          volumeMounts:
            - name: config
              mountPath: /vault/config
            - name: data
              mountPath: /vault/data
            - name: home
              mountPath: /home/vault
          readinessProbe:
            httpGet:
              path: /v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204
              port: 8200
              scheme: HTTP
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
            successThreshold: 1
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
EOF

  echo "  StatefulSet aplicado."

  # -------------------------------------------------------------------------
  print_step "PASO 6/10: ROUTE OPENSHIFT (edge HTTP)"

  # Route edge: el router OCP termina la conexión HTTPS y reenvía HTTP al pod.
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
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  to:
    kind: Service
    name: ${RELEASE_NAME}-ui
    weight: 100
  wildcardPolicy: None
EOF

  echo "  Route aplicada."

  # -------------------------------------------------------------------------
  # Los pods arrancan SEALED. Se espera que vault-0 responda antes del init.
  print_step "PASO 7/10: ESPERANDO POD Running"

  echo "  Esperando 60s iniciales..."
  sleep 60

  echo "  Verificando que ${RELEASE_NAME}-0 responda (timeout 120s)..."
  WAIT_SECS=0
  MAX_WAIT=120
  until oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -c "${RELEASE_NAME}" -- \
        vault status 2>/dev/null | grep -qE "Sealed|Initialized"; do
    if [ "${WAIT_SECS}" -ge "${MAX_WAIT}" ]; then
      echo "  ADVERTENCIA: ${RELEASE_NAME}-0 no respondió en ${MAX_WAIT}s. Continuando..."
      break
    fi
    echo "  ... no responde aún, reintentando en 10s (${WAIT_SECS}/${MAX_WAIT}s)"
    sleep 10
    WAIT_SECS=$((WAIT_SECS + 10))
  done

  echo ""
  echo "  Estado actual del pod:"
  oc get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${RELEASE_NAME}"

  # -------------------------------------------------------------------------
  print_step "PASO 8/10: INVENTARIO DE RECURSOS"
  oc get pods,svc,pvc,configmap,route \
    -n "${NAMESPACE}" \
    -l "app.kubernetes.io/name=${RELEASE_NAME}" 2>&1 || true

  # -------------------------------------------------------------------------
  # oc exec ... > INIT_FILE (redirección a disco, nunca a $()).
  # Sin python: se parsea con grep/awk.
  print_step "PASO 9/10: INICIALIZACIÓN & UNSEAL DE VAULT"

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && { pwd -W 2>/dev/null || pwd; })"
  INIT_FILE="${SCRIPT_DIR}/${RELEASE_NAME}-init-$(date +%Y%m%d%H%M%S).json"

  INIT_STATUS=$(oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
    vault status 2>/dev/null \
    | grep "^Initialized" | awk '{print $2}' || echo "unknown")

  if [ "${INIT_STATUS}" = "true" ]; then
    echo "  VAULT ya inicializado. Leyendo credenciales del SECRET existente..."
    SKIP_INIT=true
  else
    SKIP_INIT=false
    echo "  VAULT no inicializado. Ejecutando VAULT OPERATOR INIT..."
    echo "  (Guardando JSON en: ${INIT_FILE})"

    oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
      vault operator init -key-shares=1 -key-threshold=1 \
      -format=json > "${INIT_FILE}" 2>&1 || true

    if [ ! -s "${INIT_FILE}" ]; then
      echo ""
      echo "  ╔══════════════════════════════════════════════════════════════════╗"
      echo "  ║  ERROR CRÍTICO: VAULT OPERATOR INIT no generó salida            ║"
      echo "  ╚══════════════════════════════════════════════════════════════════╝"
      echo ""
      echo "  DIAGNÓSTICO — Estado del pod:"
      oc get pod "${RELEASE_NAME}-0" -n "${NAMESPACE}" 2>/dev/null || true
      echo ""
      echo "  DIAGNÓSTICO — Últimas líneas del log del pod:"
      oc logs "${RELEASE_NAME}-0" -n "${NAMESPACE}" --tail=20 2>/dev/null || true
      echo ""
      echo "  CAUSA MÁS PROBABLE: el pod no está en estado Running."
      echo "  Verifica los eventos del pod y vuelve a ejecutar --modalidad=install"
      echo ""
      # Limpiar el archivo vacío para no confundir en la siguiente ejecución
      rm -f "${INIT_FILE}"
      exit 1
    fi
    echo "  Init completado. JSON guardado en: ${INIT_FILE}"
    echo "  *** CUSTODIAR — contiene la unseal key y el root token ***"
  fi

  if [ "${SKIP_INIT}" = "false" ] && [ -s "${INIT_FILE}" ]; then
    UNSEAL_KEY_1=$(grep -o '"[A-Za-z0-9+/=]\{44,\}"' "${INIT_FILE}" | sed 's/"//g' | sed -n '1p')
    ROOT_TOKEN=$(grep '"root_token"' "${INIT_FILE}" | awk -F'"' '{print $4}')

    echo "  Key extraída: ${UNSEAL_KEY_1:0:8}...   Root token: ${ROOT_TOKEN:0:12}..."

    K1B=$(printf '%s' "${UNSEAL_KEY_1}" | base64 -w0 2>/dev/null || printf '%s' "${UNSEAL_KEY_1}" | base64)
    RTB=$(printf '%s' "${ROOT_TOKEN}"   | base64 -w0 2>/dev/null || printf '%s' "${ROOT_TOKEN}"   | base64)

    # Guardar credenciales en Secret K8s para reutilización
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
        -d '{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"${RELEASE_NAME}-init-credentials\",\"namespace\":\"${NAMESPACE}\"},\"data\":{\"unseal-key-1\":\"${K1B}\",\"root-token\":\"${RTB}\"}}' \
        && echo 'CREDENTIALS_SAVED' || echo 'CREDENTIALS_SAVE_FAILED'
    " 2>/dev/null
    echo "  Credenciales guardadas en Secret '${RELEASE_NAME}-init-credentials'."

  elif [ "${SKIP_INIT}" = "true" ]; then
    UNSEAL_KEY_1=$(oc get secret "${RELEASE_NAME}-init-credentials" -n "${NAMESPACE}" \
      -o jsonpath='{.data.unseal-key-1}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    ROOT_TOKEN=$(oc get secret "${RELEASE_NAME}-init-credentials" -n "${NAMESPACE}" \
      -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  fi

  # Unseal: en DESA solo 1 key share / threshold 1
  echo ""
  echo "  Esperando 10s antes del UNSEAL..."
  sleep 10

  oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
    vault operator unseal "${UNSEAL_KEY_1}" >/dev/null 2>&1 \
    && echo "  UNSEAL OK" || echo "  ADVERTENCIA: UNSEAL falló (puede que ya esté UNSEALED)"

  echo ""
  echo "  Estado final del POD:"
  oc get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${RELEASE_NAME}"

  # -------------------------------------------------------------------------
  # VaultConnection + VaultAuth (VSO) — solo si el CRD existe en el clúster
  print_step "PASO 10/10: RECURSOS VSO (VaultConnection + VaultAuth)"

  if oc get crd vaultconnections.secrets.hashicorp.com &>/dev/null; then
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
  address: http://${RELEASE_NAME}.${NAMESPACE}.svc.cluster.local:8200
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

    echo "  Esperando 5s para que VSO reconcilie..."
    sleep 5
    oc get vaultconnection,vaultauth -n "${NAMESPACE}" 2>/dev/null || true
  else
    echo "  VSO no instalado en este clúster — recursos VaultConnection/VaultAuth omitidos."
    echo "  Instala el Vault Secrets Operator si necesitas sincronización de secretos."
  fi

  # -------------------------------------------------------------------------
  VAULT_ROUTE=$(oc get route "${RELEASE_NAME}-ui" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "${VAULT_ROUTE_HOST}")

  VS_INITIALIZED=$(oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
    vault status 2>/dev/null | grep "^Initialized" | awk '{print $2}' || echo "?")
  VS_SEALED=$(oc exec "${RELEASE_NAME}-0" -n "${NAMESPACE}" -- \
    vault status 2>/dev/null | grep "^Sealed" | awk '{print $2}' || echo "?")

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║                                                                      ║"
  echo "║   INSTALACIÓN COMPLETADA — VAULT DESA  (NAMESPACE: ${NAMESPACE})     ║"
  echo "║                                                                      ║"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  ┌─ CLUSTER ──────────────────────────────────────────────────────────┐"
  echo "  │  _ NAMESPACE   : ${NAMESPACE}"
  echo "  │  _ MODO        : Single-node Raft | HTTP (sin TLS) | Sin Helm"
  echo "  │  _ IMAGEN      : ${VAULT_IMAGE}"
  echo "  │  _ STORAGE     : 1 × data-${DATA_PVC_SIZE} (${STORAGE_CLASS})"
  echo "  │  _ INITIALIZED : ${VS_INITIALIZED}   Sealed: ${VS_SEALED}"
  echo "  └────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  ┌─ ACCESO UI ────────────────────────────────────────────────────────┐"
  echo "  │   URL            : https://${VAULT_ROUTE}/ui"
  echo "  │   MÉTODO DE LOGIN: Token"
  echo "  └────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  ┌─ ROOT TOKEN ── ⚠  COPIAR AHORA  ⚠ ────────────────────────────────┐"
  echo "  │   ${ROOT_TOKEN}"
  echo "  └────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  ┌─ UNSEAL KEY ───────────────────────────────────────────────────────┐"
  echo "  │   Key 1 : ${UNSEAL_KEY_1}"
  echo "  └────────────────────────────────────────────────────────────────────┘"
  echo ""
  if [ "${SKIP_INIT}" = "false" ]; then
    echo "  ┌─ ARCHIVO DE CLAVES (disco local) ──────────────────────────────────┐"
    echo "  │  ${INIT_FILE}"
    echo "  │  ⚠  Eliminar tras custodiar:  rm \"${INIT_FILE}\""
    echo "  └────────────────────────────────────────────────────────────────────┘"
    echo ""
  fi
  echo "  ┌─ SECRET EN OPENSHIFT ──────────────────────────────────────────────┐"
  echo "  │  $ oc get secret ${RELEASE_NAME}-init-credentials -n ${NAMESPACE} -o yaml"
  echo "  └────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  ┌─ PRÓXIMOS PASOS ───────────────────────────────────────────────────┐"
  echo "  │  1. Ejecutar script de configuración:"
  echo "  │     sh ./3_Script_Configuracion_Vault_[Operator]_DESA.sh --modalidad=install"
  echo "  │  2. Acceder a la UI: https://${VAULT_ROUTE}/ui"
  echo "  └────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║  FIN DE INSTALACIÓN — ${RELEASE_NAME}  (NAMESPACE: ${NAMESPACE})     ║"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
  echo ""
}

case "${MODALIDAD}" in
  install) modalidad_install ;;
  delete)  modalidad_delete  ;;
esac
