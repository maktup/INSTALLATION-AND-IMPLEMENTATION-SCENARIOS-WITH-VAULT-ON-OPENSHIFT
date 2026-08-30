#!/bin/bash

# ==============================================================================
# INSTALACIÓN / DESINSTALACIÓN - MARIADB en OPENSHIFT
# ==============================================================================
# INSTALA la BD de tipo MARIADB en OPENSHIFT.
#
#   --modalidad=install  → Crea namespace, Service, PVC y Deployment de
#                          MariaDB; espera disponibilidad, ejecuta SQL
#                          inicial y valida la conexión.
#   --modalidad=delete   → Elimina en orden: Deployment, Service, PVC
#                          & namespace.
#
# CARACTERÍSTICAS:
#   _ RÉPLICAS  : 1 (Deployment single-pod)
#   _ CPU       : sin requests/limits definidos — sin restricción de CPU
#   _ MEMORIA   : sin requests/limits definidos — sin restricción de memoria
#   _ STORAGE   : 5Gi PVC (ocs-external-storagecluster-ceph-rbd)
#   _ TLS       : no — acceso interno ClusterIP puerto 3306
#   _ SEGURIDAD : credenciales en variables de entorno del pod
#   _ NAMESPACE : dummy-database
#   _ EXTRAS    : SQL inicial con tabla TB_EMPLEADOS & registro de prueba
#                 + usuario Vault con permisos para dynamic credentials
#
# PRERREQUISITOS:
#   1. Autenticación en OPENSHIFT activa: $ oc login ...
#
# REQUERIMIENTOS DE INFRAESTRUCTURA:
#   _ CPU     : sin límite definido — el pod compite por CPU disponible en el nodo
#   _ MEMORIA : sin límite definido — el pod compite por memoria disponible en el nodo
#   _ STORAGE : 1 × 5Gi PVC (ocs-external-storagecluster-ceph-rbd)
#   _ NODOS   : 1 worker con acceso a la StorageClass: 'ocs-external-storagecluster-ceph-rbd'
#
# USO:
#   $ sh ./2_Script_Instalacion_MariaDB.sh --modalidad=install
#   $ sh ./2_Script_Instalacion_MariaDB.sh --modalidad=delete
# ==============================================================================

set -e

# --- Parámetros ---
NAMESPACE="dummy-database"

APP_NAME="mariadb"
SERVICE_NAME="mariadb"
PVC_NAME="mariadb-pvc"
DEPLOYMENT_NAME="mariadb"

MARIADB_IMAGE="mariadb:10.5"
MARIADB_PORT="3306"

# Ajustar según la StorageClass disponible en el clúster OCP.
STORAGE_CLASS_NAME="ocs-external-storagecluster-ceph-rbd"
STORAGE_SIZE="5Gi"

# NOTA: En entornos productivos estas variables deben provenir de un Secret.
MYSQL_USER="admin"
MYSQL_PASSWORD="admin"
MYSQL_DATABASE="mariadb"
MYSQL_ROOT_PASSWORD="rootpassword"

TABLE_NAME="TB_EMPLEADOS"
EMP_NOMBRES="CESAR RICARDO"
EMP_APELLIDOS="GUERRA ARNAIZ"
EMP_DNI="41816133"

# --- Utilidades ---
print_cmd() {
  echo ""
  echo "Sentencia ejecutada:"
  echo "$1"
  echo ""
}

# Usuario que Vault usará para conectarse y crear credenciales dinámicas.
# Debe coincidir con el connection_url configurado en Vault database secrets engine.
VAULT_DB_USER="vault"
VAULT_DB_PASSWORD="vaultpassword"

usage() {
  echo ""
  echo "Uso: $0 --modalidad=<install|delete>"
  echo ""
  echo "  --modalidad=install   Instala MariaDB en el namespace '${NAMESPACE}'"
  echo "  --modalidad=delete    Elimina todos los recursos de MariaDB del namespace '${NAMESPACE}'"
  echo ""
  exit 1
}

MODALIDAD=""

for arg in "$@"; do
  case "${arg}" in
    --modalidad=install)
      MODALIDAD="install"
      ;;
    --modalidad=delete)
      MODALIDAD="delete"
      ;;
    --modalidad=*)
      echo "ERROR: Modalidad desconocida: '${arg}'"
      usage
      ;;
    *)
      echo "ERROR: Argumento no reconocido: '${arg}'"
      usage
      ;;
  esac
done

if [ -z "${MODALIDAD}" ]; then
  echo "ERROR: Debe especificar una modalidad."
  usage
fi

modalidad_delete() {
  echo "----------------------------- [INICIO DE ELIMINACIÓN MARIADB] -----------------------------"

  echo "===> 1. ELIMINANDO DEPLOYMENT: ${DEPLOYMENT_NAME}"
  oc delete deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true

  echo "===> 2. ESPERANDO QUE EL POD TERMINE"
  oc wait pod --for=delete -l app="${APP_NAME}" -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true

  echo "===> 3. ELIMINANDO SERVICE: ${SERVICE_NAME}"
  oc delete svc "${SERVICE_NAME}" -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true

  echo "===> 4. ELIMINANDO PVC: ${PVC_NAME}"
  oc delete pvc "${PVC_NAME}" -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true

  echo "===> 5. ELIMINANDO NAMESPACE: ${NAMESPACE}"
  oc delete ns "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true

  # Esperar a que el namespace desaparezca completamente antes de retornar
  # (importante para reinstall: evita colisión al re-crear el namespace)
  echo "===> 6. ESPERANDO QUE EL NAMESPACE SE ELIMINE COMPLETAMENTE"
  for i in $(seq 1 24); do
    if ! oc get ns "${NAMESPACE}" 2>/dev/null | grep -q "${NAMESPACE}"; then
      echo "Namespace '${NAMESPACE}' eliminado."
      break
    fi
    echo "Esperando eliminación del namespace... intento ${i}/24"
    sleep 5
  done

  echo ""
  echo "----------------------------- [TÉRMINO DE ELIMINACIÓN DE: MARIADB] -----------------------------"
}

modalidad_install() {
  echo "----------------------------- [INICIO DE INSTALACIÓN DE: MARIADB] -----------------------------"

  echo "===> 1. CREANDO NAMESPACE: ${NAMESPACE}"
  oc create ns "${NAMESPACE}" 2>/dev/null || true

  echo "===> 2. APLICANDO YAML DE MARIADB"

  print_cmd "oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  selector:
    app: ${APP_NAME}
  ports:
    - name: mysql
      port: ${MARIADB_PORT}
      targetPort: ${MARIADB_PORT}
      protocol: TCP
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS_NAME}
  resources:
    requests:
      storage: ${STORAGE_SIZE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
        - name: ${APP_NAME}
          image: ${MARIADB_IMAGE}
          ports:
            - containerPort: ${MARIADB_PORT}
              name: mysql
          env:
            - name: MYSQL_USER
              value: \"${MYSQL_USER}\"
            - name: MYSQL_PASSWORD
              value: \"${MYSQL_PASSWORD}\"
            - name: MYSQL_DATABASE
              value: \"${MYSQL_DATABASE}\"
            - name: MYSQL_ROOT_PASSWORD
              value: \"${MYSQL_ROOT_PASSWORD}\"
          volumeMounts:
            - name: mariadb-storage
              mountPath: /var/lib/mysql
      volumes:
        - name: mariadb-storage
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF"

  oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  selector:
    app: ${APP_NAME}
  ports:
    - name: mysql
      port: ${MARIADB_PORT}
      targetPort: ${MARIADB_PORT}
      protocol: TCP
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS_NAME}
  resources:
    requests:
      storage: ${STORAGE_SIZE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
        - name: ${APP_NAME}
          image: ${MARIADB_IMAGE}
          ports:
            - containerPort: ${MARIADB_PORT}
              name: mysql
          env:
            - name: MYSQL_USER
              value: "${MYSQL_USER}"
            - name: MYSQL_PASSWORD
              value: "${MYSQL_PASSWORD}"
            - name: MYSQL_DATABASE
              value: "${MYSQL_DATABASE}"
            - name: MYSQL_ROOT_PASSWORD
              value: "${MYSQL_ROOT_PASSWORD}"
          volumeMounts:
            - name: mariadb-storage
              mountPath: /var/lib/mysql
      volumes:
        - name: mariadb-storage
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF

  echo "===> 3. OBTENIENDO PODS"
  oc get pods -n "${NAMESPACE}"
  echo ""

  echo "===> 4. ESPERANDO DISPONIBILIDAD DEL DEPLOYMENT"
  oc rollout status "deployment/${DEPLOYMENT_NAME}" -n "${NAMESPACE}"
  echo ""

  echo "===> 5. OBTENIENDO POD DE MARIADB"
  MARIADB_POD=$(oc get pods -n "${NAMESPACE}" -l app="${APP_NAME}" -o jsonpath='{.items[0].metadata.name}')
  echo "POD encontrado: ${MARIADB_POD}"
  echo ""

  # OpenShift corre el pod con UID aleatorio (ej: 1000940000), no como root del SO.
  # Por eso el plugin unix_socket de MariaDB deniega la conexión sin contraseña.
  # Solución: conectar por TCP (-h 127.0.0.1) con la contraseña root → evita unix_socket.
  #
  # Espera en dos fases:
  #   Fase A — mysqladmin ping por TCP: el proceso acepta conexiones TCP.
  #   Fase B — verificar que la base de datos fue creada por el entrypoint.
  echo "===> 6. ESPERANDO QUE MARIADB ACEPTE CONEXIONES"
  MAX_RETRIES=15
  SLEEP_SECONDS=5

  print_cmd "oc rsh -n ${NAMESPACE} -c ${APP_NAME} ${MARIADB_POD} mysqladmin ping -h 127.0.0.1 -u root -p******** --silent"

  for i in $(seq 1 "${MAX_RETRIES}"); do
    echo "Intento ${i}/${MAX_RETRIES}: esperando que MariaDB acepte conexiones TCP..."

    if oc rsh -n "${NAMESPACE}" -c "${APP_NAME}" "${MARIADB_POD}" \
      mysqladmin ping -h 127.0.0.1 -u root -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; then
      echo "MariaDB activo y aceptando conexiones TCP."
      break
    fi

    if [ "${i}" -eq "${MAX_RETRIES}" ]; then
      echo "ERROR: MariaDB no estuvo disponible después de varios intentos."
      exit 1
    fi

    sleep "${SLEEP_SECONDS}"
  done

  print_cmd "oc rsh -n ${NAMESPACE} -c ${APP_NAME} ${MARIADB_POD} mysql -h 127.0.0.1 -u root -p******** -e \"SHOW DATABASES LIKE '${MYSQL_DATABASE}';\""

  for i in $(seq 1 "${MAX_RETRIES}"); do
    echo "Intento ${i}/${MAX_RETRIES}: esperando que la base de datos '${MYSQL_DATABASE}' exista..."

    DB_EXISTS=$(oc rsh -n "${NAMESPACE}" -c "${APP_NAME}" "${MARIADB_POD}" \
      mysql -h 127.0.0.1 -u root -p"${MYSQL_ROOT_PASSWORD}" \
      -e "SHOW DATABASES LIKE '${MYSQL_DATABASE}';" 2>/dev/null | grep -c "${MYSQL_DATABASE}" || true)

    if [ "${DB_EXISTS}" -ge 1 ]; then
      echo "Base de datos '${MYSQL_DATABASE}' disponible."
      break
    fi

    if [ "${i}" -eq "${MAX_RETRIES}" ]; then
      echo "ERROR: La base de datos '${MYSQL_DATABASE}' no fue creada por el entrypoint."
      exit 1
    fi

    sleep "${SLEEP_SECONDS}"
  done
  echo ""

  echo "===> 7. EJECUTANDO COMANDOS SQL EN MARIADB"
 
  SQL_COMMANDS="
-- *** Usuario de aplicación ***
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';

-- *** Usuario de Vault (para dynamic credentials) ***
CREATE USER IF NOT EXISTS '${VAULT_DB_USER}'@'%' IDENTIFIED BY '${VAULT_DB_PASSWORD}';
ALTER USER '${VAULT_DB_USER}'@'%' IDENTIFIED BY '${VAULT_DB_PASSWORD}';
GRANT CREATE USER ON *.* TO '${VAULT_DB_USER}'@'%' WITH GRANT OPTION;
GRANT SELECT ON mysql.global_priv TO '${VAULT_DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${VAULT_DB_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;

-- *** Validación de usuarios creados ***
SELECT User, Host FROM mysql.global_priv WHERE User IN ('${MYSQL_USER}','${VAULT_DB_USER}');

-- *** Tabla de prueba ***
CREATE TABLE IF NOT EXISTS \`${TABLE_NAME}\` (
  id INT PRIMARY KEY AUTO_INCREMENT,
  nombres VARCHAR(50),
  apellidos VARCHAR(50),
  dni VARCHAR(100)
);

INSERT INTO \`${TABLE_NAME}\`(nombres, apellidos, dni)
VALUES('${EMP_NOMBRES}', '${EMP_APELLIDOS}', '${EMP_DNI}');

SELECT * FROM \`${TABLE_NAME}\`;
"

  # Conexión por TCP (-h 127.0.0.1) con contraseña: evita unix_socket plugin.
  print_cmd "oc rsh -n ${NAMESPACE} -c ${APP_NAME} ${MARIADB_POD} mysql -h 127.0.0.1 -u root -p********"

  oc rsh -n "${NAMESPACE}" -c "${APP_NAME}" "${MARIADB_POD}" \
    mysql -h 127.0.0.1 -u root -p"${MYSQL_ROOT_PASSWORD}" <<EOF
USE \`${MYSQL_DATABASE}\`;
${SQL_COMMANDS}
EOF
  echo ""

  echo "===> 8. VALIDANDO CONEXIÓN CON USUARIO ${MYSQL_USER}"

  print_cmd "oc rsh -n ${NAMESPACE} -c ${APP_NAME} ${MARIADB_POD} mysql -u ${MYSQL_USER} -p******** ${MYSQL_DATABASE} -e 'SELECT * FROM \`${TABLE_NAME}\`;'"

  oc rsh -n "${NAMESPACE}" -c "${APP_NAME}" "${MARIADB_POD}" \
    mysql -h 127.0.0.1 -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "${MYSQL_DATABASE}" \
    -e "SELECT * FROM \`${TABLE_NAME}\`;"
  echo ""

  echo "===> 9. VALIDANDO CONEXIÓN CON USUARIO VAULT: ${VAULT_DB_USER}"

  print_cmd "oc rsh -n ${NAMESPACE} -c ${APP_NAME} ${MARIADB_POD} mysql -h 127.0.0.1 -u ${VAULT_DB_USER} -p******** ${MYSQL_DATABASE} -e 'SHOW GRANTS;'"

  oc rsh -n "${NAMESPACE}" -c "${APP_NAME}" "${MARIADB_POD}" \
    mysql -h 127.0.0.1 -u "${VAULT_DB_USER}" -p"${VAULT_DB_PASSWORD}" "${MYSQL_DATABASE}" \
    -e "SHOW GRANTS;"
  echo ""

  echo "===> 10. OBTENIENDO SERVICE DNS PARA CONEXIÓN DESDE PODS"
  oc get svc "${SERVICE_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.metadata.name}.{.metadata.namespace}.svc.cluster.local'
  echo ""

  echo ""
  echo "============================================================"
  echo " RESUMEN DE CONEXIÓN"
  echo "============================================================"
  echo " SERVICE DNS : ${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
  echo " PUERTO      : ${MARIADB_PORT}"
  echo " BASE DE DATOS: ${MYSQL_DATABASE}"
  echo " USUARIO APP : ${MYSQL_USER}"
  echo " USUARIO VAULT: ${VAULT_DB_USER}"
  echo ""
  echo " CONNECTION STRING PARA VAULT:"
  echo " ${VAULT_DB_USER}:${VAULT_DB_PASSWORD}@tcp(${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local:${MARIADB_PORT})/${MYSQL_DATABASE}"
  echo "============================================================"
  echo ""

  echo "----------------------------- [TÉRMINO DE INSTALACIÓN DE: MARIADB] -----------------------------"
}

case "${MODALIDAD}" in
  install)
    modalidad_install
    ;;
  delete)
    modalidad_delete
    ;;
esac
