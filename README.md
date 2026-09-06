# Riskship

Agente de monitoreo de anomalías construido sobre [Hermes Agent](https://hermes-agent.nousresearch.com).
Corre sin supervisión, detecta anomalías y las reporta como issues en Linear.
Este repositorio es una *distribución de perfil* de Hermes: contiene la identidad,
la configuración, los cron jobs y los scripts del agente, pero nunca los secretos.

## Despliegue en una VPS

Requisitos del servidor: Linux, Python 3.11 a 3.13, `git`, `curl` y `python3` en el
`PATH`, y un usuario con `sudo`.

1. Instalar Hermes:

   ```bash
   curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
   ```

2. Dar acceso al repositorio privado. El instalador clona con el `git` del sistema,
   así que la VPS necesita una deploy key de GitHub en `~/.ssh` o un token HTTPS de
   solo lectura.

3. Instalar el perfil desde el repositorio:

   ```bash
   hermes profile install git@github.com:aristotekean/riskship-agent.git --alias -y
   ```

   Crea `~/.hermes/profiles/riskship`, copia los archivos del agente, genera
   `.env.EXAMPLE` a partir de `distribution.yaml` y deja el alias `riskship`
   como atajo de `hermes -p riskship`.

4. Cargar los secretos. Copiar `.env.EXAMPLE` a `.env` dentro del perfil y completar
   las variables. Ver [Variables de entorno](#variables-de-entorno).

5. Instalar el gateway como servicio del sistema. Sin él, los cron jobs nunca se
   ejecutan:

   ```bash
   sudo hermes -p riskship gateway install --system --run-as-user <usuario>
   ```

   Crea la unidad `hermes-gateway-riskship` en systemd, que arranca al boot y corre
   el scheduler.

### Verificación

```bash
hermes -p riskship cron list
hermes -p riskship cron run trm-diario-linear
```

Si el segundo comando termina en `succeeded` y aparece un issue nuevo en Linear, el
agente está operativo.

### Actualizar el agente

```bash
hermes -p riskship profile update
```

Vuelve a clonar el repositorio y aplica los cambios. `.env`, bases de datos y estado
de ejecución se conservan.

## Variables de entorno

| Variable | Obligatoria | Uso |
|----------|-------------|-----|
| `FIREWORKS_API_KEY` | Sí | Inferencia del modelo. Las keys de Fireworks empiezan con `fw_`. |
| `LINEAR_API_KEY` | Sí | Crear issues en Linear. Necesita permiso de escritura. |
| `LINEAR_TEAM_KEY` | No | Clave del equipo de Linear (por ejemplo `RIS`). Si falta, se usa el primer equipo visible. |
| `NEON_READONLY_URL` | No | Postgres de Neon, solo lectura. Reservada para los cron de detección; aún no se usa. |

## Estructura del repositorio

| Ruta | Contenido |
|------|-----------|
| `distribution.yaml` | Manifiesto de la distribución: versión, requisitos y variables de entorno. |
| `SOUL.md` | Identidad y valores del agente. |
| `config.yaml` | Modelo, proveedor, zona horaria (`America/Bogota`) y backend de terminal. |
| `cron/jobs.json` | Definición de los cron jobs. Hermes también escribe aquí el estado de cada ejecución. |
| `scripts/` | Scripts auxiliares que usan los cron jobs. |

## Cron jobs

| Job | Horario | Qué hace |
|-----|---------|----------|
| `trm-diario-linear` | Diario, 14:00 Colombia | Obtiene la TRM oficial USD/COP desde datos.gov.co y crea un issue en Linear con el valor y su vigencia. |

Los scripts corren con el `python3` del sistema, no con el entorno virtual de Hermes.
Evitar sintaxis de Python 3.12 o superior en `scripts/`.

## Qué no va en el repositorio

`.env`, `auth.json`, bases de datos (`state.db`, `executions.db`), cachés y las skills
que trae Hermes de fábrica. El `.gitignore` es una lista blanca: cualquier archivo nuevo
que deba versionarse hay que agregarlo explícitamente.
