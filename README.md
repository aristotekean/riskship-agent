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

2. Dar acceso al repositorio privado. Hermes clona con un entorno de `git` aislado
   que ignora la configuración global, así que los credential helpers de `git` no
   sirven. Hay dos opciones:

   - **GitHub CLI (recomendado)**: autenticar `gh` con un token que tenga el
     permiso `Contents` de lectura sobre el repositorio, clonar con `gh` y
     luego instalar el perfil desde el directorio local.

     ```bash
     gh auth login
     gh repo clone aristotekean/riskship-agent /root/riskship-agent
     hermes profile install /root/riskship-agent --alias -y
     ```

   - **Deploy key**: crear una clave SSH en `~/.ssh`, registrarla como deploy key
     de solo lectura en el repositorio e instalar con la URL SSH.

     ```bash
     hermes profile install git@github.com:aristotekean/riskship-agent.git --alias -y
     ```

   No incrustar tokens en la URL HTTPS: Hermes guarda el origen tal cual en el
   `distribution.yaml` del perfil y el token quedaría escrito en disco.

3. Verificar la instalación. `hermes profile install` crea
   `~/.hermes/profiles/riskship`, copia los archivos del agente, genera
   `.env.EXAMPLE` a partir de `distribution.yaml` y deja el alias `riskship`
   como atajo de `hermes -p riskship`.

   ```bash
   hermes profile list
   ```

4. Cargar los secretos. Copiar `.env.EXAMPLE` a `.env` dentro del perfil y completar
   las variables. Ver [Variables de entorno](#variables-de-entorno).

5. Instalar el gateway como servicio del sistema. Sin él, los cron jobs nunca se
   ejecutan:

   ```bash
   sudo hermes -p riskship gateway install --system --run-as-user <usuario>
   ```

   Crea la unidad `hermes-gateway-riskship` en systemd, que arranca al boot y corre
   el scheduler.

6. Habilitar el bus de usuario para el servicio. Hermes lanza cada ejecución de
   cron dentro de un scope transitorio (`systemd-run --user --scope`) y falla si no
   puede crearlo. Un servicio de sistema no tiene bus D-Bus de usuario, y la unidad
   generada no lo configura, así que sin este paso el cron dispara a tiempo pero
   la ejecución termina en `systemd-run --user --scope is unavailable`.

   Reemplazar `<usuario>` y `<uid>` por el usuario del paso anterior (`id -u <usuario>`):

   ```bash
   sudo loginctl enable-linger <usuario>
   sudo systemctl start user@<uid>.service
   sudo mkdir -p /etc/systemd/system/hermes-gateway-riskship.service.d
   sudo tee /etc/systemd/system/hermes-gateway-riskship.service.d/user-bus.conf > /dev/null <<'EOF'
   [Service]
   Environment="XDG_RUNTIME_DIR=/run/user/<uid>"
   Environment="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus"
   EOF
   sudo systemctl daemon-reload
   sudo systemctl restart hermes-gateway-riskship
   ```

   El drop-in es un archivo aparte de la unidad, así que sobrevive si Hermes la
   regenera. Comprobar que el scope se puede crear:

   ```bash
   XDG_RUNTIME_DIR=/run/user/<uid> DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus \
     systemd-run --user --scope --collect /bin/true && echo OK
   ```

### Verificación

```bash
hermes -p riskship cron list
hermes -p riskship cron run trm-diario-linear
```

Si el segundo comando termina en `succeeded` y aparece un issue nuevo en Linear, el
agente está operativo.

### Actualizar el agente

`profile update` relee desde el origen registrado al instalar. Si el perfil se
instaló desde el clon local, primero hay que actualizar ese clon:

```bash
git -C /root/riskship-agent pull
hermes profile update riskship -y
```

Si se instaló con deploy key, alcanza con el segundo comando: Hermes vuelve a
clonar el repositorio. En ambos casos `.env`, bases de datos y estado de ejecución
se conservan.

#### Cambios en `config.yaml`

`profile update` **no** sobrescribe un `config.yaml` existente, para conservar los
ajustes locales del servidor. Un cambio versionado en ese archivo (por ejemplo, un
servidor MCP nuevo) no llega al perfil instalado con el update normal.

| Caso | Qué hacer en el VPS |
|------|---------------------|
| Cambio aditivo (servidor MCP) | Repetir el mismo comando que lo generó, por ejemplo `hermes -p riskship mcp add ...`. No toca el resto del archivo. |
| Dejar el VPS idéntico al repositorio | `hermes profile update riskship --force-config -y`. Descarta los ajustes locales. |

Antes de usar `--force-config`, comparar ambos archivos:

```bash
diff /root/riskship-agent/config.yaml ~/.hermes/profiles/riskship/config.yaml
```

Después de cualquier cambio en `config.yaml`, reiniciar el gateway:

```bash
sudo systemctl restart hermes-gateway-riskship
```

#### Memoria persistente (Engram)

El agente usa [Engram](https://github.com/Gentleman-Programming/engram) como
servidor MCP por stdio. El binario se instala aparte y debe quedar en
`/usr/local/bin`, que está en el `PATH` por defecto de systemd:

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
curl -fsSL -o /tmp/engram.tgz "https://github.com/Gentleman-Programming/engram/releases/download/v2.0.0/engram_2.0.0_linux_${ARCH}.tar.gz"
sudo tar -xzf /tmp/engram.tgz -C /usr/local/bin engram
hermes -p riskship mcp test engram
```

En una instalación nueva el servidor ya viene declarado en `config.yaml`. Si el
perfil se instaló antes de ese cambio, `mcp test` responde `not found in config` y
hay que agregarlo a mano:

```bash
hermes -p riskship mcp add engram --command engram --args mcp --tools=agent --project riskship-runtime
```

`--project riskship-runtime` separa las memorias del agente de las notas de
desarrollo del repositorio. La base de datos queda en `~/.engram/engram.db` del
usuario que ejecuta el gateway y no se sincroniza entre máquinas.

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
