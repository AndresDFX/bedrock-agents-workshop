# Más allá del Chatbot: Agente Autónomo de Soporte con Amazon Bedrock

¡Bienvenido al taller práctico! Construirás un **Agente de IA Autónomo** para
soporte al cliente que verifica pedidos, procesa reembolsos y consulta un
catálogo de productos — todo sin que le digas explícitamente qué pasos seguir.

La gran diferencia con un chatbot normal: el agente **decide por sí solo** qué
herramientas usar y en qué orden, encadenando múltiples acciones para resolver
tu solicitud de principio a fin.

Usaremos **Amazon Bedrock Agents** con **Claude Haiku 4.5** y desplegaremos toda
la infraestructura con **AWS CloudFormation**.

---

## ¿Qué diferencia a un Agente de un Chatbot?

| Chatbot tradicional | Agente Autónomo (este taller) |
|---|---|
| Responde con texto generado | Ejecuta acciones reales |
| Tú defines el flujo | El modelo decide el flujo |
| Una llamada al modelo por turno | Puede hacer múltiples llamadas a herramientas |
| Conocimiento estático | Consulta datos en tiempo real |

---

## Prerrequisito Único

- Una cuenta de AWS activa.
  (Trabajaremos **100% en la nube** usando **AWS CloudShell**, sin instalar nada local).

---

# Paso 0: Preparación del Entorno

## 0.1 Habilitar acceso a Claude Haiku 4.5 en Amazon Bedrock

1. En la barra de búsqueda de la consola de AWS, escribe **Amazon Bedrock**.
2. En el menú lateral, entra a **Model catalog**.
3. Busca y selecciona **Claude Haiku 4.5**.
4. Haz clic en **Open in Playground**.
5. Completa el formulario de uso con algo como:

```
Educational purposes for an autonomous agents workshop
```

El modelo quedará habilitado para tu cuenta.

### ⚠️ Nota sobre facturación

Recibirás un correo automático con asunto **"You accepted an AWS Marketplace offer"**.
El costo inicial será **$0.00**. Solo se cobrarán fracciones de centavo por las
peticiones del taller.

---

## 0.2 Abrir AWS CloudShell

1. En la consola de AWS, haz clic en el ícono de terminal **CloudShell** (barra superior).
2. Espera a que cargue el entorno (ya trae `aws`, `git`, `zip` y `jq` preinstalados).

---

## 0.3 Descargar el código del taller

```bash
git clone https://github.com/AndresDFX/bedrock-agents-workshop.git
cd bedrock-agents-workshop
```

---

# Estructura del Proyecto

```
.
├── template.yaml          → Infraestructura CloudFormation (roles, Lambda, Agente)
├── deploy.sh              → Script único: empaqueta y despliega todo
├── destroy.sh             → Script único: elimina todos los recursos
├── test.sh                → Script de pruebas (escenarios, trace, chat, compare…)
├── invoke_agent.py        → Cliente boto3 que invoca al agente (streaming + trace + confirmación)
├── invoke_chatbot.py      → Haiku directo sin herramientas (contraste «chatbot»)
└── src/
    └── lambda_function.py → Herramientas del agente (lógica Python)
```

---

# Paso 1: Entendiendo el Código del Agente

## 1.1 Las Herramientas (`src/lambda_function.py`)

La Lambda actúa como el **ejecutor de herramientas** del agente. Implementa tres funciones:

| Herramienta | Qué hace |
|---|---|
| `verificar_pedido` | Consulta el estado y elegibilidad de reembolso |
| `procesar_reembolso` | Aprueba el reembolso si el pedido es elegible (con confirmación humana en Bedrock) |
| `consultar_producto` | Devuelve precio, stock y especificaciones |

## 1.2 La Infraestructura (`template.yaml`)

El template CloudFormation crea los recursos necesarios:

1. **IAM Role (Lambda)** — permisos para ejecutar la función y escribir logs
2. **Lambda Function** — las herramientas que ejecuta el agente
3. **Lambda Permission** — autoriza a Bedrock a invocar la Lambda
4. **IAM Role (Bedrock Agent)** — permite al agente invocar el modelo de IA
5. **Bedrock Agent** — el orquestador que razona y decide qué herramientas usar
6. **Bedrock Agent Alias** — endpoint estable para invocar el agente

💡 **Nota arquitectónica:** El rol del agente DEBE llamarse
`AmazonBedrockExecutionRoleForAgents_*` — es un requisito de AWS Bedrock.

---

# Paso 2: Desplegar la Infraestructura

Un único comando empaqueta la Lambda, sube el ZIP a S3 y lanza el stack:

```bash
bash deploy.sh
```

El script:

1. Crea (si no existe) el bucket `workshop-agentes-<ACCOUNT_ID>`.
2. Empaqueta `src/lambda_function.py` en `lambda.zip`.
3. Sube el ZIP a S3.
4. Ejecuta `aws cloudformation deploy` con el stack `agente-soporte`.
5. Genera `agent.env` con `AGENT_ID` y `ALIAS_ID` listos para usar.

El despliegue tarda ~2-3 minutos. Al terminar, carga las variables en tu shell:

```bash
source agent.env
```

> 🔁 **¿Por qué `deploy.sh` pasa `AliasUpdateToken=$(date +%s)`?**
> El alias `produccion` no usa `RoutingConfiguration` fija, así que Bedrock crea
> automáticamente una nueva versión del agente cada vez que el alias se actualiza.
> Sin ese token cambiante, CloudFormation no detectaría cambios en el alias y el
> alias seguiría apuntando a la versión anterior — sin tus cambios en
> `RequireConfirmation`, instrucciones, ni Action Groups. Con el token, cada
> `bash deploy.sh` propaga los cambios a producción.

## 2.1 Ver los Action Groups en la consola

1. Ve a **Amazon Bedrock → Agents → `techstore-agente-agent`**.
2. La página principal solo muestra un **resumen**. Para ver/editar funciones,
   pulsa **"Edit in Agent Builder"** (botón superior).
3. Dentro del builder verás la sección **"Action groups"** con `SoporteAcciones`
   y las tres funciones; en `procesar_reembolso` aparecerá **"User confirmation"**
   activado.

---

# Paso 3: Probar el Agente Autónomo

El agente se invoca con lenguaje natural. Observa cómo encadena herramientas
automáticamente sin que tú se las indiques.

> 💡 **Nota técnica:** `InvokeAgent` es una operación con respuesta en
> *streaming*. La AWS CLI **no expone** ese subcomando, así que invocamos al
> agente desde Python con `boto3` (el mismo SDK que usa la consola de
> Bedrock). El script `test.sh` se encarga de todo automáticamente.

## Atajo: ejecutar los 3 escenarios de un solo golpe

```bash
bash test.sh
```

También puedes correr un escenario individual: `bash test.sh 1`, `bash test.sh 2`
o `bash test.sh 3`. Demos avanzadas (`trace`, `chat`, `confirm`, `compare`): secciones 3.4–3.7.

> Los escenarios automáticos (`bash test.sh`, escenarios 1–3) exportan
> `AUTO_CONFIRM=CONFIRM` para que `procesar_reembolso` complete sin prompts
> interactivos (la función tiene **confirmación humana** habilitada en el template).

## 3.1 Consulta simple (1 herramienta)

```bash
python invoke_agent.py "¿Cuánto cuesta el monitor y cuántos hay en stock?"
```

## 3.2 Flujo multi-paso autónomo (2 herramientas encadenadas)

Aquí el agente verificará el pedido ANTES de procesar el reembolso — sin que
se lo pidas explícitamente:

```bash
AUTO_CONFIRM=CONFIRM python invoke_agent.py "Quiero un reembolso para mi pedido ORD-1001 porque el producto llegó dañado"
```

(Omitir `AUTO_CONFIRM` si quieres que el script te pregunte en consola antes de ejecutar `procesar_reembolso`.)

**¿Qué hace el agente internamente?**

```
1. Recibe: "Quiero un reembolso para el pedido ORD-1001..."
2. Razona: "Debo verificar si es elegible antes de procesar"
3. Llama:  verificar_pedido(numero_pedido="ORD-1001")
4. Ve:     "Entregado hace 5 días → ELEGIBLE"
5. Llama:  procesar_reembolso(numero_pedido="ORD-1001", motivo="producto llegó dañado")
6. Responde: "Tu reembolso de $1299.99 fue aprobado..."
```

## 3.3 Pedido no elegible (lógica de negocio autónoma)

```bash
python invoke_agent.py "Necesito reembolso del pedido ORD-1004"
```

El agente detectará que han pasado 45 días y rechazará el reembolso con una
explicación clara — todo de forma autónoma.

## 3.4 Ver el razonamiento del agente (trace)

Activa `enableTrace` en boto3 y muestra pasos de orquestación (razonamiento,
invocación de herramientas, observación):

```bash
bash test.sh trace 2
```

También puedes indicar el escenario `1` o `3`. Equivalente:

```bash
source agent.env
python invoke_agent.py --trace "Quiero un reembolso para mi pedido ORD-1001 porque el producto llegó dañado"
```

## 3.5 Multi-turno con la misma sesión (`sessionId`)

```bash
bash test.sh chat
```

Opcional: ver trace también en el chat:

```bash
bash test.sh chat trace
```

## 3.6 Human-in-the-loop (confirmación antes de `procesar_reembolso`)

En `template.yaml`, la función `procesar_reembolso` tiene `RequireConfirmation: true`.
Cuando el agente intenta ejecutarla, la API devuelve `returnControl` y tu aplicación
debe enviar `CONFIRM` o `DENY` en la siguiente llamada (lo hace `invoke_agent.py`).

Demo interactiva:

```bash
bash test.sh confirm
```

Respuesta del prompt: `s` / `si` confirma; cualquier otra cosa niega.

Sin prompts (útil en scripts):

```bash
AUTO_CONFIRM=CONFIRM python invoke_agent.py "Tu mensaje…"
AUTO_CONFIRM=DENY python invoke_agent.py "Tu mensaje…"
```

## 3.7 Chatbot vs agente (mismo prompt)

Compara el mismo texto con **Haiku solo** (`invoke_model`, sin herramientas) frente al **agente**
(orquestación + Lambda):

```bash
bash test.sh compare
```

Internamente el paso del agente usa `AUTO_CONFIRM=CONFIRM` para cerrar el flujo de
reembolso sin interrupciones en pantalla.

## 3.8 (Alternativa) Probar desde la consola de AWS

1. Ve a **Amazon Bedrock → Agents** y abre tu agente.
2. Pulsa **Test** y escribe los mismos prompts en la ventana de prueba.

---

# Paso 3.5: Actualizar un stack ya desplegado

Si modificaste algo (template, código de la Lambda, instrucción del agente) y
quieres aplicar los cambios sin destruir todo, basta con volver a correr:

```bash
bash deploy.sh
```

`deploy.sh` es **idempotente**: reutiliza el bucket si ya existe, vuelve a
empaquetar `lambda.zip`, lo sube a S3 y ejecuta `aws cloudformation deploy`
(que internamente hace `create-or-update`). Si CloudFormation detecta cambios,
los aplica; si no, te dice "No changes to deploy".

> ⚠️ **Truco importante con la Lambda.** El `S3Key` del template es siempre
> `lambda.zip`. Si solo cambiaste `src/lambda_function.py` pero no
> `template.yaml`, CloudFormation puede no detectar el cambio en la Lambda
> (mismo bucket + misma key). Para forzar la actualización tras editar la
> Lambda, ejecuta:
>
> ```bash
> aws lambda update-function-code \
>   --function-name techstore-agente-action-handler \
>   --zip-file fileb://lambda.zip \
>   --region ${AWS_REGION}
> ```
>
> O simplemente corre `bash destroy.sh && bash deploy.sh` para empezar limpio.

Después, vuelve a cargar las variables y re-prueba:

```bash
source agent.env
bash test.sh
```

---

# Paso 4: Destruir los Recursos (Evitar Costos)

```bash
bash destroy.sh
```

Esto elimina el stack de CloudFormation, vacía y borra el bucket S3, y limpia
los archivos locales (`lambda.zip`, `agent.env`).

---

## Resultado

Has construido un **Agente Autónomo de IA** capaz de:

- Razonar sobre qué herramientas usar en cada situación
- Encadenar múltiples llamadas sin instrucciones explícitas
- Aplicar reglas de negocio de forma inteligente
- Responder en lenguaje natural a solicitudes complejas

Tecnologías utilizadas:

- Amazon Bedrock Agents
- Claude Haiku 4.5 (Cross-Region Inference Profile)
- AWS Lambda (Action Group Handler)
- AWS CloudFormation (IaC)
- AWS IAM

---

Desarrollado con ☁️ para AWS Community Day.
