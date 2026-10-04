---
name: riesgo-envio
description: "Evalúa el riesgo de pérdida de un envío con la red neuronal RiskShip y crea un ticket en Linear cuando supera el umbral (65 % por defecto)."
version: 1.0.0
author: Riskship
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [riskship, riesgo, envios, linear, inferencia, red-neuronal]
    requires_toolsets: [terminal]
required_environment_variables:
  - name: LINEAR_API_KEY
    prompt: "API key personal de Linear"
    help: "Se usa para crear el ticket. El script la lee de $HERMES_HOME/.env si no está exportada."
    required_for: "crear tickets"
  - name: LINEAR_TEAM_KEY
    prompt: "Clave del equipo de Linear (por ejemplo RIS)"
    help: "Opcional. Sin ella se usa el primer equipo visible para la API key."
    required_for: "elegir el equipo del ticket"
---

# Riesgo de pérdida de envío

Ejecuta la red neuronal entrenada en el proyecto `riskship-rna`, cuya copia exportada
vive en este skill (`model/riskship_rna_model.pickle`, con sus metadatos en
`model/riskship_rna_model.json`), sobre uno o más envíos; informa la probabilidad de
pérdida estimada **al momento de la creación del envío** y abre un ticket en Linear por
cada envío cuya probabilidad supere el umbral. El skill es autónomo: no necesita el
repositorio del proyecto, solo `uv` en el host. `scripts/predict_risk.py` declara sus
dependencias inline con las versiones exactas con las que se escribió el pickle, y la
primera ejecución las descarga.

## Cuándo usar

- El usuario pide evaluar, puntuar o predecir el riesgo de pérdida de un envío.
- El usuario entrega los datos de un envío (JSON o campos sueltos) o un `SHIPMENT_ID`.
- Un job programado debe revisar envíos nuevos y escalar los riesgosos a Linear. El
  cron `riesgo-envio-neon` ya lo hace con `scripts/neon_fetch_shipments.sh` (perfil),
  que lee la tabla `shipments` de Neon (espejo de `dataset.parquet`, creada y cargada
  desde el proyecto `riskship-rna` con `load_neon.py`); en ese caso
  el agente solo resume la salida y no vuelve a ejecutar nada.

## Referencia rápida

Un solo script hace todo: inferencia y ticket.

```bash
S="$HERMES_HOME/skills/riesgo-envio/scripts/evaluar_riesgo.sh"
echo '{"SHIPMENT_ID":"X", ...}' | bash "$S" -  # un envío entregado por el usuario (JSON por stdin)
bash "$S" envio.json                           # uno o varios envíos desde un archivo JSON
bash "$S" --dry-run envio.json                 # solo puntuar, sin tocar Linear
bash "$S" --threshold 0.80 envio.json          # otro umbral
# Con RISKSHIP_DATASET apuntando a un dataset.parquet del proyecto, también:
RISKSHIP_DATASET=/ruta/dataset.parquet bash "$S" --shipment-id 46411999224
RISKSHIP_DATASET=/ruta/dataset.parquet bash "$S" --dry-run --sample 3
```

Columnas que el modelo necesita (las demás se ignoran): `PICKING_TYPE`,
`SHP_LG_FACILITY_ID`, `DOM_DOMAIN_ID`, `ORD_CATEGORY_NAME_L1`, `BRAND_NAME`,
`TIPO_BULKY` (puede ser null), `PESO_TOTAL_KG`, `DIM_MAX_CM`, `VALOR_TOTAL_USD`,
`CANTIDAD_ITEMS`, `RATIO_SVC_MES_ANTERIOR`, `ES_BULKY` y `date_status_0`
(fecha y hora de creación, ISO 8601; solo se usa su día de la semana).

## Procedimiento

1. Reunir los datos del envío. Si el usuario da campos sueltos, armar el JSON con
   los nombres de columna exactos de arriba. Si falta alguno, preguntarlo; no
   inventar valores.
2. Si el usuario solo quiere ver el resultado, o hay dudas sobre los datos, correr
   primero con `--dry-run`.
3. Correr el script. Imprime una línea por envío con su probabilidad y, para los
   que superan el umbral, llama a `scripts/linear_create_issue.sh` y muestra
   `created <IDENTIFICADOR> <url>`.
4. Responder con: probabilidad por envío, si superó el umbral, y el identificador
   y la URL del ticket cuando se creó. Si el script falla, reportar el error tal
   cual y no afirmar que el ticket existe.

## Cómo interpretar

- La probabilidad está en la escala de la muestra de entrenamiento, que
  sobrerrepresenta las pérdidas. En operación real una alerta de 65 % no significa
  que dos de cada tres envíos se pierdan; significa que el envío se parece a los
  que se perdieron. Decirlo así, sin inferir causas.
- El modelo solo ve atributos conocidos al crear el envío. No usa el historial de
  estados posterior y no diagnostica qué salió mal.

## Errores comunes

- `missing .../model/riskship_rna_model.pickle`: falta el modelo en el skill. Se regenera
  con `uv run export_model.py` en el proyecto `riskship-rna` y se copian el `.pickle` y
  el `.json` de `exports/` a `model/`.
- `uv is required`: instalar `uv` en el host (`curl -LsSf https://astral.sh/uv/install.sh | sh`).
- `input is missing columns`: el JSON no trae alguna columna requerida.
- `LINEAR_API_KEY is not set`: la variable no está en el entorno ni en `$HERMES_HOME/.env`.
- `team key ... not found`: `LINEAR_TEAM_KEY` no coincide con ningún equipo visible.
- `--shipment-id` y `--sample` requieren `RISKSHIP_DATASET`; sin dataset, solo JSON.

## Verificación

- Un ticket existe solo si el script imprimió `created <ID> <url>`.
- En `--dry-run` no se crea nada, aunque la salida muestre el ticket completo.
