# Homestead Minecraft Server - Docker

[![Docker Image Version](https://img.shields.io/docker/v/dkge/homestead-docker?logo=docker&label=Docker%20Hub)](https://hub.docker.com/r/dkge/homestead-docker)
[![Docker Pulls](https://img.shields.io/docker/pulls/dkge/homestead-docker?logo=docker&label=Pulls)](https://hub.docker.com/r/dkge/homestead-docker)

Run the Homestead modded Minecraft server with Docker. Java and the Fabric runtime are installed inside the image.

## Requirements

- Docker Desktop or Docker Engine with Compose
- 12-16 GB of memory available to Docker for the default 10 GB server allocation
- The official Homestead server-pack ZIP

## Quick start

1. Download the latest [Homestead server pack](https://cozystudios.org/homestead/server-pack/).
2. Place the ZIP in the `zip/` directory without extracting it.
3. Start the server:

   ```bash
   docker compose up -d
   ```

4. Follow startup until Minecraft reports `Done`:

   ```bash
   docker compose logs -f
   ```

5. Connect to `localhost:25565`.

The first startup downloads Minecraft and Fabric and can take several minutes.

### Optional automatic server-pack download

Manual ZIP selection remains the default. To opt in, set one of these values in the Compose `environment` section:

```yaml
VERSION: latest  # Follow the newest official server pack
# VERSION: "1.3.7"  # Pin one exact version instead
```

An exact version is selected even when newer ZIPs are present in `zip/`. It does not disable the downgrade guard: use a backup restore for an intentional rollback. Downloads are validated and moved atomically into `server-data/.serverpack-cache/`; cached exact versions do not require another network request, while `latest` checks the official page for updates on each start. Unset `VERSION` to return to manual local ZIP selection.

## Commands

```bash
docker compose pull           # Download the newest published image
docker compose up -d          # Create and start
docker compose stop           # Graceful stop and world save
docker compose restart        # Restart
docker compose logs -f        # Follow logs
docker compose down           # Remove the container and network; data remains
```

## Updating Homestead

1. Keep the old pack ZIP in `zip/` and add the newer server-pack ZIP.
2. Restart with `docker compose restart`.
3. The entrypoint selects the highest version, backs up the existing server, replaces Homestead-managed directories, preserves world and operator settings, and installs the pack's requested Fabric runtime.

Backups are written to `server-data/backups/`. Updates replace all six pack-managed directories (`config/`, `defaultconfigs/`, `kubejs/`, `mods/`, `patchouli_books/`, and `scripts/`) so removed files cannot leak into the new version. Custom mods must be re-added after an update.

Downgrades are blocked automatically. Restore a backup instead of attempting to install an older pack over a newer world.

## Updating the Docker image

Pull the newest image and recreate the container without removing persistent server data:

```bash
docker compose pull
docker compose up -d
```

## Restoring a backup

1. Copy the desired backup from `server-data/backups/` into `zip/`.
2. Set `RESTORE_BACKUP` in `docker-compose.yml` to that exact filename.
3. Run `docker compose up -d`.
4. Confirm the restored server starts, then remove `RESTORE_BACKUP` from Compose to resume normal pack updates.

The same backup is restored only once while `RESTORE_BACKUP` remains set, preventing every restart from overwriting new progress.

## Settings

Edit `docker-compose.yml`:

```yaml
environment:
  MEMORY: 10G
  EULA: "true"
```

`MEMORY` accepts whole-number values such as `8192M`, `8G`, `10G`, or `12G`, with a minimum of 2 GB. Leave enough memory for Docker and the host operating system.

Setting `EULA=true` records acceptance of the [Minecraft EULA](https://www.minecraft.net/eula).

## Data and ports

- `zip/`: read-only server-pack and restore archives
- `server-data/`: worlds, configuration, generated runtime, backups, and the automatic-download cache
- `25565/tcp`: Minecraft
- `24454/udp`: proximity voice chat

Both local directories are ignored by Git.

## Validation

Run the regression suite before publishing an image:

```bash
./tests/entrypoint_test.sh
docker compose config
docker build -t homestead-docker:local .
```

## Troubleshooting

- **No server pack found:** Ensure the ZIP filename contains a version such as `1.3.7`.
- **Automatic download fails:** Check access to `cozystudios.org` and Google Drive. A failed or invalid download is discarded without changing the installed server.
- **Out of memory:** Increase Docker's memory allocation or lower `MEMORY`.
- **Cannot connect:** Wait for `Done` in `docker compose logs -f`.
- **Update is rejected:** The selected ZIP is older than `.installed`; restore a backup for intentional rollbacks.
- **Restore does not repeat:** Remove `RESTORE_BACKUP`, start once, then set it again or rename the backup file for an intentional second restore.
