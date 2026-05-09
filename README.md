# Más allá del Chatbot: Agente Autónomo de Soporte con Amazon Bedrock

¡Bienvenido al taller práctico! Construirás un **Agente de IA Autónomo** para
soporte al cliente que verifica pedidos, procesa reembolsos, consulta un
catálogo de productos **y responde sobre las políticas de la empresa con RAG**
— todo sin que le digas explícitamente qué pasos seguir.

La gran diferencia con un chatbot normal: el agente **decide por sí solo** qué
herramientas o fuentes consultar y en qué orden, encadenando múltiples
acciones (`Lambda` + `Knowledge Base`) para resolver la solicitud de principio
a fin.

Usaremos **Amazon Bedrock Agents** con **Claude Haiku 4.5**, embeddings
**Titan v2** sobre **Amazon S3 Vectors**, y desplegaremos toda la
infraestructura con **AWS CloudFormation**.

---

## ¿Qué diferencia a un Agente de un Chatbot?

| Chatbot tradicional | Agente Autónomo (este taller) |
|---|---|
| Responde con texto generado | Ejecuta acciones reales |
| Tú defines el flujo | El modelo decide el flujo |
| Una llamada al modelo por turno | Puede hacer múltiples llamadas a herramientas |
| Conocimiento estático en el modelo | Consulta datos en tiempo real (`Lambda`) **y** documentos vectorizados (`Knowledge Base`) |
| Inventa cuando no sabe | Cita fuentes y reconoce sus límites |

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
├── template.yaml           → Infraestructura CloudFormation (roles, Lambda, Agente, KB, S3 Vectors)
├── deploy.sh               → Script único: empaqueta, sube docs, despliega y dispara la ingesta
├── destroy.sh              → Script único: elimina todos los recursos
├── test.sh                 → Script de pruebas (escenarios, trace, chat, compare, rag…)
├── invoke_agent.py         → Cliente boto3 que invoca al agente (streaming + trace + confirmación + KB)
├── invoke_chatbot.py       → Haiku directo sin herramientas ni RAG (contraste «chatbot»)
├── web/                    → Sitio estático (S3 website): UI comparativa en dos columnas
├── src-web/                → Lambda demo web: streaming Haiku vs agente (`chat_lambda.js` + CLI Python opcional)
├── src/
│   └── lambda_function.py  → Herramientas del agente (lógica Python para pedidos y catálogo)
└── kb-data/                → Documentos seed que se indexan en la Knowledge Base
    ├── politicas-devoluciones.md
    ├── politicas-garantia.md
    ├── politicas-envio.md
    ├── metodos-pago.md
    ├── faq-soporte.md
    ├── catalogo-detallado.md
    ├── info-empresa.md       (datos demo / ficticios)
    ├── programa-fidelidad.md (datos demo / ficticios — TechCoins)
    └── sucursales.md         (datos demo / ficticios)
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

1. **IAM Role (Lambda)** — permisos para ejecutar la función y escribir logs.
2. **Lambda Function** — las herramientas que ejecuta el agente.
3. **Lambda Permission** — autoriza a Bedrock a invocar la Lambda.
4. **IAM Role (Bedrock Agent)** — permite al agente invocar el modelo y
   consultar la Knowledge Base (`bedrock:Retrieve`).
5. **S3 Vectors VectorBucket + VectorIndex** — almacenamiento serverless de
   embeddings (1024 dim, distancia coseno).
6. **IAM Role (Knowledge Base)** — lee S3 (data source), escribe en S3 Vectors,
   invoca el modelo de embeddings.
7. **Bedrock Knowledge Base** — orquesta los embeddings y el storage vectorial.
8. **Bedrock Data Source** — apunta al prefijo `kb-data/` del bucket S3.
9. **Bedrock Agent** — orquestador que razona y decide qué fuente consultar
   (`Lambda` o `KnowledgeBase`).
10. **Bedrock Agent Alias** — endpoint estable para invocar el agente.
11. **Bucket S3 + política de lectura pública** — aloja la página estática `web/`
    (solo taller / demo).
12. **Lambda `*-chat-demo` + Function URL (`RESPONSE_STREAM`)** — recibe el POST con el prompt,
    llama a Bedrock en modo Haiku directo o modo agente y devuelve texto en streaming.

💡 **Nota arquitectónica:** El rol del agente DEBE llamarse
`AmazonBedrockExecutionRoleForAgents_*` — es un requisito de AWS Bedrock. Lo
mismo aplica para el rol de la KB con prefijo
`AmazonBedrockExecutionRoleForKnowledgeBase_*`.

## 1.3 ¿Por qué S3 Vectors y no OpenSearch Serverless?

Bedrock Knowledge Bases admite varios *vector stores*: OpenSearch Serverless
(OSS), Aurora con `pgvector`, Pinecone, MongoDB Atlas, Neptune Analytics y —
desde diciembre 2025 — **Amazon S3 Vectors**.

| | OpenSearch Serverless | **S3 Vectors (este taller)** |
|---|---|---|
| Cuesta solo cuando se usa | ❌ paga por *OCU/hora* (≈$170/mes mínimo) | ✅ paga por GB y por consulta |
| Setup en CloudFormation | Collection + 3 políticas + Lambda custom para crear el índice | 2 recursos (`VectorBucket` + `Index`) |
| Latencia p99 | <50 ms | <100 ms |
| Bueno para | Búsqueda compleja con filtros, ANN ajustado | Talleres, prototipos, RAG con bajo tráfico |

Como este taller debe poder borrarse al final sin generar costos, S3 Vectors
es la opción ganadora.

---

# Paso 2: Desplegar la Infraestructura

Un único comando empaqueta la Lambda, sube el ZIP a S3 y lanza el stack:

```bash
bash deploy.sh
```

El script:

1. Crea (si no existe) el bucket `workshop-agentes-<ACCOUNT_ID>`.
2. Empaqueta `src/lambda_function.py` en `lambda.zip`.
3. Sube `lambda.zip` a S3.
4. Ejecuta `npm install` + **esbuild** sobre `src-web/chat_lambda.js` y genera
   `chat_lambda.zip` (un solo `index.js` con el SDK de Bedrock embebido).
5. Sube `chat_lambda.zip` a S3 (parámetro `WebLambdaS3Key`).
6. **Sincroniza** los documentos `kb-data/*.md` a `s3://.../kb-data/`.
7. Ejecuta `aws cloudformation deploy` con el stack `agente-soporte`
   (incluye S3 Vectors, KB, DataSource, bucket web y Lambda demo).
8. **Publica el sitio**: reemplaza `__FUNCTION_URL__` en `web/app.js` por la
   **Lambda Function URL** del stack y hace `aws s3 sync` al bucket del website.
9. **Dispara la ingesta** (`StartIngestionJob`) y espera a que termine.
10. Genera `agent.env` con `AGENT_ID`, `ALIAS_ID`, `KNOWLEDGE_BASE_ID` y
    `DATA_SOURCE_ID` listos para usar.

El despliegue tarda ~3-5 minutos (la primera vez la ingesta puede tomar 60-90
segundos extra). Al terminar, carga las variables en tu shell:

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

## 2.2 Probar desde el navegador (Haiku vs agente en streaming)

Al finalizar `bash deploy.sh`, el script imprime una línea **Frontend URL** con el *website endpoint*
HTTP del bucket S3 (sin CloudFront). Ábrela en el navegador:

1. Escribe un prompt (por ejemplo *«¿Cómo funciona el programa TechCoins?»*).
2. Pulsa **Comparar**. Verás dos columnas en paralelo:
   - **Haiku (chatbot):** `invoke_model_with_response_stream` con el mismo *system prompt* que `invoke_chatbot.py`.
   - **Agente Bedrock:** `invoke_agent` en streaming con herramientas Lambda + Knowledge Base.

### Streaming en Lambda y runtime Node.js

Amazon Lambda solo habilita **RESPONSE_STREAM** en runtimes **Node.js** gestionados.
Por eso la función publicada es **`src-web/chat_lambda.js`** (empaquetada como `index.js`
dentro de `chat_lambda.zip` mediante esbuild). El archivo **`src-web/chat_lambda.py`**
ofrece la misma lógica para **pruebas locales** en CLI (`python chat_lambda.py …`), pero **no**
es el artefacto que ejecuta la Function URL.

### Seguridad (deuda técnica del taller)

La Lambda Function URL está configurada con **`AuthType: NONE`**: cualquiera que conozca la URL puede
invocar Bedrock en tu cuenta. Es aceptable en una sesión controlada de taller; en producción deberías
proteger el endpoint (p. ej. JWT/API Gateway, `AWS_IAM`, Amazon Cognito, WAF, etc.).

### Confirmaciones (`RequireConfirmation`)

Si el agente llega a un paso **human-in-the-loop**, la demo web solo muestra un mensaje informativo
en el stream (no hay botón **CONFIRM** en esta iteración). Para el flujo completo usa `invoke_agent.py`
(interactivo o `AUTO_CONFIRM=CONFIRM`).

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
3. En el panel "Trace" verás los `knowledgeBaseLookupInput` y los chunks
   recuperados con su URI `s3://...`.

## 3.9 RAG: el agente consulta la Knowledge Base

La carpeta `kb-data/` contiene 9 documentos en español (políticas reales,
catálogo extendido, datos demo de la empresa y del programa **TechCoins**, y
sucursales). Con `bash deploy.sh` se sincronizan a S3, se vectorizan con
`amazon.titan-embed-text-v2:0` (1024 dim) y se guardan en S3 Vectors.

### 4 escenarios RAG de un solo golpe

```bash
bash test.sh rag
```

| # | Pregunta | Esperado |
|---|---|---|
| 1 | Política de devoluciones (con producto abierto) | Cita el 90% de reembolso del documento |
| 2 | ¿Cómo funciona el programa TechCoins? | Responde con la equivalencia 1 TechCoin = $50 COP |
| 3 | Garantía de monitores | 36 meses, política 0 píxeles muertos en 14 días |
| 4 | Sucursal en Lima | El agente debe **reconocer que NO existe** y no inventar |

Para uno solo: `bash test.sh rag 1` … `bash test.sh rag 4`.

### Ver el RAG en acción (trace en vivo)

```bash
bash test.sh rag trace 2
```

Verás líneas como:

```
· [KB consulta] id=ABCD1234 → "programa TechCoins puntos por compra"
· [KB resultados] 3 fragmento(s) recuperado(s)
    1. Por cada $10.000 COP gastados (sin contar IVA y envío) ganas 20 TechCoins…
       (s3://workshop-agentes-XXX/kb-data/programa-fidelidad.md)
    2. …
```

### Chatbot vs agente con RAG

```bash
bash test.sh rag-vs-chatbot
```

- **A)** El chatbot Haiku sin RAG inventa o se rinde.
- **B)** El agente recupera de la KB y responde citando los datos del
  documento `programa-fidelidad.md`.

### Combinación tools + RAG

Pregúntale al agente cosas que mezclen la Lambda y la KB:

```bash
python invoke_agent.py --trace "Mi pedido ORD-1001 tiene 5 días, ¿es elegible para reembolso según la política?"
```

Verás cómo encadena `verificar_pedido` (Lambda) y la consulta a la KB
(política de 30 días) antes de responder.

### Re-ingestar después de editar `kb-data/`

Si modificas algún documento, vuelve a correr:

```bash
bash deploy.sh
```

`deploy.sh` re-sincroniza el bucket y dispara una nueva ingesta. Si solo
quieres re-ingestar (sin tocar el stack):

```bash
source agent.env
aws s3 sync kb-data/ "s3://workshop-agentes-$(aws sts get-caller-identity --query Account --output text)/kb-data/" --delete --exclude README.md
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "${KNOWLEDGE_BASE_ID}" \
  --data-source-id "${DATA_SOURCE_ID}"
```

> ⚠️ **Limitación importante de Bedrock:**
> No puedes cambiar la `ChunkingConfiguration` (estrategia, `MaxTokens`,
> `OverlapPercentage`, etc.) de un `DataSource` ya creado — la API de
> `UpdateDataSource` no lo permite, y CloudFormation responde con un
> `UPDATE_ROLLBACK_COMPLETE`.
>
> Si quieres probar otra estrategia (`HIERARCHICAL`, `SEMANTIC`) o nuevos
> valores de tokens/overlap, debes **recrear** el DataSource:
>
> ```bash
> bash destroy.sh && bash deploy.sh
> ```
>
> Esto borra el stack completo y lo crea desde cero con la nueva
> configuración. La ingesta inicial vuelve a tardar ~60–90 s.

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

- Razonar sobre qué fuente consultar en cada situación (`Lambda` o `KB`).
- Encadenar múltiples llamadas sin instrucciones explícitas.
- Aplicar reglas de negocio de forma inteligente.
- **Recuperar información citando documentos** y reconocer cuando no sabe algo.
- Responder en lenguaje natural a solicitudes complejas.

Tecnologías utilizadas:

- Amazon Bedrock Agents (orquestación + tool use)
- Claude Haiku 4.5 (Cross-Region Inference Profile)
- Amazon Bedrock Knowledge Bases (RAG)
- Amazon Titan Embeddings v2 (1024 dim, multilingüe)
- Amazon S3 Vectors (vector store serverless)
- AWS Lambda (Action Group Handler)
- AWS CloudFormation (IaC)
- AWS IAM

---

Desarrollado con ☁️ para AWS Community Day.
