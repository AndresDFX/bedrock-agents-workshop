#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# create-students.sh
#
# Crea N usuarios IAM (estudiante01..estudianteNN) en la cuenta del ponente,
# todos con el Permission Boundary del workshop adjuntado, password generica
# y permisos para hacer el taller sin escapar del sandbox.
#
# Pre-requisitos:
#   1. Haber desplegado boundary-stack.yaml (cfn create-stack).
#   2. AWS CLI configurada como usuario admin / root de la cuenta del ponente.
#   3. jq instalado (CloudShell ya lo trae).
#
# Variables de entorno opcionales:
#   NUM_USERS          (default 50)   Cuantos usuarios crear.
#   WORKSHOP_PASSWORD  (default       Password generica para todos.
#                       TallerBedrock2026!)
#   BOUNDARY_NAME      (default       Nombre de la policy de boundary.
#                       WorkshopBoundaryPolicy)
#   GROUP_NAME         (default       Grupo IAM al que se agregan.
#                       WorkshopStudents)
#   REGION             (default us-east-1)
#   USER_PREFIX        (default estudiante)
#   START_INDEX        (default 1)
#
# Salida:
#   students.csv               Lista username,password,console_url
#   students-summary.txt       Resumen para el ponente con la URL de login
#
# Idempotencia:
#   Si un usuario ya existe, se reusa (no se recrea).
#   Si el grupo o la policy no existen, falla con instrucciones.
# ---------------------------------------------------------------------------

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
NUM_USERS="${NUM_USERS:-60}"
START_INDEX="${START_INDEX:-1}"
PASSWORD="${WORKSHOP_PASSWORD:-TallerBedrock2026!}"
BOUNDARY_NAME="${BOUNDARY_NAME:-WorkshopBoundaryPolicy}"
GROUP_NAME="${GROUP_NAME:-WorkshopStudents}"
USER_PREFIX="${USER_PREFIX:-estudiante}"

# Usuario adicional de prueba para que el ponente valide end-to-end ANTES del
# evento. Se crea con el mismo boundary y la misma password, pero con un nombre
# distinto al de los estudiantes (no se mete en el conteo de NUM_USERS).
# Pon CREATE_TEST_USER=false para saltarlo.
CREATE_TEST_USER="${CREATE_TEST_USER:-true}"
TEST_USER_NAME="${TEST_USER_NAME:-ponente-test}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_FILE="${SCRIPT_DIR}/students.csv"
SUMMARY_FILE="${SCRIPT_DIR}/students-summary.txt"

echo "==> Verificando credenciales AWS..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "    Cuenta:  ${ACCOUNT_ID}"
echo "    Identidad: ${CALLER_ARN}"
echo "    Region:  ${REGION}"

BOUNDARY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${BOUNDARY_NAME}"
BOUNDARY_STACK_NAME="${BOUNDARY_STACK_NAME:-workshop-boundary}"
BOUNDARY_TEMPLATE="${SCRIPT_DIR}/boundary-stack.yaml"

# ---------------------------------------------------------------------------
# Asegurar que el stack del boundary esta desplegado y al dia. SIEMPRE corremos
# cloudformation deploy (idempotente):
#   - Si el stack no existe, lo crea.
#   - Si existe, aplica el cambio si hay diferencias; si no, dice "No changes".
# Asi cuando el template del boundary cambia (ej. nuevos ARNs en PassRole),
# el usuario solo tiene que reejecutar este script y el boundary se actualiza.
# ---------------------------------------------------------------------------
echo "==> Desplegando / actualizando stack del boundary (${BOUNDARY_STACK_NAME})..."
if [ ! -f "${BOUNDARY_TEMPLATE}" ]; then
  echo ""
  echo "❌ No se encontro ${BOUNDARY_TEMPLATE}."
  echo "   Asegurate de correr este script desde Codigo/workshop-tenants/"
  echo "   o ajusta SCRIPT_DIR / BOUNDARY_TEMPLATE."
  exit 1
fi

aws cloudformation deploy \
  --template-file "${BOUNDARY_TEMPLATE}" \
  --stack-name "${BOUNDARY_STACK_NAME}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "${REGION}" \
  --no-fail-on-empty-changeset

echo "    Verificando policy tras el deploy..."
for _ in 1 2 3 4 5; do
  if aws iam get-policy --policy-arn "${BOUNDARY_ARN}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! aws iam get-policy --policy-arn "${BOUNDARY_ARN}" >/dev/null 2>&1; then
  echo ""
  echo "❌ La policy ${BOUNDARY_NAME} no esta visible tras el deploy."
  echo "   Revisa eventos del stack:"
  echo "     aws cloudformation describe-stack-events --stack-name ${BOUNDARY_STACK_NAME} --region ${REGION}"
  exit 1
fi
echo "    Boundary OK: ${BOUNDARY_ARN}"

# ---------------------------------------------------------------------------
# Crear (o reusar) el grupo del workshop. Le adjuntamos AdministratorAccess
# directamente; el Permission Boundary intersecta y limita el alcance real.
# ---------------------------------------------------------------------------
echo "==> Asegurando grupo IAM (${GROUP_NAME})..."
if aws iam get-group --group-name "${GROUP_NAME}" >/dev/null 2>&1; then
  echo "    Grupo ya existe."
else
  aws iam create-group --group-name "${GROUP_NAME}" >/dev/null
  echo "    Grupo creado."
fi

echo "==> Adjuntando AdministratorAccess al grupo (boundary lo restringira)..."
aws iam attach-group-policy \
  --group-name "${GROUP_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess >/dev/null 2>&1 || true
echo "    Listo."

# ---------------------------------------------------------------------------
# Genera el CSV / summary con header.
# ---------------------------------------------------------------------------
LOGIN_URL="https://${ACCOUNT_ID}.signin.aws.amazon.com/console"

echo "username,password,console_url" > "${CSV_FILE}"

{
  echo "Workshop multi-tenant — resumen para el ponente"
  echo "==============================================="
  echo "Cuenta AWS:        ${ACCOUNT_ID}"
  echo "Region:            ${REGION}"
  echo "Login URL:         ${LOGIN_URL}"
  echo "Password generica: ${PASSWORD}"
  echo "Boundary policy:   ${BOUNDARY_NAME}"
  echo "Grupo IAM:         ${GROUP_NAME}"
  echo "Estudiantes:       ${NUM_USERS} (${USER_PREFIX}$(printf '%02d' "${START_INDEX}")..${USER_PREFIX}$(printf '%02d' $((START_INDEX + NUM_USERS - 1))))"
  if [ "${CREATE_TEST_USER}" = "true" ]; then
    echo "Usuario de prueba: ${TEST_USER_NAME} (validacion pre-evento del ponente)"
  fi
  echo ""
  echo "Reparte el archivo students.csv entre los participantes:"
  echo "una fila por persona. La ultima fila (${TEST_USER_NAME}) NO la repartas,"
  echo "es para tu propia validacion antes del evento."
  echo ""
} > "${SUMMARY_FILE}"

# ---------------------------------------------------------------------------
# Bucle de creacion. Idempotente: si el usuario existe, se reusa.
# ---------------------------------------------------------------------------
echo "==> Creando ${NUM_USERS} usuarios IAM con Permission Boundary..."
CREATED=0
REUSED=0

END_INDEX=$((START_INDEX + NUM_USERS - 1))
for i in $(seq "${START_INDEX}" "${END_INDEX}"); do
  USERNAME="${USER_PREFIX}$(printf '%02d' "${i}")"

  # 1. Usuario (con boundary). Si existe, sigue.
  if aws iam get-user --user-name "${USERNAME}" >/dev/null 2>&1; then
    echo "    [reuse] ${USERNAME}"
    REUSED=$((REUSED + 1))
  else
    aws iam create-user \
      --user-name "${USERNAME}" \
      --permissions-boundary "${BOUNDARY_ARN}" \
      --tags Key=Workshop,Value=BedrockAgents2026 \
             Key=ManagedBy,Value=create-students.sh \
      >/dev/null
    echo "    [crear] ${USERNAME}"
    CREATED=$((CREATED + 1))
  fi

  # 2. Asegurar que el boundary esta puesto (por si el usuario existia sin el).
  aws iam put-user-permissions-boundary \
    --user-name "${USERNAME}" \
    --permissions-boundary "${BOUNDARY_ARN}" >/dev/null

  # 3. Login profile (password).
  if aws iam get-login-profile --user-name "${USERNAME}" >/dev/null 2>&1; then
    # Reset password al valor generico para mantener consistencia.
    aws iam update-login-profile \
      --user-name "${USERNAME}" \
      --password "${PASSWORD}" \
      --no-password-reset-required >/dev/null 2>&1 || true
  else
    aws iam create-login-profile \
      --user-name "${USERNAME}" \
      --password "${PASSWORD}" \
      --no-password-reset-required >/dev/null
  fi

  # 4. Agregar al grupo (hereda permisos del grupo + boundary).
  aws iam add-user-to-group \
    --user-name "${USERNAME}" \
    --group-name "${GROUP_NAME}" >/dev/null 2>&1 || true

  # 5. Append al CSV.
  echo "${USERNAME},${PASSWORD},${LOGIN_URL}" >> "${CSV_FILE}"
done

echo ""
echo "✅ Estudiantes listos."
echo "    Creados nuevos: ${CREATED}"
echo "    Reusados:       ${REUSED}"
echo "    Total final:    ${NUM_USERS}"
echo ""

# ---------------------------------------------------------------------------
# Usuario adicional de PRUEBA para que el ponente valide end-to-end ANTES del
# evento. Se crea con el mismo boundary, misma password y mismo grupo que los
# estudiantes, pero con un nombre distinto para que sea facil identificarlo y
# borrarlo aparte si quieres. No se incluye en NUM_USERS.
# ---------------------------------------------------------------------------
if [ "${CREATE_TEST_USER}" = "true" ]; then
  echo "==> Creando usuario de PRUEBA para el ponente (${TEST_USER_NAME})..."

  if aws iam get-user --user-name "${TEST_USER_NAME}" >/dev/null 2>&1; then
    echo "    [reuse] ${TEST_USER_NAME}"
  else
    aws iam create-user \
      --user-name "${TEST_USER_NAME}" \
      --permissions-boundary "${BOUNDARY_ARN}" \
      --tags Key=Workshop,Value=BedrockAgents2026 \
             Key=ManagedBy,Value=create-students.sh \
             Key=Purpose,Value=PreEventValidation \
      >/dev/null
    echo "    [crear] ${TEST_USER_NAME}"
  fi

  # Boundary attached (idempotente).
  aws iam put-user-permissions-boundary \
    --user-name "${TEST_USER_NAME}" \
    --permissions-boundary "${BOUNDARY_ARN}" >/dev/null

  # Login profile.
  if aws iam get-login-profile --user-name "${TEST_USER_NAME}" >/dev/null 2>&1; then
    aws iam update-login-profile \
      --user-name "${TEST_USER_NAME}" \
      --password "${PASSWORD}" \
      --no-password-reset-required >/dev/null 2>&1 || true
  else
    aws iam create-login-profile \
      --user-name "${TEST_USER_NAME}" \
      --password "${PASSWORD}" \
      --no-password-reset-required >/dev/null
  fi

  # Grupo (hereda AdministratorAccess intersectado con el boundary).
  aws iam add-user-to-group \
    --user-name "${TEST_USER_NAME}" \
    --group-name "${GROUP_NAME}" >/dev/null 2>&1 || true

  # Lo agregamos al final del CSV con tag explicito.
  echo "${TEST_USER_NAME},${PASSWORD},${LOGIN_URL}" >> "${CSV_FILE}"

  echo "    ✅ Usuario de prueba listo."
  echo ""
  echo "    >>> Usalo para validar end-to-end ANTES del evento: <<<"
  echo "        1. Logout de tu sesion admin."
  echo "        2. Login con ${TEST_USER_NAME} + ${PASSWORD} en ${LOGIN_URL}."
  echo "        3. Abre CloudShell."
  echo "        4. git clone https://github.com/AndresDFX/aws-community-day-2026.git"
  echo "        5. cd aws-community-day-2026 && bash deploy.sh"
  echo "        6. Verifica que dice: Modo: multi-tenant (sufijo='${TEST_USER_NAME}')"
  echo "        7. bash test.sh trace 2  (validar tools)"
  echo "        8. bash test.sh rag 2    (validar KB)"
  echo "        9. bash destroy.sh       (limpia el stack del ponente-test)"
  echo ""
fi


echo "📄 Archivos generados:"
echo "    ${CSV_FILE}"
echo "    ${SUMMARY_FILE}"
echo ""
echo "🔗 URL de login para los participantes:"
echo "    ${LOGIN_URL}"
echo ""
echo "🔐 Password generica:"
echo "    ${PASSWORD}"
echo ""
echo "Cada estudiante entra con su usuario (${USER_PREFIX}XX) + esa password,"
echo "abre CloudShell, hace 'git clone ...' y sigue Guia-Participantes.md."
echo "deploy.sh detecta su username y nombra los recursos con sufijo unico."
if [ "${CREATE_TEST_USER}" = "true" ]; then
  echo ""
  echo "🧪 IMPORTANTE: NO repartas la fila '${TEST_USER_NAME}' del CSV."
  echo "   Esa cuenta es para que TU valides el flujo end-to-end ANTES"
  echo "   del evento. Una vez validada, dejala creada (no la borres)"
  echo "   para revalidar el dia del evento si hay dudas."
fi
