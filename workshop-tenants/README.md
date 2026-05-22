# Workshop Multi-Tenant — Setup para el ponente

> ⚠️ **Esto NO es para los participantes.** Esta carpeta contiene los scripts y plantillas que **el ponente** ejecuta UNA SOLA VEZ antes del evento para provisionar **60 usuarios IAM** + **1 usuario de prueba (`ponente-test`)** aislados dentro de su propia cuenta AWS. Los participantes simplemente usan su `estudianteNN` + password, abren CloudShell y siguen [Guia-Participantes.md](../../Guia-Participantes.md) normal.

## Qué hace este directorio

Provisiona **60 sandboxes aislados + 1 usuario de prueba** dentro de una sola cuenta AWS usando:
- **Permission Boundary**: una jaula IAM que limita lo que cada usuario puede hacer (permite Bedrock/Lambda/S3/CFN/API Gateway; bloquea EC2/RDS/SageMaker/etc.).
- **Usuarios IAM individuales**: cada participante recibe `estudianteNN` + password genérica (NN = 01..60).
- **Usuario de prueba (`ponente-test`)**: idéntico a un estudiante pero con nombre distinto, para que **TÚ** valides el flujo end-to-end antes del evento sin "gastar" una cuenta de estudiante.
- **Sufijo único por usuario** en `deploy.sh`: detecta el `IAM_USER` actual y nombra todos los recursos con sufijo (`agente-soporte-estudiante07`, `workshop-agentes-estudiante07-XXX`, etc.). Los 60 stacks + el de prueba coexisten sin colisión.

## Cuándo usar este enfoque

✅ **Cuando tiene sentido:**
- No conseguiste AWS Workshop Studio ni vouchers.
- No quieres exigir cuenta AWS personal a los participantes.
- Estás dispuesto a absorber USD 10–30 de Bedrock para los 50.
- Tienes una cuenta AWS dedicada al workshop (recomendado), no tu cuenta personal con datos sensibles.

❌ **Cuando NO usarlo:**
- Si te aprobaron Workshop Studio → úsalo, es mejor.
- Si los participantes ya van a tener su propia cuenta → guía actual sin esto.
- Si tu cuenta tiene workloads de producción mezclados → riesgo de blast radius.

## Archivos

| Archivo | Propósito |
|---|---|
| `boundary-stack.yaml` | CFN stack que crea la `WorkshopBoundaryPolicy` (Permission Boundary). |
| `create-students.sh` | Crea los 60 estudiantes + 1 usuario de prueba (`ponente-test`) con boundary, password genérica, grupo. Genera `students.csv`. |
| `destroy-students.sh` | Borra los 60 usuarios y sus recursos huérfanos (stacks, buckets). El `ponente-test` se conserva salvo que pases `DELETE_TEST_USER=true`. |
| `students.csv` | (Generado) lista `username,password,console_url` para repartir. |
| `students-summary.txt` | (Generado) resumen con la URL de login. |

## Flujo completo

### Pre-evento (1 semana antes)

```bash
cd Codigo/workshop-tenants

# 1. Despliega la policy de boundary (una sola vez).
aws cloudformation deploy \
  --template-file boundary-stack.yaml \
  --stack-name workshop-boundary \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1

# 2. Crea los 60 usuarios + el usuario de prueba (ponente-test).
chmod +x create-students.sh
bash create-students.sh
#   → Te genera students.csv con username,password,url para cada uno.
#   → La ULTIMA fila del CSV es ponente-test (para TU validacion). NO la repartas.

# 3. (Opcional) Habilita Sonnet 4.5 y Titan v2 en Bedrock (Model catalog).
#    Esto solo lo haces tú una vez; los estudiantes heredan el acceso.

# 4. (Opcional) Pide aumento de cuota de Sonnet 4.5 si esperas tráfico en paralelo.
#    Service Quotas → Amazon Bedrock → "On-demand model inference requests per minute".
```

### Día del evento

1. **Reparte el CSV** o proyecta una pantalla con la tabla `username → password → login_url`. Cada participante toma una fila (uno por persona, sin duplicar).
2. **Anuncia** la URL de login (`https://<ACCOUNT_ID>.signin.aws.amazon.com/console`) y la password genérica.
3. Cada participante:
   - Entra a la consola con su `estudianteNN`.
   - Abre **CloudShell**.
   - `git clone https://github.com/AndresDFX/aws-community-day-2026.git`
   - `cd aws-community-day-2026 && bash deploy.sh`
   - Sigue [Guia-Participantes.md](../../Guia-Participantes.md).

**El `deploy.sh` detecta automáticamente que estás como `estudiante07`** y nombra todos los recursos con ese sufijo. Los 60 stacks (más el de `ponente-test` si lo dejaste) no colisionan entre sí.

### Post-evento (mismo día o al día siguiente)

```bash
cd Codigo/workshop-tenants

# 1. Destruye TODOS los stacks de los estudiantes (los que no corrieron destroy.sh).
# 2. Borra usuarios IAM, login profiles, group memberships.
# 3. Borra buckets S3 huérfanos.
bash destroy-students.sh

# 4. (Opcional) Borra la policy de boundary si no vas a volver a usarla.
aws cloudformation delete-stack --stack-name workshop-boundary --region us-east-1
```

## Cómo funciona la seguridad

### Permission Boundary (la jaula)

La policy `WorkshopBoundaryPolicy` (definida en `boundary-stack.yaml`) declara:

1. **Allow amplio** sobre los servicios del taller: CloudFormation, Lambda, Bedrock (todos los namespaces), S3, S3 Vectors, API Gateway, Logs, CloudShell.
2. **Allow condicional** para crear/modificar roles IAM **solo si traen el boundary attached**. Sin esto, un estudiante creativo podría crear un rol "admin" y asignárselo a una Lambda.
3. **Allow restringido** para `iam:PassRole` solo a roles cuyo nombre matchea el workshop (`AmazonBedrockExecutionRoleForAgents_*`, `techstore-*`, etc.).
4. **Deny absoluto** sobre EC2, RDS, SageMaker, KMS, Organizations, DynamoDB CreateTable, OpenSearch, Athena, EMR, Glue, todos los servicios de ML pago (Rekognition, Comprehend, Polly…), media transcoding, Marketplace Subscribe, y todas las acciones IAM peligrosas (CreateUser, CreateAccessKey, AttachUserPolicy…).

**Regla AWS:** el permiso efectivo de un usuario con boundary es **la intersección** entre las políticas que tiene (en este caso `AdministratorAccess`) y el boundary. Aunque parezca admin, el boundary lo limita.

### El truco del Permission Boundary en CFN

El `template.yaml` del workshop usa `CAPABILITY_NAMED_IAM` y crea 4 roles. Para que un estudiante pueda crear esos roles **sin escapar del sandbox**, el template **inyecta el boundary** en cada rol que crea (via parámetro `PermissionsBoundaryArn`). `deploy.sh` lo pasa automáticamente.

Si un estudiante intentara crear un rol manualmente sin boundary → recibe `AccessDeniedException` por la condición `iam:PermissionsBoundary` en la policy.

### Aislamiento entre estudiantes

Cada estudiante:
- **Ve** sus propios stacks, sus propios buckets, su propio agente.
- **NO ve** los recursos de otros estudiantes (S3 buckets son únicos por sufijo; IAM roles tienen el sufijo en el nombre; CFN stacks idem).
- **NO puede** modificar el stack de otro estudiante (las APIs IAM/CFN respetan ownership por defecto cuando el ARN tiene un sufijo distinto, y el boundary les bloquea modificar usuarios/grupos que no son ellos).

Hay una pequeña fuga teórica: **podrían listar otros buckets/roles** (`s3:ListAllMyBuckets`, `iam:ListRoles`) porque esos APIs no aceptan resource-level scoping. Para un taller es aceptable; el conocimiento de "existe un bucket llamado workshop-agentes-estudiante42-XXX" no es información sensible.

## Costos esperados

| Concepto | Estimado |
|---|---|
| Bedrock Sonnet 4.5 (60 personas × ~5 prompts) | USD 7–18 |
| Bedrock Titan v2 embeddings (50 ingestas iniciales) | < USD 0.50 |
| S3 Vectors (50 índices vacíos durante 1 día) | < USD 1 |
| Lambda + API Gateway + S3 + CloudWatch | < USD 1 |
| **Total** | **USD 10–20** |

**Optimización:** corre `destroy-students.sh` el mismo día del evento. Cada hora extra con 60 stacks idle suma centavos por S3 Vectors.

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| Throttling de Bedrock con 60 personas simultáneas | Pide aumento de quota antes del evento. Cross-region inference profile (`us.*`) ya está activo y reparte carga. |
| Un estudiante crea un loop infinito de invocaciones | Boundary bloquea recursos que escalen costo (DynamoDB, OpenSearch). Bedrock tiene quota por cuenta. Considera CloudWatch alarm sobre `EstimatedCharges`. |
| Cuotas de cuenta: 50 KBs, 50 agentes, 50 VectorBuckets | Verifica cuotas antes: `aws service-quotas list-service-quotas --service-code bedrock`. Default: ≥ 50 en cada uno. Si no, pide aumento. |
| Estudiante deja recursos sin destruir | `destroy-students.sh` los limpia todos automáticamente. |
| Un participante comparte sus credenciales fuera del evento | Password expira / cámbiala / borra el usuario después. Considera MFA pero complica el setup. |

## FAQ

**P: ¿Tengo que ser admin AWS para correr `create-students.sh`?**
R: Necesitas permisos para `iam:CreateUser`, `iam:CreateLoginProfile`, `iam:CreateGroup`, `iam:AttachGroupPolicy`. AdminAccess o un rol equivalente funciona.

**P: ¿Funciona en una cuenta que ya tiene workloads en producción?**
R: **No recomendado.** El boundary protege a tus workloads de los estudiantes, pero un error en el boundary podría exponer algo. Mejor cuenta dedicada.

**P: ¿Y si un estudiante olvida `bash destroy.sh` y se va?**
R: Tu `destroy-students.sh` los limpia automáticamente al final. Tu costo total termina igual.

**P: ¿Puedo correr esto en una cuenta gratuita / Free Tier?**
R: Sí, pero Bedrock NO está en Free Tier — pagas los tokens. Los otros servicios (Lambda, S3, etc.) sí están en Free Tier para volúmenes de taller.

**P: ¿Cómo cambio el `WORKSHOP_PASSWORD`?**
R: `WORKSHOP_PASSWORD='OtraPassword' bash create-students.sh`. Recuerda regenerar `students.csv`.

**P: ¿Qué pasa si quiero menos / más usuarios?**
R: `NUM_USERS=30 bash create-students.sh`. Los crea idempotentemente.

## Verificación pre-evento (recomendado)

`create-students.sh` ya crea automáticamente un usuario llamado **`ponente-test`** con el mismo boundary y password que los estudiantes — exactamente para esto. Simula como participante:

```bash
# 1. (Ya hecho por create-students.sh) → existe el usuario ponente-test.

# 2. Logout de tu sesion admin.
# 3. Login con ponente-test + la password generica en el login URL.
# 4. Abre CloudShell.
# 5. Dentro de CloudShell:
git clone https://github.com/AndresDFX/aws-community-day-2026.git
cd aws-community-day-2026
bash deploy.sh
# 6. Verifica que el output diga: Modo: multi-tenant (sufijo='ponente-test')
bash test.sh trace 2     # validar tools encadenadas
bash test.sh rag 2       # validar Knowledge Base
bash destroy.sh          # limpiar solo el stack de ponente-test
```

Si esto funciona end-to-end, los 60 usuarios reales también funcionarán.

**El usuario `ponente-test` se conserva por defecto** después del evento (por si quieres revalidar). Para borrarlo al final:

```bash
DELETE_TEST_USER=true bash destroy-students.sh
```

Variables para personalizar:
- `NUM_USERS=30 bash create-students.sh` → 30 estudiantes en vez de 60.
- `CREATE_TEST_USER=false bash create-students.sh` → no crear `ponente-test`.
- `TEST_USER_NAME=mi-test bash create-students.sh` → cambia el nombre del usuario de prueba.
