# Homestead Minecraft Server - Docker

Run the Homestead modded Minecraft server in Docker.

## Download

- **Server Pack**: [Get from Wiki](https://github.com/CozyCord/homestead/wiki/Server-Pack)
- **Client**: [Download from CurseForge](https://www.curseforge.com/minecraft/modpacks/homestead-cozy)

## Quick Start

1. Download server pack zip and place in `zip/` folder
2. Run: `docker-compose up -d --build`
3. Connect to `localhost:25565`

First startup takes 3-5 minutes.

## Commands

```bash
docker-compose up -d       # Start
docker-compose stop        # Stop
docker-compose restart     # Restart
docker-compose logs -f     # View logs
docker-compose down        # Remove
```

## Updating

1. Place new version zip in `zip/` folder
2. Run: `docker-compose restart`
3. Old version is backed up automatically to `server-data/`

## Restore Backup

1. Copy backup zip (with `-backup-` in name) to `zip/` folder
2. Run: `docker-compose restart`

## Settings

Edit `docker-compose.yml`:

```yaml
environment:
  - MEMORY=10G      # 512M, 2G, 4G, 6G, 8G, 12G, etc.
  - EULA=true      # Must be true to start
```

## Troubleshooting

- **Won't start**: Check `EULA=true` in docker-compose.yml
- **Out of memory**: Increase `MEMORY=10G` to `MEMORY=8G` or higher
- **Can't connect**: Wait for "Done!" in logs

View logs: `docker-compose logs -f`
