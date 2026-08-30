#!/bin/bash

# =============================================================================
# INSTALACIÓN / DESINSTALACIÓN - VAULT HA (PRODUCCIÓN) - [HELM]
# =============================================================================
# INSTALA o ELIMINA Vault en modo HA RAFT (3 réplicas, TLS) en OPENSHIFT usando HELM.
#
# CARACTERÍSTICAS:
#   _ RÉPLICAS  : 3 (HA Raft integrated storage)
#   _ CPU       : request 250m  / limit 500m  (Vault) | 50m / 250m (Injector)
#   _ MEMORIA   : request 256Mi / limit 512Mi (Vault) | 64Mi / 128Mi (Injector)
#   _ STORAGE   : 10Gi data + 5Gi audit por nodo (ocs-storagecluster-ceph-rbd)
#   _ TLS       : habilitado — certificado x509 autofirmado (openssl)
#   _ SEGURIDAD : 5 unseal keys / threshold 3, audit log por PVC
#   _ ROUTE     : passthrough HTTPS (TLS llega directo al pod)
#   _ EXTRAS    : Agent Injector habilitado, PodDisruptionBudget maxUnavailable=1
#
# PRERREQUISITOS:
#   1. NAMESPACE "${NAMESPACE}" existente: $ oc create namespace ${NAMESPACE}
#   2. IBM ENTITLEMENT-KEY aplicado en el NAMESPACE "${NAMESPACE}" antes de este SCRIPT:
#      $ oc create secret docker-registry ibm-entitlement-key \
#          --docker-server=cp.icr.io --docker-username=cp \
#          --docker-password=<ENTITLEMENT_KEY> -n ${NAMESPACE}
#   3. Autenticación en OPENSHIFT activa: $ oc login ...
#
# REQUERIMIENTOS DE INFRAESTRUCTURA:
#   _ CPU     : 3 nodos con al menos 250m disponibles c/u (request) / 500m (limit) — Vault
#               + 50m (request) / 250m (limit) — Agent Injector
#   _ MEMORIA : 3 nodos con al menos 256Mi disponibles c/u (request) / 512Mi (limit) — Vault
#               + 64Mi (request) / 128Mi (limit) — Agent Injector
#   _ STORAGE : 3 × 10Gi data + 3 × 5Gi audit = 45Gi total (ocs-storagecluster-ceph-rbd)
#   _ NODOS   : mínimo 3 workers para distribución HA (topologyKey: kubernetes.io/hostname)
#
# USO:
#   $ sh ./1_Script_Instalacion_Vault_[Helm]_PROD.sh --modalidad=install
#   $ sh ./1_Script_Instalacion_Vault_[Helm]_PROD.sh --modalidad=delete
# =============================================================================

set -e
set -o pipefail

# Limpiar variables Vault heredadas de Windows para evitar que MSYS2
# convierta paths Unix en rutas Windows al pasarlos a oc exec.
unset VAULT_CACERT VAULT_TLSCERT VAULT_TLSKEY VAULT_ADDR VAULT_TOKEN VAULT_NAMESPACE

MODALIDAD=""

for ARG in "$@"; do
  case "${ARG}" in
    --modalidad=install)
      MODALIDAD="install"
      ;;
    --modalidad=delete)
      MODALIDAD="delete"
      ;;
    --modalidad=*)
      echo "ERROR: Modalidad desconocida '${ARG}'."
      echo "       Usa: --modalidad=install  o  --modalidad=delete"
      exit 1
      ;;
    *)
      echo "ERROR: Argumento desconocido '${ARG}'."
      echo "       Uso: sh ./1_Script_Instalacion_Vault_[Helm]_PROD.sh --modalidad=install|delete"
      exit 1
      ;;
  esac
done

if [ -z "${MODALIDAD}" ]; then
  echo "ERROR: Debes indicar la modalidad de ejecución."
  echo ""
  echo "  Uso:"
  echo "    sh ./1_Script_Instalacion_Vault_[Helm]_PROD.sh --modalidad=install"
  echo "    sh ./1_Script_Instalacion_Vault_[Helm]_PROD.sh --modalidad=delete"
  echo ""
  exit 1
fi

# --- Parámetros ---
NAMESPACE="vault"

HELM_REPO_NAME="hashicorp"
HELM_REPO_URL="https://helm.releases.hashicorp.com"
RELEASE_NAME="vault"

VAULT_IMAGE_REPOSITORY="registry.connect.redhat.com/hashicorp/vault"
VAULT_IMAGE_TAG="1.21.2-ubi"

VAULT_K8S_IMAGE_REPOSITORY="registry.connect.redhat.com/hashicorp/vault-k8s"
VAULT_K8S_IMAGE_TAG="1.7.2-ubi"

VAULT_SERVICE_UI="${RELEASE_NAME}-ui"

VAULT_REPLICAS=3
VAULT_STORAGE_CLASS="ocs-storagecluster-ceph-rbd"
VAULT_STORAGE_SIZE="10Gi"

VAULT_CPU_REQUEST="250m"
VAULT_CPU_LIMIT="500m"
VAULT_MEM_REQUEST="256Mi"
VAULT_MEM_LIMIT="512Mi"

INJECTOR_CPU_REQUEST="50m"
INJECTOR_CPU_LIMIT="250m"
INJECTOR_MEM_REQUEST="64Mi"
INJECTOR_MEM_LIMIT="128Mi"

TLS_SECRET="vault-tls"
VAULT_DOMAIN="vault.${NAMESPACE}.svc.cluster.local"

# Doble slash (//) impide que MSYS2 convierta el path Unix a ruta Windows
# cuando se pasa como argumento a oc exec en Git Bash.
VAULT_TLS_PATH="//vault/userconfig/${TLS_SECRET}"

# --- Utilidades ---
print_step() {
  echo ""
  echo "Sentencia ejecutada:"
  echo "$1"
  echo ""
}

run_cmd() {
  print_step "$*"
  "$@"
}

run_cmd_allow_error() {
  print_step "$*"
  "$@" || true
}

modalidad_delete() {
  echo ""
  echo "==========================================================================="
  echo "  [INICIO DE ELIMINACIÓN - PRODUCCIÓN]  namespace: ${NAMESPACE}"
  echo "==========================================================================="
  echo ""

  echo "===> D.1. Eliminando Helm release '${RELEASE_NAME}'..."
  if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}"
    echo "     Release eliminado. Esperando 15s para que los pods terminen..."
    sleep 15
  else
    echo "     No existe release. Omitiendo."
  fi

  echo "===> D.2. Eliminando PVCs del namespace '${NAMESPACE}'..."
  PVC_LIST=$(oc get pvc -n "${NAMESPACE}" --no-headers \
    -o custom-columns=":metadata.name" 2>/dev/null || true)
  if [ -n "${PVC_LIST}" ]; then
    oc delete pvc -n "${NAMESPACE}" --all
    echo "     PVCs eliminados: ${PVC_LIST}"
  else
    echo "     No existen PVCs. Omitiendo."
  fi

  echo "===> D.3. Eliminando Secret TLS '${TLS_SECRET}'..."
  if oc get secret "${TLS_SECRET}" -n "${NAMESPACE}" &>/dev/null; then
    oc delete secret "${TLS_SECRET}" -n "${NAMESPACE}"
    echo "     Secret eliminado."
  else
    echo "     No existe. Omitiendo."
  fi

  echo "===> D.4. Eliminando Route '${RELEASE_NAME}-ui'..."
  if oc get route "${RELEASE_NAME}-ui" -n "${NAMESPACE}" &>/dev/null; then
    oc delete route "${RELEASE_NAME}-ui" -n "${NAMESPACE}"
    echo "     Route eliminada."
  else
    echo "     No existe. Omitiendo."
  fi

  echo "===> D.6. Eliminando ServiceAccounts y ClusterRoleBindings residuales..."
  oc delete serviceaccount "${RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null || true
  oc delete serviceaccount "${RELEASE_NAME}-agent-injector" -n "${NAMESPACE}" 2>/dev/null || true
  oc delete clusterrolebinding "${RELEASE_NAME}-server-binding" 2>/dev/null || true
  oc delete clusterrolebinding "${RELEASE_NAME}-agent-injector-binding" 2>/dev/null || true
  oc delete clusterrole "${RELEASE_NAME}-agent-injector-clusterrole" 2>/dev/null || true
  oc delete mutatingwebhookconfiguration "${RELEASE_NAME}-agent-injector-cfg" 2>/dev/null || true

  echo "===> D.7. El namespace '${NAMESPACE}' NO es eliminado por este script (prerrequisito externo)."

  echo ""
  echo "==========================================================================="
  echo "  [FIN DE ELIMINACIÓN]  Vault ha sido desinstalado del namespace '${NAMESPACE}'."
  echo "==========================================================================="
  echo ""
}

modalidad_install() {
  echo ""
  echo "==========================================================================="
  echo "  [INICIO DE INSTALACIÓN - PRODUCCIÓN]  namespace: ${NAMESPACE}"
  echo "==========================================================================="
  echo ""

  echo "===> 0. LIMPIEZA DE INSTALACIÓN PREVIA (si existe)"

  echo "  --> Helm release '${RELEASE_NAME}'..."
  if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" &>/dev/null; then
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}"
    echo "      Release eliminado."
    echo "      Esperando 10s para que los pods terminen..."
    sleep 10
  else
    echo "      No existe. Omitiendo."
  fi

  echo "  --> PVCs del namespace '${NAMESPACE}'..."
  PVC_LIST=$(oc get pvc -n "${NAMESPACE}" --no-headers \
    -o custom-columns=":metadata.name" 2>/dev/null || true)
  if [ -n "${PVC_LIST}" ]; then
    oc delete pvc -n "${NAMESPACE}" --all
    echo "      PVCs eliminados: ${PVC_LIST}"
  else
    echo "      No existen PVCs. Omitiendo."
  fi

  echo "  --> Secret TLS '${TLS_SECRET}'..."
  if oc get secret "${TLS_SECRET}" -n "${NAMESPACE}" &>/dev/null; then
    oc delete secret "${TLS_SECRET}" -n "${NAMESPACE}"
    echo "      Secret eliminado."
  else
    echo "      No existe. Omitiendo."
  fi

  echo "  --> Route '${RELEASE_NAME}-ui'..."
  if oc get route "${RELEASE_NAME}-ui" -n "${NAMESPACE}" &>/dev/null; then
    oc delete route "${RELEASE_NAME}-ui" -n "${NAMESPACE}"
    echo "      Route eliminada."
  else
    echo "      No existe. Omitiendo."
  fi

  echo "  Limpieza completada."
  echo ""

  echo "===> 1. VERIFICANDO IBM ENTITLEMENT KEY (prerrequisito)"
  if ! oc get secret "ibm-entitlement-key" -n "${NAMESPACE}" &>/dev/null; then
    echo "ERROR: El secret 'ibm-entitlement-key' no existe en el namespace '${NAMESPACE}'."
    echo "       Créalo antes de ejecutar este script (ver PRERREQUISITOS en el encabezado)."
    exit 1
  fi
  echo "     Secret 'ibm-entitlement-key' encontrado. Continuando..."

  # Genera certificado x509 autofirmado para los SANs de Vault (service + headless + localhost).
  # Usa archivo de configuración openssl en lugar de -subj/-addext para evitar conversión de paths MSYS2.
  # En producción reemplazar por certificado de la CA corporativa o cert-manager.
  echo "===> 3. GENERANDO CERTIFICADO TLS AUTOFIRMADO PARA VAULT"

  TLS_DIR=$(mktemp -d)

  cat > "${TLS_DIR}/vault-openssl.cnf" <<EOF
[req]
default_bits       = 2048
distinguished_name = req_distinguished_name
x509_extensions    = v3_ca
prompt             = no

[req_distinguished_name]
CN = ${VAULT_DOMAIN}
O  = HashiCorpVault

[v3_ca]
subjectAltName   = @alt_names
basicConstraints = CA:TRUE
keyUsage         = critical, keyCertSign, cRLSign, digitalSignature, keyEncipherment

[alt_names]
DNS.1 = ${VAULT_DOMAIN}
DNS.2 = ${RELEASE_NAME}
DNS.3 = ${RELEASE_NAME}.${NAMESPACE}
DNS.4 = localhost
DNS.5 = ${RELEASE_NAME}-0.${RELEASE_NAME}-internal
DNS.6 = ${RELEASE_NAME}-1.${RELEASE_NAME}-internal
DNS.7 = ${RELEASE_NAME}-2.${RELEASE_NAME}-internal
IP.1  = 127.0.0.1
EOF

  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "${TLS_DIR}/vault.key" \
    -out    "${TLS_DIR}/vault.crt" \
    -config "${TLS_DIR}/vault-openssl.cnf"

  oc create secret generic "${TLS_SECRET}" \
    --from-file=vault.key="${TLS_DIR}/vault.key" \
    --from-file=vault.crt="${TLS_DIR}/vault.crt" \
    --from-file=vault.ca="${TLS_DIR}/vault.crt" \
    -n "${NAMESPACE}"

  rm -rf "${TLS_DIR}"

  echo "===> 4. AGREGANDO REPOSITORIO HELM DE HASHICORP"
  helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" 2>/dev/null || true

  echo "===> 5. ACTUALIZANDO REPOSITORIO HELM"
  helm repo update

  # MSYS_NO_PATHCONV=1 evita que MSYS2 convierta los paths Unix (/vault/...)
  # a rutas Windows en todos los argumentos --set que contienen paths.
  echo "===> 6. INSTALANDO VAULT EN MODO HA / RAFT (PRODUCCIÓN)"

  MSYS_NO_PATHCONV=1 helm install "${RELEASE_NAME}" "${HELM_REPO_NAME}/vault" \
    -n "${NAMESPACE}" \
    \
    --set global.openshift=true \
    \
    --set server.dev.enabled=false \
    \
    --set server.image.repository="${VAULT_IMAGE_REPOSITORY}" \
    --set server.image.tag="${VAULT_IMAGE_TAG}" \
    \
    --set server.replicas="${VAULT_REPLICAS}" \
    \
    --set server.resources.requests.cpu="${VAULT_CPU_REQUEST}" \
    --set server.resources.requests.memory="${VAULT_MEM_REQUEST}" \
    --set server.resources.limits.cpu="${VAULT_CPU_LIMIT}" \
    --set server.resources.limits.memory="${VAULT_MEM_LIMIT}" \
    \
    --set server.affinity="" \
    --set server.topologySpreadConstraints[0].maxSkew=1 \
    --set server.topologySpreadConstraints[0].topologyKey=kubernetes.io/hostname \
    --set 'server.topologySpreadConstraints[0].whenUnsatisfiable=DoNotSchedule' \
    --set "server.topologySpreadConstraints[0].labelSelector.matchLabels.app\.kubernetes\.io/name=${RELEASE_NAME}" \
    \
    --set server.dataStorage.enabled=true \
    --set server.dataStorage.size="${VAULT_STORAGE_SIZE}" \
    --set server.dataStorage.storageClass="${VAULT_STORAGE_CLASS}" \
    --set server.dataStorage.accessMode=ReadWriteOnce \
    \
    --set server.auditStorage.enabled=true \
    --set server.auditStorage.size="5Gi" \
    --set server.auditStorage.storageClass="${VAULT_STORAGE_CLASS}" \
    --set server.auditStorage.accessMode=ReadWriteOnce \
    \
    --set "server.extraEnvironmentVars.VAULT_CACERT=//vault/userconfig/${TLS_SECRET}/vault.ca" \
    --set "server.extraEnvironmentVars.VAULT_TLSCERT=//vault/userconfig/${TLS_SECRET}/vault.crt" \
    --set "server.extraEnvironmentVars.VAULT_TLSKEY=//vault/userconfig/${TLS_SECRET}/vault.key" \
    --set "server.extraEnvironmentVars.VAULT_ADDR=https://127.0.0.1:8200" \
    \
    --set "server.volumes[0].name=${TLS_SECRET}" \
    --set "server.volumes[0].secret.secretName=${TLS_SECRET}" \
    --set "server.volumeMounts[0].mountPath=//vault/userconfig/${TLS_SECRET}" \
    --set "server.volumeMounts[0].name=${TLS_SECRET}" \
    --set "server.volumeMounts[0].readOnly=true" \
    \
    --set 'server.ha.enabled=true' \
    --set "server.ha.replicas=${VAULT_REPLICAS}" \
    --set 'server.ha.raft.enabled=true' \
    --set 'server.ha.raft.setNodeId=true' \
    --set "server.ha.raft.config=ui = true
cluster_name = \"${RELEASE_NAME}-ha-cluster\"
storage \"raft\" {
path = \"/vault/data\"
retry_join {
leader_api_addr         = \"https://${RELEASE_NAME}-0.${RELEASE_NAME}-internal:8200\"
    leader_ca_cert_file     = \"/vault/userconfig/${TLS_SECRET}/vault.ca\"
    leader_client_cert_file = \"/vault/userconfig/${TLS_SECRET}/vault.crt\"
    leader_client_key_file  = \"/vault/userconfig/${TLS_SECRET}/vault.key\"
  }
  retry_join {
    leader_api_addr         = \"https://${RELEASE_NAME}-1.${RELEASE_NAME}-internal:8200\"
    leader_ca_cert_file     = \"/vault/userconfig/${TLS_SECRET}/vault.ca\"
    leader_client_cert_file = \"/vault/userconfig/${TLS_SECRET}/vault.crt\"
    leader_client_key_file  = \"/vault/userconfig/${TLS_SECRET}/vault.key\"
  }
  retry_join {
    leader_api_addr         = \"https://${RELEASE_NAME}-2.${RELEASE_NAME}-internal:8200\"
    leader_ca_cert_file     = \"/vault/userconfig/${TLS_SECRET}/vault.ca\"
    leader_client_cert_file = \"/vault/userconfig/${TLS_SECRET}/vault.crt\"
    leader_client_key_file  = \"/vault/userconfig/${TLS_SECRET}/vault.key\"
  }
}
listener \"tcp\" {
  address         = \"[::]:8200\"
  cluster_address = \"[::]:8201\"
  tls_cert_file   = \"/vault/userconfig/${TLS_SECRET}/vault.crt\"
  tls_key_file    = \"/vault/userconfig/${TLS_SECRET}/vault.key\"
  tls_min_version = \"tls12\"
}
service_registration \"kubernetes\" {}" \
    \
    --set server.ha.disruptionBudget.enabled=true \
    --set server.ha.disruptionBudget.maxUnavailable=1 \
    \
    --set injector.enabled=true \
    --set injector.image.repository="${VAULT_K8S_IMAGE_REPOSITORY}" \
    --set injector.image.tag="${VAULT_K8S_IMAGE_TAG}" \
    --set injector.agentImage.repository="${VAULT_IMAGE_REPOSITORY}" \
    --set injector.agentImage.tag="${VAULT_IMAGE_TAG}" \
    --set injector.resources.requests.cpu="${INJECTOR_CPU_REQUEST}" \
    --set injector.resources.requests.memory="${INJECTOR_MEM_REQUEST}" \
    --set injector.resources.limits.cpu="${INJECTOR_CPU_LIMIT}" \
    --set injector.resources.limits.memory="${INJECTOR_MEM_LIMIT}" \
    \
    --set ui.enabled=true

  echo "===> 7. VALIDANDO ESTADO DEL RELEASE HELM"
  helm status "${RELEASE_NAME}" -n "${NAMESPACE}"

  # En modo HA los pods arrancan SEALED (Running 0/1): el readiness probe falla
  # hasta el unseal. Se espera con loop hasta que vault-0 pase a Running.
  echo "===> 8. ESPERANDO QUE LOS PODS ESTÉN RUNNING (timeout 3 min)"
  PODS_WAIT=0
  until oc get pod "${RELEASE_NAME}-0" -n "${NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; do
    if [ "${PODS_WAIT}" -ge 180 ]; then
      echo "  ADVERTENCIA: ${RELEASE_NAME}-0 no pasó a Running en 180s. Continuando..."
      break
    fi
    echo "  ... esperando ${RELEASE_NAME}-0 Running (${PODS_WAIT}/180s)"
    sleep 10
    PODS_WAIT=$((PODS_WAIT + 10))
  done
  echo "  (Esperando 20s adicionales para que el proceso vault inicie dentro del pod...)"
  sleep 20

  echo "===> 9. RECURSOS DESPLEGADOS (pods, servicios, PVCs)"
  oc get pods,svc,pvc -n "${NAMESPACE}"

  # 5 key shares, threshold 3 → estándar producción.
  # El JSON con las unseal keys y el root token se guarda en disco local.
  # CUSTODIAR CON EXTREMO CUIDADO y eliminar tras distribuir las keys entre custodios.
  echo "===> 10. INICIALIZANDO VAULT"

  # pwd -W devuelve el path Windows (C:\...) en Git Bash/Windows;
  # si falla (Linux/Mac) se usa pwd estándar.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && { pwd -W 2>/dev/null || pwd; })"
  INIT_OUTPUT_FILE="${SCRIPT_DIR}/${RELEASE_NAME}-init-keys-$(date +%Y%m%d%H%M%S).txt"

  MSYS_NO_PATHCONV=1 oc exec -n "${NAMESPACE}" "${RELEASE_NAME}-0" -- \
    env "VAULT_CACERT=${VAULT_TLS_PATH}/vault.ca" \
        "VAULT_ADDR=https://127.0.0.1:8200" \
    vault operator init \
      -key-shares=5 \
      -key-threshold=3 \
      -format=json | tee "${INIT_OUTPUT_FILE}"

  if [ ! -s "${INIT_OUTPUT_FILE}" ]; then
    echo ""
    echo "  ERROR: El archivo de init quedó vacío (${INIT_OUTPUT_FILE})."
    echo "  Revise los logs de ${RELEASE_NAME}-0: oc logs ${RELEASE_NAME}-0 -n ${NAMESPACE}"
    echo ""
    exit 1
  fi

  echo ""
  echo "  *** IMPORTANTE: Las claves de unseal & el Root Token se guardaron en:"
  echo "  ***   ${INIT_OUTPUT_FILE}"
  echo "  *** Distribuya las keys entre los custodios designados y elimine el archivo."
  echo ""

  echo "===> 11. HACIENDO UNSEAL DE ${RELEASE_NAME}-0"

  UNSEAL_KEY_1=$(grep -o '"[A-Za-z0-9+/=]\{44,\}"' "${INIT_OUTPUT_FILE}" | sed 's/"//g' | sed -n '1p')
  UNSEAL_KEY_2=$(grep -o '"[A-Za-z0-9+/=]\{44,\}"' "${INIT_OUTPUT_FILE}" | sed 's/"//g' | sed -n '2p')
  UNSEAL_KEY_3=$(grep -o '"[A-Za-z0-9+/=]\{44,\}"' "${INIT_OUTPUT_FILE}" | sed 's/"//g' | sed -n '3p')

  for KEY in "${UNSEAL_KEY_1}" "${UNSEAL_KEY_2}" "${UNSEAL_KEY_3}"; do
    MSYS_NO_PATHCONV=1 oc exec -n "${NAMESPACE}" "${RELEASE_NAME}-0" -- \
      env "VAULT_CACERT=${VAULT_TLS_PATH}/vault.ca" \
          "VAULT_ADDR=https://127.0.0.1:8200" \
      vault operator unseal "${KEY}"
  done

  # El raft join se ejecuta íntegramente dentro del pod (sh -c) para que
  # los paths de los certificados sean resueltos por el shell del contenedor
  # y no sean convertidos por MSYS2 en el host Windows.
  echo "===> 12. RAFT JOIN Y UNSEAL DE NODOS SECUNDARIOS"

  for POD in "${RELEASE_NAME}-1" "${RELEASE_NAME}-2"; do
    echo "  --> ${POD}: raft join"
    MSYS_NO_PATHCONV=1 oc exec -n "${NAMESPACE}" "${POD}" -- \
      sh -c "export VAULT_CACERT=/vault/userconfig/${TLS_SECRET}/vault.ca
             export VAULT_ADDR=https://127.0.0.1:8200
             vault operator raft join \
               -leader-ca-cert=\"\$(cat /vault/userconfig/${TLS_SECRET}/vault.ca)\" \
               -leader-client-cert=\"\$(cat /vault/userconfig/${TLS_SECRET}/vault.crt)\" \
               -leader-client-key=\"\$(cat /vault/userconfig/${TLS_SECRET}/vault.key)\" \
               https://${RELEASE_NAME}-0.${RELEASE_NAME}-internal:8200" || true

    echo "  --> ${POD}: unseal"
    for KEY in "${UNSEAL_KEY_1}" "${UNSEAL_KEY_2}" "${UNSEAL_KEY_3}"; do
      MSYS_NO_PATHCONV=1 oc exec -n "${NAMESPACE}" "${POD}" -- \
        env "VAULT_CACERT=${VAULT_TLS_PATH}/vault.ca" \
            "VAULT_ADDR=https://127.0.0.1:8200" \
        vault operator unseal "${KEY}"
    done
    echo ""
  done

  echo "===> 13. ESTADO DE CADA NODO VAULT"
  for POD in "${RELEASE_NAME}-0" "${RELEASE_NAME}-1" "${RELEASE_NAME}-2"; do
    echo "  --> ${POD}:"
    MSYS_NO_PATHCONV=1 oc exec -n "${NAMESPACE}" "${POD}" -- \
      sh -c 'vault status -tls-skip-verify 2>/dev/null || true'
    echo ""
  done

  echo "===> 14. MIEMBROS DEL CLÚSTER RAFT"
  ROOT_TOKEN=$(grep '"root_token"' "${INIT_OUTPUT_FILE}" | awk -F'"' '{print $4}')

  MSYS_NO_PATHCONV=1 oc exec -n "${NAMESPACE}" "${RELEASE_NAME}-0" -- \
    env "VAULT_CACERT=${VAULT_TLS_PATH}/vault.ca" \
        "VAULT_ADDR=https://127.0.0.1:8200" \
        "VAULT_TOKEN=${ROOT_TOKEN}" \
    vault operator raft list-peers

  echo "===> 15. EXPONIENDO LA UI DE VAULT (Route passthrough HTTPS)"

  EXISTING_TERMINATION=$(oc get route "${RELEASE_NAME}-ui" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "none")

  if [ "${EXISTING_TERMINATION}" != "passthrough" ]; then
    oc delete route "${RELEASE_NAME}-ui" -n "${NAMESPACE}" 2>/dev/null || true
    oc create route passthrough "${RELEASE_NAME}-ui" \
      --service="${VAULT_SERVICE_UI}" \
      --port=8200 \
      -n "${NAMESPACE}"
    echo "  Route passthrough creada."
  else
    echo "  Route passthrough ya existe, sin cambios."
  fi

  echo "===> 16. ROUTES DEL NAMESPACE"
  oc get route -n "${NAMESPACE}"

  VAULT_ROUTE=$(oc get route "${RELEASE_NAME}-ui" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.host}' 2>/dev/null || echo "N/A")
  VAULT_HEALTH=$(curl -sk --max-time 5 "https://${VAULT_ROUTE}/v1/sys/health" 2>/dev/null \
    | awk 'BEGIN{sealed="?";ha="?"} \
           /"sealed"[[:space:]]*:[[:space:]]*/{match($0,/"sealed"[[:space:]]*:[[:space:]]*([a-z]+)/,a); if(a[1]!="") sealed=a[1]} \
           /"ha_enabled"[[:space:]]*:[[:space:]]*/{match($0,/"ha_enabled"[[:space:]]*:[[:space:]]*([a-z]+)/,a); if(a[1]!="") ha=a[1]} \
           END{print "sealed="sealed" ha_enabled="ha}' \
    || echo "no_response")

  echo ""
  echo "=========================================================================="
  echo "  INSTALACIÓN DE VAULT HA (PRODUCCIÓN) - RESUMEN"
  echo "=========================================================================="
  echo "  _ NAMESPACE           : ${NAMESPACE}"
  echo "  _ REPLICAS            : ${VAULT_REPLICAS}"
  echo "  _ MODO                : HA / Raft Integrated Storage"
  echo "  _ TLS                 : Habilitado (secret: ${TLS_SECRET})"
  echo "  _ STORAGE CLASS       : ${VAULT_STORAGE_CLASS}"
  echo "  _ STORAGE SIZE (DATA) : ${VAULT_STORAGE_SIZE} por nodo"
  echo "  _ STORAGE SIZE (AUDIT): 5Gi por nodo"
  echo "  _ UI URL              : https://${VAULT_ROUTE}/ui"
  echo "  _ UI HEALTH CHECK     : ${VAULT_HEALTH}"
  echo "  _ ROOT TOKEN (login)  : ${ROOT_TOKEN}"
  echo "  _ ARCHIVO DE CLAVES   : ${INIT_OUTPUT_FILE}"
  echo "=========================================================================="
  echo ""
  echo "  PRÓXIMOS PASOS RECOMENDADOS:"
  echo "  1. Eliminar ${INIT_OUTPUT_FILE} del sistema una vez distribuidas las KEYs."
  echo "  2. Habilitar AUDIT LOG:"
  echo "     $ vault audit enable file file_path=/vault/audit/audit.log"
  echo "  3. Reemplazar el certificado autofirmado por uno de la CA corporativa."
  echo "=========================================================================="
  echo ""
  echo "----------------------------- [TÉRMINO DE INSTALACIÓN - PRODUCCIÓN] -----------------------------"
}

case "${MODALIDAD}" in
  install)
    modalidad_install
    ;;
  delete)
    modalidad_delete
    ;;
esac
